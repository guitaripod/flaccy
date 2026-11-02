use crate::db::{Db, LyricsContent, LyricsRow};
use crate::library::Track;
use flaccy_shared::lyrics::{
    best_candidate, clean_title, lead_artist, next_retry, parse_lrc, parse_lyricsfile,
    tries_next_question, Candidate, Document, LyricsFailure, Retry, Wanted,
};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// The generation of the lyrics pipeline that stores rows. Rows saved before
/// line ends and word timing existed hold content that a second look at the
/// server can improve, so they are asked for once more.
const REVISION: i64 = 2;

/// A lyrics answer can be a minute of the server's patience; past this the
/// request is given up on and the panel offers Try Again.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
/// The pause before the one retry of a request the server turned away, when it
/// does not say how long to wait, and the bounds on what it may ask for.
const DEFAULT_RETRY_WAIT: f64 = 0.8;
const SHORTEST_RETRY_WAIT: f64 = 0.3;
const LONGEST_RETRY_WAIT: f64 = 3.0;

/// How long a remembered miss stands before lrclib is asked again — the corpus
/// is community-contributed and grows.
const MISS_TTL_DAYS: f64 = 30.0;

/// A miss is stored already this many days old, at most, so a library fetched
/// in one afternoon does not come due for a second pass all at once.
const MISS_JITTER_DAYS: f64 = 7.5;

/// One track's lyrics together with the listener's own timing correction.
#[derive(Clone, Default)]
pub struct Lyrics {
    pub document: Document,
    pub offset_ms: i64,
}

impl Lyrics {
    /// The correction in seconds, positive meaning every line comes later.
    pub fn offset_seconds(&self) -> f64 {
        self.offset_ms as f64 / 1000.0
    }

    /// The moment of the song to look up for a playback position: the position
    /// less the correction.
    pub fn song_time(&self, position: f64) -> f64 {
        position - self.offset_seconds()
    }

    /// The sung line at a playback position, for surfaces that show one line.
    pub fn text_at(&self, position: f64) -> Option<&str> {
        self.document.text_at(self.song_time(position))
    }
}

/// Distinguishes "lrclib has nothing for this track" from "we couldn't ask",
/// and says why we couldn't. A miss is cached (and expires); a failure is not,
/// so a flaky network never leaves a permanently blank panel.
#[derive(Clone)]
pub enum LyricsResult {
    Found(Lyrics),
    Missing,
    Failed(LyricsFailure),
}

/// Where lrclib is. `FLACCY_LRCLIB_URL` names a stand-in for drills that need
/// the server to misbehave: a 503 for a minute, a 429 with a long `Retry-After`.
fn lrclib_base() -> String {
    std::env::var("FLACCY_LRCLIB_URL")
        .ok()
        .map(|url| url.trim().trim_end_matches('/').to_string())
        .filter(|url| !url.is_empty())
        .unwrap_or_else(|| "https://lrclib.net".to_string())
}

fn user_agent() -> String {
    format!(
        "flaccy/{} (https://github.com/guitaripod/flaccy)",
        env!("CARGO_PKG_VERSION")
    )
}

/// Builds the document a stored or fetched answer describes. A Lyricsfile wins
/// when it reads cleanly and holds synchronized lines; otherwise the LRC text
/// does.
fn document_from(
    synced: Option<&str>,
    plain: Option<&str>,
    lyricsfile: Option<&str>,
    instrumental: bool,
) -> Document {
    if instrumental {
        return Document {
            instrumental: true,
            ..Document::default()
        };
    }
    let from_file = lyricsfile
        .and_then(parse_lyricsfile)
        .filter(Document::has_synced);
    let mut document = match (from_file, synced) {
        (Some(document), _) => document,
        (None, Some(synced)) => parse_lrc(synced),
        (None, None) => Document::default(),
    };
    if document.plain.is_none() {
        document.plain = plain
            .filter(|text| !text.trim().is_empty())
            .map(str::to_string);
    }
    document
}

fn lyrics_from_row(row: &LyricsRow) -> Lyrics {
    Lyrics {
        document: document_from(
            row.synced.as_deref(),
            row.plain.as_deref(),
            row.lyricsfile.as_deref(),
            row.instrumental,
        ),
        offset_ms: row.offset_ms,
    }
}

fn has_content(row: &LyricsRow) -> bool {
    row.instrumental
        || is_filled(row.synced.as_deref())
        || is_filled(row.plain.as_deref())
        || is_filled(row.lyricsfile.as_deref())
}

fn is_filled(text: Option<&str>) -> bool {
    text.is_some_and(|text| !text.trim().is_empty())
}

/// A row is served as it stands unless it is a miss old enough to ask again
/// about, or holds content from before the current pipeline revision.
fn is_current(row: &LyricsRow) -> bool {
    if has_content(row) {
        row.revision >= REVISION
    } else {
        row.age_days <= MISS_TTL_DAYS
    }
}

/// Whether the track's lyrics need no lookup: a current answer is stored,
/// found or missing.
pub fn is_cached(db: &Db, track: &Track) -> bool {
    db.fetch_lyrics(&track.title, &track.artist)
        .as_ref()
        .is_some_and(is_current)
}

fn found_or_missing(lyrics: Lyrics) -> LyricsResult {
    if lyrics.document.is_empty() {
        LyricsResult::Missing
    } else {
        LyricsResult::Found(lyrics)
    }
}

/// The lookup without a settle gate, for tests that read it straight.
#[cfg(test)]
pub fn fetch_blocking(db_path: &Path, music_root: &Path, track: &Track) -> LyricsResult {
    resolve(db_path, music_root, track, None).unwrap_or(LyricsResult::Missing)
}

/// Resolution order: the local database cache, then lyrics the user keeps
/// alongside the audio (`.lrc` sidecar or an embedded tag), then lrclib. A
/// cached answer from an older pipeline revision is shown if the server cannot
/// improve on it, and a cached miss never hides a file the listener has added
/// since. An unreadable cache costs only the memory, never the lookup.
///
/// `settled` is asked once the cache and the local files have had their say and
/// before lrclib is called: answering false abandons the lookup (`None`)
/// instead of spending a request on a track the listener has already skipped
/// away from.
fn resolve(
    db_path: &Path,
    music_root: &Path,
    track: &Track,
    settled: Option<&dyn Fn() -> bool>,
) -> Option<LyricsResult> {
    let db = Db::open(db_path).ok();
    let cached = db
        .as_ref()
        .and_then(|db| db.fetch_lyrics(&track.title, &track.artist));
    if let Some(row) = cached
        .as_ref()
        .filter(|row| is_current(row) && has_content(row))
    {
        return Some(found_or_missing(lyrics_from_row(row)));
    }
    let offset_ms = cached.as_ref().map_or(0, |row| row.offset_ms);

    if let Some(local) = read_local(&music_root.join(&track.rel_path)) {
        let content = LyricsContent {
            synced: local.synced_raw.clone(),
            plain: local.plain.clone(),
            lyricsfile: None,
            instrumental: false,
            revision: REVISION,
        };
        if let Some(db) = &db {
            let _ = db.save_lyrics(&track.title, &track.artist, &content);
        }
        return Some(found_or_missing(Lyrics {
            document: document_from(local.synced_raw.as_deref(), local.plain.as_deref(), None, false),
            offset_ms,
        }));
    }
    if cached.as_ref().is_some_and(is_current) {
        return Some(LyricsResult::Missing);
    }

    let stale = cached.as_ref().filter(|row| has_content(row));
    if settled.is_some_and(|settled| !settled()) {
        return None;
    }
    Some(match lookup_remote(track) {
        Remote::Found(fetched) => {
            let content = LyricsContent {
                synced: fetched.synced.clone(),
                plain: fetched.plain.clone(),
                lyricsfile: fetched.lyricsfile.clone(),
                instrumental: fetched.instrumental,
                revision: REVISION,
            };
            if let Some(db) = &db {
                let _ = db.save_lyrics(&track.title, &track.artist, &content);
            }
            found_or_missing(Lyrics {
                document: document_from(
                    fetched.synced.as_deref(),
                    fetched.plain.as_deref(),
                    fetched.lyricsfile.as_deref(),
                    fetched.instrumental,
                ),
                offset_ms,
            })
        }
        Remote::Missing => match stale {
            Some(row) => {
                if let Some(db) = &db {
                    let _ = db.set_lyrics_revision(&track.title, &track.artist, REVISION);
                }
                found_or_missing(lyrics_from_row(row))
            }
            None => {
                if let Some(db) = &db {
                    let _ = db.save_lyrics(
                        &track.title,
                        &track.artist,
                        &LyricsContent {
                            synced: None,
                            plain: None,
                            lyricsfile: None,
                            instrumental: false,
                            revision: REVISION,
                        },
                    );
                }
                if let Some(db) = &db {
                    let _ = db.age_lyrics(
                        &track.title,
                        &track.artist,
                        rand::random::<f64>() * MISS_JITTER_DAYS,
                    );
                }
                crate::logger::info(
                    "lyrics",
                    &format!(
                        "no lyrics for {} — {} (cached miss)",
                        track.title, track.artist
                    ),
                );
                LyricsResult::Missing
            }
        },
        Remote::Failed(failure) => match stale {
            Some(row) => found_or_missing(lyrics_from_row(row)),
            None => LyricsResult::Failed(failure),
        },
    })
}

/// How long a track has to stay the wanted one before lrclib is asked about it,
/// so skipping through a queue costs the cache reads and nothing on the
/// network.
const SETTLE_DELAY: Duration = Duration::from_millis(300);

/// Whether a lookup may go to the network right away or only once the track
/// has stayed wanted for `SETTLE_DELAY`.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Pace {
    Settled,
    Immediate,
}

/// The track the player is on, as far as lookups are concerned.
static WANTED: Mutex<Option<String>> = Mutex::new(None);

/// One lookup running on behalf of every caller that asks for the same track.
struct Flight {
    key: String,
    outcome: Mutex<Option<Option<LyricsResult>>>,
    done: Condvar,
}

static FLIGHTS: Mutex<Vec<Arc<Flight>>> = Mutex::new(Vec::new());

fn flight_key(track: &Track) -> String {
    format!("{}\u{1f}{}\u{1f}{}", track.rel_path, track.title, track.artist)
}

/// Records which track is current, so a lookup that waits out `SETTLE_DELAY`
/// can tell whether it is still wanted.
pub fn want(track: &Track) {
    if let Ok(mut wanted) = WANTED.lock() {
        *wanted = Some(flight_key(track));
    }
}

fn is_wanted(key: &str) -> bool {
    WANTED
        .lock()
        .map(|wanted| wanted.as_deref() == Some(key))
        .unwrap_or(true)
}

/// Publishes a flight's outcome and retires it, also when the leader panics.
struct Leader {
    flight: Arc<Flight>,
}

impl Leader {
    fn finish(&self, outcome: Option<LyricsResult>) {
        if let Ok(mut flights) = FLIGHTS.lock() {
            flights.retain(|flight| !Arc::ptr_eq(flight, &self.flight));
        }
        if let Ok(mut slot) = self.flight.outcome.lock() {
            if slot.is_none() {
                *slot = Some(outcome);
            }
        }
        self.flight.done.notify_all();
    }
}

impl Drop for Leader {
    fn drop(&mut self) {
        self.finish(None);
    }
}

/// Joins the lookup already running for `key`, or starts one: `Ok` is the
/// flight to wait on, `Err` the leader that has to run it.
fn join_or_lead(key: &str) -> Result<Arc<Flight>, Leader> {
    let Ok(mut flights) = FLIGHTS.lock() else {
        return Err(Leader {
            flight: Arc::new(Flight {
                key: key.to_string(),
                outcome: Mutex::new(None),
                done: Condvar::new(),
            }),
        });
    };
    if let Some(flight) = flights.iter().find(|flight| flight.key == key) {
        return Ok(Arc::clone(flight));
    }
    let flight = Arc::new(Flight {
        key: key.to_string(),
        outcome: Mutex::new(None),
        done: Condvar::new(),
    });
    flights.push(Arc::clone(&flight));
    Err(Leader { flight })
}

/// `fetch_blocking` for callers that may overlap: while one thread is looking
/// a track up, another asking for the same track waits for that answer instead
/// of repeating the request and the database write. Cache and local-file reads
/// are immediate; with `Pace::Settled` the network is only used once the track
/// has stayed wanted for `SETTLE_DELAY`, and `None` means it was skipped away
/// from first.
pub fn fetch_shared(
    db_path: &Path,
    music_root: &Path,
    track: &Track,
    pace: Pace,
) -> Option<LyricsResult> {
    let key = flight_key(track);
    match join_or_lead(&key) {
        Ok(flight) => {
            let mut outcome = flight.outcome.lock().ok()?;
            while outcome.is_none() {
                outcome = flight.done.wait(outcome).ok()?;
            }
            (*outcome).clone().flatten()
        }
        Err(leader) => {
            let settle = || {
                std::thread::sleep(SETTLE_DELAY);
                is_wanted(&key)
            };
            let gate: Option<&dyn Fn() -> bool> = match pace {
                Pace::Settled => Some(&settle),
                Pace::Immediate => None,
            };
            let result = resolve(db_path, music_root, track, gate);
            leader.finish(result.clone());
            result
        }
    }
}

/// How often a wait between retries looks at whether anyone still wants the
/// answer.
const WAIT_SLICE: Duration = Duration::from_millis(250);

/// Sleeps for `seconds` in slices and says whether the answer is still wanted
/// afterwards: not once the listener moved to another track, `stop` was raised
/// or the receiving end went away.
fn keep_waiting(
    seconds: f64,
    still_wanted: &dyn Fn() -> bool,
    stop: &AtomicBool,
    tx: &async_channel::Sender<Option<LyricsResult>>,
) -> bool {
    let until = Instant::now() + Duration::from_secs_f64(seconds);
    loop {
        if stop.load(Ordering::Relaxed) || tx.is_closed() || !still_wanted() {
            return false;
        }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return true;
        }
        std::thread::sleep(left.min(WAIT_SLICE));
    }
}

/// `fetch_shared` for the lyrics a listener is waiting on: a lookup lrclib
/// could not answer is asked again with growing pauses, out of sight, instead
/// of being reported at once. The answer goes to `tx` (`None` when the track
/// was skipped away from first); a failure that outlasts the quiet window is
/// sent once, and the pauses go on at a slow pace so the lyrics still arrive
/// when lrclib returns. The lookup ends with `stop`, with the track no longer
/// being the wanted one, or with `tx` closing.
pub fn fetch_patient(
    db_path: &Path,
    music_root: &Path,
    track: &Track,
    pace: Pace,
    stop: &AtomicBool,
    tx: &async_channel::Sender<Option<LyricsResult>>,
) {
    let key = flight_key(track);
    let mut pace = pace;
    let mut failures = 0;
    loop {
        let outcome = fetch_shared(db_path, music_root, track, pace);
        pace = Pace::Immediate;
        let Some(LyricsResult::Failed(failure)) = outcome else {
            let _ = tx.send_blocking(outcome);
            return;
        };
        failures += 1;
        let cooldown = crate::precache::LRCLIB.cooldown_left().as_secs_f64();
        let pause = match next_retry(failure, failures, cooldown) {
            Retry::GiveUp => {
                let _ = tx.send_blocking(Some(LyricsResult::Failed(failure)));
                return;
            }
            Retry::Show(pause) => {
                if tx
                    .send_blocking(Some(LyricsResult::Failed(failure)))
                    .is_err()
                {
                    return;
                }
                pause
            }
            Retry::Quietly(pause) => pause,
        };
        if !keep_waiting(pause, &|| is_wanted(&key), stop, tx) {
            return;
        }
    }
}

/// Remembers the listener's timing correction for a track's lyrics.
pub fn save_offset(db_path: &Path, track: &Track, offset_ms: i64) {
    if let Ok(db) = Db::open(db_path) {
        let _ = db.save_lyrics_offset(&track.title, &track.artist, offset_ms);
    }
}

struct Fetched {
    synced: Option<String>,
    plain: Option<String>,
    lyricsfile: Option<String>,
    instrumental: bool,
}

enum Remote {
    Found(Fetched),
    Missing,
    Failed(LyricsFailure),
}

enum Reply {
    Body(String),
    NotFound,
    Failed(LyricsFailure),
}

/// One question put to lrclib on the way to a song's lyrics.
enum Question<'a> {
    Exact {
        title: &'a str,
        artist: &'a str,
        album: Option<&'a str>,
    },
    Search {
        title: &'a str,
        artist: &'a str,
    },
}

/// lrclib's exact-match endpoint is strict about the album name and about the
/// title as tagged, which are the commonest causes of a false 404. So: try the
/// full signature, then drop the album, then the title and artist with edition
/// decoration and featuring credits removed, then the fuzzy search endpoint,
/// ranking its results here (the endpoint itself is duration-blind).
fn lookup_remote(track: &Track) -> Remote {
    let agent = ureq::AgentBuilder::new().timeout(REQUEST_TIMEOUT).build();
    let ua = user_agent();
    lookup_through(track, &mut |question| match question {
        Question::Exact {
            title,
            artist,
            album,
        } => get_exact(&agent, &ua, title, artist, *album, track.duration),
        Question::Search { title, artist } => search_fallback(&agent, &ua, track, title, artist),
    })
}

/// Asks the questions in order until one is answered with lyrics. A question
/// lrclib answered "busy" does not end the lookup, because lrclib is still
/// working on it and the plainer ones after it are often answered at once; if
/// none of the others finds the song either, the lookup failed rather than
/// came up empty, since the busy question might have found it. Any other
/// failure ends the lookup, as the server is not answering at all.
fn lookup_through(track: &Track, ask: &mut dyn FnMut(&Question) -> Remote) -> Remote {
    let title = clean_title(&track.title);
    let artist = lead_artist(&track.artist);

    let mut questions: Vec<Question> = Vec::new();
    if !track.album.trim().is_empty() {
        questions.push(Question::Exact {
            title: &track.title,
            artist: &track.artist,
            album: Some(&track.album),
        });
    }
    questions.push(Question::Exact {
        title: &track.title,
        artist: &track.artist,
        album: None,
    });
    if title != track.title || artist != track.artist {
        questions.push(Question::Exact {
            title: &title,
            artist: &artist,
            album: None,
        });
    }
    questions.push(Question::Search {
        title: &title,
        artist: &artist,
    });

    let mut busy = None;
    for question in &questions {
        match ask(question) {
            Remote::Found(fetched) => return Remote::Found(fetched),
            Remote::Missing => {}
            Remote::Failed(failure) if tries_next_question(failure) => busy = Some(failure),
            Remote::Failed(failure) => return Remote::Failed(failure),
        }
    }
    match busy {
        Some(failure) => Remote::Failed(failure),
        None => Remote::Missing,
    }
}

fn get_exact(
    agent: &ureq::Agent,
    ua: &str,
    title: &str,
    artist: &str,
    album: Option<&str>,
    duration: f64,
) -> Remote {
    let mut url = format!(
        "{}/api/get?track_name={}&artist_name={}",
        lrclib_base(),
        url_encode(title),
        url_encode(artist)
    );
    if let Some(album) = album {
        url.push_str(&format!("&album_name={}", url_encode(album)));
    }
    if duration > 0.0 {
        url.push_str(&format!("&duration={}", duration.round() as i64));
    }
    match request(agent, ua, &url) {
        Reply::Body(body) => parse_record(&body).unwrap_or(Remote::Missing),
        Reply::NotFound => Remote::Missing,
        Reply::Failed(failure) => Remote::Failed(failure),
    }
}

fn search_fallback(
    agent: &ureq::Agent,
    ua: &str,
    track: &Track,
    title: &str,
    artist: &str,
) -> Remote {
    let url = format!(
        "{}/api/search?track_name={}&artist_name={}",
        lrclib_base(),
        url_encode(title),
        url_encode(artist)
    );
    let body = match request(agent, ua, &url) {
        Reply::Body(body) => body,
        Reply::NotFound => return Remote::Missing,
        Reply::Failed(failure) => return Remote::Failed(failure),
    };
    let Ok(records) = serde_json::from_str::<Vec<serde_json::Value>>(&body) else {
        return Remote::Missing;
    };
    let titles: Vec<String> = records
        .iter()
        .map(|record| clean_title(record["trackName"].as_str().unwrap_or_default()))
        .collect();
    let artists: Vec<String> = records
        .iter()
        .map(|record| lead_artist(record["artistName"].as_str().unwrap_or_default()))
        .collect();
    let candidates: Vec<Candidate> = records
        .iter()
        .enumerate()
        .map(|(index, record)| Candidate {
            title: &titles[index],
            artist: &artists[index],
            album: record["albumName"].as_str().unwrap_or_default(),
            duration: record["duration"].as_f64().unwrap_or(0.0),
            has_synced: is_filled(record["syncedLyrics"].as_str()),
            has_word_sync: record["hasWordSync"].as_bool().unwrap_or(false),
        })
        .collect();
    let wanted = Wanted {
        title,
        artist,
        album: &track.album,
        duration: track.duration,
    };
    match best_candidate(&wanted, &candidates) {
        Some((index, score)) => {
            crate::logger::info(
                "lyrics",
                &format!(
                    "lrclib search matched {} — {} (score {score:.2})",
                    track.title, track.artist
                ),
            );
            record_from_value(&records[index]).unwrap_or(Remote::Missing)
        }
        None => Remote::Missing,
    }
}

/// One GET, retried once when the server is overloaded or throttling, waiting
/// as long as it asks within reason. A 404 is an answer, not a failure. Every
/// attempt waits its turn at the shared gate, and a 429 starts the gate's
/// cooldown for the full time the server asked, so a request that would break
/// that promise is not sent.
fn request(agent: &ureq::Agent, ua: &str, url: &str) -> Reply {
    request_through(&crate::precache::LRCLIB, agent, ua, url)
}

fn request_through(gate: &crate::precache::governor::Gate, agent: &ureq::Agent, ua: &str, url: &str) -> Reply {
    let mut last_failure = LyricsFailure::Unreachable;
    for attempt in 0..2 {
        if gate
            .wait_turn(Duration::from_secs_f64(LONGEST_RETRY_WAIT))
            .is_err()
        {
            return Reply::Failed(LyricsFailure::Busy);
        }
        match agent.get(url).set("User-Agent", ua).call() {
            Ok(response) => {
                return response
                    .into_string()
                    .map(Reply::Body)
                    .unwrap_or(Reply::Failed(LyricsFailure::Unreachable));
            }
            Err(ureq::Error::Status(404, _)) => return Reply::NotFound,
            Err(ureq::Error::Status(code, response)) if code == 429 || code >= 500 => {
                let asked = response
                    .header("Retry-After")
                    .and_then(|value| value.trim().parse::<f64>().ok())
                    .unwrap_or(DEFAULT_RETRY_WAIT)
                    .max(SHORTEST_RETRY_WAIT);
                last_failure = LyricsFailure::from_status(code);
                if code == 429 {
                    gate.throttled(Duration::from_secs_f64(asked));
                }
                if attempt == 1 {
                    break;
                }
                if code != 429 {
                    std::thread::sleep(Duration::from_secs_f64(asked.min(LONGEST_RETRY_WAIT)));
                }
            }
            Err(err) => {
                crate::logger::warn("lyrics", &format!("lrclib request failed: {err}"));
                return Reply::Failed(failure_of(&err));
            }
        }
    }
    Reply::Failed(last_failure)
}

/// What a transport or status error from lrclib means to the listener.
fn failure_of(err: &ureq::Error) -> LyricsFailure {
    match err {
        ureq::Error::Status(code, _) => LyricsFailure::from_status(*code),
        ureq::Error::Transport(transport) => {
            let timed_out = std::error::Error::source(transport)
                .and_then(|source| source.downcast_ref::<std::io::Error>())
                .is_some_and(|io| {
                    matches!(
                        io.kind(),
                        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                    )
                });
            if timed_out {
                LyricsFailure::TimedOut
            } else {
                LyricsFailure::Unreachable
            }
        }
    }
}

fn parse_record(body: &str) -> Option<Remote> {
    let value = serde_json::from_str::<serde_json::Value>(body).ok()?;
    record_from_value(&value)
}

fn record_from_value(value: &serde_json::Value) -> Option<Remote> {
    let text = |key: &str| {
        value[key]
            .as_str()
            .filter(|text| !text.trim().is_empty())
            .map(str::to_string)
    };
    let fetched = Fetched {
        synced: text("syncedLyrics"),
        plain: text("plainLyrics"),
        lyricsfile: text("lyricsfile"),
        instrumental: value["instrumental"].as_bool().unwrap_or(false),
    };
    if fetched.synced.is_none() && fetched.plain.is_none() && !fetched.instrumental {
        return Some(Remote::Missing);
    }
    Some(Remote::Found(fetched))
}

struct LocalLyrics {
    synced_raw: Option<String>,
    plain: Option<String>,
}

/// Lyrics the user curated themselves, in the order other players look: an
/// `.lrc`/`.elrc` sidecar next to the audio, then the file's own tags. Never
/// written back — the library is the user's.
fn read_local(path: &Path) -> Option<LocalLyrics> {
    for extension in ["lrc", "elrc"] {
        let sidecar = path.with_extension(extension);
        if let Ok(text) = std::fs::read_to_string(&sidecar) {
            if !text.trim().is_empty() {
                crate::logger::info("lyrics", &format!("using sidecar {}", sidecar.display()));
                return Some(classify_local(&text));
            }
        }
    }
    read_tagged_lyrics(path).map(|text| classify_local(&text))
}

/// Text with timestamps is synchronized lyrics (word tags and all, so a
/// timed file keeps its words); anything else is plain.
fn classify_local(text: &str) -> LocalLyrics {
    if parse_lrc(text).has_synced() {
        LocalLyrics {
            synced_raw: Some(text.to_string()),
            plain: None,
        }
    } else {
        LocalLyrics {
            synced_raw: None,
            plain: Some(text.to_string()),
        }
    }
}

fn read_tagged_lyrics(path: &Path) -> Option<String> {
    use lofty::file::TaggedFileExt;
    use lofty::prelude::{Accessor, ItemKey};
    use lofty::probe::Probe;

    let tagged = Probe::open(path).ok()?.read().ok()?;
    let tags: Vec<_> = tagged
        .primary_tag()
        .into_iter()
        .chain(tagged.tags().iter())
        .collect();
    for tag in tags {
        for key in [
            ItemKey::Lyrics,
            ItemKey::Unknown("SYNCEDLYRICS".to_string()),
            ItemKey::Unknown("UNSYNCEDLYRICS".to_string()),
            ItemKey::Unknown("LYRICS".to_string()),
        ] {
            if let Some(text) = tag.get_string(&key).filter(|text| !text.trim().is_empty()) {
                return Some(text.to_string());
            }
        }
        if let Some(text) = tag.comment().filter(|text| text.contains("[00:")) {
            return Some(text.to_string());
        }
    }
    None
}

fn url_encode(input: &str) -> String {
    let mut result = String::new();
    for byte in input.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                result.push(*byte as char)
            }
            _ => result.push_str(&format!("%{:02X}", byte)),
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const LYRICSFILE: &str = "version: '1.0'\nmetadata:\n  title: t\n  artist: a\nlines:\n- text: Hello\n  start_ms: 1000\n  end_ms: 3000\n  words:\n  - text: 'Hel'\n    start_ms: 1000\n    end_ms: 2000\n  - text: lo\n    start_ms: 2000\n    end_ms: 3000\n";

    fn row(synced: Option<&str>, lyricsfile: Option<&str>, revision: i64) -> LyricsRow {
        LyricsRow {
            synced: synced.map(str::to_string),
            plain: None,
            lyricsfile: lyricsfile.map(str::to_string),
            instrumental: false,
            offset_ms: 0,
            revision,
            age_days: 0.0,
        }
    }

    #[test]
    fn a_readable_lyricsfile_beats_the_lrc_text() {
        let document = document_from(Some("[00:05.00]other"), None, Some(LYRICSFILE), false);
        assert!(document.has_word_sync());
        assert_eq!(document.lines.last().unwrap().text, "Hello");
    }

    #[test]
    fn an_unreadable_lyricsfile_falls_back_to_the_lrc_text() {
        let document = document_from(Some("[00:05.00]other"), None, Some("not: [yaml"), false);
        assert!(!document.has_word_sync());
        assert_eq!(document.lines.last().unwrap().text, "other");
    }

    #[test]
    fn plain_lyrics_ride_along_with_synced_ones() {
        let document = document_from(Some("[00:05.00]x"), Some("x\ny"), None, false);
        assert_eq!(document.plain.as_deref(), Some("x\ny"));
    }

    #[test]
    fn instrumental_wins_over_everything() {
        let document = document_from(Some("[00:05.00]x"), Some("x"), Some(LYRICSFILE), true);
        assert!(document.instrumental);
        assert!(document.lines.is_empty());
    }

    #[test]
    fn content_from_an_older_revision_is_asked_for_again() {
        assert!(!is_current(&row(Some("[00:01.00]x"), None, 0)));
        assert!(is_current(&row(Some("[00:01.00]x"), None, REVISION)));
    }

    #[test]
    fn a_miss_stands_for_thirty_days_whatever_its_revision() {
        let mut miss = row(None, None, 0);
        miss.age_days = 10.0;
        assert!(is_current(&miss));
        miss.age_days = 31.0;
        assert!(!is_current(&miss));
    }

    #[test]
    fn a_local_file_with_stamps_stays_synchronized_with_its_word_tags() {
        let local = classify_local("[00:05.00]<00:05.00>Hi <00:05.50>there");
        let document = document_from(local.synced_raw.as_deref(), None, None, false);
        assert!(document.has_word_sync());
        let unsynced = classify_local("just words\nno stamps");
        assert!(unsynced.synced_raw.is_none());
        assert_eq!(unsynced.plain.as_deref(), Some("just words\nno stamps"));
    }

    #[test]
    fn the_offset_moves_the_song_time_opposite_to_the_position() {
        let lyrics = Lyrics {
            document: parse_lrc("[00:10.00]a\n[00:20.00]b"),
            offset_ms: 500,
        };
        assert_eq!(lyrics.text_at(10.4), None);
        assert_eq!(lyrics.text_at(10.6), Some("a"));
        let earlier = Lyrics {
            offset_ms: -500,
            ..lyrics
        };
        assert_eq!(earlier.text_at(9.6), Some("a"));
    }

    fn scratch_dir(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("flaccy-lyrics-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn track(rel_path: &str) -> Track {
        Track {
            id: 1,
            rel_path: rel_path.to_string(),
            title: "Song".to_string(),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            album_artist: None,
            track_number: 1,
            duration: 100.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    #[test]
    fn a_cached_miss_does_not_hide_a_lrc_file_added_since() {
        let dir = scratch_dir("miss-then-sidecar");
        let db_path = dir.join("library.sqlite");
        let db = Db::open(&db_path).unwrap();
        db.save_lyrics(
            "Song",
            "Artist",
            &LyricsContent {
                synced: None,
                plain: None,
                lyricsfile: None,
                instrumental: false,
                revision: REVISION,
            },
        )
        .unwrap();
        drop(db);
        assert!(matches!(
            fetch_blocking(&db_path, &dir, &track("missing.flac")),
            LyricsResult::Missing
        ));
        std::fs::write(dir.join("song.lrc"), "[00:05.00]Hello there").unwrap();
        match fetch_blocking(&db_path, &dir, &track("song.flac")) {
            LyricsResult::Found(lyrics) => {
                assert_eq!(lyrics.document.lines.last().unwrap().text, "Hello there");
            }
            _ => panic!("the sidecar should have been read past the cached miss"),
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn cache_found(db_path: &Path) {
        let db = Db::open(db_path).unwrap();
        db.save_lyrics(
            "Song",
            "Artist",
            &LyricsContent {
                synced: Some("[00:05.00]Cached".to_string()),
                plain: None,
                lyricsfile: None,
                instrumental: false,
                revision: REVISION,
            },
        )
        .unwrap();
    }

    #[test]
    fn a_lookup_skipped_away_from_never_reaches_the_network() {
        let dir = scratch_dir("skipped");
        let db_path = dir.join("library.sqlite");
        drop(Db::open(&db_path).unwrap());
        let result = resolve(&db_path, &dir, &track("gone.flac"), Some(&|| false));
        assert!(result.is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_cached_answer_is_read_without_waiting_to_settle() {
        let dir = scratch_dir("cache-hit");
        let db_path = dir.join("library.sqlite");
        cache_found(&db_path);
        let result = resolve(&db_path, &dir, &track("song.flac"), Some(&|| false));
        assert!(matches!(result, Some(LyricsResult::Found(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn overlapping_lookups_for_one_track_all_get_the_answer() {
        let dir = scratch_dir("overlap");
        let db_path = dir.join("library.sqlite");
        cache_found(&db_path);
        want(&track("song.flac"));
        let handles: Vec<_> = (0..4)
            .map(|_| {
                let (db_path, dir) = (db_path.clone(), dir.clone());
                std::thread::spawn(move || {
                    fetch_shared(&db_path, &dir, &track("song.flac"), Pace::Settled)
                })
            })
            .collect();
        for handle in handles {
            assert!(matches!(
                handle.join().unwrap(),
                Some(LyricsResult::Found(_))
            ));
        }
        let key = flight_key(&track("song.flac"));
        assert!(!FLIGHTS.lock().unwrap().iter().any(|flight| flight.key == key));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_patient_lookup_that_finds_the_answer_sends_it_once_and_ends() {
        let dir = scratch_dir("patient-hit");
        let db_path = dir.join("library.sqlite");
        cache_found(&db_path);
        let (tx, rx) = async_channel::unbounded();
        fetch_patient(&db_path, &dir, &track("patient.flac"), Pace::Immediate, &AtomicBool::new(false), &tx);
        drop(tx);
        assert!(matches!(rx.try_recv(), Ok(Some(LyricsResult::Found(_)))));
        assert!(rx.try_recv().is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_patient_lookup_skipped_away_from_says_so_and_ends() {
        let dir = scratch_dir("patient-skipped");
        let db_path = dir.join("library.sqlite");
        drop(Db::open(&db_path).unwrap());
        let (tx, rx) = async_channel::unbounded();
        fetch_patient(&db_path, &dir, &track("gone.flac"), Pace::Settled, &AtomicBool::new(false), &tx);
        drop(tx);
        assert!(matches!(rx.try_recv(), Ok(None)));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn waiting_between_retries_ends_for_a_stop_a_closed_listener_or_another_track() {
        let (tx, rx) = async_channel::unbounded();
        let wanted = || true;
        assert!(keep_waiting(0.0, &wanted, &AtomicBool::new(false), &tx));
        assert!(!keep_waiting(5.0, &wanted, &AtomicBool::new(true), &tx));
        assert!(!keep_waiting(5.0, &|| false, &AtomicBool::new(false), &tx));
        drop(rx);
        assert!(!keep_waiting(5.0, &wanted, &AtomicBool::new(false), &tx));
    }

    fn fetched() -> Fetched {
        Fetched {
            synced: Some("[00:01.00]words".to_string()),
            plain: None,
            lyricsfile: None,
            instrumental: false,
        }
    }

    fn scripted(answers: Vec<fn() -> Remote>) -> (Remote, usize) {
        let mut asked = 0;
        let remote = lookup_through(&track("song.flac"), &mut |_| {
            let answer = answers.get(asked).map_or(Remote::Missing, |answer| answer());
            asked += 1;
            answer
        });
        (remote, asked)
    }

    #[test]
    fn a_busy_answer_lets_the_plainer_question_find_the_song() {
        let (remote, asked) = scripted(vec![
            || Remote::Failed(LyricsFailure::Server(503)),
            || Remote::Found(fetched()),
        ]);
        assert!(matches!(remote, Remote::Found(_)));
        assert_eq!(asked, 2);
    }

    #[test]
    fn questions_that_were_all_busy_make_the_lookup_a_failure_not_a_miss() {
        let (remote, asked) = scripted(vec![
            || Remote::Failed(LyricsFailure::Server(503)),
            || Remote::Missing,
            || Remote::Missing,
        ]);
        assert!(matches!(remote, Remote::Failed(LyricsFailure::Server(503))));
        assert_eq!(asked, 3);
    }

    #[test]
    fn a_lookup_where_every_question_was_answered_empty_is_a_miss() {
        let (remote, asked) = scripted(vec![]);
        assert!(matches!(remote, Remote::Missing));
        assert_eq!(asked, 3);
    }

    #[test]
    fn a_server_that_is_not_answering_ends_the_lookup_at_once() {
        for failure in [
            LyricsFailure::Unreachable,
            LyricsFailure::TimedOut,
            LyricsFailure::Busy,
            LyricsFailure::Server(502),
            LyricsFailure::Rejected(403),
        ] {
            let mut asked = 0;
            let remote = lookup_through(&track("song.flac"), &mut |_| {
                asked += 1;
                Remote::Failed(failure)
            });
            assert!(matches!(remote, Remote::Failed(got) if got == failure));
            assert_eq!(asked, 1, "{failure:?}");
        }
    }

    #[test]
    fn a_decorated_title_adds_a_question_with_the_edition_removed() {
        let mut decorated = track("song.flac");
        decorated.title = "Song (Remastered 2011)".to_string();
        let mut asked = 0;
        let remote = lookup_through(&decorated, &mut |_| {
            asked += 1;
            Remote::Missing
        });
        assert!(matches!(remote, Remote::Missing));
        assert_eq!(asked, 4);
    }

    fn stub(answer: &'static str) -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        use std::io::{BufRead, BufReader, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}/api/get", listener.local_addr().unwrap());
        let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = std::sync::Arc::clone(&hits);
        std::thread::spawn(move || {
            for mut stream in listener.incoming().flatten() {
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                loop {
                    let mut line = String::new();
                    if reader.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                        break;
                    }
                }
                let _ = stream.write_all(answer.as_bytes());
            }
        });
        (url, hits)
    }

    fn agent() -> ureq::Agent {
        ureq::AgentBuilder::new().timeout(Duration::from_secs(5)).build()
    }

    #[test]
    fn a_429_starts_a_cooldown_for_the_whole_time_asked_and_is_not_retried_inside_it() {
        use crate::precache::governor::Gate;
        let (url, hits) = stub("HTTP/1.1 429 Slow\r\nRetry-After: 60\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        let gate = Gate::new(Duration::from_millis(1));
        let reply = request_through(&gate, &agent(), "test", &url);
        assert!(matches!(reply, Reply::Failed(LyricsFailure::Busy)));
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 1);
        assert!(gate.cooldown_left() >= Duration::from_secs(59));
    }

    #[test]
    fn nothing_is_sent_while_a_cooldown_is_running() {
        use crate::precache::governor::Gate;
        let (url, hits) = stub("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
        let gate = Gate::new(Duration::from_millis(1));
        gate.throttled(Duration::from_secs(60));
        let reply = request_through(&gate, &agent(), "test", &url);
        assert!(matches!(reply, Reply::Failed(LyricsFailure::Busy)));
        assert_eq!(hits.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    #[test]
    fn an_answer_and_a_not_found_pass_through_the_gate() {
        use crate::precache::governor::Gate;
        let gate = Gate::new(Duration::from_millis(1));
        let (found, _) = stub("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}");
        assert!(matches!(request_through(&gate, &agent(), "test", &found), Reply::Body(body) if body == "{}"));
        let (missing, _) = stub("HTTP/1.1 404 No\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
        assert!(matches!(request_through(&gate, &agent(), "test", &missing), Reply::NotFound));
    }

    #[test]
    fn a_miss_is_stored_up_to_a_week_old_and_a_found_answer_is_not_aged() {
        let dir = scratch_dir("aged");
        let db = Db::open(&dir.join("library.sqlite")).unwrap();
        let miss = LyricsContent {
            synced: None,
            plain: None,
            lyricsfile: None,
            instrumental: false,
            revision: REVISION,
        };
        db.save_lyrics("Song", "Artist", &miss).unwrap();
        db.age_lyrics("Song", "Artist", 7.0).unwrap();
        let aged = db.fetch_lyrics("Song", "Artist").unwrap();
        assert!(aged.age_days > 6.99 && aged.age_days < 7.1, "{}", aged.age_days);
        assert!(is_current(&aged));
        db.age_lyrics("Song", "Artist", MISS_TTL_DAYS).unwrap();
        assert!(!is_current(&db.fetch_lyrics("Song", "Artist").unwrap()));
        assert!(!is_cached(&db, &track("x.flac")));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
