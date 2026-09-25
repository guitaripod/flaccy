use crate::config::{self, Config, Session};
use crate::db::Db;
use crate::events::{AppEvent, EventHub};
use crate::library::{self, Library, Track};
use crate::load_progress::{LoadPhase, LoadProgress};
use crate::player::Player;
use crate::scanner::{self, ScanEvent};
use crate::ui;
use adw::prelude::*;
use flaccy_shared::enrichment_job::{Activity, JobProgress, Scope};
use flaccy_shared::import_plan;
use flaccy_shared::library_debut::DebutSummary;
use gtk::glib;
use std::cell::{Cell, RefCell};
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
    pub session: RefCell<Option<Session>>,
    pub artwork: ui::artwork::ArtworkCache,
    pub scanning: Cell<bool>,
    pub smoke: bool,
    pub current_play: RefCell<Option<crate::scrobbler::CurrentPlay>>,
    pub drain_in_flight: Rc<Cell<bool>>,
    pub mpris: RefCell<Option<Rc<mpris_server::Player>>>,
    pub enrich_tx: RefCell<Option<async_channel::Sender<crate::enrichment::EnrichRequest>>>,
    pub import_in_flight: Cell<bool>,
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
    lyric_lines: RefCell<Vec<(f64, String)>>,
    /// The level unmuting returns to.
    restore_volume: Cell<f64>,
    config_save_queued: Cell<bool>,
}

/// Below this the volume counts as muted.
const MUTE_FLOOR: f64 = 0.005;
/// Where unmuting lands when there is no earlier level to return to.
const UNMUTE_DEFAULT: f64 = 0.6;
/// How long a settled change waits before it is written to the config file, so
/// a drag across the volume slider saves once rather than on every frame.
const CONFIG_SAVE_DELAY: Duration = Duration::from_millis(400);

impl AppCore {
    pub fn new(smoke: bool) -> Rc<Self> {
        let config = config::load();
        let db_path = crate::db::default_db_path();
        let db = Db::open_with_recovery(&db_path).expect("library database must open");
        let hub = Rc::new(EventHub::new());
        let root = config.music_root();
        crate::logger::info("lifecycle", &format!("library root: {}", root.display()));
        let player = Player::new(Rc::clone(&hub), root);
        player.set_volume(config.volume);
        player.set_shuffle(config.shuffle);
        player.set_repeat(crate::player::RepeatMode::from_id(&config.repeat_mode));
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
            session: RefCell::new(session),
            artwork,
            scanning: Cell::new(false),
            smoke,
            current_play: RefCell::new(None),
            drain_in_flight: Rc::new(Cell::new(false)),
            mpris: RefCell::new(None),
            enrich_tx: RefCell::new(None),
            import_in_flight: Cell::new(false),
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
            lyric_lines: RefCell::new(Vec::new()),
            restore_volume: Cell::new(restore_volume),
            config_save_queued: Cell::new(false),
        });
        core.artwork.start(&core);
        core.wire_scrobbler();
        core
    }

    pub fn music_root(&self) -> PathBuf {
        self.config.borrow().music_root()
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

    pub fn start(self: &Rc<Self>, _window: &adw::ApplicationWindow) {
        self.reload_library();
        self.start_tick();
        crate::mpris::start(self);
        crate::scrobbler::startup_maintenance(self);
        crate::enrichment::start(self);
        crate::downloads::start(self);
        crate::musicvideo::start(self);
        self.wire_autoplay();
        self.rescan();
        self.schedule_periodic_drain();
        self.schedule_wantlist_refresh();
        self.schedule_history_import();
        self.wire_lastfm_sync();
        if config::demo_mode() {
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
                        break;
                    }
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

    pub fn play_tracks(self: &Rc<Self>, tracks: Vec<Track>, start: usize) {
        crate::scrobbler::checkpoint_skip(self);
        self.player.play_queue(tracks, start);
    }

    pub fn play_album_key(self: &Rc<Self>, key: &str, shuffle: bool) {
        let library = self.library.borrow().clone();
        let Some(album) = library.album_by_key(key) else {
            return;
        };
        if shuffle && !self.player.shuffle_enabled() {
            self.player.toggle_shuffle();
        }
        if !shuffle && self.player.shuffle_enabled() {
            self.player.toggle_shuffle();
        }
        let start = if shuffle {
            let len = album.tracks.len();
            (crate::palette::fnv1a_64(&format!("{}{}", key, chrono::Utc::now().timestamp_micros()))
                % len.max(1) as u64) as usize
        } else {
            0
        };
        self.play_tracks(album.tracks.clone(), start);
    }

    /// Every library track `artist` is on (feat. credits collapse to the lead
    /// artist), in album order: the albums credited to them in full, plus the
    /// individual tracks they perform on somebody else's record.
    ///
    /// Taking only credited albums would hand a composer on a Various Artists
    /// soundtrack an empty queue while the library holds thirty-one of their
    /// tracks.
    pub fn artist_tracks(&self, artist: &str) -> Vec<Track> {
        let library = self.library.borrow();
        let key = crate::hygiene::artist_key(artist);
        library
            .albums
            .iter()
            .flat_map(|album| {
                let credited = crate::hygiene::artist_key(&album.artist) == key;
                let key = key.clone();
                album.tracks.iter().filter(move |track| {
                    credited || crate::hygiene::artist_key(&track.artist) == key
                })
            })
            .cloned()
            .collect()
    }

    pub fn play_artist(self: &Rc<Self>, artist: &str, shuffle: bool) {
        let tracks = self.artist_tracks(artist);
        if tracks.is_empty() {
            return;
        }
        if shuffle != self.player.shuffle_enabled() {
            self.player.toggle_shuffle();
        }
        let start = if shuffle {
            let seed = format!("{artist}{}", chrono::Utc::now().timestamp_micros());
            (crate::palette::fnv1a_64(&seed) % tracks.len() as u64) as usize
        } else {
            0
        };
        self.play_tracks(tracks, start);
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

    /// Resolves the new track's synced lyrics off the main thread — database
    /// cache, then the file's own lyrics, then lrclib — which also warms the
    /// cache the lyrics panel reads, so opening it on this song is instant.
    pub fn prefetch_lyric_lines(self: &Rc<Self>, track: &Track) {
        self.lyric_lines.borrow_mut().clear();
        let (tx, rx) = async_channel::bounded::<Vec<(f64, String)>>(1);
        let db_path = self.db_path.clone();
        let music_root = self.music_root();
        let for_thread = track.clone();
        let spawned = std::thread::Builder::new()
            .name("flaccy-lyrics-prefetch".into())
            .spawn(move || {
                let lines = match crate::lyrics::fetch_blocking(&db_path, &music_root, &for_thread)
                {
                    crate::lyrics::LyricsResult::Found(lyrics) => lyrics.synced,
                    _ => Vec::new(),
                };
                let _ = tx.send_blocking(lines);
            });
        if spawned.is_err() {
            return;
        }
        let weak = Rc::downgrade(self);
        let rel_path = track.rel_path.clone();
        glib::spawn_future_local(async move {
            let Ok(lines) = rx.recv().await else {
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
                *core.lyric_lines.borrow_mut() = lines;
            }
        });
    }

    /// The lyric line sung `seconds` into the playing track, when it has
    /// synced lyrics.
    pub fn lyric_line_at(&self, seconds: f64) -> Option<String> {
        crate::lyrics::line_at(&self.lyric_lines.borrow(), seconds).map(str::to_string)
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

    pub fn toggle_love(self: &Rc<Self>, rel_path: &str) {
        let library = self.library.borrow().clone();
        let Some(track) = library.track_by_rel_path(rel_path) else {
            return;
        };
        let loved = !track.loved;
        let pending_op = if loved { "love" } else { "unlove" };
        if let Err(err) = self.db.set_loved(rel_path, loved, Some(pending_op)) {
            crate::logger::error("database", &format!("setLoved failed: {err}"));
            return;
        }
        let updated = self.library.borrow().clone_with_loved(rel_path, loved);
        *self.library.borrow_mut() = Rc::new(updated);
        self.hub.emit(&AppEvent::LovedChanged {
            rel_path: rel_path.to_string(),
            loved,
        });
        crate::logger::info(
            "scrobble",
            &format!("{} {} — {}", pending_op, track.title, track.artist),
        );
        crate::scrobbler::submit_love(self, rel_path, &track.title, &track.artist, loved);
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

    /// One-shot Last.fm history pull a bit after launch: when authenticated and
    /// the local scrobbles table is still essentially empty, imports the full
    /// listening history so Stats (tiles, heatmap, clock, top lists) fills in
    /// without the user hunting for the Import button.
    fn schedule_history_import(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_secs(12), move || {
            if let Some(core) = weak.upgrade() {
                core.maybe_import_history();
            }
        });
    }

    /// Kicks off a full history import only when the local scrobbles table is
    /// still below the seeded threshold. Count-gated rather than flag-gated so
    /// it is a no-op once history is present and self-heals from an interrupted
    /// pull (which resumes from the persisted page cursor) on the next attempt.
    fn maybe_import_history(self: &Rc<Self>) {
        const AUTO_IMPORT_THRESHOLD: i64 = 50;
        if config::demo_mode()
            || !crate::lastfm::keys_available()
            || self.session.borrow().is_none()
            || self.import_in_flight.get()
        {
            return;
        }
        let core = Rc::clone(self);
        let db_path = self.db_path.clone();
        let resume_cursor = self.config.borrow().import_page_cursor;
        let (tx, rx) = async_channel::bounded::<i64>(1);
        std::thread::Builder::new()
            .name("flaccy-import-check".into())
            .spawn(move || {
                let count = Db::open(&db_path)
                    .map(|db| db.scrobble_count())
                    .unwrap_or(0);
                let _ = tx.send_blocking(count);
            })
            .ok();
        glib::spawn_future_local(async move {
            let count = rx.recv().await.unwrap_or(i64::MAX);
            if crate::importer::should_auto_import(resume_cursor, count, AUTO_IMPORT_THRESHOLD) {
                crate::logger::info(
                    "import",
                    &format!(
                        "auto-import: {count} local scrobbles, cursor at page {resume_cursor}; pulling Last.fm history"
                    ),
                );
                crate::importer::start(&core);
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
                    core.maybe_import_history();
                }
                crate::wantlist::refresh(&core);
            }
            true
        });
    }

    pub fn set_sleep_timer_minutes(self: &Rc<Self>, minutes: i64) {
        self.sleep_end_of_track.set(false);
        self.sleep_remaining.set(Some(minutes * 60));
        self.emit_sleep_state();
        crate::logger::info("playback", &format!("sleep timer set: {minutes} min"));
        self.ensure_sleep_tick();
    }

    pub fn set_sleep_timer_end_of_track(self: &Rc<Self>) {
        self.sleep_remaining.set(None);
        self.sleep_end_of_track.set(true);
        self.emit_sleep_state();
        crate::logger::info("playback", "sleep timer set: end of track");
    }

    pub fn cancel_sleep_timer(&self) {
        self.sleep_remaining.set(None);
        self.sleep_end_of_track.set(false);
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
        let library_artists: Vec<String> = library.artists.iter().map(|a| a.name.clone()).collect();
        let db_path = self.db_path.clone();
        let session_key = self.session.borrow().as_ref().map(|s| s.key.clone());
        let (tx, rx) = async_channel::bounded::<Vec<Track>>(1);
        let seed_for_thread = seed_artist.clone();
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
                core.toast("Not enough music for a station");
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
            core.player
                .play_queue_with_seed(station, 0, Some(seed_artist));
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
    /// like the Apple clients' import sentence.
    pub fn import_dropped_paths(self: &Rc<Self>, paths: Vec<std::path::PathBuf>) {
        let root = self.music_root();
        let (tx, rx) = async_channel::unbounded::<DropImport>();
        std::thread::Builder::new()
            .name("flaccy-dnd".into())
            .spawn(move || run_drop_import(&paths, &root, &tx))
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            while let Ok(event) = rx.recv().await {
                let Some(core) = weak.upgrade() else { return };
                match event {
                    DropImport::Scanning => core.toast("Looking for music…"),
                    DropImport::Copying { done, total } => core.toast(&format!(
                        "Copying {} of {}…",
                        crate::load_progress::group_digits(done),
                        crate::load_progress::group_digits(total)
                    )),
                    DropImport::Finished(outcome) => {
                        crate::logger::info(
                            "library",
                            &format!(
                                "drag-drop import: {} imported, {} skipped, {} failed",
                                outcome.imported, outcome.skipped, outcome.failed
                            ),
                        );
                        core.toast(&import_plan::report(&outcome).0);
                        if outcome.imported > 0 {
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
                    if core.sleep_end_of_track.replace(false) && core.player.is_playing() {
                        core.player.toggle_play_pause();
                        core.emit_sleep_state();
                        crate::logger::info("playback", "sleep timer (end of track) fired: paused");
                    }
                }
                AppEvent::NaturalEnd(track) => {
                    crate::scrobbler::on_natural_end(&core, track);
                }
                _ => {}
            }
            true
        });
    }
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

impl Library {
    fn clone_with_loved(&self, rel_path: &str, loved: bool) -> Library {
        let mut tracks = self.tracks.clone();
        for track in &mut tracks {
            if track.rel_path == rel_path {
                track.loved = loved;
            }
        }
        let mut albums = self.albums.clone();
        for album in &mut albums {
            for track in &mut album.tracks {
                if track.rel_path == rel_path {
                    track.loved = loved;
                }
            }
        }
        Library {
            tracks,
            albums,
            artists: self.artists.clone(),
        }
    }
}

enum DropImport {
    Scanning,
    Copying { done: usize, total: usize },
    Finished(import_plan::Outcome),
}

/// Plans the drop with the shared rules, then copies each file through a
/// hidden `.part` beside its destination so an interrupted copy never leaves a
/// truncated song under the real name for the next import to mistake for a
/// different file.
fn run_drop_import(
    paths: &[PathBuf],
    root: &std::path::Path,
    tx: &async_channel::Sender<DropImport>,
) {
    let _ = tx.send_blocking(DropImport::Scanning);
    let plan = import_plan::plan(paths, root, &scanner::SUPPORTED_EXTENSIONS);
    let import_root = root.join("Imported");
    let placed = import_plan::placements(&plan, &import_root);
    let is_audio = |p: &&import_plan::Placed| p.item.kind == import_plan::Kind::Audio;
    let total = placed
        .iter()
        .filter(is_audio)
        .filter(|p| matches!(p.placement, import_plan::Placement::Copy(_)))
        .count();
    let mut outcome = import_plan::Outcome {
        skipped: plan.already_in_library
            + placed
                .iter()
                .filter(is_audio)
                .filter(|p| p.placement == import_plan::Placement::AlreadyPresent)
                .count(),
        ..Default::default()
    };
    let mut last_report: Option<std::time::Instant> = None;
    for entry in &placed {
        let import_plan::Placement::Copy(destination) = &entry.placement else {
            continue;
        };
        let result = copy_without_clobbering(&entry.item.source, &import_root.join(destination));
        if let Err(err) = &result {
            crate::logger::error(
                "library",
                &format!("import copy failed for {}: {err}", entry.item.source.display()),
            );
        }
        if entry.item.kind != import_plan::Kind::Audio {
            continue;
        }
        if result.is_ok() {
            outcome.imported += 1;
        } else {
            outcome.failed += 1;
        }
        let done = outcome.imported + outcome.failed;
        let due = last_report.is_none_or(|at| at.elapsed() >= Duration::from_millis(150));
        if due || done == total {
            last_report = Some(std::time::Instant::now());
            let _ = tx.send_blocking(DropImport::Copying { done, total });
        }
    }
    let _ = tx.send_blocking(DropImport::Finished(outcome));
}

fn copy_without_clobbering(source: &std::path::Path, target: &std::path::Path) -> std::io::Result<()> {
    let parent = target.parent().unwrap_or(target);
    std::fs::create_dir_all(parent)?;
    let name = target
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let staging = parent.join(format!(".{name}.flaccy-part"));
    let _ = std::fs::remove_file(&staging);
    let staged = std::fs::copy(source, &staging).and_then(|_| {
        if target.exists() {
            Err(std::io::Error::new(
                std::io::ErrorKind::AlreadyExists,
                "destination appeared during the copy",
            ))
        } else {
            std::fs::rename(&staging, target)
        }
    });
    if staged.is_err() {
        let _ = std::fs::remove_file(&staging);
    }
    staged
}

pub fn activate(app: &adw::Application, smoke: bool) {
    if let Some(window) = app.active_window() {
        window.present();
        return;
    }
    let core = AppCore::new(smoke);
    let window = ui::window::build(app, &core);
    core.start(&window);
    window.present();
}

#[cfg(test)]
mod tests {
    use super::{run_drop_import, DropImport};

    fn drain(rx: &async_channel::Receiver<DropImport>) -> flaccy_shared::import_plan::Outcome {
        let mut finished = None;
        while let Ok(event) = rx.try_recv() {
            if let DropImport::Finished(outcome) = event {
                finished = Some(outcome);
            }
        }
        finished.expect("the import reports its outcome")
    }

    #[test]
    fn a_dropped_folder_keeps_its_tree_and_a_second_drop_copies_nothing() {
        let temp = std::env::temp_dir().join(format!("flaccy-dnd-test-{}", std::process::id()));
        let source = temp.join("src/Album");
        let root = temp.join("root");
        std::fs::create_dir_all(source.join("CD2")).expect("mkdir");
        std::fs::create_dir_all(&root).expect("mkdir root");
        std::fs::write(source.join("01.flac"), b"x").expect("write");
        std::fs::write(source.join("01.lrc"), b"[00:01]x").expect("write");
        std::fs::write(source.join("CD2/01.mp3"), b"y").expect("write");
        std::fs::write(source.join("notes.txt"), b"z").expect("write");

        let (tx, rx) = async_channel::unbounded();
        run_drop_import(std::slice::from_ref(&source), &root, &tx);
        let first = drain(&rx);
        assert_eq!((first.imported, first.skipped, first.failed), (2, 0, 0));
        assert!(root.join("Imported/Album/01.flac").exists());
        assert!(root.join("Imported/Album/01.lrc").exists());
        assert!(root.join("Imported/Album/CD2/01.mp3").exists());
        assert!(!root.join("Imported/Album/notes.txt").exists());
        assert!(!root.join("Imported/Album/.01.flac.flaccy-part").exists());

        run_drop_import(&[source], &root, &tx);
        let second = drain(&rx);
        assert_eq!((second.imported, second.skipped, second.failed), (0, 2, 0));
        assert!(!root.join("Imported/Album/01_1.flac").exists());
        let _ = std::fs::remove_dir_all(&temp);
    }
}
