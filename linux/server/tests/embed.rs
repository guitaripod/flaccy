//! The embedded server: start, enroll over real HTTP, push, stop gracefully, start again.

mod common;

use std::net::SocketAddr;
use std::sync::Mutex;
use std::time::Duration;

use common::http::{send, Reply};
use common::TempDir;
use flaccy_server::embed::{EmbedConfig, EmbedError, EmbeddedServer, Handle};
use flaccy_server::lock::DataDirLock;
use serde_json::{json, Value};
use tokio::runtime::Runtime;

const READY_WITHIN: Duration = Duration::from_secs(30);

static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

fn config_in(dir: &TempDir, name: &str) -> EmbedConfig {
    std::fs::create_dir_all(dir.file("music")).unwrap();
    EmbedConfig {
        music_folder: dir.file("music"),
        data_dir: dir.file("data"),
        name: name.to_owned(),
        port: 0,
        ffmpeg: None,
        log_dir: dir.file("logs"),
    }
}

fn loopback(handle: &Handle) -> SocketAddr {
    handle.bound_addresses().into_iter().find(|address| address.ip().is_loopback() && address.is_ipv4()).unwrap()
}

fn call(runtime: &Runtime, address: SocketAddr, method: &str, path: &str, token: Option<&str>, body: &Value) -> Reply {
    let bearer = token.map(|token| format!("Bearer {token}"));
    let mut headers = vec![("Content-Type", "application/json")];
    if let Some(bearer) = bearer.as_deref() {
        headers.push(("Authorization", bearer));
    }
    runtime.block_on(send(address, method, path, &headers, body.to_string().as_bytes()))
}

fn enroll_device(runtime: &Runtime, handle: &Handle, address: SocketAddr) -> (String, String) {
    let enrollment = handle.create_enrollment(None).unwrap();
    assert!(enrollment.link.starts_with("flaccy://server?url="), "{}", enrollment.link);
    assert_eq!(enrollment.user, "owner");
    let body = json!({ "enroll": enrollment.code, "name": "Test phone", "platform": "ios", "instance": "embed-instance" });
    let reply = call(runtime, address, "POST", "/flaccy/v1/devices", None, &body);
    assert_eq!(reply.status, 201, "{}", String::from_utf8_lossy(&reply.body));
    let device = reply.json();
    (device["device"].as_str().unwrap().to_owned(), device["token"].as_str().unwrap().to_owned())
}

fn push_love(runtime: &Runtime, address: SocketAddr, device: &str, token: &str) {
    let song = common::song(0);
    let mutation = json!({
        "id": 1, "name": "love.set", "stamp": (common::BASE_TIME_MS << 16) + 1,
        "args": { "songKey": song["songKey"], "ref": song, "loved": true }
    });
    let body = json!({ "device": device, "instance": "embed-instance", "mutations": [mutation] });
    let reply = call(runtime, address, "POST", "/flaccy/v1/sync/push", Some(token), &body);
    assert_eq!(reply.status, 200, "{}", String::from_utf8_lossy(&reply.body));
    assert_eq!(reply.json()["results"][0]["status"], "applied");
}

fn pulled_kinds(runtime: &Runtime, address: SocketAddr, token: &str) -> Vec<String> {
    let reply = call(runtime, address, "GET", "/flaccy/v1/sync/pull?since=0&instance=embed-instance", Some(token), &json!(null));
    assert_eq!(reply.status, 200, "{}", String::from_utf8_lossy(&reply.body));
    reply.json()["changes"].as_array().unwrap().iter().map(|change| change["kind"].as_str().unwrap().to_owned()).collect()
}

fn leftover_log_bytes(dir: &TempDir) -> u64 {
    ["state.sqlite-wal", "security.sqlite-wal", "library.sqlite-wal"]
        .iter()
        .filter_map(|name| std::fs::metadata(dir.file("data").join(name)).ok())
        .map(|metadata| metadata.len())
        .sum()
}

#[test]
fn a_server_starts_enrolls_syncs_and_stops_twice_in_one_process() {
    let _serial = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let runtime = Runtime::new().unwrap();
    let dir = TempDir::new("embed");

    let first = EmbeddedServer::start(config_in(&dir, "Test Mac")).unwrap();
    first.wait_until_running(READY_WITHIN).unwrap();
    assert!(first.is_running());
    let address = loopback(&first);
    let hello = call(&runtime, address, "GET", "/flaccy/v1/hello", None, &json!(null));
    assert_eq!(hello.json()["server"]["name"], "Test Mac");
    let (device, token) = enroll_device(&runtime, &first, address);
    push_love(&runtime, address, &device, &token);
    assert_eq!(pulled_kinds(&runtime, address, &token), ["love"]);
    let status: Value = serde_json::from_str(&first.status_json()).unwrap();
    assert_eq!(status["state"], "running");
    assert_eq!(status["deviceCount"], 1);
    assert!(status["lastError"].is_null());
    first.stop().unwrap();
    assert!(!first.is_running());
    assert_eq!(leftover_log_bytes(&dir), 0, "stopping empties the write-ahead logs");
    assert_eq!(serde_json::from_str::<Value>(&first.status_json()).unwrap()["state"], "stopped");
    first.stop().unwrap();
    drop(first);

    let second = EmbeddedServer::start(config_in(&dir, "Test Mac")).unwrap();
    second.wait_until_running(READY_WITHIN).unwrap();
    let address = loopback(&second);
    assert_eq!(pulled_kinds(&runtime, address, &token), ["love"], "the device and its data survive a restart");
    second.stop().unwrap();
}

#[test]
fn a_second_server_in_the_process_and_a_held_data_folder_are_refused() {
    let _serial = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let dir = TempDir::new("embed-refused");
    let other = TempDir::new("embed-other");
    let running = EmbeddedServer::start(config_in(&dir, "")).unwrap();
    let refused = EmbeddedServer::start(config_in(&other, "")).err().unwrap();
    assert!(matches!(refused, EmbedError::AlreadyRunning), "{refused}");
    running.stop().unwrap();

    let _held = DataDirLock::acquire(&dir.file("data")).unwrap();
    let locked = EmbeddedServer::start(config_in(&dir, "")).err().unwrap();
    assert!(matches!(locked, EmbedError::Locked(_)), "{locked}");
    assert!(locked.to_string().contains("already using"), "{locked}");
}

#[test]
fn a_missing_music_folder_and_a_busy_port_are_reported_not_hidden() {
    let _serial = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let dir = TempDir::new("embed-errors");
    let mut config = config_in(&dir, "");
    config.music_folder = dir.file("missing");
    let error = EmbeddedServer::start(config).err().unwrap();
    assert!(matches!(error, EmbedError::Config(_)) && error.to_string().contains("Choose the folder again"), "{error}");

    let taken = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let mut config = config_in(&dir, "");
    config.port = taken.local_addr().unwrap().port();
    let handle = EmbeddedServer::start(config).unwrap();
    let failure = handle.wait_until_running(READY_WITHIN).err().unwrap();
    assert!(failure.to_string().contains("Could not listen on port"), "{failure}");
    let status: Value = serde_json::from_str(&handle.status_json()).unwrap();
    assert_eq!(status["state"], "error");
    assert!(status["lastError"].as_str().unwrap().contains("port"));
    handle.stop().unwrap();
    let again = EmbeddedServer::start(config_in(&dir, "")).expect("a failed start frees the process slot and the folder");
    again.wait_until_running(READY_WITHIN).unwrap();
    again.stop().unwrap();
}
