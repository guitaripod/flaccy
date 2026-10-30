use crate::sync_util::locked;
use flaccy_library::server_sync::Transport;
use serde_json::Value;
use std::fs::OpenOptions;
use std::net::{SocketAddr, TcpListener};
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const READY_LIMIT: Duration = Duration::from_secs(60);
const TERM_LIMIT: Duration = Duration::from_secs(40);
#[cfg(target_os = "linux")]
const ADDRESS: &str = "127.0.0.2";
#[cfg(not(target_os = "linux"))]
const ADDRESS: &str = "127.0.0.1";

/// How a SIGTERM ended.
#[derive(Debug)]
pub enum TermOutcome {
    /// The server exited with status 0.
    Clean,
    /// The server exited another way, or had to be killed; the text says how.
    Unclean(String),
}

struct Inner {
    child: Option<Child>,
    expected_stop: bool,
}

/// The real `flaccy-server` binary running as a child process on a throwaway data directory.
pub struct Server {
    binary: PathBuf,
    config: PathBuf,
    log: PathBuf,
    data_dir: PathBuf,
    address: SocketAddr,
    inner: Mutex<Inner>,
}

impl Server {
    /// Writes the configuration under `root`; nothing runs until [`Server::start`].
    pub fn prepare(binary: &Path, root: &Path, music: &Path) -> Result<Server, String> {
        let port = free_port()?;
        let data_dir = root.join("server-data");
        std::fs::create_dir_all(&data_dir).map_err(|error| format!("cannot create {}: {error}", data_dir.display()))?;
        let config = root.join("server-config.toml");
        let text = format!(
            "music_folder = \"{}\"\ndata_dir = \"{}\"\naddress = \"{ADDRESS}\"\nport = {port}\nhosts = [\"{ADDRESS}\", \"127.0.0.1\"]\n",
            music.display(),
            data_dir.display()
        );
        std::fs::write(&config, text).map_err(|error| format!("cannot write {}: {error}", config.display()))?;
        let address = SocketAddr::new(ADDRESS.parse().map_err(|_| "bad address".to_owned())?, port);
        Ok(Server {
            binary: binary.to_path_buf(),
            config,
            log: root.join("server.log"),
            data_dir,
            address,
            inner: Mutex::new(Inner { child: None, expected_stop: false }),
        })
    }

    /// Where the server listens.
    pub fn address(&self) -> SocketAddr {
        self.address
    }

    /// The server's base URL.
    pub fn url(&self) -> String {
        format!("http://{}", self.address)
    }

    /// The sync state database.
    pub fn state_db(&self) -> PathBuf {
        self.data_dir.join("state.sqlite")
    }

    /// The running process id, if any.
    pub fn pid(&self) -> Option<u32> {
        locked(&self.inner).child.as_ref().map(Child::id)
    }

    /// Starts the process and waits until `GET /hello` answers.
    pub fn start(&self) -> Result<(), String> {
        let log = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log)
            .map_err(|error| format!("cannot open {}: {error}", self.log.display()))?;
        let errors = log.try_clone().map_err(|error| format!("cannot share the log: {error}"))?;
        let child = Command::new(&self.binary)
            .arg("--config")
            .arg(&self.config)
            .arg("serve")
            .stdin(Stdio::null())
            .stdout(Stdio::from(log))
            .stderr(Stdio::from(errors))
            .spawn()
            .map_err(|error| format!("cannot start {}: {error}", self.binary.display()))?;
        {
            let mut inner = locked(&self.inner);
            inner.child = Some(child);
            inner.expected_stop = false;
        }
        self.wait_ready()
    }

    /// SIGKILLs the process and reaps it. Returns false when nothing was running.
    pub fn kill(&self) -> bool {
        let mut inner = locked(&self.inner);
        inner.expected_stop = true;
        let Some(mut child) = inner.child.take() else {
            return false;
        };
        let _ = child.kill();
        let _ = child.wait();
        true
    }

    /// SIGTERMs the process and waits for it to exit by itself.
    pub fn terminate(&self) -> Option<TermOutcome> {
        let mut child = {
            let mut inner = locked(&self.inner);
            inner.expected_stop = true;
            inner.child.take()?
        };
        let _ = Command::new("kill").arg("-TERM").arg(child.id().to_string()).status();
        let started = Instant::now();
        loop {
            match child.try_wait() {
                Ok(Some(status)) if status.success() => return Some(TermOutcome::Clean),
                Ok(Some(status)) => return Some(TermOutcome::Unclean(describe(status))),
                Ok(None) if started.elapsed() < TERM_LIMIT => std::thread::sleep(Duration::from_millis(100)),
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Some(TermOutcome::Unclean(format!("still running {}s after SIGTERM, killed", TERM_LIMIT.as_secs())));
                }
                Err(error) => return Some(TermOutcome::Unclean(format!("cannot wait for the server: {error}"))),
            }
        }
    }

    /// Reports a process that exited without the controller asking, and forgets it.
    pub fn reap_unexpected(&self) -> Option<String> {
        let mut inner = locked(&self.inner);
        if inner.expected_stop {
            return None;
        }
        let status = inner.child.as_mut()?.try_wait().ok().flatten()?;
        inner.child = None;
        Some(describe(status))
    }

    /// A fresh single-use enrollment code for the soak user, made by the real CLI.
    pub fn enroll_code(&self) -> Result<String, String> {
        let output = Command::new(&self.binary)
            .arg("--config")
            .arg(&self.config)
            .args(["enroll", "--user", "soak", "--json", "--url"])
            .arg(self.url())
            .output()
            .map_err(|error| format!("cannot run the enroll command: {error}"))?;
        if !output.status.success() {
            return Err(format!("enroll failed: {}", String::from_utf8_lossy(&output.stderr)));
        }
        let parsed: Value = serde_json::from_slice(&output.stdout).map_err(|error| format!("enroll printed no JSON: {error}"))?;
        parsed["code"].as_str().map(str::to_owned).ok_or_else(|| "enroll printed no code".to_owned())
    }

    fn wait_ready(&self) -> Result<(), String> {
        let started = Instant::now();
        let transport = Transport::probing(&self.url());
        loop {
            if transport.hello().is_ok() {
                return Ok(());
            }
            if let Some(status) = self.reap_unexpected() {
                return Err(format!("the server exited while starting: {status}"));
            }
            if started.elapsed() > READY_LIMIT {
                return Err(format!("the server did not answer within {}s", READY_LIMIT.as_secs()));
            }
            std::thread::sleep(Duration::from_millis(150));
        }
    }
}

fn describe(status: std::process::ExitStatus) -> String {
    match (status.code(), status.signal()) {
        (Some(code), _) => format!("exit code {code}"),
        (None, Some(signal)) => format!("killed by signal {signal}"),
        _ => "unknown exit".to_owned(),
    }
}

fn free_port() -> Result<u16, String> {
    let listener = TcpListener::bind((ADDRESS, 0)).map_err(|error| format!("no free port on {ADDRESS}: {error}"))?;
    listener.local_addr().map(|address| address.port()).map_err(|error| format!("no port: {error}"))
}
