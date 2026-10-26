//! Flaccy Server sync on the GTK client: a worker thread that owns the engine's driver and its own database handle, and the main-thread [`Service`] the interface talks to. The wire contract is `docs/server/PROTOCOL.md` and the words are `docs/server/UX.md`; the engine lives in `flaccy_library::server_sync`.

pub mod address;
pub mod copy;
mod demo;
pub mod failure;
mod incoming;
pub mod link;
mod manage;
mod schedule;
pub mod status_line;
mod worker;

use crate::app::AppCore;
use crate::events::AppEvent;
use failure::{failure_for, Failure, Stage};
use flaccy_library::server_sync::{
    DeviceInfo, Dirty, Engine, MergeReport, ServerIdentity, ServerLink, SyncStatus, TokenStore,
};
use gtk::glib;
use gtk::prelude::*;
use std::cell::{Cell, RefCell};
use std::rc::{Rc, Weak};
use std::sync::mpsc;
use std::time::Duration;
use worker::{Command, LibraryChange, Report};

pub use demo::open_ui as open_demo_ui;
pub use incoming::{deliver, open_incoming, register_ui};
pub use worker::Connected;

const LOG: &str = "server-sync";
const REFRESH_COALESCE: Duration = Duration::from_millis(250);

/// What pulled pages changed, waiting for one refresh of the views.
#[derive(Default)]
struct Pending {
    library: bool,
    playlists: bool,
    plays: usize,
}

/// The main-thread side of sync: what the interface asks and what it shows.
pub struct Service {
    core: Weak<AppCore>,
    commands: mpsc::Sender<Command>,
    status: RefCell<Option<SyncStatus>>,
    connected: Cell<bool>,
    pending: RefCell<Pending>,
    refresh_queued: Cell<bool>,
    merge: RefCell<Option<MergeReport>>,
    library_songs: Cell<Option<usize>>,
    counting: Cell<bool>,
}

impl Service {
    fn send(&self, command: Command) -> bool {
        self.commands.send(command).is_ok()
    }

    /// True while a Flaccy Server is connected.
    pub fn connected(&self) -> bool {
        self.connected.get()
    }

    /// What the connected server calls itself, or a neutral phrase when it never said.
    pub fn name(&self) -> String {
        self.core
            .upgrade()
            .map(|core| core.config.borrow().flaccy_server_name.clone())
            .filter(|name| !name.is_empty())
            .unwrap_or_else(|| copy::SERVER_NAME_FALLBACK.to_owned())
    }

    /// The status line under the server's name.
    pub fn status_line(&self) -> String {
        status_line::status_line(
            &self.name(),
            self.status.borrow().as_ref(),
            chrono::Utc::now().timestamp_millis(),
        )
    }

    /// When the last complete pull finished, in Unix milliseconds.
    pub fn last_synced_at(&self) -> Option<i64> {
        self.status
            .borrow()
            .as_ref()
            .and_then(|status| status.last_synced_at)
    }

    /// Asks for a sync soon, after a local write.
    pub fn poke(&self) {
        self.send(Command::Poke);
    }

    /// Looks at an address: who answers there and whether it can sync with this Flaccy.
    pub async fn probe(&self, url: &str) -> Result<ServerIdentity, Failure> {
        let name = address::short_name(url);
        let (reply, answer) = async_channel::bounded(1);
        let url = url.to_owned();
        if !self.send(Command::Probe { url, reply }) {
            return Err(unavailable(&name));
        }
        match answer.recv().await {
            Ok(Ok(identity)) => Ok(identity),
            Ok(Err(error)) => Err(failure_for(&error, Stage::Probe, &name)),
            Err(_) => Err(unavailable(&name)),
        }
    }

    /// Redeems the link's code, remembers the server and starts syncing. The result is applied here even when the dialog that asked has gone.
    pub async fn connect(self: &Rc<Self>, link: ServerLink) -> Result<Connected, Failure> {
        let hint = link
            .name
            .clone()
            .unwrap_or_else(|| address::short_name(&link.url));
        let (reply, answer) = async_channel::bounded(1);
        let command = Command::Connect {
            link,
            device_name: address::device_name(),
            reply,
        };
        if !self.send(command) {
            return Err(unavailable(&hint));
        }
        match answer.recv().await {
            Ok(Ok(connected)) => {
                self.remember(&connected.server);
                Ok(connected)
            }
            Ok(Err(failed)) => Err(failure_for(&failed.error, failed.stage, &hint)),
            Err(_) => Err(unavailable(&hint)),
        }
    }

    /// Forgets the server on this computer; the server keeps its copy.
    pub async fn disconnect(self: &Rc<Self>) -> Result<(), String> {
        let (reply, answer) = async_channel::bounded(1);
        if !self.send(Command::Disconnect { reply }) {
            return Err(copy::SERVICE_UNAVAILABLE.to_owned());
        }
        match answer.recv().await {
            Ok(Ok(())) => {
                self.forget();
                Ok(())
            }
            Ok(Err(error)) => {
                crate::logger::error(LOG, &format!("disconnect failed: {error}"));
                Err(copy::DISCONNECT_FAILED.to_owned())
            }
            Err(_) => Err(copy::SERVICE_UNAVAILABLE.to_owned()),
        }
    }

    /// The devices on the account.
    pub async fn devices(&self) -> Result<Vec<DeviceInfo>, Failure> {
        let name = self.name();
        let (reply, answer) = async_channel::bounded(1);
        if !self.send(Command::Devices { reply }) {
            return Err(unavailable(&name));
        }
        match answer.recv().await {
            Ok(Ok(devices)) => Ok(devices),
            Ok(Err(error)) => Err(failure_for(&error, Stage::Connected, &name)),
            Err(_) => Err(unavailable(&name)),
        }
    }

    fn remember(&self, server: &ServerIdentity) {
        let Some(core) = self.core.upgrade() else {
            return;
        };
        core.config.borrow_mut().flaccy_server_name = server.name.clone();
        core.save_config();
        self.connected.set(true);
        core.hub.emit(&AppEvent::ServerSyncChanged);
    }

    fn forget(&self) {
        let Some(core) = self.core.upgrade() else {
            return;
        };
        core.config.borrow_mut().flaccy_server_name.clear();
        core.save_config();
        self.connected.set(false);
        *self.status.borrow_mut() = None;
        core.hub.emit(&AppEvent::ServerSyncChanged);
    }

    fn set_status(&self, status: SyncStatus) {
        *self.status.borrow_mut() = Some(status);
        if let Some(core) = self.core.upgrade() {
            core.hub.emit(&AppEvent::ServerSyncChanged);
        }
    }

    fn note_dirty(self: &Rc<Self>, dirty: Dirty) {
        {
            let mut pending = self.pending.borrow_mut();
            pending.library |= !dirty.loves.is_empty();
            pending.playlists |= !dirty.playlists.is_empty();
            pending.plays += dirty.listens;
        }
        if self.refresh_queued.replace(true) {
            return;
        }
        let weak = Rc::downgrade(self);
        glib::timeout_add_local_once(REFRESH_COALESCE, move || {
            if let Some(service) = weak.upgrade() {
                service.refresh_views();
            }
        });
    }

    fn repaint_hearts(&self, files: &[(String, bool)]) {
        let Some(core) = self.core.upgrade() else {
            return;
        };
        let Some(playing) = core.player.current_track() else {
            return;
        };
        if let Some((rel_path, loved)) = files.iter().find(|(path, _)| *path == playing.rel_path) {
            crate::logger::info(LOG, &format!("heart repainted: loved={loved}"));
            core.hub.emit(&AppEvent::LovedChanged {
                rel_path: rel_path.clone(),
                loved: *loved,
            });
        }
    }

    fn refresh_views(&self) {
        self.refresh_queued.set(false);
        let pending = std::mem::take(&mut *self.pending.borrow_mut());
        let Some(core) = self.core.upgrade() else {
            return;
        };
        crate::logger::info(
            LOG,
            &format!(
                "views refresh: library={} playlists={} plays={}",
                pending.library, pending.playlists, pending.plays
            ),
        );
        if pending.library {
            core.reload_library();
        } else if pending.playlists {
            core.hub.emit(&AppEvent::LibraryReloaded);
        }
        if pending.plays > 0 {
            core.hub.emit(&AppEvent::HistorySynced {
                stored: pending.plays,
            });
        }
    }
}

fn unavailable(name: &str) -> Failure {
    Failure {
        title: copy::generic_title(name),
        body: copy::SERVICE_UNAVAILABLE.to_owned(),
        remedy: failure::Remedy::Ok,
    }
}

/// Starts sync: the worker thread, the hooks that wake it, and the demo connect when the environment asks for one. Does nothing when the worker cannot start.
pub fn start(core: &Rc<AppCore>, window: &adw::ApplicationWindow) {
    let (reports, inbox) = async_channel::unbounded::<Report>();
    let tokens = TokenStore::new(crate::config::server_token_path());
    let Some(commands) = worker::spawn(core.db_path.clone(), tokens, reports) else {
        crate::logger::error(LOG, "the sync thread could not start");
        return;
    };
    let service = Rc::new(Service {
        core: Rc::downgrade(core),
        commands,
        status: RefCell::new(None),
        connected: Cell::new(Engine::new().is_attached(&core.db)),
        pending: RefCell::new(Pending::default()),
        refresh_queued: Cell::new(false),
        merge: RefCell::new(None),
        library_songs: Cell::new(None),
        counting: Cell::new(false),
    });
    drain_reports(&service, inbox);
    service.ensure_library();
    wake_on_local_writes(core, &service);
    wake_on_focus(window, &service);
    wake_on_network(&service);
    let _ = core.server_sync.set(Rc::clone(&service));
    demo::start(&service);
}

fn drain_reports(service: &Rc<Service>, inbox: async_channel::Receiver<Report>) {
    let weak = Rc::downgrade(service);
    glib::spawn_future_local(async move {
        while let Ok(report) = inbox.recv().await {
            let Some(service) = weak.upgrade() else { return };
            match report {
                Report::Status(status) => service.set_status(status),
                Report::Dirty(dirty) => service.note_dirty(dirty),
                Report::Loved(files) => service.repaint_hearts(&files),
                Report::Merged(merge) => service.set_merge(merge),
                Report::Library(change) => service.library_changed(change),
            }
        }
    });
}

fn wake_on_local_writes(core: &Rc<AppCore>, service: &Rc<Service>) {
    let weak = Rc::downgrade(service);
    core.hub.subscribe(move |event| {
        let Some(service) = weak.upgrade() else {
            return false;
        };
        match event {
            AppEvent::LovedChanged { .. }
            | AppEvent::LibraryReloaded
            | AppEvent::ScrobbleRecorded => {
                service.poke();
            }
            AppEvent::RemoteChanged => service.refresh_library_count(),
            AppEvent::ScanFinished { added, .. } if *added > 0 => {
                service.send(Command::ResolveGhosts);
            }
            _ => {}
        }
        true
    });
}

fn wake_on_focus(window: &adw::ApplicationWindow, service: &Rc<Service>) {
    service.send(Command::Focus(window.is_active()));
    let weak = Rc::downgrade(service);
    window.connect_is_active_notify(move |window| {
        if let Some(service) = weak.upgrade() {
            service.send(Command::Focus(window.is_active()));
        }
    });
}

fn wake_on_network(service: &Rc<Service>) {
    let weak = Rc::downgrade(service);
    gtk::gio::NetworkMonitor::default().connect_network_changed(move |_, available| {
        if let (true, Some(service)) = (available, weak.upgrade()) {
            service.send(Command::NetworkRecovered);
        }
    });
}
