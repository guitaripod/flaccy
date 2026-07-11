use crate::config::{self, Config, Session};
use crate::db::Db;
use crate::events::{AppEvent, EventHub};
use crate::library::{self, Library, Track};
use crate::player::Player;
use crate::scanner::{self, ScanEvent};
use crate::ui;
use adw::prelude::*;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::path::PathBuf;
use std::rc::Rc;
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
    reload_in_flight: Cell<bool>,
    reload_pending: Cell<bool>,
    enrich_total: Cell<usize>,
    enrich_done: Cell<usize>,
}

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
        let session = config::load_session();
        if let Some(session) = &session {
            crate::logger::info("auth", &format!("last.fm session loaded for {}", session.username));
        }
        let artwork = ui::artwork::ArtworkCache::new(db_path.clone());

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
            reload_in_flight: Cell::new(false),
            reload_pending: Cell::new(false),
            enrich_total: Cell::new(0),
            enrich_done: Cell::new(0),
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
    pub fn reload_library(self: &Rc<Self>) {
        if self.reload_in_flight.replace(true) {
            self.reload_pending.set(true);
            return;
        }
        let db_path = self.db_path.clone();
        let group_album_editions = self.config.borrow().group_album_editions;
        let (tx, rx) = async_channel::bounded::<(Library, Vec<(String, f64)>)>(1);
        std::thread::Builder::new()
            .name("flaccy-reload".into())
            .spawn(move || {
                let Ok(db) = Db::open(&db_path) else { return };
                let library = library::load(&db, group_album_editions);
                let now = chrono::Utc::now().timestamp();
                let weights = db
                    .track_sort_keys()
                    .into_iter()
                    .map(|(rel, last_played)| (rel, crate::station::history_weight(last_played, now)))
                    .collect();
                let _ = tx.send_blocking((library, weights));
            })
            .ok();
        let core = Rc::clone(self);
        glib::spawn_future_local(async move {
            let received = rx.recv().await;
            core.reload_in_flight.set(false);
            let Ok((library, weights)) = received else { return };
            core.player.set_history_weights(weights.into_iter().collect());
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
            core.hub.emit(&AppEvent::LibraryReloaded);
            if core.reload_pending.replace(false) {
                core.reload_library();
            }
        });
    }

    pub fn toast(&self, message: &str) {
        self.hub.emit(&AppEvent::Toast(message.to_string()));
    }

    /// Tracks enrichment so the UI can show a running "finding artwork"
    /// progress. Counting is balanced — every queued album (see
    /// enrichment::request_album) is matched by one completion — and silent at
    /// queue time so a bulk pass doesn't emit hundreds of updates; the indicator
    /// appears as soon as the first album completes.
    pub fn add_enrichment_pending(&self) {
        self.enrich_total.set(self.enrich_total.get() + 1);
    }

    pub fn note_enrichment_done(&self) {
        self.enrich_done.set(self.enrich_done.get() + 1);
        if self.enrich_done.get() >= self.enrich_total.get() {
            self.enrich_total.set(0);
            self.enrich_done.set(0);
        }
        self.hub.emit(&AppEvent::EnrichmentProgress {
            done: self.enrich_done.get(),
            total: self.enrich_total.get(),
        });
    }

    pub fn start(self: &Rc<Self>, _window: &adw::ApplicationWindow) {
        self.reload_library();
        self.start_tick();
        crate::mpris::start(self);
        crate::scrobbler::startup_maintenance(self);
        crate::enrichment::start(self);
        self.wire_autoplay();
        self.rescan();
        self.schedule_periodic_drain();
        self.schedule_enrichment_pass();
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
        let wanted = std::env::var("FLACCY_DEMO_TRACK").unwrap_or_else(|_| "Slow Machine".to_string());
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
            let start = album.tracks.iter().position(|t| t.title == wanted).unwrap_or(0);
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
                    ScanEvent::Progress(done, total) => {
                        core.hub.emit(&AppEvent::ScanProgress(done, total));
                    }
                    ScanEvent::Done { added, removed } => {
                        core.scanning.set(false);
                        core.hub.emit(&AppEvent::ScanFinished { added, removed });
                        if added > 0 || removed > 0 {
                            core.reload_library();
                        }
                        break;
                    }
                    ScanEvent::Failed(message) => {
                        crate::logger::error("library", &format!("scan failed: {message}"));
                        core.scanning.set(false);
                        core.hub
                            .emit(&AppEvent::ScanFinished { added: 0, removed: 0 });
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
        let Some(album) = library.album_by_key(key) else { return };
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

    pub fn play_artist(self: &Rc<Self>, artist: &str, shuffle: bool) {
        let library = self.library.borrow().clone();
        let tracks: Vec<Track> = library
            .albums
            .iter()
            .filter(|album| crate::hygiene::artist_key(&album.artist) == crate::hygiene::artist_key(artist))
            .flat_map(|album| album.tracks.iter().cloned())
            .collect();
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

    pub fn set_volume(&self, volume: f64) {
        self.player.set_volume(volume);
        self.config.borrow_mut().volume = volume;
        self.hub.emit(&AppEvent::VolumeChanged(volume));
    }

    pub fn toggle_love(self: &Rc<Self>, rel_path: &str) {
        let library = self.library.borrow().clone();
        let Some(track) = library.track_by_rel_path(rel_path) else { return };
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

    /// Runs the library-wide background enrichment pass a few seconds after
    /// launch so startup scan and first paint are never blocked by it.
    fn schedule_enrichment_pass(self: &Rc<Self>) {
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(Duration::from_secs(6), move || {
            if let Some(core) = weak.upgrade() {
                crate::enrichment::schedule_background_pass(&core);
            }
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
        let (tx, rx) = async_channel::bounded::<i64>(1);
        std::thread::Builder::new()
            .name("flaccy-import-check".into())
            .spawn(move || {
                let count = Db::open(&db_path).map(|db| db.scrobble_count()).unwrap_or(0);
                let _ = tx.send_blocking(count);
            })
            .ok();
        glib::spawn_future_local(async move {
            let count = rx.recv().await.unwrap_or(i64::MAX);
            if count < AUTO_IMPORT_THRESHOLD {
                crate::logger::info(
                    "import",
                    &format!("auto-import: {count} local scrobbles below threshold, pulling Last.fm history"),
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
            let Some(core) = weak.upgrade() else { return false };
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
        let Some(track) = library.track_by_rel_path(rel_path).cloned() else { return };
        self.start_station(track.artist.clone(), Some(track));
    }

    fn start_station(self: &Rc<Self>, seed_artist: String, seed_track: Option<Track>) {
        let library = self.library.borrow().clone();
        let pool = library.tracks.clone();
        let library_artists: Vec<String> =
            library.artists.iter().map(|a| a.name.clone()).collect();
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
                &format!("station started: seed '{seed_artist}', {} tracks", station.len()),
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
            let Some(core) = weak.upgrade() else { return false };
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
        let Some(current_track) = self.player.current_track() else { return };
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
        let library_artists: Vec<String> =
            library.artists.iter().map(|a| a.name.clone()).collect();
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

    /// Copies dropped audio files/folders into the library root and rescans.
    pub fn import_dropped_paths(self: &Rc<Self>, paths: Vec<std::path::PathBuf>) {
        let root = self.music_root();
        let (tx, rx) = async_channel::bounded::<(usize, usize)>(1);
        std::thread::Builder::new()
            .name("flaccy-dnd".into())
            .spawn(move || {
                let mut copied = 0;
                let mut skipped = 0;
                for path in paths {
                    copy_into_library(&path, &root, &mut copied, &mut skipped);
                }
                let _ = tx.send_blocking((copied, skipped));
            })
            .ok();
        let weak = Rc::downgrade(self);
        glib::spawn_future_local(async move {
            let Ok((copied, skipped)) = rx.recv().await else { return };
            let Some(core) = weak.upgrade() else { return };
            crate::logger::info(
                "library",
                &format!("drag-drop import: {copied} copied, {skipped} skipped"),
            );
            if copied > 0 {
                core.toast(&format!(
                    "Imported {copied} file{}{}",
                    if copied == 1 { "" } else { "s" },
                    if skipped > 0 {
                        format!(" · {skipped} skipped")
                    } else {
                        String::new()
                    }
                ));
                core.rescan();
            } else {
                core.toast("Nothing to import — drop audio files or folders");
            }
        });
    }

    fn wire_scrobbler(self: &Rc<Self>) {
        let core = Rc::downgrade(self);
        self.hub.subscribe(move |event| {
            let Some(core) = core.upgrade() else { return false };
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
        &format!("SMOKE: starting playback of '{} — {}'", track.title, track.artist),
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

const IMPORT_EXTENSIONS: [&str; 8] = ["flac", "mp3", "m4a", "ogg", "opus", "wav", "aiff", "aif"];

fn copy_into_library(source: &std::path::Path, root: &std::path::Path, copied: &mut usize, skipped: &mut usize) {
    if source.is_dir() {
        let Ok(entries) = std::fs::read_dir(source) else {
            *skipped += 1;
            return;
        };
        for entry in entries.flatten() {
            copy_into_library(&entry.path(), root, copied, skipped);
        }
        return;
    }
    let extension = source
        .extension()
        .map(|e| e.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    if !IMPORT_EXTENSIONS.contains(&extension.as_str()) {
        *skipped += 1;
        return;
    }
    if source.starts_with(root) {
        *skipped += 1;
        return;
    }
    let Some(name) = source.file_name() else {
        *skipped += 1;
        return;
    };
    let target_dir = root.join("Imported");
    if std::fs::create_dir_all(&target_dir).is_err() {
        *skipped += 1;
        return;
    }
    let mut destination = target_dir.join(name);
    let mut counter = 1;
    while destination.exists() {
        let stem = source.file_stem().unwrap_or_default().to_string_lossy();
        destination = target_dir.join(format!("{stem} ({counter}).{extension}"));
        counter += 1;
    }
    match std::fs::copy(source, &destination) {
        Ok(_) => *copied += 1,
        Err(err) => {
            crate::logger::error(
                "library",
                &format!("import copy failed for {}: {err}", source.display()),
            );
            *skipped += 1;
        }
    }
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
    use super::copy_into_library;

    #[test]
    fn copies_audio_skips_other_and_duplicates() {
        let temp = std::env::temp_dir().join(format!("flaccy-dnd-test-{}", std::process::id()));
        let source = temp.join("src");
        let root = temp.join("root");
        std::fs::create_dir_all(source.join("nested")).expect("mkdir");
        std::fs::create_dir_all(&root).expect("mkdir root");
        std::fs::write(source.join("song.flac"), b"x").expect("write");
        std::fs::write(source.join("nested/deep.mp3"), b"y").expect("write");
        std::fs::write(source.join("notes.txt"), b"z").expect("write");
        let mut copied = 0;
        let mut skipped = 0;
        copy_into_library(&source, &root, &mut copied, &mut skipped);
        assert_eq!(copied, 2);
        assert_eq!(skipped, 1);
        assert!(root.join("Imported/song.flac").exists());
        assert!(root.join("Imported/deep.mp3").exists());
        copy_into_library(&source.join("song.flac"), &root, &mut copied, &mut skipped);
        assert!(root.join("Imported/song (1).flac").exists());
        let _ = std::fs::remove_dir_all(&temp);
    }
}
