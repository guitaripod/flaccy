use crate::config::{self, Config, Session};
use crate::db::Db;
use crate::eq::EqEngine;
use crate::events::{AppEvent, EventHub};
use crate::home_state::{self, SavedSession, SavedTrack};
use crate::library::{self, Library, Track};
use crate::load_progress::{LoadPhase, LoadProgress};
use crate::player::Player;
use crate::scanner::{self, ScanEvent};
use crate::ui;
use crate::versions;
use adw::prelude::*;
use flaccy_shared::enrichment_job::{Activity, JobProgress, Scope};
use flaccy_shared::home::{self, ContextKind, PlaybackContext, RecentContexts};
use flaccy_shared::home_copy;
use flaccy_shared::import_plan;
use flaccy_shared::library_debut::DebutSummary;
use flaccy_shared::track_revision::copy;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

pub struct AppCore {
    pub db: Db,
    pub db_path: PathBuf,
    pub config: RefCell<Config>,
    pub library: RefCell<Rc<Library>>,
    pub hub: Rc<EventHub>,
    pub player: Rc<Player>,
    pub eq: Rc<EqEngine>,
    pub session: RefCell<Option<Session>>,
    pub artwork: ui::artwork::ArtworkCache,
    pub scanning: Cell<bool>,
    pub smoke: bool,
    pub current_play: RefCell<Option<crate::scrobbler::CurrentPlay>>,
    pub drain_in_flight: Rc<Cell<bool>>,
    pub mpris: RefCell<Option<Rc<mpris_server::Player>>>,
    pub enrich_tx: RefCell<Option<async_channel::Sender<crate::enrichment::EnrichRequest>>>,
    pub history_sync_in_flight: Cell<bool>,
    pub history_state: RefCell<Option<flaccy_library::listen_history::HistorySyncState>>,
    pub history_status: RefCell<crate::history_sync::HistoryStatus>,
    /// Paths that have a version kept in Previous Versions, so a track's context
    /// menu can offer to restore it without asking the database per row.
    previous_versions: RefCell<HashSet<String>>,
    pub sample_in_flight: Cell<bool>,
    pub sleep_remaining: Cell<Option<i64>>,
    pub sleep_end_of_track: Cell<bool>,
    pub autoplay_in_flight: Cell<bool>,
    pub wantlist_in_flight: Cell<bool>,
    pub downloads: crate::downloads::DownloadHandle,
    pub music_video: crate::musicvideo::MusicVideoHandle,
    /// GIO's reachability verdict, shared with the enrichment workers so an
    /// offline stretch suspends the job instead of burning attempts on it.
    pub network_available: Arc<AtomicBool>,
    /// How many enrichment requests are queued or being worked on right now.
    /// The countdown is a `count(*)`, but *whether the job is running* is not
    /// answerable from the database: a pass that ends with a hundred albums
    /// still due after a hundred transport failures is idle, not busy.
    pub enrich_in_flight: Cell<usize>,
    /// Set when a pass is asked for while one is still draining, so a rescan
    /// mid-pass costs one flag instead of a second copy of the backlog.
    pub enrich_rerun: Cell<bool>,
    /// Raised by the workers after a run of transport failures, and cleared by
    /// a route change, a bounded timer or an explicit retry. Separate from
    /// `network_available` on purpose: GIO can call a captive portal
    /// reachable, and only the requests know it is not.
    pub network_suspect: Arc<AtomicBool>,
    /// Whether the reload now in flight is closing out an album build, so the
    /// determinate 100% is emitted for a scan and not for every reload.
    building_albums: Cell<bool>,
    reload_in_flight: Cell<bool>,
    reload_pending: Cell<bool>,
    job: RefCell<JobProgress>,
    /// The playing track's synced lyrics, so the seek bar can name the line
    /// under the pointer. Cleared the moment the track changes.
    lyrics: RefCell<crate::lyrics::Lyrics>,
    /// The level unmuting returns to.
    restore_volume: Cell<f64>,
    config_save_queued: Cell<bool>,
    /// A refresh of the servers' catalogs is running, so another is not begun.
    pub remote_syncing: Cell<bool>,
    /// What the queue now playing was started from, for Home's Continue and
    /// Jump Back In.
    context: RefCell<PlaybackContext>,
    /// The albums, playlists, mixes and radios the person started.
    pub recents: RefCell<RecentContexts>,
    /// The queue as it stood when playback was last touched, kept across
    /// launches so Home can offer to carry on.
    pub last_session: RefCell<Option<SavedSession>>,
    session_save_queued: Cell<bool>,
    session_saved_position: Cell<f64>,
    /// Flaccy Server sync, set once the window exists.
    pub server_sync: std::cell::OnceCell<Rc<crate::server_sync::Service>>,
}

/// How long after launch the servers are refreshed first, and how often after.
const REMOTE_FIRST_REFRESH_DELAY: Duration = Duration::from_millis(800);
const REMOTE_REFRESH_INTERVAL: Duration = Duration::from_secs(6 * 60 * 60);
/// Below this the volume counts as muted.
const MUTE_FLOOR: f64 = 0.005;
/// Where unmuting lands when there is no earlier level to return to.
const UNMUTE_DEFAULT: f64 = 0.6;
/// The most songs a saved session keeps, so an endless station's queue never
/// turns every track change into a megabyte write.
const SESSION_MAX_TRACKS: usize = 1000;
/// How many songs behind the current one a trimmed session keeps.
const SESSION_TRAILING_TRACKS: usize = 100;
/// How often playback progress is written while a song plays, in seconds.
const SESSION_PROGRESS_INTERVAL: f64 = 15.0;
/// How long queue and track changes wait to be written as one session.
const SESSION_SAVE_DELAY: Duration = Duration::from_millis(300);
/// How long a settled change waits before it is written to the config file, so
/// a drag across the volume slider saves once rather than on every frame.
const CONFIG_SAVE_DELAY: Duration = Duration::from_millis(400);

impl AppCore {
    pub fn new(smoke: bool) -> Rc<Self> {
        let config = config::load();
        let db_path = crate::db::default_db_path();
        let db = Db::open_with_recovery(&db_path).expect("library database must open");
        crate::remote::start(&config, &db_path);
        let hub = Rc::new(EventHub::new());
        let root = config.music_root();
        crate::logger::info("lifecycle", &format!("library root: {}", root.display()));
        let eq = EqEngine::new(Rc::clone(&hub));
        let player = Player::new(Rc::clone(&hub), root, eq.element());
        player.set_volume(config.volume);
        player.set_shuffle(config.shuffle);
        player.set_repeat(crate::player::RepeatMode::from_id(&config.repeat_mode));
        if config::demo_mode() && std::env::var("FLACCY_DEMO_HOME").as_deref() == Ok("dayone") {
            db.delete_all_scrobbles();
        }
        let session = config::load_session();
        if let Some(session) = &session {
            crate::logger::info(
                "auth",
                &format!("last.fm session loaded for {}", session.username),
            );
        }
        let artwork = ui::artwork::ArtworkCache::new(db_path.clone());
        let restore_volume = if config.volume > MUTE_FLOOR {
            config.volume
        } else {
            UNMUTE_DEFAULT
        };

        let core = Rc::new(Self {
            db,
            db_path,
            config: RefCell::new(config),
            library: RefCell::new(Rc::new(Library::empty())),
            hub,
            player,
            eq,
            session: RefCell::new(session),
            artwork,
            scanning: Cell::new(false),
            smoke,
            current_play: RefCell::new(None),
            drain_in_flight: Rc::new(Cell::new(false)),
            mpris: RefCell::new(None),
            enrich_tx: RefCell::new(None),
            history_sync_in_flight: Cell::new(false),
            history_state: RefCell::new(None),
            history_status: RefCell::new(crate::history_sync::HistoryStatus::Waiting),
            previous_versions: RefCell::new(HashSet::new()),
            sample_in_flight: Cell::new(false),
            sleep_remaining: Cell::new(None),
            sleep_end_of_track: Cell::new(false),
            autoplay_in_flight: Cell::new(false),
            wantlist_in_flight: Cell::new(false),
            downloads: crate::downloads::DownloadHandle::new(),
            music_video: crate::musicvideo::MusicVideoHandle::new(),
            network_available: Arc::new(AtomicBool::new(true)),
            enrich_in_flight: Cell::new(0),
            enrich_rerun: Cell::new(false),
            network_suspect: Arc::new(AtomicBool::new(false)),
            building_albums: Cell::new(false),
            reload_in_flight: Cell::new(false),
            reload_pending: Cell::new(false),
            job: RefCell::new(JobProgress::idle()),
            lyrics: RefCell::new(crate::lyrics::Lyrics::default()),
            restore_volume: Cell::new(restore_volume),
            config_save_queued: Cell::new(false),
            remote_syncing: Cell::new(false),
            context: RefCell::new(PlaybackContext::anonymous_queue()),
            recents: RefCell::new(
                Some(home_state::load_recents())
                    .filter(|_| std::env::var("FLACCY_DEMO_HOME").as_deref() != Ok("dayone"))
                    .unwrap_or_default(),
            ),
            last_session: RefCell::new(
                home_state::load_session()
                    .filter(|_| std::env::var("FLACCY_DEMO_HOME").as_deref() != Ok("dayone")),
            ),
            session_save_queued: Cell::new(false),
            session_saved_position: Cell::new(0.0),
            server_sync: std::cell::OnceCell::new(),
        });
        core.artwork.start(&core);
        core.wire_scrobbler();
        core.wire_remote();
        core.wire_session();
        core
    }

    pub fn music_root(&self) -> PathBuf {
        self.config.borrow().music_root()
    }

    fn refresh_previous_versions(&self) {
        *self.previous_versions.borrow_mut() = self
            .db
            .fetch_previous_versions()
            .into_iter()
            .map(|version| version.rel_path)
            .collect();
    }

    pub fn has_previous_version(&self, rel_path: &str) -> bool {
        self.previous_versions.borrow().contains(rel_path)
    }

    /// Deletes the previous versions that have been kept past the retention,
    /// off the main thread, then refreshes what the menus offer.
    fn purge_expired_versions(self: &Rc<Self>) {
        let db_path = self.db_path.clone();
        let (tx, rx) = async_channel::bounded::<usize>(1);
        std::thread::Builder::new()
            .name("flaccy-purge".into())
            .spawn(move || {
                let purged = Db::open(&db_path)
                    .map(|db| versions::purge_expired(&db, crate::db::now_ms()))
                    .unwrap_or(0);
                let _ = tx.send_blocking(purged);
            })
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(purged) = rx.recv().await else { return };
            if purged > 0 {
                crate::logger::info("library", &format!("purged {purged} expired previous versions"));
                if let Some(core) = weak.upgrade() {
                    core.refresh_previous_versions();
                }
            }
        });
    }

    /// Swaps a song with the version kept for it, off the main thread, and
    /// reloads the views from the same row.
    pub fn restore_previous_version(self: &Rc<Self>, rel_path: &str) {
        let Some(track) = self.library.borrow().track_by_rel_path(rel_path).cloned() else {
            return;
        };
        let (db_path, root, rel) = (self.db_path.clone(), self.music_root(), rel_path.to_string());
        let (tx, rx) = async_channel::bounded::<Result<(), versions::VersionFailure>>(1);
        std::thread::Builder::new()
            .name("flaccy-restore".into())
            .spawn(move || {
                let result = match Db::open(&db_path) {
                    Ok(db) => versions::restore_previous(&db, &root, &rel),
                    Err(err) => Err(versions::VersionFailure {
                        step: "opening the library database",
                        cause: err.to_string(),
                    }),
                };
                let _ = tx.send_blocking(result);
            })
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(result) = rx.recv().await else { return };
            let Some(core) = weak.upgrade() else { return };
            match result {
                Ok(()) => {
                    crate::logger::info("library", &format!("restored the previous mix of {}", track.title));
                    core.reload_library();
                    core.reopen_if_playing(&track.rel_path, false);
                    core.toast(&copy::fill(copy::RESTORED, &[&track.title]));
                }
                Err(failure) => {
                    crate::logger::error(
                        "library",
                        &format!("restore failed for {}: {} — {}", track.rel_path, failure.step, failure.cause),
                    );
                    core.toast(&format!(
                        "Couldn’t restore the previous mix of “{}” — {} failed: {}. Nothing was changed; check the folder’s permissions and try again.",
                        track.title, failure.step, failure.cause
                    ));
                }
            }
        });
    }

    /// Reopens the playing song when it is `rel_path`, so the player reads the
    /// file now at that path instead of the one it opened.
    pub fn reopen_if_playing(&self, rel_path: &str, from_start: bool) {
        let playing = self
            .player
            .current_track()
            .is_some_and(|track| track.rel_path == rel_path);
        if playing {
            self.player.reopen_current(from_start);
        }
    }

    /// Reloads the views for songs the scan recognised as new versions, and
    /// offers the new mix from the start when one of them is playing.
    pub(crate) fn note_new_versions(self: &Rc<Self>, rel_paths: &[String]) {
        self.reload_library();
        if let Some(track) = self.player.current_track() {
            if rel_paths.contains(&track.rel_path) {
                self.hub.emit(&AppEvent::NewMixPlaying {
                    rel_path: track.rel_path,
                    title: track.title,
                });
            }
        }
    }

    /// Loads the library on a dedicated thread (own SQLite connection) and
    /// applies the result on the main loop, so a large library never stalls
    /// the UI. Overlapping requests coalesce into one trailing reload.
    ///
    /// The read is the `OpeningLibrary` phase of the shared load bar — the
    /// 0.05 slice every client mirrors — and it always ends by publishing
    /// `Idle`, so a phase stream that starts is a phase stream that finishes.
    pub fn reload_library(self: &Rc<Self>) {
        if self.reload_in_flight.replace(true) {
            self.reload_pending.set(true);
            return;
        }
        self.hub.emit(&AppEvent::ScanProgress(LoadProgress::new(
            LoadPhase::OpeningLibrary,
        )));
        let db_path = self.db_path.clone();
        let group_album_editions = self.config.borrow().group_album_editions;
        let (tx, rx) = async_channel::bounded::<(Library, Vec<(String, f64)>)>(1);
        std::thread::Builder::new()
            .name("flaccy-reload".into())
            .spawn(move || {
                let Ok(db) = Db::open(&db_path) else { return };
                db.resolve_album_credits();
                let library = library::load(&db, group_album_editions);
                let now = chrono::Utc::now().timestamp();
                let weights = db
                    .track_sort_keys()
                    .into_iter()
                    .map(|(rel, last_played)| {
                        (rel, crate::station::history_weight(last_played, now))
                    })
                    .collect();
                let _ = tx.send_blocking((library, weights));
            })
            .ok();
        let core = Rc::clone(self);
        glib::spawn_future_local(async move {
            let received = rx.recv().await;
            core.reload_in_flight.set(false);
            let Ok((library, weights)) = received else {
                return;
            };
            core.player
                .set_history_weights(weights.into_iter().collect());
            crate::logger::info(
                "library",
                &format!(
                    "library loaded: {} tracks, {} albums, {} artists",
                    library.tracks.len(),
                    library.albums.len(),
                    library.artists.len()
                ),
            );
            *core.library.borrow_mut() = Rc::new(library);
            core.refresh_previous_versions();
            core.record_library_debut();
            if core.building_albums.replace(false) {
                core.emit_build_completed();
            }
            core.hub
                .emit(&AppEvent::ScanProgress(LoadProgress::new(LoadPhase::Idle)));
            core.hub.emit(&AppEvent::LibraryReloaded);
            if core.reload_pending.replace(false) {
                core.reload_library();
            }
        });
    }

    /// Writes the once-per-library setup summary the first time a build yields
    /// an album, and never again. This is Linux's counterpart to the Apple
    /// clients' `LibraryStartupProbe.markIndexed()`, which fires at the same
    /// point in the first build: a library that has been indexed once has had
    /// its Debut, so quitting mid-show does not replay the showpiece on the
    /// next launch. `Stage::finish` overwrites the row with what the reader
    /// actually saw, so the build-time figures are a floor, not the report.
    fn record_library_debut(&self) {
        if self.library.borrow().albums.is_empty() || self.db.library_debut().is_some() {
            return;
        }
        let summary = self.current_debut_summary();
        match self.db.save_library_debut(&summary) {
            Ok(()) => crate::logger::info(
                "library",
                &format!(
                    "library debut recorded: {} tracks, {} albums, {} covers",
                    summary.track_count, summary.album_count, summary.covers_resolved
                ),
            ),
            Err(err) => {
                crate::logger::error("database", &format!("libraryDebut write failed: {err}"))
            }
        }
    }

    /// The figures the summary card reports, computed from the library and the
    /// database as they stand right now — so a card raised at Act III counts
    /// every cover and year the job fetched during Act II, not just what the
    /// scan hoisted out of embedded tags. Bitrate is derived from the PCM shape
    /// the tags actually carry, averaged over the tracks that declare one;
    /// Linux never calls Groq, so `ai_cleaned_tracks` is always zero here.
    pub fn current_debut_summary(&self) -> DebutSummary {
        let library = self.library.borrow().clone();
        let (covers_resolved, albums_dated) = self.db.debut_album_tallies();
        let mut lossless_track_count = 0;
        let mut bitrate_total = 0_u64;
        let mut bitrate_samples = 0_u64;
        let mut total_duration_seconds = 0.0;
        for track in &library.tracks {
            total_duration_seconds += track.duration;
            if crate::hygiene::is_lossless(track.codec.as_deref()) {
                lossless_track_count += 1;
            }
            if let (Some(bits), Some(rate), Some(channels)) =
                (track.bit_depth, track.sample_rate, track.channels)
            {
                bitrate_total += (bits as u64 * rate as u64 * channels as u64) / 1000;
                bitrate_samples += 1;
            }
        }
        DebutSummary {
            track_count: library.tracks.len(),
            album_count: library.albums.len(),
            artist_count: library.artists.len(),
            covers_resolved,
            albums_dated,
            ai_cleaned_tracks: 0,
            lossless_track_count,
            average_bitrate: bitrate_total.checked_div(bitrate_samples).unwrap_or(0) as usize,
            total_duration_seconds,
            completed_at: chrono::Utc::now(),
        }
    }

    /// Closes `BuildingAlbums` out determinately. Every phase behind the bar is
    /// bounded disk work, so the last thing a build says must be a real 100% —
    /// an indeterminate final snapshot leaves the bar stopped at 92% and the
    /// Debut's first act ending on a number that never arrived.
    pub fn emit_build_completed(&self) {
        let (albums, tracks) = {
            let library = self.library.borrow();
            (library.albums.len(), library.tracks.len())
        };
        let counted = albums.max(1);
        self.hub.emit(&AppEvent::ScanProgress(LoadProgress {
            phase: LoadPhase::BuildingAlbums,
            completed: counted,
            total: counted,
            albums_built: albums,
            tracks_indexed: tracks,
            ..LoadProgress::default()
        }));
    }

    /// Everything that shows an album's cover starts asking again: the cache
    /// forgets each key first, so no surface can be handed the old picture,
    /// then one event per key tells the live ones to repaint.
    pub fn album_artwork_changed(&self, keys: &[(String, String)]) {
        for (title, artist) in keys {
            self.artwork.invalidate(title, artist);
        }
        for (title, artist) in keys {
            self.hub.emit(&AppEvent::AlbumArtworkChanged {
                title: title.clone(),
                artist: artist.clone(),
            });
        }
    }

    pub fn toast(&self, message: &str) {
        self.hub.emit(&AppEvent::Toast(message.to_string()));
    }

    pub fn job_progress(&self) -> JobProgress {
        self.job.borrow().clone()
    }

    /// Notes one finished entity. Only `completed_this_run` is accumulated —
    /// "how much did this launch fix" has no query — and even that is silent
    /// here, because the countdown itself is republished from the database.
    pub fn note_enrichment_completed(&self, title: Option<String>) {
        let mut job = self.job.borrow_mut();
        job.completed_this_run += 1;
        job.current_title = title;
    }

    /// Re-reads the countdown from the database and emits it. `remaining` is a
    /// `count(*)` over the very predicate the queue drains, never an
    /// accumulator, so the class of bug where an unbalanced counter freezes the
    /// label for a whole session is unrepresentable. The *activity* is the one
    /// thing the count cannot answer — a hundred albums a transport failure
    /// left pending are still due while nothing is being worked on — so it is
    /// read off the requests actually in flight, which is what Apple's
    /// `publish(.idle)` at the tail of a pass amounts to.
    pub fn refresh_job_progress(&self) {
        let now = chrono::Utc::now();
        let (scope, remaining) = self.outstanding_scope(now);
        let exhausted = self.db.count_exhausted(scope);
        let reachable = self.network_available.load(Ordering::Relaxed)
            && !self.network_suspect.load(Ordering::Relaxed);
        let in_flight = self.enrich_in_flight.get();
        let snapshot = {
            let mut job = self.job.borrow_mut();
            job.scope = scope;
            job.remaining = remaining;
            job.exhausted = exhausted;
            job.activity = match (in_flight, remaining, reachable) {
                (0, _, _) | (_, 0, _) => Activity::Idle,
                (_, _, false) => Activity::WaitingForNetwork,
                _ => Activity::Running,
            };
            if job.activity == Activity::Idle {
                job.completed_this_run = 0;
                job.current_title = None;
                job.started_at = None;
            } else if job.started_at.is_none() {
                job.started_at = Some(now);
            }
            job.clone()
        };
        self.hub.emit(&AppEvent::EnrichmentProgress(snapshot));
    }

    /// The scope the countdown speaks for: albums while any are outstanding,
    /// then artists. Each headline is paired with its own count, so "Finding
    /// artwork · 12 left" always means exactly twelve albums.
    fn outstanding_scope(&self, now: chrono::DateTime<chrono::Utc>) -> (Scope, usize) {
        let albums = self
            .db
            .count_due(Scope::Album, Scope::Album.current_version(), now);
        if albums > 0 {
            return (Scope::Album, albums);
        }
        let artists = self
            .db
            .count_due(Scope::Artist, Scope::Artist.current_version(), now);
        (Scope::Artist, artists)
    }

    pub fn start(self: &Rc<Self>, window: &adw::ApplicationWindow) {
        self.eq.start();
        self.purge_expired_versions();
        self.reload_library();
        self.start_tick();
        crate::mpris::start(self);
        crate::scrobbler::startup_maintenance(self);
        crate::enrichment::start(self);
        crate::downloads::start(self);
        crate::musicvideo::start(self);
        self.wire_autoplay();
        self.rescan();
        self.start_remote();
        self.schedule_periodic_drain();
        self.schedule_wantlist_refresh();
        crate::history_sync::schedule(self);
        crate::server_sync::start(self, window);
        self.wire_lastfm_sync();
        if config::demo_mode() && demo_autoplays() {
            self.schedule_demo_autoplay();
        }
        if self.smoke {
            self.schedule_smoke_test();
        }
    }

    /// Demo mode helper: once the seeded library is loaded, starts playback of
    /// the demo hero track (FLACCY_DEMO_TRACK, default "Slow Machine") so
    /// marketing screenshots show a live transport.
    fn schedule_demo_autoplay(self: &Rc<Self>) {
        let core = Rc::clone(self);
        let wanted =
            std::env::var("FLACCY_DEMO_TRACK").unwrap_or_else(|_| "Slow Machine".to_string());
        glib::timeout_add_local(Duration::from_millis(600), move || {
            let library = core.library.borrow().clone();
            let Some(album) = library
                .albums
                .iter()
                .find(|a| a.tracks.iter().any(|t| t.title == wanted))
                .cloned()
            else {
                return glib::ControlFlow::Continue;
            };
            let start = album
                .tracks
                .iter()
                .position(|t| t.title == wanted)
                .unwrap_or(0);
            core.play_tracks(album.tracks.clone(), start);
            if std::env::var_os("FLACCY_DEMO_QUEUE").is_some() {
                core.hub.emit(&AppEvent::QueueToggled(true));
            }
            if std::env::var_os("FLACCY_DEMO_SLEEP").is_some() {
                core.set_sleep_timer_minutes(30);
            }
            glib::ControlFlow::Break
        });
    }

    fn start_tick(self: &Rc<Self>) {
        let core = Rc::clone(self);
        glib::timeout_add_local(Duration::from_millis(250), move || {
            if core.player.is_playing() {
                core.player.check_progress();
                let position = core.player.position().unwrap_or(0.0);
                let duration = core.player.duration().unwrap_or(0.0);
                core.hub.emit(&AppEvent::Tick { position, duration });
                crate::scrobbler::on_tick(&core, position);
            }
            glib::ControlFlow::Continue
        });
    }

    pub fn rescan(self: &Rc<Self>) {
        if self.scanning.get() {
            return;
        }
        self.scanning.set(true);
        self.hub.emit(&AppEvent::ScanStarted);
        let (tx, rx) = async_channel::unbounded::<ScanEvent>();
        scanner::spawn_scan(self.music_root(), self.db_path.clone(), tx);
        let core = Rc::clone(self);
        glib::spawn_future_local(async move {
            while let Ok(event) = rx.recv().await {
                match event {
                    ScanEvent::Progress(progress) => {
                        core.hub.emit(&AppEvent::ScanProgress(progress));
                    }
                    ScanEvent::CoversHoisted(covers) => {
                        core.hub.emit(&AppEvent::AlbumCoversHoisted(covers));
                    }
                    ScanEvent::Done { added, removed } => {
                        core.scanning.set(false);
                        if added > 0 || removed > 0 {
                            let indexed = core.library.borrow().tracks.len();
                            core.building_albums.set(true);
                            core.hub.emit(&AppEvent::ScanProgress(LoadProgress {
                                phase: LoadPhase::BuildingAlbums,
                                tracks_indexed: indexed,
                                ..LoadProgress::default()
                            }));
                            core.reload_library();
                        } else {
                            core.emit_build_completed();
                        }
                        crate::enrichment::request_background_pass(&core);
                        core.hub.emit(&AppEvent::ScanFinished { added, removed });
                    }
                    ScanEvent::Revised(rel_paths) => core.note_new_versions(&rel_paths),
                    ScanEvent::Retagged => core.reload_library(),
                    ScanEvent::Failed(message) => {
                        crate::logger::error("library", &format!("scan failed: {message}"));
                        core.scanning.set(false);
                        crate::enrichment::request_background_pass(&core);
                        core.hub.emit(&AppEvent::ScanFinished {
                            added: 0,
                            removed: 0,
                        });
                        break;
                    }
                }
            }
        });
    }

    /// Plays `tracks` from `start`, naming what they were started from by
    /// looking at them (see `context_for`).
    pub fn play_tracks(self: &Rc<Self>, tracks: Vec<Track>, start: usize) {
        self.play_tracks_in(tracks, start, None);
    }

    /// The one funnel every start of playback goes through. A caller that
    /// knows what it is starting (a playlist, a mix, a radio) says so in
    /// `context`; any other start is named from its songs.
    pub fn play_tracks_in(
        self: &Rc<Self>,
        tracks: Vec<Track>,
        start: usize,
        context: Option<PlaybackContext>,
    ) {
        if tracks.is_empty() {
            return;
        }
        let context = context.unwrap_or_else(|| self.context_for(&tracks));
        crate::scrobbler::checkpoint_skip(self);
        *self.context.borrow_mut() = context.clone();
        self.player.play_queue(tracks, start);
        self.note_context_started(context);
    }

    /// An album when every song belongs to one library album, else whatever the
    /// shared rule makes of their (album, credit) pairs: usually a plain queue.
    fn context_for(&self, tracks: &[Track]) -> PlaybackContext {
        let library = self.library.borrow().clone();
        let album = tracks.first().and_then(|first| {
            library
                .albums
                .iter()
                .find(|album| album.tracks.iter().any(|t| t.rel_path == first.rel_path))
        });
        if let Some(album) = album {
            let members: std::collections::HashSet<&str> =
                album.tracks.iter().map(|t| t.rel_path.as_str()).collect();
            if tracks.iter().all(|t| members.contains(t.rel_path.as_str())) {
                return album_context(&album.title, &album.artist);
            }
        }
        let pairs: Vec<(String, String)> = tracks
            .iter()
            .map(|t| (t.album.clone(), t.credit().to_string()))
            .collect();
        PlaybackContext::derived(&pairs)
    }

    /// Remembers a started context for Jump Back In. A plain queue names
    /// nothing to go back to, so the shared rule leaves it out.
    fn note_context_started(&self, context: PlaybackContext) {
        let updated = self
            .recents
            .borrow()
            .recording(context, chrono::Utc::now().timestamp());
        if *self.recents.borrow() == updated {
            return;
        }
        home_state::save_recents(&updated);
        *self.recents.borrow_mut() = updated;
        self.hub.emit(&AppEvent::HomeChanged);
    }

    /// Takes a thing off Jump Back In, history-derived albums included, until
    /// it is played again.
    pub fn dismiss_jump_back_in(&self, key: &str) {
        let updated = self
            .recents
            .borrow()
            .dismissing(key, chrono::Utc::now().timestamp());
        home_state::save_recents(&updated);
        *self.recents.borrow_mut() = updated;
        self.hub.emit(&AppEvent::HomeChanged);
    }

    pub fn play_album_key(self: &Rc<Self>, key: &str, shuffle: bool) {
        let library = self.library.borrow().clone();
        let Some(album) = library.album_by_key(key) else {
            return;
        };
        let context = album_context(&album.title, &album.artist);
        self.play_list_in(album.tracks.clone(), shuffle, key, Some(context));
    }

    /// Every library track `artist` is on, in album order.
    pub fn artist_tracks(&self, artist: &str) -> Vec<Track> {
        self.library.borrow().artist_tracks(artist)
    }

    pub fn play_artist(self: &Rc<Self>, artist: &str, shuffle: bool) {
        self.play_list(self.artist_tracks(artist), shuffle, artist);
    }

    /// Plays `tracks` from the top, or shuffled from a seeded random start,
    /// leaving the player's shuffle mode matching the request.
    pub fn play_list(self: &Rc<Self>, tracks: Vec<Track>, shuffle: bool, seed: &str) {
        self.play_list_in(tracks, shuffle, seed, None);
    }

    pub fn play_list_in(
        self: &Rc<Self>,
        tracks: Vec<Track>,
        shuffle: bool,
        seed: &str,
        context: Option<PlaybackContext>,
    ) {
        if tracks.is_empty() {
            return;
        }
        if shuffle != self.player.shuffle_enabled() {
            self.player.toggle_shuffle();
        }
        let start = if shuffle {
            let seed = format!("{seed}{}", chrono::Utc::now().timestamp_micros());
            (crate::palette::fnv1a_64(&seed) % tracks.len() as u64) as usize
        } else {
            0
        };
        self.play_tracks_in(tracks, start, context);
    }

    /// Library Radio: an endless mix of everything, weighted by how much each
    /// song is played.
    pub fn start_library_radio(self: &Rc<Self>) {
        let pool = self.library.borrow().tracks.clone();
        let db_path = self.db_path.clone();
        let (tx, rx) = async_channel::bounded::<Vec<Track>>(1);
        std::thread::Builder::new()
            .name("flaccy-library-radio".into())
            .spawn(move || {
                let counts = crate::db::Db::open(&db_path)
                    .map(|db| db.play_counts_by_track())
                    .unwrap_or_default();
                let station = crate::station::library_radio(
                    &pool,
                    &counts,
                    &std::collections::HashSet::new(),
                    crate::station::STATION_SIZE,
                );
                let _ = tx.send_blocking(station);
            })
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(station) = rx.recv().await else { return };
            let Some(core) = weak.upgrade() else { return };
            if station.is_empty() {
                core.toast("Library Radio needs songs in the library. Add some music, then try again.");
                return;
            }
            let context = PlaybackContext {
                kind: ContextKind::Radio,
                id: home_copy::LIBRARY_RADIO_ID.to_string(),
                title: home_copy::LIBRARY_RADIO_TITLE.to_string(),
                subtitle: String::new(),
            };
            core.play_tracks_in(station, 0, Some(context));
        });
    }

    /// Puts the last session's queue back and plays it from where it stopped,
    /// skipping songs whose files have left the library. `shuffle` plays the
    /// same songs shuffled from the top instead.
    pub fn resume_session(self: &Rc<Self>, shuffle: bool) -> bool {
        let Some(saved) = self.last_session.borrow().clone() else {
            return false;
        };
        let library = self.library.borrow().clone();
        let by_path: std::collections::HashMap<&str, &Track> = library
            .tracks
            .iter()
            .map(|track| (track.rel_path.as_str(), track))
            .collect();
        let Some(plan) = saved.surviving(|rel| by_path.get(rel).map(|track| track.duration)) else {
            self.toast("None of the songs in your last session are in the library any more. Their files may have moved.");
            return false;
        };
        let tracks: Vec<Track> = plan
            .tracks
            .iter()
            .filter_map(|saved| by_path.get(saved.rel_path.as_str()).map(|t| (*t).clone()))
            .collect();
        if shuffle {
            self.play_list_in(tracks, true, "session", Some(saved.context.clone()));
            return true;
        }
        crate::scrobbler::checkpoint_skip(self);
        *self.context.borrow_mut() = saved.context.clone();
        self.player.restore_queue(tracks, plan.index, plan.elapsed);
        true
    }

    /// Keeps the last session current: written a moment after the track, the
    /// queue or play/pause changes, and every so often while a song plays.
    fn wire_session(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.hub.subscribe(move |event| {
            let Some(core) = weak.upgrade() else {
                return false;
            };
            match event {
                AppEvent::TrackChanged(Some(_))
                | AppEvent::QueueChanged
                | AppEvent::PlayingChanged(_) => core.save_session_soon(),
                AppEvent::Tick { position, .. } => {
                    if (position - core.session_saved_position.get()).abs()
                        >= SESSION_PROGRESS_INTERVAL
                    {
                        core.save_session_now(false);
                    }
                }
                _ => {}
            }
            true
        });
    }

    fn save_session_soon(self: &Rc<Self>) {
        if self.session_save_queued.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(SESSION_SAVE_DELAY, move || {
            if let Some(core) = weak.upgrade() {
                core.session_save_queued.set(false);
                core.save_session_now(true);
            }
        });
    }

    /// Writes the session as it stands. A player with nothing queued leaves the
    /// file alone: quitting after a launch that never played must not erase
    /// what the last launch left behind.
    pub fn save_session_now(&self, notify: bool) {
        let snapshot = self.player.queue_snapshot();
        if snapshot.queue.is_empty() {
            return;
        }
        let position = self.player.position().unwrap_or(0.0);
        self.session_saved_position.set(position);
        let first = if snapshot.queue.len() > SESSION_MAX_TRACKS {
            snapshot.current.saturating_sub(SESSION_TRAILING_TRACKS)
        } else {
            0
        };
        let session = SavedSession {
            saved_at: chrono::Utc::now().timestamp(),
            tracks: snapshot
                .queue
                .iter()
                .skip(first)
                .take(SESSION_MAX_TRACKS)
                .map(|track| SavedTrack {
                    rel_path: track.rel_path.clone(),
                    duration: track.duration,
                })
                .collect(),
            index: snapshot.current - first,
            elapsed: position,
            context: self.context.borrow().clone(),
        };
        home_state::save_session(&session);
        *self.last_session.borrow_mut() = Some(session);
        if notify {
            self.hub.emit(&AppEvent::HomeChanged);
        }
    }

    pub fn next(self: &Rc<Self>) {
        crate::scrobbler::checkpoint_skip(self);
        self.player.next();
    }

    pub fn previous(self: &Rc<Self>) {
        if self.player.position().unwrap_or(0.0) <= 3.0 {
            crate::scrobbler::checkpoint_skip(self);
        }
        self.player.previous();
    }

    pub fn toggle_play_pause(&self) {
        self.player.toggle_play_pause();
    }

    /// Applies a volume at once and persists it a moment later, so a drag
    /// across the slider writes the config file once instead of per frame.
    pub fn set_volume(self: &Rc<Self>, volume: f64) {
        let volume = volume.clamp(0.0, 1.0);
        self.player.set_volume(volume);
        self.config.borrow_mut().volume = volume;
        self.save_config_soon();
        self.hub.emit(&AppEvent::VolumeChanged(volume));
    }

    pub fn nudge_volume(self: &Rc<Self>, delta: f64) {
        let current = self.config.borrow().volume;
        self.set_volume(current + delta);
    }

    /// Mutes, or brings the level back to where muting found it.
    pub fn toggle_mute(self: &Rc<Self>) {
        let current = self.config.borrow().volume;
        if current > MUTE_FLOOR {
            self.restore_volume.set(current);
            self.set_volume(0.0);
        } else {
            self.set_volume(self.restore_volume.get());
        }
    }

    /// Seeks relative to where playback is — or is about to be, when a seek is
    /// still landing — so repeated presses add up instead of racing.
    pub fn skip_by(&self, seconds: f64) {
        if let Some(position) = self.player.position() {
            self.player.seek(position + seconds);
        }
    }

    fn save_config_soon(self: &Rc<Self>) {
        if self.config_save_queued.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(CONFIG_SAVE_DELAY, move || {
            if let Some(core) = weak.upgrade() {
                core.config_save_queued.set(false);
                core.save_config();
            }
        });
    }

    /// Resolves the new track's lyrics off the main thread — database cache,
    /// then the file's own lyrics, then lrclib — which also warms the cache the
    /// lyrics panel reads, so opening it on this song is instant. The panel asks
    /// for the same track at the same moment; the two share one lookup, and
    /// nothing goes to the network for a song skipped within a third of a second.
    pub fn prefetch_lyrics(self: &Rc<Self>, track: &Track) {
        *self.lyrics.borrow_mut() = crate::lyrics::Lyrics::default();
        crate::lyrics::want(track);
        let (tx, rx) = async_channel::bounded::<crate::lyrics::Lyrics>(1);
        let db_path = self.db_path.clone();
        let music_root = self.music_root();
        let for_thread = track.clone();
        let spawned = std::thread::Builder::new()
            .name("flaccy-lyrics-prefetch".into())
            .spawn(move || {
                let outcome = crate::lyrics::fetch_shared(
                    &db_path,
                    &music_root,
                    &for_thread,
                    crate::lyrics::Pace::Settled,
                );
                let lyrics = match outcome {
                    Some(crate::lyrics::LyricsResult::Found(lyrics)) => lyrics,
                    _ => crate::lyrics::Lyrics::default(),
                };
                let _ = tx.send_blocking(lyrics);
            });
        if spawned.is_err() {
            return;
        }
        let weak = Rc::downgrade(self);
        let rel_path = track.rel_path.clone();
        glib::spawn_future_local(async move {
            let Ok(lyrics) = rx.recv().await else {
                return;
            };
            let Some(core) = weak.upgrade() else {
                return;
            };
            let still_playing = core
                .player
                .current_track()
                .is_some_and(|track| track.rel_path == rel_path);
            if still_playing {
                *core.lyrics.borrow_mut() = lyrics;
            }
        });
    }

    /// The lyric line sung `seconds` into the playing track, when it has
    /// synced lyrics.
    pub fn lyric_line_at(&self, seconds: f64) -> Option<String> {
        self.lyrics.borrow().text_at(seconds).map(str::to_string)
    }

    /// Records a timing correction the lyrics panel just saved, so the seek
    /// bar's hover line follows it.
    pub fn set_lyric_offset_ms(&self, offset_ms: i64) {
        self.lyrics.borrow_mut().offset_ms = offset_ms;
    }

    /// Mirrors the transport modes the player owns back into the config file so
    /// shuffle and repeat survive a restart the way volume does.
    pub fn persist_transport_modes(&self) {
        let shuffle = self.player.shuffle_enabled();
        let repeat = self.player.repeat_mode().id().to_string();
        {
            let mut config = self.config.borrow_mut();
            if config.shuffle == shuffle && config.repeat_mode == repeat {
                return;
            }
            config.shuffle = shuffle;
            config.repeat_mode = repeat;
        }
        self.save_config();
    }

    /// Refreshes every server's catalog off the main thread, then reloads the
    /// library when anything changed. `announce` is true when the person asked,
    /// so a failure is a toast; a refresh nobody asked for only writes the log.
    pub fn sync_remote_servers(self: &Rc<Self>, announce: bool) {
        let Some(remote) = crate::remote::handle().cloned() else {
            return;
        };
        let servers = remote.servers();
        if servers.is_empty() || self.remote_syncing.replace(true) {
            return;
        }
        self.hub.emit(&AppEvent::RemoteChanged);
        let (tx, rx) = async_channel::unbounded::<(String, Result<flaccy_library::remote::sync::SyncReport, String>)>();
        std::thread::Builder::new()
            .name("flaccy-remote-refresh".into())
            .spawn(move || {
                for server in servers {
                    let result = remote
                        .sync(&server.id, &|_| {})
                        .map_err(|failure| failure.message());
                    let _ = tx.send_blocking((server.name, result));
                }
            })
            .ok();
        let core = Rc::clone(self);
        glib::spawn_future_local(async move {
            let mut changed = false;
            while let Ok((name, result)) = rx.recv().await {
                match result {
                    Ok(report) => {
                        let applied = &report.applied;
                        let moved = applied.inserted
                            + applied.updated
                            + applied.new_versions.len()
                            + applied.removed.len();
                        changed |= moved > 0 || applied.listening_updated > 0;
                        if announce {
                            core.toast(&format!(
                                "Refreshed {name}: {} songs, {moved} changed.",
                                report.songs
                            ));
                        }
                    }
                    Err(message) => {
                        crate::logger::warn("remote", &format!("refresh of {name} failed: {message}"));
                        if announce {
                            core.toast(&message);
                        }
                    }
                }
            }
            core.remote_syncing.set(false);
            if changed {
                core.reload_library();
            }
            core.hub.emit(&AppEvent::RemoteChanged);
        });
    }

    /// Hands the remote library's events to the main loop, and tells it which
    /// remote song plays and which comes next so it can fetch ahead.
    fn wire_remote(self: &Rc<Self>) {
        let Some(remote) = crate::remote::handle().cloned() else {
            return;
        };
        let (tx, rx) = async_channel::unbounded::<flaccy_library::remote::service::RemoteEvent>();
        remote.set_listener(Arc::new(move |event| {
            let _ = tx.send_blocking(event);
        }));
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            use flaccy_library::remote::service::RemoteEvent;
            while let Ok(event) = rx.recv().await {
                let Some(core) = weak.upgrade() else { return };
                match event {
                    RemoteEvent::Changed => core.hub.emit(&AppEvent::RemoteChanged),
                    RemoteEvent::Toast(message) => core.toast(&message),
                    RemoteEvent::NewVersions(paths) => core.note_new_versions(&paths),
                    RemoteEvent::CoversReady(keys) => {
                        core.album_artwork_changed(&keys);
                        core.hub.emit(&AppEvent::AlbumCoversHoisted(keys));
                    }
                }
            }
        });
        let weak = Rc::downgrade(self);
        self.hub.subscribe(move |event| {
            let Some(core) = weak.upgrade() else {
                return false;
            };
            if matches!(event, AppEvent::TrackChanged(_) | AppEvent::QueueChanged) {
                core.prefetch_remote();
            }
            true
        });
    }

    /// Asks the cache to fetch the rest of the playing remote song and the
    /// start of the next queued one.
    fn prefetch_remote(&self) {
        let Some(remote) = crate::remote::handle() else {
            return;
        };
        let (current, next) = self.player.current_and_next();
        let remote_path = |track: &Option<Track>| {
            track
                .as_ref()
                .map(|track| track.rel_path.clone())
                .filter(|path| crate::remote::is_remote(path))
        };
        let (current, next) = (remote_path(&current), remote_path(&next));
        if current.is_some() || next.is_some() {
            remote.prefetch(current.as_deref(), next.as_deref());
        }
    }

    /// Refreshes the servers a moment after launch and every six hours after,
    /// and finishes any download an earlier run left half done.
    fn start_remote(self: &Rc<Self>) {
        let Some(remote) = crate::remote::handle() else {
            return;
        };
        remote.start_background();
        let core = Rc::clone(self);
        glib::timeout_add_local_once(REMOTE_FIRST_REFRESH_DELAY, move || {
            core.sync_remote_servers(false);
        });
        let core = Rc::clone(self);
        glib::timeout_add_local(REMOTE_REFRESH_INTERVAL, move || {
            core.sync_remote_servers(false);
            glib::ControlFlow::Continue
        });
    }

    pub fn toggle_love(self: &Rc<Self>, rel_path: &str) {
        let Some(track) = self.library.borrow().track_by_rel_path(rel_path).cloned() else {
            return;
        };
        let loved = !track.loved;
        let pending_op = if loved { "love" } else { "unlove" };
        if let Err(err) = self.db.set_loved(rel_path, loved, Some(pending_op)) {
            crate::logger::error("database", &format!("setLoved failed: {err}"));
            return;
        }
        self.apply_loved(rel_path, loved);
        self.hub.emit(&AppEvent::LovedChanged {
            rel_path: rel_path.to_string(),
            loved,
        });
        crate::logger::info(
            "scrobble",
            &format!("{} {} — {}", pending_op, track.title, track.artist),
        );
        crate::scrobbler::submit_love(self, rel_path, &track.title, &track.artist, loved);
        if let Some(remote) = crate::remote::handle().filter(|_| crate::remote::is_remote(rel_path)) {
            remote.set_starred(rel_path, loved);
        }
    }

    /// Swaps in a copy of the library with the loved flag flipped. Pages note
    /// which library they last built from by pointer, so a love must arrive as
    /// a new library rather than an edit of the one they already saw.
    fn apply_loved(&self, rel_path: &str, loved: bool) {
        let updated = self.library.borrow().clone_with_loved(rel_path, loved);
        *self.library.borrow_mut() = Rc::new(updated);
    }

    pub fn save_config(&self) {
        config::save(&self.config.borrow());
    }

    fn schedule_periodic_drain(self: &Rc<Self>) {
        let core = Rc::clone(self);
        glib::timeout_add_local(Duration::from_secs(300), move || {
            crate::scrobbler::drain_pending(&core);
            glib::ControlFlow::Continue
        });
    }

    fn schedule_smoke_test(self: &Rc<Self>) {
        let core = Rc::clone(self);
        glib::timeout_add_local_once(Duration::from_millis(1500), move || {
            let library = core.library.borrow().clone();
            if library.tracks.is_empty() {
                crate::logger::warn("smoke", "SMOKE: library empty, waiting for scan");
                let retry = Rc::clone(&core);
                glib::timeout_add_local_once(Duration::from_secs(8), move || {
                    run_smoke(&retry);
                });
                return;
            }
            run_smoke(&core);
        });
    }

    /// Runs the first wantlist refresh a little after launch (post-scan) so
    /// gaps/upgrades and — when authenticated — Last.fm suggestions are ready
    /// by the time the page is opened.
    fn schedule_wantlist_refresh(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_secs(10), move || {
            if let Some(core) = weak.upgrade() {
                crate::wantlist::refresh(&core);
            }
        });
    }

    /// Re-runs loved down-sync and the wantlist refresh whenever the Last.fm
    /// session connects or disconnects.
    fn wire_lastfm_sync(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.hub.subscribe(move |event| {
            let Some(core) = weak.upgrade() else {
                return false;
            };
            if let crate::events::AppEvent::LastFmChanged = event {
                if core.session.borrow().is_some() {
                    crate::scrobbler::sync_loved_from_lastfm(&core);
                    crate::history_sync::load_state(&core);
                    crate::history_sync::start(&core, crate::history_sync::Trigger::Requested);
                } else {
                    crate::history_sync::load_state(&core);
                }
                crate::wantlist::refresh(&core);
            }
            true
        });
    }

    pub fn set_sleep_timer_minutes(self: &Rc<Self>, minutes: i64) {
        self.sleep_end_of_track.set(false);
        self.player.set_stop_at_end_of_track(false);
        self.sleep_remaining.set(Some(minutes * 60));
        self.emit_sleep_state();
        crate::logger::info("playback", &format!("sleep timer set: {minutes} min"));
        self.ensure_sleep_tick();
    }

    pub fn set_sleep_timer_end_of_track(self: &Rc<Self>) {
        self.sleep_remaining.set(None);
        self.sleep_end_of_track.set(true);
        self.player.set_stop_at_end_of_track(true);
        self.emit_sleep_state();
        crate::logger::info("playback", "sleep timer set: end of track");
    }

    pub fn cancel_sleep_timer(&self) {
        self.sleep_remaining.set(None);
        self.sleep_end_of_track.set(false);
        self.player.set_stop_at_end_of_track(false);
        self.emit_sleep_state();
        crate::logger::info("playback", "sleep timer cancelled");
    }

    fn emit_sleep_state(&self) {
        self.hub.emit(&AppEvent::SleepTimerChanged {
            remaining_seconds: self.sleep_remaining.get(),
            end_of_track: self.sleep_end_of_track.get(),
        });
    }

    fn ensure_sleep_tick(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local(Duration::from_secs(1), move || {
            let Some(core) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            let Some(remaining) = core.sleep_remaining.get() else {
                return glib::ControlFlow::Break;
            };
            let next = remaining - 1;
            if next <= 0 {
                core.sleep_remaining.set(None);
                core.emit_sleep_state();
                if core.player.is_playing() {
                    core.player.toggle_play_pause();
                }
                crate::logger::info("playback", "sleep timer fired: paused");
                return glib::ControlFlow::Break;
            }
            core.sleep_remaining.set(Some(next));
            core.emit_sleep_state();
            glib::ControlFlow::Continue
        });
    }

    /// Starts an artist station: similar-artists are resolved off-main (with
    /// the 30-day cache), the station is built with Efraimidis–Spirakis
    /// weighting and artist spacing, then played with the station seed set so
    /// autoplay continuation stays on-theme.
    pub fn start_artist_station(self: &Rc<Self>, seed_artist: &str) {
        self.start_station(seed_artist.to_string(), None);
    }

    pub fn start_track_station(self: &Rc<Self>, rel_path: &str) {
        let library = self.library.borrow().clone();
        let Some(track) = library.track_by_rel_path(rel_path).cloned() else {
            return;
        };
        self.start_station(track.artist.clone(), Some(track));
    }

    fn start_station(self: &Rc<Self>, seed_artist: String, seed_track: Option<Track>) {
        let library = self.library.borrow().clone();
        let pool = library.tracks.clone();
        let library_songs = pool.len();
        let library_artists: Vec<String> = library.artists.iter().map(|a| a.name.clone()).collect();
        let db_path = self.db_path.clone();
        let session_key = self.session.borrow().as_ref().map(|s| s.key.clone());
        let (tx, rx) = async_channel::bounded::<Vec<Track>>(1);
        let seed_for_thread = seed_artist.clone();
        let seed_track_is_none = seed_track.is_none();
        std::thread::Builder::new()
            .name("flaccy-station".into())
            .spawn(move || {
                let similar = crate::db::Db::open(&db_path)
                    .map(|db| {
                        let client = crate::lastfm::LastFmClient::new(session_key);
                        crate::enrichment::similar_in_library_blocking(
                            &db,
                            client.as_ref(),
                            &seed_for_thread,
                            &library_artists,
                        )
                    })
                    .unwrap_or_default();
                let excluding = std::collections::HashSet::new();
                let station = match &seed_track {
                    Some(track) => crate::station::track_station(
                        track,
                        &similar,
                        &pool,
                        &excluding,
                        crate::station::STATION_SIZE,
                    ),
                    None => crate::station::artist_station(
                        &seed_for_thread,
                        &similar,
                        &pool,
                        &excluding,
                        crate::station::STATION_SIZE,
                    ),
                };
                let _ = tx.send_blocking(station);
            })
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(station) = rx.recv().await else { return };
            let Some(core) = weak.upgrade() else { return };
            if station.is_empty() {
                core.toast(&no_station_message(&seed_artist, library_songs));
                return;
            }
            crate::logger::info(
                "playback",
                &format!(
                    "station started: seed '{seed_artist}', {} tracks",
                    station.len()
                ),
            );
            crate::scrobbler::checkpoint_skip(&core);
            let context = seed_track_is_none.then(|| artist_radio_context(&seed_artist));
            if let Some(context) = &context {
                *core.context.borrow_mut() = context.clone();
            }
            core.player
                .play_queue_with_seed(station, 0, Some(seed_artist));
            if let Some(context) = context {
                core.note_context_started(context);
            }
        });
    }

    /// Autoplay continuation: when the queue nears exhaustion (repeat off),
    /// appends a station-built batch seeded by the station seed artist or the
    /// current track's artist, so the music never ends.
    fn wire_autoplay(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        self.hub.subscribe(move |event| {
            let Some(core) = weak.upgrade() else {
                return false;
            };
            if let AppEvent::TrackChanged(Some(_)) = event {
                core.maybe_schedule_autoplay();
            }
            true
        });
    }

    fn maybe_schedule_autoplay(self: &Rc<Self>) {
        if !self.config.borrow().autoplay_continuation {
            return;
        }
        if self.autoplay_in_flight.get() {
            return;
        }
        if self.player.repeat_mode() != crate::player::RepeatMode::Off {
            return;
        }
        let (current, len) = self.player.current_index_and_len();
        if len == 0 || current + 2 < len {
            return;
        }
        let Some(current_track) = self.player.current_track() else {
            return;
        };
        let seed_artist = self
            .player
            .station_seed()
            .unwrap_or_else(|| current_track.artist.clone());
        self.autoplay_in_flight.set(true);
        crate::logger::info(
            "playback",
            &format!("autoplay continuation building (seed '{seed_artist}')"),
        );

        let library = self.library.borrow().clone();
        let pool = library.tracks.clone();
        let library_artists: Vec<String> = library.artists.iter().map(|a| a.name.clone()).collect();
        let snapshot = self.player.queue_snapshot();
        let excluding: std::collections::HashSet<String> =
            snapshot.queue.iter().map(|t| t.rel_path.clone()).collect();
        let db_path = self.db_path.clone();
        let session_key = self.session.borrow().as_ref().map(|s| s.key.clone());
        let (tx, rx) = async_channel::bounded::<Vec<Track>>(1);
        let seed_for_thread = seed_artist.clone();
        std::thread::Builder::new()
            .name("flaccy-autoplay".into())
            .spawn(move || {
                let batch = crate::db::Db::open(&db_path)
                    .map(|db| {
                        let client = crate::lastfm::LastFmClient::new(session_key);
                        let similar = crate::enrichment::similar_in_library_blocking(
                            &db,
                            client.as_ref(),
                            &seed_for_thread,
                            &library_artists,
                        );
                        let station = crate::station::artist_station(
                            &seed_for_thread,
                            &similar,
                            &pool,
                            &excluding,
                            crate::station::CONTINUATION_BATCH_SIZE,
                        );
                        if !station.is_empty() {
                            return station;
                        }
                        crate::station::library_radio(
                            &pool,
                            &db.play_counts_by_track(),
                            &excluding,
                            crate::station::CONTINUATION_BATCH_SIZE,
                        )
                    })
                    .unwrap_or_default();
                let _ = tx.send_blocking(batch);
            })
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let batch = rx.recv().await.unwrap_or_default();
            let Some(core) = weak.upgrade() else { return };
            core.autoplay_in_flight.set(false);
            if batch.is_empty() {
                crate::logger::info("playback", "autoplay continuation found nothing to add");
                return;
            }
            crate::logger::info(
                "playback",
                &format!("autoplay continuation appended {} tracks", batch.len()),
            );
            core.player.append_tracks(batch);
        });
    }

    /// Copies dropped audio files and folders into the library's `Imported`
    /// folder and rescans. A dropped folder keeps its own tree, a file already
    /// there is skipped rather than duplicated, and the result reads exactly
    /// like the Apple clients' import sentence. A newer version of a song that
    /// is already there asks `confirm` first: it replaces the file in place and
    /// the one it replaces stays in Previous Versions, or both are kept.
    pub fn import_dropped_paths(self: &Rc<Self>, paths: Vec<PathBuf>, confirm: ConfirmReplace) {
        let root = self.music_root();
        self.toast("Looking for music…");
        let (tx, rx) = async_channel::bounded::<PlannedImport>(1);
        std::thread::Builder::new()
            .name("flaccy-dnd-plan".into())
            .spawn(move || {
                let _ = tx.send_blocking(plan_drop_import(&paths, &root));
            })
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok(planned) = rx.recv().await else { return };
            let Some(core) = weak.upgrade() else { return };
            match planned.replacement_prompt() {
                None => core.execute_import(planned, ReplaceChoice::Replace),
                Some(prompt) => {
                    let weak = Rc::downgrade(&core);
                    confirm(
                        prompt,
                        Box::new(move |choice| {
                            if let Some(core) = weak.upgrade() {
                                core.execute_import(planned, choice);
                            }
                        }),
                    );
                }
            }
        });
    }

    fn execute_import(self: &Rc<Self>, planned: PlannedImport, choice: ReplaceChoice) {
        let environment = ImportEnvironment {
            root: self.music_root(),
            db_path: self.db_path.clone(),
        };
        let (tx, rx) = async_channel::unbounded::<DropImport>();
        std::thread::Builder::new()
            .name("flaccy-dnd".into())
            .spawn(move || run_drop_import(planned, choice, &environment, &tx))
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            while let Ok(event) = rx.recv().await {
                let Some(core) = weak.upgrade() else { return };
                match event {
                    DropImport::Copying { done, total } => core.toast(&format!(
                        "Copying {} of {}…",
                        crate::load_progress::group_digits(done),
                        crate::load_progress::group_digits(total)
                    )),
                    DropImport::Finished {
                        outcome,
                        replaced,
                        failures,
                    } => {
                        crate::logger::info(
                            "library",
                            &format!(
                                "drag-drop import: {} imported, {replaced} replaced, {} skipped, {} failed",
                                outcome.imported, outcome.skipped, outcome.failed
                            ),
                        );
                        core.toast(&import_message(&outcome, replaced, &failures));
                        if outcome.imported > 0 || replaced > 0 {
                            core.rescan();
                        }
                        return;
                    }
                }
            }
        });
    }

    fn wire_scrobbler(self: &Rc<Self>) {
        let core = Rc::downgrade(self);
        self.hub.subscribe(move |event| {
            let Some(core) = core.upgrade() else {
                return false;
            };
            match event {
                AppEvent::TrackChanged(track) => {
                    crate::scrobbler::on_track_started(&core, track.clone());
                }
                AppEvent::NaturalEnd(track) => {
                    crate::scrobbler::on_natural_end(&core, track);
                    if core.sleep_end_of_track.replace(false) {
                        core.emit_sleep_state();
                        crate::logger::info("playback", "sleep timer (end of track) fired: stopped on the boundary");
                    }
                }
                _ => {}
            }
            true
        });
    }
}

/// A demo run starts playing on its own, except for the Home states that show
/// a paused library (`FLACCY_DEMO_HOME` other than `playing`).
fn demo_autoplays() -> bool {
    matches!(
        std::env::var("FLACCY_DEMO_HOME").ok().as_deref(),
        None | Some("playing")
    )
}

/// The context of an album started whole.
pub fn album_context(title: &str, credit: &str) -> PlaybackContext {
    PlaybackContext {
        kind: ContextKind::Album,
        id: home::album_key(title, credit),
        title: title.to_string(),
        subtitle: credit.to_string(),
    }
}

/// The context of an artist station: "<Artist> Radio".
pub fn artist_radio_context(artist: &str) -> PlaybackContext {
    PlaybackContext {
        kind: ContextKind::Radio,
        id: format!("artist:{}", home::fold(artist)),
        title: format!("{artist} {}", home_copy::RADIO),
        subtitle: String::new(),
    }
}

/// Why a station came out empty: it needs a song by the seed artist or by an
/// artist Last.fm calls similar that the library also holds, and none exists.
fn no_station_message(seed_artist: &str, library_songs: usize) -> String {
    if library_songs == 0 {
        return "No station yet — the library has no songs. Add music and rescan first.".to_string();
    }
    format!(
        "No station for “{seed_artist}” — none of the library’s {library_songs} songs are by them or a similar artist."
    )
}

fn run_smoke(core: &Rc<AppCore>) {
    let library = core.library.borrow().clone();
    let Some(track) = library.tracks.first().cloned() else {
        crate::logger::error("smoke", "SMOKE FAILED: no tracks in library after scan");
        return;
    };
    crate::logger::info(
        "smoke",
        &format!(
            "SMOKE: starting playback of '{} — {}'",
            track.title, track.artist
        ),
    );
    core.play_tracks(library.tracks.clone(), 0);
    let check = Rc::clone(core);
    glib::timeout_add_local_once(Duration::from_secs(3), move || {
        let position = check.player.position().unwrap_or(0.0);
        let playing = check.player.gst_state_is_playing();
        if playing && position > 0.0 {
            crate::logger::info(
                "smoke",
                &format!("SMOKE OK: pipeline PLAYING, position {position:.2}s after 3s"),
            );
        } else {
            crate::logger::error(
                "smoke",
                &format!("SMOKE FAILED: playing={playing} position={position:.2}s"),
            );
        }
    });
}

/// What the person decides when an import holds newer versions of songs that
/// are already in the library.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReplaceChoice {
    Replace,
    KeepBoth,
}

/// What the replace question names: how many songs, and the title when it is one.
pub struct ReplacePrompt {
    pub count: usize,
    pub title: Option<String>,
}

pub type ConfirmReplace = Rc<dyn Fn(ReplacePrompt, Box<dyn FnOnce(ReplaceChoice)>)>;

const IMPORT_DIR: &str = "Imported";

struct PlannedImport {
    placed: Vec<import_plan::Placed>,
    already_in_library: usize,
}

impl PlannedImport {
    fn replacements(&self) -> Vec<&import_plan::Placed> {
        self.placed
            .iter()
            .filter(|entry| matches!(entry.placement, import_plan::Placement::Replace(_)))
            .collect()
    }

    fn replacement_prompt(&self) -> Option<ReplacePrompt> {
        let replacements = self.replacements();
        let first = replacements.first()?;
        let title = (replacements.len() == 1).then(|| versions::display_title(&first.item.source));
        Some(ReplacePrompt {
            count: replacements.len(),
            title,
        })
    }
}

struct ImportEnvironment {
    root: PathBuf,
    db_path: PathBuf,
}

enum DropImport {
    Copying {
        done: usize,
        total: usize,
    },
    Finished {
        outcome: import_plan::Outcome,
        replaced: usize,
        failures: Vec<String>,
    },
}

/// Plans the drop with the shared rules, asking the files themselves whether a
/// name already taken holds a newer version of the same song.
fn plan_drop_import(paths: &[PathBuf], root: &std::path::Path) -> PlannedImport {
    let plan = import_plan::plan(paths, root, &scanner::SUPPORTED_EXTENSIONS);
    let placed = import_plan::placements(&plan, &root.join(IMPORT_DIR), Some(&versions::TagInspector));
    PlannedImport {
        placed,
        already_in_library: plan.already_in_library,
    }
}

/// Carries out a plan. Each new file is copied through a hidden `.part` beside
/// its destination so an interrupted copy never leaves a truncated song under
/// the real name for the next import to mistake for a different file; a
/// replacement goes through `versions::replace_in_place`, which keeps the song
/// it replaces.
fn run_drop_import(
    planned: PlannedImport,
    choice: ReplaceChoice,
    environment: &ImportEnvironment,
    tx: &async_channel::Sender<DropImport>,
) {
    let import_root = environment.root.join(IMPORT_DIR);
    let placed = match choice {
        ReplaceChoice::Replace => planned.placed,
        ReplaceChoice::KeepBoth => versions::keep_both(planned.placed, &import_root),
    };
    let is_audio = |p: &&import_plan::Placed| p.item.kind == import_plan::Kind::Audio;
    let total = placed
        .iter()
        .filter(is_audio)
        .filter(|p| {
            matches!(
                p.placement,
                import_plan::Placement::Copy(_) | import_plan::Placement::Replace(_)
            )
        })
        .count();
    let mut outcome = import_plan::Outcome {
        skipped: planned.already_in_library
            + placed
                .iter()
                .filter(is_audio)
                .filter(|p| p.placement == import_plan::Placement::AlreadyPresent)
                .count(),
        ..Default::default()
    };
    let database = Db::open(&environment.db_path);
    let previous_root = versions::previous_root(&environment.db_path);
    let mut replaced = 0;
    let mut failures: Vec<String> = Vec::new();
    let mut last_report: Option<std::time::Instant> = None;
    for entry in &placed {
        let result: Result<bool, String> = match &entry.placement {
            import_plan::Placement::Copy(destination) => {
                copy_without_clobbering(&entry.item.source, &import_root.join(destination))
                    .map(|()| false)
                    .map_err(|err| err.to_string())
            }
            import_plan::Placement::Replace(destination) => {
                replace_existing(&database, environment, &previous_root, destination, &entry.item.source)
                    .map(|()| true)
            }
            import_plan::Placement::AlreadyPresent => continue,
        };
        if let Err(err) = &result {
            crate::logger::error(
                "library",
                &format!("import failed for {}: {err}", entry.item.source.display()),
            );
            if matches!(entry.placement, import_plan::Placement::Replace(_)) {
                failures.push(err.clone());
            }
        }
        if entry.item.kind != import_plan::Kind::Audio {
            continue;
        }
        match result {
            Ok(true) => replaced += 1,
            Ok(false) => outcome.imported += 1,
            Err(_) => outcome.failed += 1,
        }
        let done = outcome.imported + replaced + outcome.failed;
        let due = last_report.is_none_or(|at| at.elapsed() >= Duration::from_millis(150));
        if due || done == total {
            last_report = Some(std::time::Instant::now());
            let _ = tx.send_blocking(DropImport::Copying { done, total });
        }
    }
    let _ = tx.send_blocking(DropImport::Finished {
        outcome,
        replaced,
        failures,
    });
}

/// Replaces the song at `destination` with `source`, returning the sentence
/// that names what failed when it cannot.
fn replace_existing(
    database: &Result<Db, rusqlite::Error>,
    environment: &ImportEnvironment,
    previous_root: &std::path::Path,
    destination: &str,
    source: &std::path::Path,
) -> Result<(), String> {
    let title = versions::display_title(source);
    let failure = |step: &str, cause: String| {
        format!(
            "Couldn’t replace “{title}” — {step} failed: {cause}. The version you have is untouched; check the free space and permissions, then try again."
        )
    };
    let db = database
        .as_ref()
        .map_err(|err| failure("opening the library database", err.to_string()))?;
    let rel = std::path::Path::new(IMPORT_DIR)
        .join(destination)
        .to_string_lossy()
        .into_owned();
    versions::replace_in_place(db, &environment.root, previous_root, &rel, source)
        .map_err(|err| failure(err.step, err.cause))
}

/// The toast that closes an import: the shared sentence, the songs replaced by
/// newer versions, and the first replacement that could not be made.
fn import_message(outcome: &import_plan::Outcome, replaced: usize, failures: &[String]) -> String {
    let nothing_else = outcome.imported == 0 && outcome.skipped == 0 && outcome.failed == 0;
    let mut parts: Vec<String> = Vec::new();
    if !(replaced > 0 && nothing_else) {
        parts.push(import_plan::report(outcome).0);
    }
    if replaced == 1 {
        parts.push(copy::REPLACED_ONE.to_string());
    } else if replaced > 1 {
        parts.push(copy::fill(copy::REPLACED_COUNT, &[&replaced.to_string()]));
    }
    if let Some(first) = failures.first() {
        parts.push(first.clone());
    }
    parts.join(" · ")
}

fn copy_without_clobbering(source: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
    let staging = versions::stage_copy(source, target)?;
    let staged = if target.exists() {
        Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "destination appeared during the copy",
        ))
    } else {
        std::fs::rename(&staging, target)
    };
    if staged.is_err() {
        let _ = std::fs::remove_file(&staging);
    }
    staged
}

pub fn activate(app: &adw::Application, smoke: bool) {
    if let Some(window) = main_window(app) {
        window.present();
        return;
    }
    let core = AppCore::new(smoke);
    let window = ui::window::build(app, &core);
    core.start(&window);
    window.present();
}

/// The player's own window. Launching Flaccy again must bring this one forward,
/// never `active_window()`, which is whichever window was used last and can be a
/// secondary one such as the equalizer.
fn main_window(app: &adw::Application) -> Option<gtk::Window> {
    app.windows()
        .into_iter()
        .find(|window| window.is::<adw::ApplicationWindow>())
}

#[cfg(test)]
mod tests {
    use super::{
        import_message, plan_drop_import, run_drop_import, DropImport, ImportEnvironment,
        ReplaceChoice,
    };
    use crate::db::Db;
    use crate::fingerprint::fixtures::{info_tags, tone, wav_bytes, TempDir};
    use flaccy_shared::import_plan::Outcome;

    fn drain(
        rx: &async_channel::Receiver<DropImport>,
    ) -> (Outcome, usize, Vec<String>) {
        let mut finished = None;
        while let Ok(event) = rx.try_recv() {
            if let DropImport::Finished {
                outcome,
                replaced,
                failures,
            } = event
            {
                finished = Some((outcome, replaced, failures));
            }
        }
        finished.expect("the import reports its outcome")
    }

    fn run(
        paths: &[std::path::PathBuf],
        environment: &ImportEnvironment,
        choice: ReplaceChoice,
    ) -> (Outcome, usize, Vec<String>) {
        let (tx, rx) = async_channel::unbounded();
        run_drop_import(plan_drop_import(paths, &environment.root), choice, environment, &tx);
        drain(&rx)
    }

    fn environment(temp: &std::path::Path) -> ImportEnvironment {
        let root = temp.join("root");
        std::fs::create_dir_all(&root).expect("mkdir root");
        ImportEnvironment {
            root,
            db_path: temp.join("data/library.sqlite"),
        }
    }

    #[test]
    fn a_dropped_folder_keeps_its_tree_and_a_second_drop_copies_nothing() {
        let temp = TempDir::new("dnd");
        let source = temp.path().join("src/Album");
        let environment = environment(temp.path());
        let root = environment.root.clone();
        std::fs::create_dir_all(source.join("CD2")).expect("mkdir");
        std::fs::write(source.join("01.flac"), b"x").expect("write");
        std::fs::write(source.join("01.lrc"), b"[00:01]x").expect("write");
        std::fs::write(source.join("CD2/01.mp3"), b"y").expect("write");
        std::fs::write(source.join("notes.txt"), b"z").expect("write");

        let (first, replaced, _) = run(std::slice::from_ref(&source), &environment, ReplaceChoice::Replace);
        assert_eq!((first.imported, first.skipped, first.failed, replaced), (2, 0, 0, 0));
        assert!(root.join("Imported/Album/01.flac").exists());
        assert!(root.join("Imported/Album/01.lrc").exists());
        assert!(root.join("Imported/Album/CD2/01.mp3").exists());
        assert!(!root.join("Imported/Album/notes.txt").exists());
        assert!(!root.join("Imported/Album/.01.flac.flaccy-part").exists());

        let (second, replaced, _) = run(&[source], &environment, ReplaceChoice::Replace);
        assert_eq!((second.imported, second.skipped, second.failed, replaced), (0, 2, 0, 0));
        assert!(!root.join("Imported/Album/01_1.flac").exists());
    }

    fn write_song(path: &std::path::Path, step: i16) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let tags = info_tags("Rough Mix", "Drill Band", "Rough Cuts");
        std::fs::write(path, wav_bytes(&tone(4000, step), Some(&tags))).unwrap();
    }

    #[test]
    fn a_newer_version_replaces_the_song_and_keeps_both_files_apart_when_asked() {
        let temp = TempDir::new("dnd-replace");
        let environment = environment(temp.path());
        let in_library = environment.root.join("Imported/Rough Mix.wav");
        write_song(&in_library, 7);
        let db = Db::open(&environment.db_path).expect("db");
        let mut track = crate::scanner::read_metadata(&in_library, "Imported/Rough Mix.wav").expect("tags");
        track.signature = crate::fingerprint::signature(&in_library);
        track.fingerprint = crate::fingerprint::fingerprint(&in_library);
        db.insert_track(&track).expect("insert");
        let newer = temp.path().join("elsewhere/Rough Mix.wav");
        write_song(&newer, 11);
        let newer_fingerprint = crate::fingerprint::fingerprint(&newer);

        let (kept, replaced, _) = run(std::slice::from_ref(&newer), &environment, ReplaceChoice::KeepBoth);
        assert_eq!((kept.imported, replaced), (1, 0));
        assert!(environment.root.join("Imported/Rough Mix_1.wav").exists());
        assert!(db.previous_version("Imported/Rough Mix.wav").is_none());
        std::fs::remove_file(environment.root.join("Imported/Rough Mix_1.wav")).unwrap();

        let (done, replaced, failures) = run(&[newer], &environment, ReplaceChoice::Replace);
        assert_eq!((done.imported, done.failed, replaced), (0, 0, 1));
        assert!(failures.is_empty());
        assert_eq!(crate::fingerprint::fingerprint(&in_library), newer_fingerprint);
        let previous = db.previous_version("Imported/Rough Mix.wav").expect("kept");
        assert!(std::path::Path::new(&previous.stored_path).is_file());
    }

    #[test]
    fn the_closing_toast_counts_replaced_songs() {
        let none = Outcome::default();
        assert_eq!(
            import_message(&none, 2, &[]),
            "2 songs replaced with newer versions"
        );
        assert_eq!(
            import_message(&none, 1, &[]),
            "1 song replaced with a newer version"
        );
        let some = Outcome {
            imported: 3,
            ..Default::default()
        };
        assert_eq!(
            import_message(&some, 2, &[]),
            "Imported 3 items · 2 songs replaced with newer versions"
        );
        assert_eq!(import_message(&some, 0, &[]), "Imported 3 items");
        assert_eq!(import_message(&none, 0, &[]), "Nothing to import.");
        let failed = Outcome {
            failed: 1,
            ..Default::default()
        };
        assert_eq!(
            import_message(&failed, 0, &["Couldn’t replace “A” — x failed: y.".into()]),
            "Import failed — the files couldn't be copied. · Couldn’t replace “A” — x failed: y."
        );
    }
}
