//! The server as a library call, for a program that hosts it itself: the sandboxed Mac app.
//!
//! [`EmbeddedServer::start`] takes the data-folder lock, then runs the same [`hosting::run`] as
//! `flaccy-server serve` on a runtime of its own, on dedicated threads. It never installs signal
//! handlers and never prints; log lines go to `log_dir`. One embedded server runs per process.

use std::future::Future;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;
use std::time::Duration;

use chrono::{SecondsFormat, Utc};
use flaccy_library::logger;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::runtime::{Builder, Handle as RuntimeHandle, Runtime};
use tokio::sync::oneshot;

use crate::admin::enrollment_link;
use crate::config::{Config, Mode};
use crate::hosting::{self, Online, Settings};
use crate::lock::{DataDirLock, LockError};
use crate::security::{Role, Store, User};
use crate::shutdown::StopSignal;
use crate::state::OpenOptions;

const OWNER: &str = "owner";
const WORKER_THREADS: usize = 4;
const ENROLLMENT_TTL: Duration = Duration::from_secs(10 * 60);
const STARTUP_WAIT: Duration = Duration::from_secs(60);
const CALL_WAIT: Duration = Duration::from_secs(30);
const RUNTIME_LINGER: Duration = Duration::from_secs(2);

static PROCESS_SLOT: AtomicBool = AtomicBool::new(false);

/// What the hosting program decides; everything else is the server's own defaults.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct EmbedConfig {
    /// The folder the music lives in; the caller holds access to it for as long as the server runs.
    pub music_folder: PathBuf,
    /// Where the databases, covers and backups live; created when missing.
    pub data_dir: PathBuf,
    /// The name devices show for this server; the machine's host name when empty.
    #[serde(default)]
    pub name: String,
    /// The port to listen on, 0 for any free one.
    #[serde(default)]
    pub port: u16,
    /// The ffmpeg program for converting audio; `None` turns conversion off.
    #[serde(default)]
    pub ffmpeg: Option<String>,
    /// Where `flaccy.log` goes.
    pub log_dir: PathBuf,
}

/// Why an embedded server could not start or answer.
#[derive(Debug)]
pub enum EmbedError {
    /// One embedded server already runs in this process.
    AlreadyRunning,
    /// The configuration cannot be used; the text says what to change.
    Config(String),
    /// Another server holds the data folder.
    Locked(LockError),
    /// The server has not started, or has stopped.
    NotRunning,
    /// The server did not become ready, or did not answer, in time.
    Timeout,
    /// The user to enroll does not exist.
    UnknownUser(String),
    /// The server failed while starting or answering.
    Failed(String),
}

impl std::fmt::Display for EmbedError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AlreadyRunning => formatter.write_str("A library server is already running in this app. Stop it before starting another."),
            Self::Config(message) | Self::Failed(message) => formatter.write_str(message),
            Self::Locked(error) => write!(formatter, "{error}"),
            Self::NotRunning => formatter.write_str("The library server is not running. Start it, then try again."),
            Self::Timeout => formatter.write_str("The library server did not answer in time. Try again in a moment; if it repeats, stop and start sharing again."),
            Self::UnknownUser(name) => write!(formatter, "There is no user called '{name}' on this server. Enroll the owner instead."),
        }
    }
}

impl std::error::Error for EmbedError {}

/// A one-time code that enrolls one device, with the link and address to give it.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Enrollment {
    /// The `flaccy://server` link a device opens.
    pub link: String,
    /// The code, shown once.
    pub code: String,
    /// The address the device connects to.
    pub url: String,
    /// The user the device will belong to.
    pub user: String,
    /// When the code stops working, RFC 3339.
    pub expires_at: String,
}

enum Phase {
    Starting,
    Running(Online),
    Failed(String),
    Stopped,
}

struct SlotClaim;

impl SlotClaim {
    fn take() -> Option<Self> {
        PROCESS_SLOT.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire).ok().map(|_| Self)
    }
}

impl Drop for SlotClaim {
    fn drop(&mut self) {
        PROCESS_SLOT.store(false, Ordering::Release);
    }
}

struct Inner {
    config: EmbedConfig,
    phase: Mutex<Phase>,
    changed: Condvar,
    stop: StopSignal,
    runtime: RuntimeHandle,
    thread: Mutex<Option<JoinHandle<()>>>,
}

impl Inner {
    fn phase(&self) -> MutexGuard<'_, Phase> {
        self.phase.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn set_phase(&self, next: Phase) {
        *self.phase() = next;
        self.changed.notify_all();
    }

    fn finish(&self, outcome: Result<(), String>) {
        let mut phase = self.phase();
        *phase = match (outcome, &*phase) {
            (Err(message), _) => Phase::Failed(message),
            (Ok(()), Phase::Failed(message)) => Phase::Failed(message.clone()),
            (Ok(()), _) => Phase::Stopped,
        };
        drop(phase);
        self.changed.notify_all();
    }

    fn online(&self) -> Result<Online, EmbedError> {
        match &*self.phase() {
            Phase::Running(online) => Ok(Online { state: online.state.clone(), addresses: online.addresses.clone() }),
            Phase::Starting => Err(EmbedError::Timeout),
            Phase::Failed(message) => Err(EmbedError::Failed(message.clone())),
            Phase::Stopped => Err(EmbedError::NotRunning),
        }
    }
}

/// Starts embedded servers.
pub struct EmbeddedServer;

impl EmbeddedServer {
    /// Checks the configuration, takes the data-folder lock and starts the server on its own threads.
    /// Returns without waiting for the databases or the listener: [`Handle::wait_until_running`] waits for those,
    /// and a failure there shows in [`Handle::status_json`].
    pub fn start(config: EmbedConfig) -> Result<Handle, EmbedError> {
        let claim = SlotClaim::take().ok_or(EmbedError::AlreadyRunning)?;
        check(&config)?;
        let lock = DataDirLock::acquire(&config.data_dir).map_err(EmbedError::Locked)?;
        logger::init(&config.log_dir);
        logger::silence_console();
        let runtime = build_runtime()?;
        let inner = Arc::new(Inner {
            config: config.clone(),
            phase: Mutex::new(Phase::Starting),
            changed: Condvar::new(),
            stop: StopSignal::new(),
            runtime: runtime.handle().clone(),
            thread: Mutex::new(None),
        });
        let worker = Arc::clone(&inner);
        let thread = std::thread::Builder::new()
            .name("flaccy-server".into())
            .spawn(move || host(runtime, worker, config, lock, claim))
            .map_err(|error| EmbedError::Failed(format!("Could not start the server thread: {error}. Quit other apps to free memory, then try again.")))?;
        *inner.thread.lock().unwrap_or_else(PoisonError::into_inner) = Some(thread);
        Ok(Handle { inner })
    }
}

fn check(config: &EmbedConfig) -> Result<(), EmbedError> {
    if !config.music_folder.is_dir() {
        return Err(EmbedError::Config(format!(
            "The music folder {} is not a folder this app can open. Choose the folder again.",
            config.music_folder.display()
        )));
    }
    Ok(())
}

fn build_runtime() -> Result<Runtime, EmbedError> {
    Builder::new_multi_thread()
        .worker_threads(WORKER_THREADS)
        .thread_name("flaccy-server-worker")
        .enable_all()
        .build()
        .map_err(|error| EmbedError::Failed(format!("Could not start the server runtime: {error}. Quit other apps to free memory, then try again.")))
}

fn server_config(config: &EmbedConfig) -> Config {
    Config {
        music_folder: config.music_folder.clone(),
        address: "127.0.0.1".to_owned(),
        port: config.port,
        data_dir: Some(config.data_dir.clone()),
        behind_proxy: false,
        mode: Mode::Easy,
        hosts: Vec::new(),
        lastfm: Default::default(),
        backup_dir: None,
    }
}

/// Runs the server on the thread it was given until it stops, then releases everything it held.
fn host(runtime: Runtime, inner: Arc<Inner>, config: EmbedConfig, lock: DataDirLock, claim: SlotClaim) {
    let settings = Settings {
        open: OpenOptions { ffmpeg: config.ffmpeg.clone(), name: Some(config.name.clone()).filter(|name| !name.is_empty()) },
        warn_without_account: false,
        port_advice: "choose another port, or quit the program using it; if the port is free, this app may not be allowed to accept connections.",
    };
    let guard = PanicGuard(&inner);
    let outcome = runtime.block_on(serve(&inner, server_config(&config), settings));
    inner.finish(outcome);
    runtime.shutdown_timeout(RUNTIME_LINGER);
    drop(lock);
    drop(claim);
    guard.disarm();
}

async fn serve(inner: &Arc<Inner>, config: Config, settings: Settings) -> Result<(), String> {
    let (online, ready) = oneshot::channel();
    let announcer = {
        let inner = Arc::clone(inner);
        tokio::spawn(async move {
            if let Ok(online) = ready.await {
                inner.set_phase(Phase::Running(online));
            }
        })
    };
    let outcome = hosting::run(config, settings, inner.stop.clone(), Some(online)).await;
    announcer.abort();
    outcome
}

/// Marks the server failed when its thread unwinds, so waiters are not left on a server that is gone.
struct PanicGuard<'a>(&'a Arc<Inner>);

impl PanicGuard<'_> {
    fn disarm(self) {
        std::mem::forget(self);
    }
}

impl Drop for PanicGuard<'_> {
    fn drop(&mut self) {
        self.0.set_phase(Phase::Failed("The library server stopped unexpectedly. Stop sharing and start it again.".to_owned()));
    }
}

/// A running embedded server. Dropping it asks the server to stop without waiting; [`Handle::stop`] waits.
pub struct Handle {
    inner: Arc<Inner>,
}

impl Drop for Handle {
    fn drop(&mut self) {
        self.inner.stop.raise();
    }
}

impl Handle {
    /// Waits until the server accepts connections, or fails if it cannot.
    pub fn wait_until_running(&self, timeout: Duration) -> Result<(), EmbedError> {
        let mut phase = self.inner.phase();
        let deadline = std::time::Instant::now() + timeout;
        while matches!(&*phase, Phase::Starting) {
            let left = deadline.checked_duration_since(std::time::Instant::now()).ok_or(EmbedError::Timeout)?;
            phase = self.inner.changed.wait_timeout(phase, left).unwrap_or_else(PoisonError::into_inner).0;
        }
        match &*phase {
            Phase::Running(_) => Ok(()),
            Phase::Failed(message) => Err(EmbedError::Failed(message.clone())),
            _ => Err(EmbedError::NotRunning),
        }
    }

    /// True from the start until the server has stopped or failed, including while it is still starting.
    pub fn is_active(&self) -> bool {
        matches!(&*self.inner.phase(), Phase::Starting | Phase::Running(_))
    }

    /// True while the server accepts connections.
    pub fn is_running(&self) -> bool {
        matches!(&*self.inner.phase(), Phase::Running(_))
    }

    /// Every address with its port the server listens on; empty until it runs.
    pub fn bound_addresses(&self) -> Vec<std::net::SocketAddr> {
        match &*self.inner.phase() {
            Phase::Running(online) => online.addresses.bound(),
            _ => Vec::new(),
        }
    }

    /// Stops accepting, gives open requests ten seconds, empties the databases' logs and waits for the server threads.
    /// Calling it again, or on a server that failed, is harmless.
    pub fn stop(&self) -> Result<(), EmbedError> {
        self.inner.stop.raise();
        let thread = self.inner.thread.lock().unwrap_or_else(PoisonError::into_inner).take();
        match thread {
            Some(thread) => thread.join().map_err(|_| EmbedError::Failed("The library server stopped unexpectedly.".to_owned())),
            None => Ok(()),
        }
    }

    /// The state as JSON: `state` (starting, running, stopped or error), `addresses`, `urls`, `deviceCount`,
    /// `songCount`, `lastError`, `name`, `musicFolder`, `dataFolder` and `version`.
    pub fn status_json(&self) -> String {
        let (state, last_error, online) = match &*self.inner.phase() {
            Phase::Starting => ("starting", None, None),
            Phase::Running(online) => ("running", None, Some(Online { state: online.state.clone(), addresses: online.addresses.clone() })),
            Phase::Failed(message) => ("error", Some(message.clone()), None),
            Phase::Stopped => ("stopped", None, None),
        };
        let devices = online.as_ref().and_then(|online| self.run(device_count(online.state.0.security.clone())).ok()).and_then(Result::ok);
        let value = json!({
            "state": state,
            "addresses": online.as_ref().map(|online| online.addresses.bound().iter().map(ToString::to_string).collect::<Vec<_>>()).unwrap_or_default(),
            "urls": online.as_ref().map(|online| online.addresses.urls()).unwrap_or_default(),
            "deviceCount": devices,
            "songCount": online.as_ref().map(|online| online.state.catalog().song_count()),
            "lastError": last_error,
            "name": self.inner.config.name,
            "musicFolder": self.inner.config.music_folder.display().to_string(),
            "dataFolder": self.inner.config.data_dir.display().to_string(),
            "version": crate::VERSION,
        });
        value.to_string()
    }

    /// Makes a ten-minute code that enrolls one device for `user` (the owner when `None`), with its link and address.
    /// The first user made is an admin; asking for any other missing user fails.
    pub fn create_enrollment(&self, user: Option<&str>) -> Result<Enrollment, EmbedError> {
        self.wait_until_running(STARTUP_WAIT)?;
        let online = self.inner.online()?;
        let name = user.map(str::trim).filter(|name| !name.is_empty()).unwrap_or(OWNER).to_owned();
        let url = online.addresses.urls().into_iter().next().ok_or(EmbedError::NotRunning)?;
        let state = online.state.clone();
        let (user, code) = self.run(issue_code(state.0.security.clone(), name))??;
        let expires_at = (Utc::now() + chrono::Duration::from_std(ENROLLMENT_TTL).unwrap_or_default()).to_rfc3339_opts(SecondsFormat::Secs, true);
        Ok(Enrollment { link: enrollment_link(&url, &code, state.server_name()), code, url, user: user.name, expires_at })
    }

    /// Runs `future` on the server's runtime and waits for it, from any thread.
    fn run<F, T>(&self, future: F) -> Result<T, EmbedError>
    where
        F: Future<Output = T> + Send + 'static,
        T: Send + 'static,
    {
        let (sender, receiver) = mpsc::channel();
        self.inner.runtime.spawn(async move {
            let _ = sender.send(future.await);
        });
        receiver.recv_timeout(CALL_WAIT).map_err(|error| match error {
            RecvTimeoutError::Timeout => EmbedError::Timeout,
            RecvTimeoutError::Disconnected => EmbedError::NotRunning,
        })
    }
}

async fn device_count(security: Store) -> Result<usize, EmbedError> {
    let devices = security.list_devices(None).await.map_err(|error| EmbedError::Failed(error.to_string()))?;
    Ok(devices.iter().filter(|device| device.revoked_at.is_none()).count())
}

async fn issue_code(security: Store, name: String) -> Result<(User, String), EmbedError> {
    let failed = |error: crate::security::SecurityError| EmbedError::Failed(error.to_string());
    let user = match security.find_user_by_name(&name).await.map_err(failed)? {
        Some(user) => user,
        None if security.list_users().await.map_err(failed)?.is_empty() => security.create_user(&name, Role::Admin).await.map_err(failed)?,
        None => return Err(EmbedError::UnknownUser(name)),
    };
    let code = security.create_enrollment(&user.id, ENROLLMENT_TTL).await.map_err(failed)?;
    Ok((user, code))
}
