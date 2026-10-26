#![allow(dead_code)]

use std::io::{Read, Write};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::process::{Child, Command, ExitStatus, Output, Stdio};
use std::time::{Duration, Instant};

use serde_json::{json, Value};

use super::http::{send, Device, Reply};
use super::{TempDir, BASE_TIME_MS};

const READY_TIMEOUT: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(25);

/// A config file and data folder inside a temp dir, and the loopback port a server of it listens on.
pub struct Layout {
    pub config: PathBuf,
    pub data: PathBuf,
    pub address: SocketAddr,
}

impl Layout {
    pub fn new(dir: &TempDir) -> Self {
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let music = dir.file("music");
        std::fs::create_dir_all(&music).unwrap();
        let config = dir.file("config.toml");
        let data = dir.file("data");
        let text = format!("music_folder = \"{}\"\ndata_dir = \"{}\"\nport = {port}\n", music.display(), data.display());
        std::fs::write(&config, text).unwrap();
        Self { config, data, address: SocketAddr::from(([127, 0, 0, 1], port)) }
    }

    pub fn cli(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_flaccy-server"))
            .arg("--config")
            .arg(&self.config)
            .args(args)
            .output()
            .unwrap()
    }

    pub fn cli_ok(&self, args: &[&str]) -> String {
        let output = self.cli(args);
        assert!(output.status.success(), "{args:?} failed: {}", String::from_utf8_lossy(&output.stderr));
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    pub fn state_file(&self) -> PathBuf {
        self.data.join("state.sqlite")
    }

    pub fn start(&self) -> ChildServer {
        let mut command = Command::new(env!("CARGO_BIN_EXE_flaccy-server"));
        command
            .arg("--config")
            .arg(&self.config)
            .arg("serve")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unblock_all_signals(&mut command);
        let child = command.spawn().unwrap();
        let mut server = ChildServer { child: Some(child), address: self.address };
        server.wait_until_ready();
        server
    }

    pub async fn enroll(&self, server: &ChildServer, user: &str, instance: &str) -> Device {
        let made: Value = serde_json::from_str(&self.cli_ok(&["enroll", "--user", user, "--json"])).unwrap();
        let body = json!({ "enroll": made["code"], "name": format!("{user} {instance}"), "platform": "linux", "instance": instance });
        let reply = send(server.address, "POST", "/flaccy/v1/devices", &[("Content-Type", "application/json")], body.to_string().as_bytes()).await;
        assert_eq!(reply.status, 201, "{}", String::from_utf8_lossy(&reply.body));
        let body = reply.json();
        Device {
            id: body["device"].as_str().unwrap().to_owned(),
            token: body["token"].as_str().unwrap().to_owned(),
            user: body["user"]["id"].as_str().unwrap_or_default().to_owned(),
            instance: instance.to_owned(),
        }
    }
}

/// Gives the child an empty signal mask, because a test runner started from a sandboxed shell can pass on a mask that blocks SIGTERM and SIGINT for good.
fn unblock_all_signals(command: &mut Command) {
    use std::os::unix::process::CommandExt;
    unsafe {
        command.pre_exec(|| {
            let mut empty = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
            libc::sigemptyset(empty.as_mut_ptr());
            libc::sigprocmask(libc::SIG_SETMASK, empty.as_ptr(), std::ptr::null_mut());
            Ok(())
        });
    }
}

/// A `flaccy-server serve` child process. Dropping it kills that process by pid.
pub struct ChildServer {
    child: Option<Child>,
    pub address: SocketAddr,
}

impl ChildServer {
    pub fn pid(&self) -> u32 {
        self.child.as_ref().map(Child::id).unwrap()
    }

    fn wait_until_ready(&mut self) {
        let started = Instant::now();
        loop {
            if let Some(status) = self.child.as_mut().unwrap().try_wait().unwrap() {
                panic!("the server exited while starting: {status}");
            }
            if self.answers_hello() {
                return;
            }
            assert!(started.elapsed() < READY_TIMEOUT, "the server did not come up");
            std::thread::sleep(POLL);
        }
    }

    fn answers_hello(&self) -> bool {
        let Ok(mut stream) = std::net::TcpStream::connect_timeout(&self.address, Duration::from_millis(200)) else {
            return false;
        };
        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
        let request = format!("GET /flaccy/v1/hello HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n", self.address);
        let mut reply = String::new();
        stream.write_all(request.as_bytes()).is_ok() && stream.read_to_string(&mut reply).is_ok() && reply.starts_with("HTTP/1.1 200")
    }

    pub fn signal(&self, name: &str) -> bool {
        Command::new("kill").arg(format!("-{name}")).arg(self.pid().to_string()).status().map(|status| status.success()).unwrap_or(false)
    }

    pub fn wait_exit(&mut self, timeout: Duration) -> Option<ExitStatus> {
        let started = Instant::now();
        while started.elapsed() < timeout {
            if let Some(status) = self.child.as_mut().unwrap().try_wait().unwrap() {
                return Some(status);
            }
            std::thread::sleep(POLL);
        }
        None
    }

    pub async fn push(&self, device: &Device, first_id: i64, mutations: Vec<(&str, Value)>) -> Reply {
        push_to(self.address, device, first_id, mutations).await
    }

    pub async fn post(&self, token: &str, path: &str, extra: &[(&str, &str)], body: &Value) -> Reply {
        let bearer = format!("Bearer {token}");
        let mut headers = vec![("Content-Type", "application/json"), ("Authorization", bearer.as_str())];
        headers.extend_from_slice(extra);
        send(self.address, "POST", path, &headers, body.to_string().as_bytes()).await
    }

    pub async fn pull(&self, device: &Device, since: i64, extra: &[(&str, &str)]) -> Reply {
        let bearer = format!("Bearer {}", device.token);
        let mut headers = vec![("Authorization", bearer.as_str())];
        headers.extend_from_slice(extra);
        send(self.address, "GET", &format!("/flaccy/v1/sync/pull?since={since}&instance={}", device.instance), &headers, &[]).await
    }
}

pub async fn push_to(address: SocketAddr, device: &Device, first_id: i64, mutations: Vec<(&str, Value)>) -> Reply {
    let list: Vec<Value> = mutations
        .into_iter()
        .enumerate()
        .map(|(offset, (name, args))| {
            let id = first_id + offset as i64;
            json!({ "id": id, "name": name, "stamp": (BASE_TIME_MS << 16) + id, "args": args })
        })
        .collect();
    let body = json!({ "device": device.id, "instance": device.instance, "mutations": list });
    let bearer = format!("Bearer {}", device.token);
    let headers = [("Content-Type", "application/json"), ("Authorization", bearer.as_str())];
    send(address, "POST", "/flaccy/v1/sync/push", &headers, body.to_string().as_bytes()).await
}

impl Drop for ChildServer {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
    }
}
