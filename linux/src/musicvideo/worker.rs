use super::stream::{self, Codec, Stream};
use super::{align, llm, score, search, Candidate, Phase, Settings, VideoMatch, VideoState};
use crate::db::Db;
use crate::library::Track;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// How long a remembered "this song has no music video" stands. Videos get
/// uploaded; a permanent no would be wrong.
const MISS_TTL_DAYS: f64 = 30.0;

/// The aligner that maps a whole song section by section. Matches aligned by
/// an older one are listened to again, once.
pub const ALIGN_VERSION: i64 = 2;

/// How long a search's results are reused for the chooser.
const SEARCH_REUSE: Duration = Duration::from_secs(3600);

/// The most searches remembered at once.
const SEARCH_MEMORY: usize = 32;

/// How long a request waits for the prefetcher to finish the same song rather
/// than searching for it a second time.
const PREFETCH_WAIT: Duration = Duration::from_secs(60);

/// Characters of reasoning the caption can carry before it stops being a
/// caption.
pub const REASON_LIMIT: usize = 90;

pub enum Request {
    Resolve {
        seq: u64,
        track: Track,
        settings: Settings,
        force: bool,
    },
    /// Decides the next song's match and resolves its stream ahead of time, so
    /// the video is there the moment the song starts.
    Prefetch {
        track: Track,
        settings: Settings,
    },
    Choose {
        seq: u64,
        track: Track,
        candidate: Candidate,
        settings: Settings,
    },
    /// A video the listener pasted a link to.
    ChooseLink {
        seq: u64,
        track: Track,
        video_id: String,
        settings: Settings,
    },
    Candidates {
        seq: u64,
        track: Track,
    },
    /// Re-resolves the stream for a match already decided — the signed URL
    /// aged out mid-session, YouTube refused it, or the format it named turned
    /// out to be one this GStreamer cannot decode.
    Renew {
        seq: u64,
        video_id: String,
        settings: Settings,
        strict: bool,
    },
}

pub enum Response {
    Progress {
        seq: u64,
        phase: Phase,
    },
    Resolved {
        seq: u64,
        state: VideoState,
        stream: Option<Stream>,
    },
    Renewed {
        seq: u64,
        stream: Option<Stream>,
    },
    /// A finished alignment. Keyed by video rather than by request, because it
    /// can finish after the listener moved on and came back.
    Aligned {
        found: VideoMatch,
    },
    Candidates {
        seq: u64,
        list: Vec<Candidate>,
    },
    LinkFailed {
        seq: u64,
        message: String,
    },
}

type SongKey = (String, String);

fn song_key(track: &Track) -> SongKey {
    (track.title.clone(), track.artist.clone())
}

/// State the request worker, the prefetcher and alignment jobs share.
struct Shared {
    db_path: PathBuf,
    root: PathBuf,
    latest: Arc<AtomicU64>,
    codecs: Vec<Codec>,
    streams: Mutex<HashMap<(String, i32, bool), Stream>>,
    searches: Mutex<HashMap<SongKey, (Instant, Vec<Candidate>)>>,
    prefetching: Mutex<Option<SongKey>>,
    prefetched: Condvar,
    aligning: Mutex<HashSet<String>>,
    responses: async_channel::Sender<Response>,
}

impl Shared {
    fn stale(&self, seq: Option<u64>) -> bool {
        seq.is_some_and(|seq| seq != self.latest.load(Ordering::Acquire))
    }

    fn send(&self, response: Response) {
        let _ = self.responses.send_blocking(response);
    }

    fn progress(&self, seq: Option<u64>, phase: Phase) {
        if let Some(seq) = seq {
            self.send(Response::Progress { seq, phase });
        }
    }

    /// The stream for a video, from memory while its URL is still good,
    /// otherwise freshly resolved and given the moment YouTube needs before
    /// it starts serving a new URL.
    fn stream_for(
        &self,
        video_id: &str,
        settings: &Settings,
        strict: bool,
        fresh: bool,
    ) -> Result<(Stream, Candidate), String> {
        let key = (video_id.to_string(), settings.max_height, strict);
        let now = chrono::Utc::now().timestamp();
        if !fresh {
            if let Some(stream) = self
                .streams
                .lock()
                .ok()
                .and_then(|cache| cache.get(&key).cloned())
            {
                if stream.usable_at(now) {
                    return Ok((stream, Candidate::bare(video_id)));
                }
            }
        }
        let started = Instant::now();
        let (stream, video) =
            stream::resolve(video_id, settings.max_height, &self.codecs, strict, now)?;
        let resolved = started.elapsed();
        if !stream::await_ready(&stream.url) {
            return Err("YouTube refused to serve this video's stream".to_string());
        }
        crate::logger::info(
            "musicvideo",
            &format!(
                "stream for {video_id}: {}p {} (resolved in {:.1}s, served after {:.1}s)",
                stream.height,
                stream.codec.map(|codec| codec.label()).unwrap_or("unknown codec"),
                resolved.as_secs_f64(),
                started.elapsed().as_secs_f64()
            ),
        );
        if let Ok(mut cache) = self.streams.lock() {
            cache.retain(|_, cached| cached.usable_at(now));
            cache.insert(key, stream.clone());
        }
        Ok((stream, video))
    }

    fn remember_search(&self, track: &Track, list: &[Candidate]) {
        if let Ok(mut searches) = self.searches.lock() {
            if searches.len() >= SEARCH_MEMORY {
                searches.clear();
            }
            searches.insert(song_key(track), (Instant::now(), list.to_vec()));
        }
    }

    fn recalled_search(&self, track: &Track) -> Option<Vec<Candidate>> {
        let searches = self.searches.lock().ok()?;
        let (at, list) = searches.get(&song_key(track))?;
        (at.elapsed() < SEARCH_REUSE).then(|| list.clone())
    }

    /// Searches YouTube for the track, remembering the results for the
    /// chooser.
    fn search(&self, track: &Track) -> search::SearchOutcome {
        let outcome = search::search(&track.title, &track.artist);
        if let search::SearchOutcome::Found(list) = &outcome {
            self.remember_search(track, list);
        }
        outcome
    }

    /// Blocks while the prefetcher is busy with this very song, so its search
    /// is used instead of repeated.
    fn wait_for_prefetch(&self, track: &Track) {
        let key = song_key(track);
        let Ok(mut busy) = self.prefetching.lock() else {
            return;
        };
        let deadline = Instant::now() + PREFETCH_WAIT;
        while busy.as_ref() == Some(&key) {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return;
            }
            let Ok((guard, _)) = self.prefetched.wait_timeout(busy, left) else {
                return;
            };
            busy = guard;
        }
    }
}

pub fn spawn(
    db_path: PathBuf,
    root: PathBuf,
    latest: Arc<AtomicU64>,
) -> (
    async_channel::Sender<Request>,
    async_channel::Receiver<Response>,
) {
    let (request_tx, request_rx) = async_channel::unbounded::<Request>();
    let (prefetch_tx, prefetch_rx) = async_channel::unbounded::<(Track, Settings)>();
    let (response_tx, response_rx) = async_channel::unbounded::<Response>();
    let shared = Arc::new(Shared {
        db_path,
        root,
        latest,
        codecs: stream::preference(&stream::decodable_codecs()),
        streams: Mutex::new(HashMap::new()),
        searches: Mutex::new(HashMap::new()),
        prefetching: Mutex::new(None),
        prefetched: Condvar::new(),
        aligning: Mutex::new(HashSet::new()),
        responses: response_tx,
    });
    crate::logger::info(
        "musicvideo",
        &format!(
            "decodes {}",
            if shared.codecs.is_empty() {
                "no YouTube codec — falling back to H.264".to_string()
            } else {
                shared
                    .codecs
                    .iter()
                    .map(|codec| codec.label())
                    .collect::<Vec<_>>()
                    .join(", ")
            }
        ),
    );

    {
        let shared = Arc::clone(&shared);
        std::thread::Builder::new()
            .name("flaccy-musicvideo".into())
            .spawn(move || serve(&shared, request_rx, prefetch_tx))
            .ok();
    }
    std::thread::Builder::new()
        .name("flaccy-mv-prefetch".into())
        .spawn(move || prefetch_loop(&shared, prefetch_rx))
        .ok();
    (request_tx, response_rx)
}

fn serve(
    shared: &Arc<Shared>,
    rx: async_channel::Receiver<Request>,
    prefetch: async_channel::Sender<(Track, Settings)>,
) {
    let Ok(db) = Db::open(&shared.db_path) else {
        return;
    };
    while let Ok(request) = rx.recv_blocking() {
        match request {
            Request::Resolve {
                seq,
                track,
                settings,
                force,
            } => {
                if shared.stale(Some(seq)) {
                    continue;
                }
                resolve(shared, &db, seq, &track, &settings, force);
            }
            Request::Prefetch { track, settings } => {
                let _ = prefetch.send_blocking((track, settings));
            }
            Request::Choose {
                seq,
                track,
                candidate,
                settings,
            } => {
                let mut found = build_match(&candidate, "You picked this one");
                found.chosen_by_user = true;
                db.save_music_video(&track.title, &track.artist, Some(&found), 1.0);
                deliver(shared, seq, &track, found, &settings);
            }
            Request::ChooseLink {
                seq,
                track,
                video_id,
                settings,
            } => choose_link(shared, &db, seq, &track, &video_id, &settings),
            Request::Candidates { seq, track } => {
                let list =
                    shared
                        .recalled_search(&track)
                        .unwrap_or_else(|| match shared.search(&track) {
                            search::SearchOutcome::Found(found) => found,
                            _ => Vec::new(),
                        });
                let list = ranked_for_chooser(&track, list);
                shared.send(Response::Candidates { seq, list });
            }
            Request::Renew {
                seq,
                video_id,
                settings,
                strict,
            } => {
                let stream = match shared.stream_for(&video_id, &settings, strict, true) {
                    Ok((stream, _)) => Some(stream),
                    Err(err) => {
                        crate::logger::warn("musicvideo", &format!("stream renewal failed: {err}"));
                        None
                    }
                };
                shared.send(Response::Renewed { seq, stream });
            }
        }
    }
}

/// The chooser lists the plausible candidates best first, then whatever the
/// scorer ruled out, so the right video is near the top even when the
/// automatic pick was wrong.
fn ranked_for_chooser(track: &Track, list: Vec<Candidate>) -> Vec<Candidate> {
    let ranked = score::rank(&track.title, &track.artist, track.duration, &list);
    let mut ordered: Vec<Candidate> = ranked
        .iter()
        .map(|scored| scored.candidate.clone())
        .collect();
    for candidate in &list {
        if !ordered.iter().any(|kept| kept.id == candidate.id) {
            ordered.push(candidate.clone());
        }
    }
    ordered
}

fn prefetch_loop(shared: &Arc<Shared>, rx: async_channel::Receiver<(Track, Settings)>) {
    let Ok(db) = Db::open(&shared.db_path) else {
        return;
    };
    while let Ok(mut job) = rx.recv_blocking() {
        while let Ok(newer) = rx.try_recv() {
            job = newer;
        }
        let (track, settings) = job;
        if let Ok(mut busy) = shared.prefetching.lock() {
            *busy = Some(song_key(&track));
        }
        prefetch(shared, &db, &track, &settings);
        if let Ok(mut busy) = shared.prefetching.lock() {
            *busy = None;
        }
        shared.prefetched.notify_all();
    }
}

fn prefetch(shared: &Arc<Shared>, db: &Db, track: &Track, settings: &Settings) {
    let found = match remembered(db, track) {
        Remembered::Match(found) => found,
        Remembered::Miss => return,
        Remembered::Unknown => match pick(shared, track, settings, None) {
            Pick::Chosen(found) => {
                db.save_music_video(&track.title, &track.artist, Some(&found), 1.0);
                found
            }
            Pick::Nothing(_) => {
                db.save_music_video(&track.title, &track.artist, None, 0.0);
                return;
            }
            Pick::Failed(_) | Pick::Stale => return,
        },
    };
    if let Err(err) = shared.stream_for(&found.video_id, settings, false, false) {
        crate::logger::warn(
            "musicvideo",
            &format!("prefetch of {} failed: {err}", found.video_id),
        );
        return;
    }
    if settings.align && found.align_version < ALIGN_VERSION {
        if let Some(aligned) = align_now(shared, db, track, &found) {
            shared.send(Response::Aligned { found: aligned });
        }
    }
    crate::logger::info(
        "musicvideo",
        &format!("prefetched {} for the next song", found.video_id),
    );
}

enum Remembered {
    Match(VideoMatch),
    Miss,
    Unknown,
}

fn remembered(db: &Db, track: &Track) -> Remembered {
    let Some(row) = db.fetch_music_video(&track.title, &track.artist) else {
        return Remembered::Unknown;
    };
    match row.video_id {
        Some(video_id) => Remembered::Match(VideoMatch {
            video_id,
            title: row.video_title,
            channel: row.channel,
            duration: row.duration,
            offset: row.offset,
            aligned: row.aligned,
            chosen_by_user: row.chosen_by_user,
            reason: row.reason,
            map: row.map,
            trim: row.trim,
            align_version: row.align_version,
        }),
        None if row.age_days <= MISS_TTL_DAYS => Remembered::Miss,
        None => Remembered::Unknown,
    }
}

fn resolve(
    shared: &Arc<Shared>,
    db: &Db,
    seq: u64,
    track: &Track,
    settings: &Settings,
    force: bool,
) {
    shared.wait_for_prefetch(track);
    if shared.stale(Some(seq)) {
        return;
    }
    if !force {
        match remembered(db, track) {
            Remembered::Match(found) => {
                deliver(shared, seq, track, found, settings);
                return;
            }
            Remembered::Miss => {
                shared.send(Response::Resolved {
                    seq,
                    state: VideoState::Missing(
                        "An earlier search found no matching video for this song.".to_string(),
                    ),
                    stream: None,
                });
                return;
            }
            Remembered::Unknown => {}
        }
    }

    match pick(shared, track, settings, Some(seq)) {
        Pick::Chosen(found) => {
            db.save_music_video(&track.title, &track.artist, Some(&found), 1.0);
            deliver(shared, seq, track, found, settings);
        }
        Pick::Nothing(reason) => {
            db.save_music_video(&track.title, &track.artist, None, 0.0);
            shared.send(Response::Resolved {
                seq,
                state: VideoState::Missing(reason),
                stream: None,
            });
        }
        Pick::Failed(err) => shared.send(Response::Resolved {
            seq,
            state: VideoState::Failed(format!("Couldn't search YouTube: {err}")),
            stream: None,
        }),
        Pick::Stale => {}
    }
}

fn choose_link(
    shared: &Arc<Shared>,
    db: &Db,
    seq: u64,
    track: &Track,
    video_id: &str,
    settings: &Settings,
) {
    match shared.stream_for(video_id, settings, false, true) {
        Ok((stream, video)) => {
            let mut found = build_match(&video, "You picked this one");
            found.video_id = video_id.to_string();
            found.chosen_by_user = true;
            db.save_music_video(&track.title, &track.artist, Some(&found), 1.0);
            shared.send(Response::Resolved {
                seq,
                state: VideoState::Ready(found.clone()),
                stream: Some(stream),
            });
            align_later(shared, track, found, settings);
        }
        Err(err) => shared.send(Response::LinkFailed {
            seq,
            message: format!("Couldn't open that video: {err}"),
        }),
    }
}

pub enum Pick {
    Chosen(VideoMatch),
    Nothing(String),
    Failed(String),
    /// The listener moved on while this was being decided.
    Stale,
}

/// Search, rank, and — when the ranking is close — let a local model read the
/// titles and break the tie.
fn pick(shared: &Shared, track: &Track, settings: &Settings, seq: Option<u64>) -> Pick {
    let candidates = match shared.search(track) {
        search::SearchOutcome::Found(found) => found,
        search::SearchOutcome::Empty => {
            return Pick::Nothing("YouTube returned no results for this song.".to_string())
        }
        search::SearchOutcome::Failed(err) => return Pick::Failed(err),
    };
    if shared.stale(seq) {
        return Pick::Stale;
    }
    let ranked = score::rank(&track.title, &track.artist, track.duration, &candidates);
    if ranked.is_empty() {
        return Pick::Nothing(format!(
            "None of YouTube's {} results looked like this song or ran about as long.",
            candidates.len()
        ));
    }
    if score::decisive(&ranked) {
        return Pick::Chosen(build_match(
            ranked[0].candidate,
            "Matched on title, channel and runtime",
        ));
    }

    let shortlist: Vec<&Candidate> = ranked.iter().take(5).map(|s| s.candidate).collect();
    let scores: Vec<f64> = ranked.iter().take(5).map(|s| s.score).collect();
    if settings.use_llm {
        if let Some(model) = llm::choose_model(&settings.model, &llm::installed_models()) {
            shared.progress(seq, Phase::Judging(model.clone()));
            let verdict = llm::adjudicate(
                &model,
                &score::search_title(&track.title),
                &track.artist,
                track.duration,
                &shortlist,
            );
            if shared.stale(seq) {
                return Pick::Stale;
            }
            if let Some(verdict) = verdict {
                let blended = llm::blend(&scores, &verdict);
                let best = blended.iter().enumerate().max_by(|a, b| a.1.total_cmp(b.1));
                if let Some((index, best_score)) = best {
                    if *best_score >= score::ACCEPT {
                        let reason = if verdict.reason.is_empty() {
                            format!("Chosen by {model}")
                        } else {
                            format!("{} — {model}", verdict.reason)
                        };
                        return Pick::Chosen(build_match(shortlist[index], &reason));
                    }
                }
                return Pick::Nothing(format!(
                    "{model} judged that none of the top {} results is this song's video.",
                    shortlist.len()
                ));
            }
        }
    }

    if ranked[0].score >= score::ACCEPT {
        Pick::Chosen(build_match(
            ranked[0].candidate,
            "Best match among close results",
        ))
    } else {
        Pick::Nothing(format!(
            "None of YouTube's {} results matched this song's title, channel and length closely enough.",
            candidates.len()
        ))
    }
}

pub fn build_match(candidate: &Candidate, reason: &str) -> VideoMatch {
    VideoMatch {
        video_id: candidate.id.clone(),
        title: candidate.title.clone(),
        channel: candidate.channel.clone(),
        duration: candidate.duration,
        offset: 0.0,
        aligned: false,
        chosen_by_user: false,
        reason: clip_reason(reason),
        map: Default::default(),
        trim: 0.0,
        align_version: 0,
    }
}

/// The caption under the video is one line. A model asked for a short sentence
/// sometimes writes a paragraph, so it is cut to its first sentence and capped.
pub fn clip_reason(reason: &str) -> String {
    let first = reason
        .split_inclusive(['.', '!', '?'])
        .next()
        .unwrap_or(reason)
        .trim();
    let clipped: String = first.chars().take(REASON_LIMIT).collect();
    if clipped.chars().count() < first.chars().count() {
        format!("{}…", clipped.trim_end())
    } else {
        clipped.to_string()
    }
}

/// Resolves a playable stream for a decided match and hands it back, then —
/// the first time this aligner meets the video — works out how its timeline
/// maps onto the file on disk, without holding up the next request.
fn deliver(shared: &Arc<Shared>, seq: u64, track: &Track, found: VideoMatch, settings: &Settings) {
    if shared.stale(Some(seq)) {
        return;
    }
    shared.progress(Some(seq), Phase::Loading);
    match shared.stream_for(&found.video_id, settings, false, false) {
        Ok((stream, _)) => {
            if shared.stale(Some(seq)) {
                return;
            }
            shared.send(Response::Resolved {
                seq,
                state: VideoState::Ready(found.clone()),
                stream: Some(stream),
            });
            align_later(shared, track, found, settings);
        }
        Err(err) => shared.send(Response::Resolved {
            seq,
            state: VideoState::Failed(format!("Couldn't load the video's stream: {err}")),
            stream: None,
        }),
    }
}

fn align_later(shared: &Arc<Shared>, track: &Track, found: VideoMatch, settings: &Settings) {
    if !settings.align || found.align_version >= ALIGN_VERSION {
        return;
    }
    let shared = Arc::clone(shared);
    let track = track.clone();
    std::thread::Builder::new()
        .name("flaccy-mv-align".into())
        .spawn(move || {
            let Ok(db) = Db::open(&shared.db_path) else {
                return;
            };
            if let Some(aligned) = align_now(&shared, &db, &track, &found) {
                shared.send(Response::Aligned { found: aligned });
            }
        })
        .ok();
}

/// Where ffmpeg can read the track's audio: the file on disk, or a server
/// song through the local proxy that serves its cached or streamed copy.
fn audio_source(track: &Track, root: &Path) -> Option<String> {
    if crate::remote::is_remote(&track.rel_path) {
        return crate::remote::proxy_uri(&track.rel_path);
    }
    let local = track.abs_path(root);
    local
        .is_file()
        .then(|| local.to_string_lossy().into_owned())
}

/// Listens to the video's soundtrack against the track and records the time
/// map. Returns the updated match, or `None` when the audio could not be
/// fetched — that is retried next time, a failed alignment is not.
fn align_now(shared: &Shared, db: &Db, track: &Track, found: &VideoMatch) -> Option<VideoMatch> {
    if !shared
        .aligning
        .lock()
        .map(|mut busy| busy.insert(found.video_id.clone()))
        .unwrap_or(false)
    {
        return None;
    }
    let result = align_unguarded(shared, db, track, found);
    if let Ok(mut busy) = shared.aligning.lock() {
        busy.remove(&found.video_id);
    }
    result
}

fn align_unguarded(
    shared: &Shared,
    db: &Db,
    track: &Track,
    found: &VideoMatch,
) -> Option<VideoMatch> {
    let source = audio_source(track, &shared.root)?;
    let scratch = scratch_dir();
    let Some(audio) = stream::download_audio(&found.video_id, &scratch) else {
        crate::logger::warn(
            "musicvideo",
            &format!("could not fetch audio to align {}", found.video_id),
        );
        return None;
    };
    let started = Instant::now();
    let alignment = align::estimate(&source, &audio.to_string_lossy());
    let _ = std::fs::remove_file(&audio);
    let mut updated = found.clone();
    updated.align_version = ALIGN_VERSION;
    match alignment {
        Some(alignment) => {
            crate::logger::info(
                "musicvideo",
                &format!(
                    "aligned {} as {} (confidence {:.2}, {:.1}s)",
                    found.video_id,
                    alignment.map.encode(),
                    alignment.confidence,
                    started.elapsed().as_secs_f64()
                ),
            );
            updated.offset = alignment.map.lead_offset();
            updated.map = alignment.map;
            updated.aligned = true;
        }
        None => crate::logger::info(
            "musicvideo",
            &format!("no confident alignment for {}", found.video_id),
        ),
    }
    db.set_music_video_alignment(&track.title, &track.artist, &found.video_id, &updated);
    Some(updated)
}

fn scratch_dir() -> PathBuf {
    let base = dirs::cache_dir().unwrap_or_else(std::env::temp_dir);
    base.join("flaccy").join("musicvideo")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_models_paragraph_is_cut_down_to_a_caption() {
        assert_eq!(clip_reason("Official channel."), "Official channel.");
        assert_eq!(
            clip_reason("It is the official video. It also has the most views by far."),
            "It is the official video."
        );
        let rambling = "The channel is the artist's official YouTube account and the title \
                        format matches their standard music video uploads exactly";
        let clipped = clip_reason(rambling);
        assert!(clipped.chars().count() <= REASON_LIMIT + 1);
        assert!(clipped.ends_with('…'));
        assert_eq!(clip_reason(""), "");
    }

    fn candidate(id: &str, title: &str, channel: &str, duration: f64) -> Candidate {
        Candidate {
            id: id.into(),
            title: title.into(),
            channel: channel.into(),
            duration,
            view_count: None,
            live_now: false,
        }
    }

    #[test]
    fn the_chooser_lists_plausible_videos_first_and_keeps_the_rest() {
        let track = Track {
            id: 0,
            rel_path: "Artist/Song.flac".into(),
            title: "Song".into(),
            artist: "Artist".into(),
            album: "A".into(),
            album_artist: None,
            track_number: 1,
            duration: 200.0,
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
        };
        let list = vec![
            candidate("extended", "Artist - Song (10 Hour Loop)", "Loops", 36000.0),
            candidate("lyrics", "Artist - Song (Lyrics)", "7clouds", 201.0),
            candidate(
                "official",
                "Artist - Song (Official Video)",
                "Artist",
                205.0,
            ),
        ];
        let ordered = ranked_for_chooser(&track, list);
        let ids: Vec<&str> = ordered.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(ids, ["official", "lyrics", "extended"]);
    }
}
