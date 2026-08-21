use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use crate::lastfm::LastFmClient;
use flaccy_shared::enrichment_job::{self as job, EnrichmentRecord, Failure, Fields, Scope};
use gtk::gio;
use gtk::glib;
use gtk::prelude::*;
use std::cell::Cell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const USER_AGENT: &str = "flaccy/1.0 (https://github.com/guitaripod/flaccy)";
const SIMILAR_FRESH_SECONDS: i64 = 30 * 86_400;
const WORKER_COUNT: usize = 3;
const QUEUE_LIMIT: usize = 100_000;
const NETWORK_POLL: Duration = Duration::from_secs(1);
/// How long the workers stay parked after a run of transport failures when no
/// route change ever arrives to clear the suspicion.
const NETWORK_SUSPICION: Duration = Duration::from_secs(60);
/// Matches the Apple coordinator's coalescing window. `remaining` is two
/// `count(*)` queries, and three workers finishing in a burst must not run them
/// once per album.
const PROGRESS_COALESCE: Duration = Duration::from_millis(250);

pub enum EnrichRequest {
    Album { title: String, artist: String },
    Artist { name: String },
}

struct Outcome {
    title: String,
    artist: String,
    changed: bool,
}

struct Throttle {
    last: Option<Instant>,
    interval: Duration,
}

impl Throttle {
    fn new(interval: Duration) -> Self {
        Self {
            last: None,
            interval,
        }
    }

    fn wait(&mut self) {
        if let Some(last) = self.last {
            let elapsed = last.elapsed();
            if elapsed < self.interval {
                std::thread::sleep(self.interval - elapsed);
            }
        }
        self.last = Some(Instant::now());
    }
}

/// The two rate gates every worker shares. MusicBrainz insists on one request
/// per second across the whole client, and everything else is paced at 200 ms
/// so three threads never look like a scraper.
struct Gates {
    general: Mutex<Throttle>,
    musicbrainz: Mutex<Throttle>,
    consecutive_transport: AtomicI64,
    network_suspect: Arc<AtomicBool>,
}

impl Gates {
    fn new(network_suspect: Arc<AtomicBool>) -> Self {
        Self {
            general: Mutex::new(Throttle::new(Duration::from_millis(200))),
            musicbrainz: Mutex::new(Throttle::new(Duration::from_secs(1))),
            consecutive_transport: AtomicI64::new(0),
            network_suspect,
        }
    }

    /// The circuit breaker Apple's coordinator spells `consecutiveTransportFailures`.
    /// A run of transport verdicts means the route is answering nothing, so the
    /// workers park rather than burn the rest of the backlog against it; every
    /// other verdict — including a clean pass — is evidence the route works.
    fn note_verdict(&self, failure: Option<Failure>) {
        if failure == Some(Failure::Transport) {
            let seen = self.consecutive_transport.fetch_add(1, Ordering::Relaxed) + 1;
            if seen >= job::TRANSPORT_FAILURES_BEFORE_WAITING {
                self.consecutive_transport.store(0, Ordering::Relaxed);
                self.network_suspect.store(true, Ordering::Relaxed);
                crate::logger::warn(
                    "enrichment",
                    "no source answered five times running — enrichment parked until the route changes",
                );
            }
            return;
        }
        self.consecutive_transport.store(0, Ordering::Relaxed);
    }

    fn general(&self) {
        self.general
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .wait();
    }

    fn musicbrainz(&self) {
        self.musicbrainz
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .wait();
    }
}

/// What the sources said when they failed to hand over the required fields.
/// Only failures the sources never actually answered are recorded: a source
/// that says "I don't have it" is information, and the absence of any recorded
/// failure is what lets an entity walk the backoff ladder toward `exhausted`.
#[derive(Default)]
struct FailureLog {
    transport: bool,
    rate_limited: bool,
}

impl FailureLog {
    fn note(&mut self, failure: Failure) {
        match failure {
            Failure::Transport | Failure::Unauthorized => self.transport = true,
            Failure::RateLimited => self.rate_limited = true,
            Failure::NotFound => {}
        }
    }

    /// Transport outranks everything, because `exhausted` is terminal: an album
    /// may only be written off when every source genuinely answered.
    fn verdict(&self) -> Failure {
        if self.transport {
            Failure::Transport
        } else if self.rate_limited {
            Failure::RateLimited
        } else {
            Failure::NotFound
        }
    }
}

pub fn start(core: &Rc<AppCore>) {
    let (req_tx, req_rx) = async_channel::unbounded::<EnrichRequest>();
    let (done_tx, done_rx) = async_channel::unbounded::<Outcome>();
    let gates = Arc::new(Gates::new(Arc::clone(&core.network_suspect)));
    let session_key = core.session.borrow().as_ref().map(|s| s.key.clone());
    for index in 0..WORKER_COUNT {
        let db_path = core.db_path.clone();
        let session_key = session_key.clone();
        let gates = Arc::clone(&gates);
        let network = Arc::clone(&core.network_available);
        let rx = req_rx.clone();
        let tx = done_tx.clone();
        std::thread::Builder::new()
            .name(format!("flaccy-enrich-{index}"))
            .spawn(move || enrich_worker(db_path, session_key, gates, network, rx, tx))
            .ok();
    }
    *core.enrich_tx.borrow_mut() = Some(req_tx);
    watch_network(core);
    drain_completions(core, done_rx);
}

/// Mirrors GIO's reachability into the flag the workers poll. Nothing durable
/// is written while the network is down, so an offline stretch costs the queue
/// exactly nothing and it resumes from where it stopped.
///
/// A route change is also the evidence the circuit breaker was waiting for, so
/// it clears the suspicion flag: the whole point of parking is that the next
/// genuinely different route is worth trying.
fn watch_network(core: &Rc<AppCore>) {
    let monitor = gio::NetworkMonitor::default();
    core.network_available
        .store(monitor.is_network_available(), Ordering::Relaxed);
    let weak = Rc::downgrade(core);
    monitor.connect_network_changed(move |_, available| {
        let Some(core) = weak.upgrade() else { return };
        core.network_available.store(available, Ordering::Relaxed);
        core.network_suspect.store(false, Ordering::Relaxed);
        crate::logger::info(
            "enrichment",
            if available {
                "network reachable — enrichment resumed"
            } else {
                "network unreachable — enrichment suspended"
            },
        );
        core.refresh_job_progress();
    });
}

fn drain_completions(core: &Rc<AppCore>, done_rx: async_channel::Receiver<Outcome>) {
    let weak = Rc::downgrade(core);
    let reload_scheduled = Rc::new(Cell::new(false));
    let publish_scheduled = Rc::new(Cell::new(false));
    let unpark_scheduled = Rc::new(Cell::new(false));
    glib::spawn_future_local(async move {
        while let Ok(outcome) = done_rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            let label = if outcome.title.is_empty() {
                outcome.artist.clone()
            } else {
                outcome.title.clone()
            };
            core.enrich_in_flight
                .set(core.enrich_in_flight.get().saturating_sub(1));
            core.note_enrichment_completed(Some(label));
            schedule_unpark(&core, &unpark_scheduled);
            schedule_publish(&core, &publish_scheduled);
            drain_rerun(&core);
            if !outcome.changed {
                continue;
            }
            if !outcome.title.is_empty() {
                core.artwork.invalidate(&outcome.title, &outcome.artist);
                core.hub.emit(&AppEvent::AlbumEnriched {
                    title: outcome.title.clone(),
                    artist: outcome.artist.clone(),
                });
            }
            if !reload_scheduled.replace(true) {
                let weak_inner = Rc::downgrade(&core);
                let flag = Rc::clone(&reload_scheduled);
                glib::timeout_add_local_once(Duration::from_secs(15), move || {
                    flag.set(false);
                    if let Some(core) = weak_inner.upgrade() {
                        core.reload_library();
                    }
                });
            }
        }
    });
}

/// Runs the pass a scan asked for while the previous one was still draining,
/// once the channel is empty. One flag, one extra pass: the requests that were
/// coalesced into it are the same rows the SELECT will find again.
fn drain_rerun(core: &Rc<AppCore>) {
    if !core.enrich_rerun.get() || queue_is_draining(core) {
        return;
    }
    core.enrich_rerun.set(false);
    schedule_background_pass(core);
}

/// Gives the parked workers a way out that does not depend on the route
/// changing. Without it a run of five timeouts on an otherwise working
/// connection would park the queue until the next relaunch, which is a worse
/// bug than the one the breaker exists to fix.
fn schedule_unpark(core: &Rc<AppCore>, scheduled: &Rc<Cell<bool>>) {
    if !core.network_suspect.load(Ordering::Relaxed) || scheduled.replace(true) {
        return;
    }
    let weak = Rc::downgrade(core);
    let flag = Rc::clone(scheduled);
    glib::timeout_add_local_once(NETWORK_SUSPICION, move || {
        flag.set(false);
        let Some(core) = weak.upgrade() else { return };
        core.network_suspect.store(false, Ordering::Relaxed);
        crate::logger::info(
            "enrichment",
            "network suspicion expired — enrichment resumed",
        );
        core.refresh_job_progress();
    });
}

fn schedule_publish(core: &Rc<AppCore>, scheduled: &Rc<Cell<bool>>) {
    if scheduled.replace(true) {
        return;
    }
    let weak = Rc::downgrade(core);
    let flag = Rc::clone(scheduled);
    glib::timeout_add_local_once(PROGRESS_COALESCE, move || {
        flag.set(false);
        if let Some(core) = weak.upgrade() {
            core.refresh_job_progress();
        }
    });
}

pub fn request_album(core: &Rc<AppCore>, title: &str, artist: &str) {
    let sent = core
        .enrich_tx
        .borrow()
        .as_ref()
        .map(|tx| {
            tx.send_blocking(EnrichRequest::Album {
                title: title.to_string(),
                artist: artist.to_string(),
            })
            .is_ok()
        })
        .unwrap_or(false);
    if sent {
        note_requested(core);
    }
}

pub fn request_artist(core: &Rc<AppCore>, name: &str) {
    let sent = core
        .enrich_tx
        .borrow()
        .as_ref()
        .map(|tx| {
            tx.send_blocking(EnrichRequest::Artist {
                name: name.to_string(),
            })
            .is_ok()
        })
        .unwrap_or(false);
    if sent {
        note_requested(core);
    }
}

/// Every accepted request produces exactly one `Outcome` — including the
/// `is_due == false` early return — so this counter balances, and it is what
/// tells "the job is working" from "a hundred albums a transport failure left
/// pending are still due while nothing is in flight".
fn note_requested(core: &Rc<AppCore>) {
    core.enrich_in_flight.set(core.enrich_in_flight.get() + 1);
}

/// The Linux twin of `EnrichmentCoordinator.resume()`: cheap to call every time
/// a scan settles, which is what keeps an album dropped into the watched folder
/// mid-session from waiting for the next launch to be enriched. A pass asked for
/// while the queue is still draining is remembered rather than re-pushed, so a
/// rescan mid-pass costs one flag instead of a second copy of the backlog.
pub fn request_background_pass(core: &Rc<AppCore>) {
    if queue_is_draining(core) {
        core.enrich_rerun.set(true);
    } else {
        schedule_background_pass(core);
    }
    core.refresh_job_progress();
}

fn queue_is_draining(core: &Rc<AppCore>) -> bool {
    core.enrich_tx
        .borrow()
        .as_ref()
        .map(|tx| !tx.is_empty())
        .unwrap_or(false)
}

/// Queues exactly what the database says is due — one SELECT for albums, one
/// for artists — instead of walking the in-memory library and interrogating
/// every album in turn. An entity that is settled, backing off, or terminal
/// never reaches the channel.
///
/// Asking for a pass clears the circuit breaker: every caller is either a scan
/// settling or a reader pressing Try Again, and a Try Again that queues work
/// nobody will pick up is a button that does nothing.
pub fn schedule_background_pass(core: &Rc<AppCore>) {
    core.network_suspect.store(false, Ordering::Relaxed);
    let now = chrono::Utc::now();
    let albums = core
        .db
        .due_album_keys(Scope::Album.current_version(), now, QUEUE_LIMIT);
    let artists = core
        .db
        .due_artist_names(Scope::Artist.current_version(), now, QUEUE_LIMIT);
    for (title, artist) in &albums {
        request_album(core, title, artist);
    }
    for name in &artists {
        request_artist(core, name);
    }
    if !albums.is_empty() || !artists.is_empty() {
        crate::logger::info(
            "enrichment",
            &format!(
                "background pass queued {} albums and {} artists",
                albums.len(),
                artists.len()
            ),
        );
    }
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent(USER_AGENT)
        .build()
}

fn enrich_worker(
    db_path: PathBuf,
    session_key: Option<String>,
    gates: Arc<Gates>,
    network: Arc<AtomicBool>,
    rx: async_channel::Receiver<EnrichRequest>,
    tx: async_channel::Sender<Outcome>,
) {
    let Ok(db) = Db::open(&db_path) else {
        crate::logger::error("enrichment", "worker db open failed");
        return;
    };
    let client = LastFmClient::new(session_key);

    while let Ok(request) = rx.recv_blocking() {
        if !wait_for_network(&network, &gates, &rx) {
            break;
        }
        let outcome = match request {
            EnrichRequest::Album { title, artist } => {
                let changed = enrich_album(&db, client.as_ref(), &gates, &title, &artist);
                Outcome {
                    title,
                    artist,
                    changed,
                }
            }
            EnrichRequest::Artist { name } => {
                let changed = enrich_artist(&db, client.as_ref(), &gates, &name);
                Outcome {
                    title: String::new(),
                    artist: name,
                    changed,
                }
            }
        };
        if tx.send_blocking(outcome).is_err() {
            break;
        }
    }
}

/// Parks the worker while there is no route out — either because GIO says so,
/// or because the requests themselves have stopped being answered. Returns
/// false once the queue is closed, so a shutdown during an offline stretch is
/// not a hung thread.
fn wait_for_network(
    network: &AtomicBool,
    gates: &Gates,
    rx: &async_channel::Receiver<EnrichRequest>,
) -> bool {
    while !network.load(Ordering::Relaxed) || gates.network_suspect.load(Ordering::Relaxed) {
        if rx.is_closed() {
            return false;
        }
        std::thread::sleep(NETWORK_POLL);
    }
    true
}

/// Resolves one album and records the attempt. The idempotence predicate is the
/// only gate: a settled, backing-off or terminal album returns without touching
/// the network, which is what replaces the old per-process "already seen" set.
fn enrich_album(
    db: &Db,
    client: Option<&LastFmClient>,
    gates: &Gates,
    title: &str,
    artist: &str,
) -> bool {
    let key = job::key_album(title, artist);
    let mut record = db
        .fetch_enrichment_record(Scope::Album, &key)
        .unwrap_or_else(|| EnrichmentRecord::new(Scope::Album, key));
    let now = chrono::Utc::now();
    if !job::is_due(Some(&record), Scope::Album, now) {
        return false;
    }

    let status = db.album_info_status(title, artist);
    let has_cover = status.as_ref().map(|s| s.has_cover).unwrap_or(false);
    let had_year = status.as_ref().and_then(|s| s.year.clone());
    let had_genre = status.as_ref().and_then(|s| s.genre.clone());

    if has_cover && had_year.is_some() {
        let resolved = album_fields(true, true, had_genre.is_some(), false);
        settle_album(db, &mut record, resolved, now, title, artist);
        return false;
    }

    let mut failures = FailureLog::default();
    let mut cover_url: Option<String> = None;
    let mut cover_data: Option<Vec<u8>> = None;
    let mut mbid: Option<String> = None;
    let mut year: Option<String> = None;
    let mut genre: Option<String> = None;

    if let Some(client) = client {
        gates.general();
        match client.fetch_album_info(artist, title) {
            Ok((url, id)) => {
                cover_url = url;
                mbid = id;
            }
            Err(err) => {
                failures.note(classify_lastfm(&err));
                crate::logger::warn(
                    "enrichment",
                    &format!("album.getInfo failed for {title}: {err}"),
                );
            }
        }
    }

    if !has_cover {
        if let Some(url) = &cover_url {
            match download_bytes(url) {
                Ok(data) => cover_data = Some(data),
                Err(failure) => failures.note(failure),
            }
        }
    }

    gates.musicbrainz();
    match fetch_musicbrainz_release(artist, title) {
        Ok(Some(release)) => {
            if !has_cover && cover_data.is_none() {
                if let Some(group) = &release.release_group_id {
                    match fetch_cover_art_archive("release-group", group) {
                        Ok(data) => cover_data = Some(data),
                        Err(failure) => failures.note(failure),
                    }
                }
            }
            if !has_cover && cover_data.is_none() {
                match fetch_cover_art_archive("release", &release.id) {
                    Ok(data) => cover_data = Some(data),
                    Err(failure) => failures.note(failure),
                }
            }
            year = release.year;
            genre = release.genre;
            if mbid.is_none() {
                mbid = Some(release.id);
            }
        }
        Ok(None) => {}
        Err(failure) => failures.note(failure),
    }

    if !has_cover && cover_data.is_none() {
        match fetch_deezer_album_cover(artist, title) {
            Ok(Some(data)) => cover_data = Some(data),
            Ok(None) => {}
            Err(failure) => failures.note(failure),
        }
    }

    let resolved = album_fields(
        has_cover || cover_data.is_some(),
        had_year.is_some() || year.is_some(),
        had_genre.is_some() || genre.is_some(),
        mbid.is_some(),
    );
    let failure = verdict(&failures, resolved, Scope::Album);
    gates.note_verdict(failure);
    job::apply(&mut record, Scope::Album, resolved, failure, now);

    if let Err(err) = db.commit_album_enrichment(
        title,
        artist,
        year.as_deref(),
        genre.as_deref(),
        cover_url.as_deref(),
        cover_data.as_deref(),
        mbid.as_deref(),
        &record,
    ) {
        crate::logger::error(
            "enrichment",
            &format!("albumInfo write failed for {title}: {err}"),
        );
        return false;
    }

    crate::logger::info(
        "enrichment",
        &format!(
            "enriched {title} — {artist} (year {year:?}, genre {genre:?}, cover {}, outcome {:?})",
            cover_data.as_ref().map(|d| d.len()).unwrap_or(0),
            failure
        ),
    );
    year.is_some() || genre.is_some() || cover_data.is_some()
}

/// An artist is its own durable entity, so a photo and a bio are looked up once
/// ever rather than once per launch for every artist the library credits.
fn enrich_artist(db: &Db, client: Option<&LastFmClient>, gates: &Gates, name: &str) -> bool {
    let key = job::key_artist(name);
    let mut record = db
        .fetch_enrichment_record(Scope::Artist, &key)
        .unwrap_or_else(|| EnrichmentRecord::new(Scope::Artist, key));
    let now = chrono::Utc::now();
    if !job::is_due(Some(&record), Scope::Artist, now) {
        return false;
    }

    let had_bio = db.artist_bio(name).is_some();
    let had_image = db.artist_image_url(name).is_some();
    if had_bio && had_image {
        settle_artist(db, &mut record, artist_fields(true, true, false), now, name);
        return false;
    }

    let mut failures = FailureLog::default();
    let mut bio: Option<String> = None;
    let mut image_url: Option<String> = None;
    let mut mbid: Option<String> = None;

    if let Some(client) = client {
        gates.general();
        match client.fetch_artist_info(name) {
            Ok((summary, lastfm_image, artist_mbid)) => {
                bio = summary;
                image_url = lastfm_image;
                mbid = artist_mbid;
            }
            Err(err) => {
                failures.note(classify_lastfm(&err));
                crate::logger::warn(
                    "enrichment",
                    &format!("artist.getInfo failed for {name}: {err}"),
                );
            }
        }
    }

    gates.general();
    match fetch_deezer_artist_image(name) {
        Ok(Some(url)) => image_url = Some(url),
        Ok(None) => {}
        Err(failure) => failures.note(failure),
    }

    let resolved = artist_fields(
        had_bio || bio.is_some(),
        had_image || image_url.is_some(),
        mbid.is_some(),
    );
    let failure = verdict(&failures, resolved, Scope::Artist);
    gates.note_verdict(failure);
    job::apply(&mut record, Scope::Artist, resolved, failure, now);

    if let Err(err) = db.commit_artist_enrichment(
        name,
        bio.as_deref(),
        image_url.as_deref(),
        mbid.as_deref(),
        &record,
    ) {
        crate::logger::error("enrichment", &format!("artist write failed for {name}: {err}"));
        return false;
    }
    bio.is_some() || image_url.is_some()
}

fn album_fields(cover: bool, year: bool, genre: bool, mbid: bool) -> Fields {
    let mut fields = Fields::NONE;
    if cover {
        fields.form_union(Fields::COVER);
    }
    if year {
        fields.form_union(Fields::YEAR);
    }
    if genre {
        fields.form_union(Fields::GENRE);
    }
    if mbid {
        fields.form_union(Fields::MBID);
    }
    fields
}

fn artist_fields(bio: bool, image: bool, mbid: bool) -> Fields {
    let mut fields = Fields::NONE;
    if bio {
        fields.form_union(Fields::ARTIST_BIO);
    }
    if image {
        fields.form_union(Fields::ARTIST_IMAGE);
    }
    if mbid {
        fields.form_union(Fields::MBID);
    }
    fields
}

fn verdict(failures: &FailureLog, resolved: Fields, scope: Scope) -> Option<Failure> {
    if resolved.contains(Fields::required(scope)) {
        None
    } else {
        Some(failures.verdict())
    }
}

/// Records an album the database already satisfied, so it leaves the queue for
/// good without a single request. This is the path that closes the "400 albums
/// enriched daily" hole for libraries whose covers came from their own files.
fn settle_album(
    db: &Db,
    record: &mut EnrichmentRecord,
    resolved: Fields,
    now: chrono::DateTime<chrono::Utc>,
    title: &str,
    artist: &str,
) {
    job::apply(record, Scope::Album, resolved, None, now);
    if let Err(err) = db.commit_album_enrichment(title, artist, None, None, None, None, None, record)
    {
        crate::logger::error(
            "enrichment",
            &format!("enrichmentState write failed for {title}: {err}"),
        );
    }
}

/// The artist twin of `settle_album`.
fn settle_artist(
    db: &Db,
    record: &mut EnrichmentRecord,
    resolved: Fields,
    now: chrono::DateTime<chrono::Utc>,
    name: &str,
) {
    job::apply(record, Scope::Artist, resolved, None, now);
    if let Err(err) = db.commit_artist_enrichment(name, None, None, None, record) {
        crate::logger::error(
            "enrichment",
            &format!("enrichmentState write failed for {name}: {err}"),
        );
    }
}

/// A source that answered with an HTTP status told us something; a socket that
/// never opened, or a captive portal handing back HTML, told us nothing. Only
/// the first kind may ever push an entity toward its terminal state.
fn classify(error: &ureq::Error) -> Failure {
    match error {
        ureq::Error::Status(429, _) => Failure::RateLimited,
        ureq::Error::Status(400 | 404 | 410, _) => Failure::NotFound,
        ureq::Error::Status(_, _) => Failure::Transport,
        ureq::Error::Transport(_) => Failure::Transport,
    }
}

/// Last.fm's client collapses every failure into a message string. A parsed,
/// well-formed negative names itself ("Album not found"); anything else is
/// treated as transport, because writing an album off on a lie is recoverable
/// only by Try Again.
fn classify_lastfm(message: &str) -> Failure {
    let lower = message.to_lowercase();
    if lower.contains("rate limit") {
        return Failure::RateLimited;
    }
    if lower.contains("not found") || lower.contains("no album") || lower.contains("no artist") {
        return Failure::NotFound;
    }
    Failure::Transport
}

fn download_bytes(url: &str) -> Result<Vec<u8>, Failure> {
    let response = agent().get(url).call().map_err(|err| classify(&err))?;
    let mut data = Vec::new();
    use std::io::Read;
    response
        .into_reader()
        .take(20 * 1024 * 1024)
        .read_to_end(&mut data)
        .map_err(|_| Failure::Transport)?;
    if data.is_empty() {
        Err(Failure::NotFound)
    } else {
        Ok(data)
    }
}

struct MusicBrainzRelease {
    id: String,
    release_group_id: Option<String>,
    year: Option<String>,
    genre: Option<String>,
}

fn fetch_musicbrainz_release(
    artist: &str,
    album: &str,
) -> Result<Option<MusicBrainzRelease>, Failure> {
    let query = format!("release:{album} AND artist:{artist}");
    let url = format!(
        "https://musicbrainz.org/ws/2/release/?query={}&limit=1&fmt=json",
        url_encode(&query)
    );
    let text = agent()
        .get(&url)
        .call()
        .map_err(|err| classify(&err))?
        .into_string()
        .map_err(|_| Failure::Transport)?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|_| Failure::Transport)?;
    let Some(release) = json["releases"].as_array().and_then(|list| list.first()) else {
        return Ok(None);
    };
    let Some(id) = release["id"].as_str().map(String::from) else {
        return Ok(None);
    };
    let release_group_id = release["release-group"]["id"].as_str().map(String::from);
    let year = release["date"]
        .as_str()
        .filter(|date| date.len() >= 4)
        .map(|date| date[..4].to_string());
    let genre = release["tags"].as_array().and_then(|tags| {
        tags.iter()
            .max_by_key(|tag| tag["count"].as_i64().unwrap_or(0))
            .and_then(|tag| tag["name"].as_str())
            .map(String::from)
    });
    Ok(Some(MusicBrainzRelease {
        id,
        release_group_id,
        year,
        genre,
    }))
}

/// Cover Art Archive front cover for a MusicBrainz release or release-group,
/// downsized to 500px. This is the Linux stand-in for the iOS Apple Music
/// artwork fallback: it covers albums whose files have no embedded art and
/// which Last.fm has no image for.
fn fetch_cover_art_archive(entity: &str, mbid: &str) -> Result<Vec<u8>, Failure> {
    download_bytes(&format!(
        "https://coverartarchive.org/{entity}/{mbid}/front-500"
    ))
}

/// Deezer album cover (no API key) — a broad streaming-catalog fallback that
/// covers many releases MusicBrainz/Cover Art Archive don't, matching how
/// Strawberry pulls art from multiple providers.
fn fetch_deezer_album_cover(artist: &str, album: &str) -> Result<Option<Vec<u8>>, Failure> {
    let query = format!("artist:\"{artist}\" album:\"{album}\"");
    let url = format!(
        "https://api.deezer.com/search/album?q={}&limit=1",
        url_encode(&query)
    );
    let text = agent()
        .get(&url)
        .call()
        .map_err(|err| classify(&err))?
        .into_string()
        .map_err(|_| Failure::Transport)?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|_| Failure::Transport)?;
    let Some(cover) = json["data"][0]["cover_xl"]
        .as_str()
        .or_else(|| json["data"][0]["cover_big"].as_str())
        .filter(|url| !url.is_empty())
    else {
        return Ok(None);
    };
    download_bytes(cover).map(Some)
}

/// Deezer artist photo URL (no API key) — a real portrait source, unlike
/// Last.fm which now serves a placeholder for every artist.
fn fetch_deezer_artist_image(artist: &str) -> Result<Option<String>, Failure> {
    let url = format!(
        "https://api.deezer.com/search/artist?q={}&limit=1",
        url_encode(artist)
    );
    let text = agent()
        .get(&url)
        .call()
        .map_err(|err| classify(&err))?
        .into_string()
        .map_err(|_| Failure::Transport)?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|_| Failure::Transport)?;
    Ok(json["data"][0]["picture_xl"]
        .as_str()
        .or_else(|| json["data"][0]["picture_big"].as_str())
        .filter(|url| !url.is_empty())
        .map(String::from))
}

/// Blocking similar-artists lookup with the 30-day similarArtistCache window,
/// intersected case-insensitively with the library's artists. Runs on worker
/// threads only.
pub fn similar_in_library_blocking(
    db: &Db,
    client: Option<&LastFmClient>,
    seed_artist: &str,
    library_artists: &[String],
) -> Vec<(String, f64)> {
    let now = chrono::Utc::now().timestamp();
    let cached = db.similar_artists(seed_artist);
    let fresh = cached
        .first()
        .map(|(_, _, fetched)| now - fetched < SIMILAR_FRESH_SECONDS)
        .unwrap_or(false);
    let similar: Vec<(String, f64)> = if fresh {
        cached
            .into_iter()
            .map(|(name, matched, _)| (name, matched))
            .collect()
    } else if let Some(client) = client {
        match client.fetch_similar_artists(seed_artist) {
            Ok(entries) => {
                if let Err(err) = db.replace_similar_artists(seed_artist, &entries) {
                    crate::logger::warn(
                        "enrichment",
                        &format!("similarArtistCache write failed: {err}"),
                    );
                }
                entries
            }
            Err(err) => {
                crate::logger::warn(
                    "enrichment",
                    &format!("artist.getSimilar failed for {seed_artist}: {err}"),
                );
                cached
                    .into_iter()
                    .map(|(name, matched, _)| (name, matched))
                    .collect()
            }
        }
    } else {
        cached
            .into_iter()
            .map(|(name, matched, _)| (name, matched))
            .collect()
    };

    let owned: std::collections::HashMap<String, String> = library_artists
        .iter()
        .map(|name| (name.to_lowercase(), name.clone()))
        .collect();
    let mut result: Vec<(String, f64)> = similar
        .into_iter()
        .filter_map(|(name, matched)| {
            owned
                .get(&name.to_lowercase())
                .map(|canonical| (canonical.clone(), matched))
        })
        .collect();
    result.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
    result
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
