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
        });
        core.artwork.start(&core);
        core.wire_scrobbler();
        core
    }

    pub fn music_root(&self) -> PathBuf {
        self.config.borrow().music_root()
    }

    pub fn reload_library(&self) {
        let library = library::load(&self.db);
        crate::logger::info(
            "library",
            &format!(
                "library loaded: {} tracks, {} albums, {} artists",
                library.tracks.len(),
                library.albums.len(),
                library.artists.len()
            ),
        );
        *self.library.borrow_mut() = Rc::new(library);
        self.hub.emit(&AppEvent::LibraryReloaded);
    }

    pub fn start(self: &Rc<Self>, _window: &adw::ApplicationWindow) {
        self.reload_library();
        self.start_tick();
        crate::mpris::start(self);
        crate::scrobbler::startup_maintenance(self);
        self.rescan();
        self.schedule_periodic_drain();
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

    fn wire_scrobbler(self: &Rc<Self>) {
        let core = Rc::downgrade(self);
        self.hub.subscribe(move |event| {
            let Some(core) = core.upgrade() else { return false };
            match event {
                AppEvent::TrackChanged(track) => {
                    crate::scrobbler::on_track_started(&core, track.clone());
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
