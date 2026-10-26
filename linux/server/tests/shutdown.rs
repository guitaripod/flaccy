//! A stop request on a real `flaccy-server serve` process: open sockets close, the request in flight finishes, the databases close.

#![cfg(unix)]

mod common;

use std::net::SocketAddr;
use std::os::unix::process::CommandExt as _;
use std::time::Duration;

use common::http::send;
use common::TempDir;
use futures_util::StreamExt;
use serde_json::{json, Value};
use tokio::process::{Child, Command};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::Message;

const BINARY: &str = env!("CARGO_BIN_EXE_flaccy-server");
const PATIENT: Duration = Duration::from_secs(20);
const INSERTS: i64 = 499;

struct Running {
    dir: TempDir,
    child: Child,
    address: SocketAddr,
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

fn unblock_signals(command: &mut Command) {
    let unblock = || {
        let mut set: libc::sigset_t = unsafe { std::mem::zeroed() };
        unsafe {
            libc::sigemptyset(&mut set);
            libc::sigprocmask(libc::SIG_SETMASK, &set, std::ptr::null_mut());
        }
        Ok(())
    };
    unsafe {
        command.as_std_mut().pre_exec(unblock);
    }
}

impl Running {
    async fn start() -> Self {
        let dir = TempDir::new("shutdown");
        std::fs::create_dir_all(dir.file("music")).unwrap();
        let port = free_port();
        let text = format!("music_folder = \"{}\"\ndata_dir = \"{}\"\nport = {port}\n", dir.file("music").display(), dir.file("data").display());
        std::fs::write(dir.file("config.toml"), text).unwrap();
        let mut command = Command::new(BINARY);
        command.arg("--config").arg(dir.file("config.toml")).arg("serve").kill_on_drop(true);
        unblock_signals(&mut command);
        let child = command.spawn().unwrap();
        let address = SocketAddr::from(([127, 0, 0, 1], port));
        let running = Self { dir, child, address };
        running.wait_until_serving().await;
        running
    }

    async fn wait_until_serving(&self) {
        let deadline = tokio::time::Instant::now() + PATIENT;
        loop {
            let ready = tokio::time::timeout(Duration::from_secs(2), async {
                match tokio::net::TcpStream::connect(self.address).await {
                    Ok(_) => send(self.address, "GET", "/flaccy/v1/hello", &[], &[]).await.status == 200,
                    Err(_) => false,
                }
            })
            .await;
            if ready == Ok(true) {
                return;
            }
            assert!(tokio::time::Instant::now() < deadline, "the server never answered");
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
    }

    async fn enroll(&self) -> (String, String) {
        let output = Command::new(BINARY)
            .arg("--config")
            .arg(self.dir.file("config.toml"))
            .args(["enroll", "--user", "alice", "--json"])
            .output()
            .await
            .unwrap();
        let made: Value = serde_json::from_slice(&output.stdout).unwrap();
        let body = json!({ "enroll": made["code"], "name": "Laptop", "platform": "linux", "instance": "i1" }).to_string();
        let reply = send(self.address, "POST", "/flaccy/v1/devices", &[("Content-Type", "application/json")], body.as_bytes()).await;
        assert_eq!(reply.status, 201);
        let device = reply.json();
        (device["device"].as_str().unwrap().to_owned(), device["token"].as_str().unwrap().to_owned())
    }

    fn signal(&self, signal: i32) {
        let pid = self.child.id().unwrap() as i32;
        assert_eq!(unsafe { libc::kill(pid, signal) }, 0);
    }

    async fn exit_status(&mut self) -> std::process::ExitStatus {
        tokio::time::timeout(PATIENT, self.child.wait()).await.expect("the server did not exit").unwrap()
    }

    fn log(&self) -> String {
        std::fs::read_to_string(self.dir.file("data/flaccy.log")).unwrap_or_default()
    }
}

fn big_push(device: &str) -> String {
    let mut mutations = vec![json!({ "id": 1, "name": "playlist.create", "stamp": common::BASE_TIME_MS << 16, "args": { "id": "mix", "name": "Mix" } })];
    for index in 0..INSERTS {
        let id = index + 2;
        let args = json!({ "id": format!("e{index}"), "playlist": "mix", "ref": common::song(index as usize), "place": { "kind": "last" } });
        mutations.push(json!({ "id": id, "name": "entry.insert", "stamp": (common::BASE_TIME_MS << 16) + id, "args": args }));
    }
    json!({ "device": device, "instance": "i1", "mutations": mutations }).to_string()
}

#[tokio::test(flavor = "multi_thread")]
async fn sigterm_closes_sockets_finishes_the_request_in_flight_and_closes_the_databases() {
    let mut server = Running::start().await;
    let (device, token) = server.enroll().await;
    let mut request = format!("ws://{}/flaccy/v1/live", server.address).into_client_request().unwrap();
    request.headers_mut().insert("Authorization", format!("Bearer {token}").parse().unwrap());
    let (mut socket, _) = tokio_tungstenite::connect_async(request).await.unwrap();

    let address = server.address;
    let bearer = format!("Bearer {token}");
    let body = big_push(&device);
    let push = tokio::spawn(async move {
        send(address, "POST", "/flaccy/v1/sync/push", &[("Content-Type", "application/json"), ("Authorization", &bearer)], body.as_bytes()).await
    });
    tokio::time::sleep(Duration::from_millis(150)).await;
    server.signal(libc::SIGTERM);

    let closing = tokio::time::timeout(PATIENT, async {
        loop {
            match socket.next().await {
                Some(Ok(Message::Close(frame))) => return frame.map(|frame| frame.code),
                Some(Ok(_)) => continue,
                _ => return None,
            }
        }
    })
    .await
    .expect("the socket was left open");
    assert_eq!(closing, Some(CloseCode::Away));

    let reply = push.await.unwrap();
    assert_eq!(reply.status, 200, "{}", String::from_utf8_lossy(&reply.body));
    assert_eq!(reply.json()["results"].as_array().unwrap().len() as i64, INSERTS + 1);
    assert!(server.exit_status().await.success());

    let log = server.log();
    assert!(log.contains("stop requested") && log.contains("databases closed"), "{log}");
    let state = rusqlite::Connection::open(server.dir.file("data/state.sqlite")).unwrap();
    let verdict: String = state.query_row("PRAGMA integrity_check", [], |row| row.get(0)).unwrap();
    let entries: i64 = state.query_row("SELECT COUNT(*) FROM playlist_entries", [], |row| row.get(0)).unwrap();
    assert_eq!((verdict.as_str(), entries), ("ok", INSERTS));
}

#[tokio::test(flavor = "multi_thread")]
async fn sigint_stops_an_idle_server_cleanly() {
    let mut server = Running::start().await;
    server.signal(libc::SIGINT);
    assert!(server.exit_status().await.success());
    assert!(server.log().contains("databases closed"));
}
