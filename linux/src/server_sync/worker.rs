use super::failure::Stage;
use super::schedule::{Outcome, Scheduler};
use async_channel::Sender as Reply;
use flaccy_library::db::Db;
use flaccy_library::server_sync::{
    files_for_loves, resolve_ghosts, Blocker, DeviceInfo, Dirty, Driver, ServerIdentity, ServerLink,
    SyncError, SyncState, SyncStatus, TokenStore,
};
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::time::Instant;

const LOG: &str = "server-sync";

/// What the worker thread is asked to do. Every reply travels on a channel the main loop awaits, so the GTK thread never blocks on the network.
pub enum Command {
    /// The window gained or lost focus.
    Focus(bool),
    /// A local write may be waiting to be sent.
    Poke,
    /// The network came back.
    NetworkRecovered,
    /// A scan added songs; entries waiting for their files may now resolve.
    ResolveGhosts,
    /// Look at an address.
    Probe {
        /// The base URL.
        url: String,
        /// Where the answer goes.
        reply: Reply<Result<ServerIdentity, SyncError>>,
    },
    /// Redeem a code and start syncing.
    Connect {
        /// The pairing link.
        link: ServerLink,
        /// This computer's name on the device list.
        device_name: String,
        /// Where the answer goes.
        reply: Reply<Result<Connected, ConnectFailure>>,
    },
    /// Forget the server.
    Disconnect {
        /// Where the answer goes.
        reply: Reply<Result<(), SyncError>>,
    },
    /// List the account's devices.
    Devices {
        /// Where the answer goes.
        reply: Reply<Result<Vec<DeviceInfo>, SyncError>>,
    },
}

/// What a successful connect hands back to the main loop.
pub struct Connected {
    /// What the server calls itself.
    pub server: ServerIdentity,
}

/// A connect that failed, and which of its two calls it was.
pub struct ConnectFailure {
    /// Looking at the address, or redeeming the code.
    pub stage: Stage,
    /// What the engine reported.
    pub error: SyncError,
}

/// What the worker tells the main loop without being asked.
pub enum Report {
    /// The status line changed.
    Status(SyncStatus),
    /// Pages were applied; the views over this data refresh.
    Dirty(Dirty),
    /// Files whose loved flag a pull changed, when there are few enough to name.
    Loved(Vec<(String, bool)>),
}

/// More changed loves than this and the views reload instead of repainting hearts one by one.
const NAMED_LOVES_LIMIT: usize = 200;

/// Starts the worker thread. `None` when the thread or its database handle could not start.
pub fn spawn(
    db_path: PathBuf,
    tokens: TokenStore,
    reports: Reports,
) -> Option<mpsc::Sender<Command>> {
    let (commands, inbox) = mpsc::channel();
    std::thread::Builder::new()
        .name("flaccy-server-sync".into())
        .spawn(move || run(&db_path, tokens, &reports, &inbox))
        .ok()?;
    Some(commands)
}

/// The channel the worker reports on.
pub type Reports = async_channel::Sender<Report>;

/// Sends `report`, ignoring a main loop that has already gone.
fn tell(reports: &Reports, report: Report) {
    let _ = reports.send_blocking(report);
}

fn run(
    db_path: &std::path::Path,
    tokens: TokenStore,
    reports: &Reports,
    inbox: &Receiver<Command>,
) {
    let db = match Db::open(db_path) {
        Ok(db) => db,
        Err(error) => {
            crate::logger::error(LOG, &format!("sync cannot open the library: {error}"));
            return;
        }
    };
    let mut driver = Driver::new(tokens, None);
    let listener = reports.clone();
    driver.on_dirty(move |dirty| tell(&listener, Report::Dirty(dirty.clone())));
    let mut worker = Worker {
        db,
        driver,
        scheduler: Scheduler::new(rand::random::<f64>),
        reports: reports.clone(),
        last_logged: None,
    };
    worker.start();
    worker.serve(inbox);
}

struct Worker {
    db: Db,
    driver: Driver,
    scheduler: Scheduler,
    reports: Reports,
    last_logged: Option<SyncState>,
}

impl Worker {
    fn start(&mut self) {
        if self.driver.engine().is_attached(&self.db) {
            self.scheduler.connect(Instant::now());
        }
    }

    fn serve(&mut self, inbox: &Receiver<Command>) {
        loop {
            match self.next_command(inbox) {
                Ok(Some(command)) => self.handle(command),
                Ok(None) => {}
                Err(RecvTimeoutError::Disconnected) => return,
                Err(RecvTimeoutError::Timeout) => {}
            }
            if self.scheduler.is_due(Instant::now()) {
                self.round();
            }
        }
    }

    fn next_command(
        &self,
        inbox: &Receiver<Command>,
    ) -> Result<Option<Command>, RecvTimeoutError> {
        let Some(deadline) = self.scheduler.deadline() else {
            return inbox.recv().map(Some).map_err(|_| RecvTimeoutError::Disconnected);
        };
        let wait = deadline.saturating_duration_since(Instant::now());
        inbox.recv_timeout(wait).map(Some)
    }

    fn handle(&mut self, command: Command) {
        let now = Instant::now();
        match command {
            Command::Focus(focused) => self.scheduler.focus(focused, now),
            Command::Poke => self.poke(now),
            Command::NetworkRecovered => self.scheduler.network_recovered(now),
            Command::ResolveGhosts => self.resolve_ghosts(),
            Command::Probe { url, reply } => {
                let _ = reply.send_blocking(self.driver.probe(&url));
            }
            Command::Connect {
                link,
                device_name,
                reply,
            } => {
                let _ = reply.send_blocking(self.connect(&link, &device_name));
            }
            Command::Disconnect { reply } => {
                let _ = reply.send_blocking(self.disconnect());
            }
            Command::Devices { reply } => {
                let _ = reply.send_blocking(self.driver.devices(&self.db));
            }
        }
    }

    fn poke(&mut self, now: Instant) {
        let waiting = self.driver.engine().unsent_count(&self.db).unwrap_or(0);
        if waiting > 0 {
            self.scheduler.poke(now);
        }
    }

    fn connect(
        &mut self,
        link: &ServerLink,
        device_name: &str,
    ) -> Result<Connected, ConnectFailure> {
        let at = |stage| move |error| ConnectFailure { stage, error };
        let server = self.driver.probe(&link.url).map_err(at(Stage::Probe))?;
        let imported = self
            .driver
            .enroll(&self.db, link, device_name)
            .map_err(at(Stage::Enroll))?;
        crate::logger::info(
            LOG,
            &format!(
                "connected to {}: {} playlists, {} loves and {} plays queued",
                server.name, imported.playlists, imported.loves, imported.listens
            ),
        );
        self.scheduler.connect(Instant::now());
        Ok(Connected { server })
    }

    fn disconnect(&mut self) -> Result<(), SyncError> {
        self.driver.disconnect(&self.db)?;
        self.scheduler.disconnect();
        self.last_logged = None;
        crate::logger::info(LOG, "disconnected");
        Ok(())
    }

    fn resolve_ghosts(&mut self) {
        if !self.driver.engine().is_attached(&self.db) {
            return;
        }
        match resolve_ghosts(&self.db) {
            Ok(dirty) if dirty.changed() => tell(&self.reports, Report::Dirty(dirty)),
            Ok(_) => {}
            Err(error) => crate::logger::warn(LOG, &format!("ghost pass failed: {error}")),
        }
    }

    fn round(&mut self) {
        self.scheduler.begin();
        let before = self.driver.status(&self.db);
        if matches!(before.state, SyncState::Syncing(_)) {
            tell(&self.reports, Report::Status(before));
        }
        let status = self.driver.run_once(&self.db);
        let dirty = self.driver.take_dirty();
        self.report_loves(&dirty);
        self.scheduler.finish(outcome_of(&status.state), Instant::now());
        self.log_change(&status.state);
        tell(&self.reports, Report::Status(status));
    }

    fn report_loves(&self, dirty: &Dirty) {
        if dirty.loves.is_empty() || dirty.loves.len() > NAMED_LOVES_LIMIT {
            return;
        }
        match files_for_loves(&self.db, &dirty.loves) {
            Ok(files) => tell(&self.reports, Report::Loved(files)),
            Err(error) => crate::logger::warn(LOG, &format!("love lookup failed: {error}")),
        }
    }

    fn log_change(&mut self, state: &SyncState) {
        if self.last_logged.as_ref() == Some(state) {
            return;
        }
        crate::logger::info(LOG, &format!("sync state: {state:?}"));
        self.last_logged = Some(state.clone());
    }
}

/// How the scheduler should treat a round that ended in `state`.
pub fn outcome_of(state: &SyncState) -> Outcome {
    match state {
        SyncState::UpToDate | SyncState::Syncing(_) => Outcome::Fine,
        SyncState::Blocked(Blocker::DeviceRevoked) => Outcome::Parked,
        SyncState::Offline | SyncState::NeedsAttention(_) | SyncState::Blocked(_) => {
            Outcome::Failed
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rounds_end_fine_failed_or_parked() {
        assert_eq!(outcome_of(&SyncState::UpToDate), Outcome::Fine);
        assert_eq!(outcome_of(&SyncState::Offline), Outcome::Failed);
        assert_eq!(
            outcome_of(&SyncState::NeedsAttention("x".into())),
            Outcome::Failed
        );
        assert_eq!(
            outcome_of(&SyncState::Blocked(Blocker::ClockBehind)),
            Outcome::Failed
        );
        assert_eq!(
            outcome_of(&SyncState::Blocked(Blocker::DeviceRevoked)),
            Outcome::Parked
        );
    }
}
