use super::credentials::TokenStore;
use super::engine::{Dirty, Engine, Enrollment, PullOutcome, PushFailure, PushRecovery};
use super::error::{Result, SyncError};
use super::ids::new_uuid_v7;
use super::import::ImportReport;
use super::link::ServerLink;
use super::sink::ScalarSink;
use super::transport::{ApiError, Transport};
use crate::db::{now_ms, Db};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

const MAX_RESTARTS: usize = 4;
const MAX_PUSH_ROUNDS: usize = 200;

/// Where a sync stands, for the status line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncState {
    /// Everything local reached the server and everything on the server is here.
    UpToDate,
    /// This many local changes are waiting to be sent.
    Syncing(usize),
    /// The server cannot be reached; local changes wait and Flaccy retries by itself.
    Offline,
    /// Something only the person can fix; the text says what, why and what to do.
    NeedsAttention(String),
}

/// The state, the queue length and the last complete pull.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncStatus {
    /// Where the sync stands.
    pub state: SyncState,
    /// Mutations still queued, refused ones included until a pull retires them.
    pub pending: usize,
    /// Unix milliseconds of the last complete pull.
    pub last_synced_at: Option<i64>,
}

/// How long to wait between retries of a call that failed in a way that may pass.
#[derive(Clone, Copy, Debug)]
pub struct Backoff {
    /// The first pause in milliseconds; each retry doubles it.
    pub base_ms: u64,
    /// The longest pause.
    pub max_ms: u64,
    /// How many times a call is tried in all.
    pub attempts: u32,
}

impl Backoff {
    /// The default: 0.5 s, doubling to 8 s, four tries.
    pub const STANDARD: Backoff = Backoff {
        base_ms: 500,
        max_ms: 8_000,
        attempts: 4,
    };
    /// Tries once and never waits; for tests.
    pub const NONE: Backoff = Backoff {
        base_ms: 0,
        max_ms: 0,
        attempts: 1,
    };

    fn pause(&self, attempt: u32) -> Duration {
        let ceiling = self
            .base_ms
            .saturating_mul(1 << attempt.min(16))
            .min(self.max_ms);
        let jitter = if ceiling == 0 {
            0
        } else {
            rand::random::<u64>() % (ceiling / 2 + 1)
        };
        Duration::from_millis(ceiling / 2 + jitter)
    }
}

/// A shared flag the GUI sets to ask for a sync soon: a local change, a focus event, a server poke.
#[derive(Clone, Default)]
pub struct PokeHandle {
    inner: Arc<(Mutex<bool>, Condvar)>,
}

impl PokeHandle {
    /// Asks the sync loop to run now.
    pub fn poke(&self) {
        let (flag, wake) = &*self.inner;
        if let Ok(mut raised) = flag.lock() {
            *raised = true;
            wake.notify_all();
        }
    }

    /// Waits up to `timeout` for a poke; true when one arrived. Clears the flag.
    pub fn wait(&self, timeout: Duration) -> bool {
        let (flag, wake) = &*self.inner;
        let Ok(mut raised) = flag.lock() else {
            return false;
        };
        if !*raised {
            raised = match wake.wait_timeout(raised, timeout) {
                Ok((guard, _)) => guard,
                Err(_) => return false,
            };
        }
        std::mem::replace(&mut *raised, false)
    }
}

enum Flow {
    Done,
    Restart,
}

enum Stop {
    Api(ApiError),
    Sync(SyncError),
}

impl From<ApiError> for Stop {
    fn from(error: ApiError) -> Self {
        Stop::Api(error)
    }
}

impl From<SyncError> for Stop {
    fn from(error: SyncError) -> Self {
        Stop::Sync(error)
    }
}

/// Runs the sync loop against one server: enrolls, then pulls, pushes and reads the play history.
pub struct Driver {
    engine: Engine,
    tokens: TokenStore,
    backoff: Backoff,
    poke: PokeHandle,
    dirty: Dirty,
}

impl Driver {
    /// A driver that keeps its token in `tokens` and hands GUI-owned scalars to `sink`.
    pub fn new(tokens: TokenStore, sink: Option<Arc<dyn ScalarSink>>) -> Self {
        let engine = match sink {
            Some(sink) => Engine::with_sink(sink),
            None => Engine::new(),
        };
        Driver {
            engine,
            tokens,
            backoff: Backoff::STANDARD,
            poke: PokeHandle::default(),
            dirty: Dirty::default(),
        }
    }

    /// The same driver with another retry schedule.
    pub fn with_backoff(mut self, backoff: Backoff) -> Self {
        self.backoff = backoff;
        self
    }

    /// Asks the loop that waits on [`Driver::poke_handle`] to sync now.
    pub fn poke(&self) {
        self.poke.poke();
    }

    /// A clone of the poke flag, for the thread that waits between runs and for the GUI that raises it.
    pub fn poke_handle(&self) -> PokeHandle {
        self.poke.clone()
    }

    /// Everything the engine recomputed since the last call, so the GUI repaints once.
    pub fn take_dirty(&mut self) -> Dirty {
        std::mem::take(&mut self.dirty)
    }

    /// The engine, for calls that need no network.
    pub fn engine(&self) -> &Engine {
        &self.engine
    }

    /// Redeems the code of a pairing link, stores the token, and queues the local playlists, loves and plays for the server.
    pub fn enroll(
        &mut self,
        db: &Db,
        link: &ServerLink,
        device_name: &str,
    ) -> Result<ImportReport> {
        let code = link.enroll.as_deref().ok_or_else(|| {
            SyncError::Protocol(
                "The link has no enrollment code. Ask the server for a new link.".into(),
            )
        })?;
        let transport = Transport::new(&link.url);
        let hello = self.retry(|| transport.hello()).map_err(api_to_sync)?;
        if !hello.protocol.contains(&1) || !hello.features.iter().any(|feature| feature == "sync") {
            return Err(SyncError::Protocol(
                "This server does not offer sync. Update the server and try again.".into(),
            ));
        }
        let instance = new_uuid_v7();
        let reply = self
            .retry(|| transport.enroll(code, device_name, &instance))
            .map_err(api_to_sync)?;
        self.tokens.save(&reply.token)?;
        self.engine.attach(
            db,
            &Enrollment {
                server_url: link.url.clone(),
                device: reply.device,
                user: reply.user.id,
                incarnation: reply.incarnation,
                instance,
                server_time_ms: reply.server_time_ms,
            },
        )
    }

    /// Forgets the server: the token, the base and the queue.
    pub fn disconnect(&mut self, db: &Db) -> Result<()> {
        self.engine.detach(db)?;
        self.tokens.clear()?;
        Ok(())
    }

    /// What the status line shows without touching the network.
    pub fn status(&self, db: &Db) -> SyncStatus {
        let pending = self.engine.pending_count(db).unwrap_or(0);
        let waiting = self.engine.unsent_count(db).unwrap_or(0);
        let state = match (self.engine.is_attached(db), waiting) {
            (false, _) => SyncState::NeedsAttention(
                "No Flaccy Server is connected. Open a server link to connect.".into(),
            ),
            (true, 0) => SyncState::UpToDate,
            (true, count) => SyncState::Syncing(count),
        };
        self.report(db, state, pending)
    }

    /// One round: pull, push what is queued, pull again to retire it, then read new plays.
    pub fn run_once(&mut self, db: &Db) -> SyncStatus {
        if !self.engine.is_attached(db) {
            return self.status(db);
        }
        let state = match self.sync(db) {
            Ok(()) => SyncState::UpToDate,
            Err(Stop::Api(error)) => api_state(&error),
            Err(Stop::Sync(error)) => SyncState::NeedsAttention(error.to_string()),
        };
        let pending = self.engine.pending_count(db).unwrap_or(0);
        self.report(db, state, pending)
    }

    fn report(&self, db: &Db, state: SyncState, pending: usize) -> SyncStatus {
        SyncStatus {
            state,
            pending,
            last_synced_at: self.engine.last_synced_at(db).unwrap_or(None),
        }
    }

    fn sync(&mut self, db: &Db) -> std::result::Result<(), Stop> {
        for _ in 0..=MAX_RESTARTS {
            if matches!(self.sync_pass(db)?, Flow::Done) {
                return Ok(());
            }
        }
        Err(Stop::Api(ApiError::Malformed(
            "The server kept replacing its data.".into(),
        )))
    }

    fn sync_pass(&mut self, db: &Db) -> std::result::Result<Flow, Stop> {
        let transport = self.transport(db)?;
        if matches!(self.pull_all(db, &transport)?, Flow::Restart) {
            return Ok(Flow::Restart);
        }
        let mut pushed = false;
        for _ in 0..MAX_PUSH_ROUNDS {
            match self.push_next(db, &transport)? {
                Push::Nothing => break,
                Push::Sent => pushed = true,
                Push::Restart => return Ok(Flow::Restart),
            }
        }
        if pushed && matches!(self.pull_all(db, &transport)?, Flow::Restart) {
            return Ok(Flow::Restart);
        }
        self.read_listens(db, &transport)
    }

    fn transport(&self, db: &Db) -> std::result::Result<Transport, Stop> {
        let url = self
            .engine
            .server_url(db)?
            .ok_or(SyncError::NotConfigured)?;
        Ok(Transport::new(&url).with_token(self.tokens.load()))
    }

    fn pull_all(&mut self, db: &Db, transport: &Transport) -> std::result::Result<Flow, Stop> {
        loop {
            let request = self.engine.pull_request(db)?;
            let response = match self.retry(|| transport.pull(&request)) {
                Ok(response) => response,
                Err(ApiError::IncarnationChanged(incarnation)) => {
                    self.engine.on_incarnation_changed(db, &incarnation)?;
                    return Ok(Flow::Restart);
                }
                Err(ApiError::CookieAhead(_)) => {
                    self.engine.on_cookie_ahead(db, &request)?;
                    return Ok(Flow::Restart);
                }
                Err(error) => return Err(error.into()),
            };
            match self
                .engine
                .on_pull_page(db, &request, &response, now_ms())?
            {
                PullOutcome::Applied { more, dirty } => {
                    self.dirty.merge(dirty);
                    if !more {
                        return Ok(Flow::Done);
                    }
                }
                PullOutcome::Stale => return Ok(Flow::Done),
                PullOutcome::Reset => return Ok(Flow::Restart),
            }
        }
    }

    fn push_next(&mut self, db: &Db, transport: &Transport) -> std::result::Result<Push, Stop> {
        let Some(request) = self.engine.next_push(db)? else {
            return Ok(Push::Nothing);
        };
        let incarnation = self.incarnation(db)?;
        match self.retry(|| transport.push(&request, incarnation.as_deref())) {
            Ok(response) => {
                let dirty =
                    self.engine
                        .on_push_response(db, &request.instance, &response, now_ms())?;
                self.dirty.merge(dirty);
                Ok(Push::Sent)
            }
            Err(ApiError::IncarnationChanged(incarnation)) => {
                self.engine.on_incarnation_changed(db, &incarnation)?;
                Ok(Push::Restart)
            }
            Err(ApiError::InstanceConflict) => {
                self.recover(db, &request.instance, PushFailure::InstanceConflict)
            }
            Err(ApiError::MutationGap { have }) => {
                self.recover(db, &request.instance, PushFailure::MutationGap { have })
            }
            Err(error) => Err(error.into()),
        }
    }

    fn recover(
        &mut self,
        db: &Db,
        instance: &str,
        failure: PushFailure,
    ) -> std::result::Result<Push, Stop> {
        Ok(match self.engine.on_push_error(db, instance, &failure)? {
            PushRecovery::Resend => Push::Sent,
            PushRecovery::Reset => Push::Restart,
            PushRecovery::Wait => Push::Nothing,
        })
    }

    fn read_listens(&mut self, db: &Db, transport: &Transport) -> std::result::Result<Flow, Stop> {
        loop {
            let request = self.engine.listens_request(db)?;
            let incarnation = self.incarnation(db)?;
            let page = match self.retry(|| transport.listens(&request, incarnation.as_deref())) {
                Ok(page) => page,
                Err(ApiError::IncarnationChanged(incarnation)) => {
                    self.engine.on_incarnation_changed(db, &incarnation)?;
                    return Ok(Flow::Restart);
                }
                Err(ApiError::CookieAhead(_)) => {
                    self.engine.on_listens_cookie_ahead(db)?;
                    return Ok(Flow::Restart);
                }
                Err(error) => return Err(error.into()),
            };
            let written = self.engine.on_listens_page(db, &page)?;
            self.dirty.listens += written;
            if !page.more && self.engine.listens_backfilled(db)? {
                return Ok(Flow::Done);
            }
        }
    }

    fn incarnation(&self, db: &Db) -> std::result::Result<Option<String>, Stop> {
        Ok(self.engine.pull_request(db)?.incarnation)
    }

    fn retry<T>(
        &self,
        mut call: impl FnMut() -> std::result::Result<T, ApiError>,
    ) -> std::result::Result<T, ApiError> {
        let mut attempt = 0;
        loop {
            match call() {
                Err(error) if error.is_transient() && attempt + 1 < self.backoff.attempts => {
                    std::thread::sleep(self.backoff.pause(attempt));
                    attempt += 1;
                }
                other => return other,
            }
        }
    }
}

enum Push {
    Nothing,
    Sent,
    Restart,
}

fn api_state(error: &ApiError) -> SyncState {
    match error {
        ApiError::Offline(_) | ApiError::Server(_) | ApiError::RateLimited(_) => SyncState::Offline,
        other => SyncState::NeedsAttention(other.to_string()),
    }
}

fn api_to_sync(error: ApiError) -> SyncError {
    SyncError::Protocol(error.to_string())
}
