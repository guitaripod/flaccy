//! The real binary under SIGTERM and SIGKILL: what is on disk afterwards, and what a second server or a restore may do.

mod common;

use std::collections::HashSet;
use std::io::Write;
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rusqlite::Connection;
use serde_json::{json, Value};

use common::child::{push_to, ChildServer, Layout};
use common::http::Device;
use common::{song, TempDir};

const LOAD_TASKS: usize = 4;
const KEYS_PER_TASK: usize = 1_000_000;
const EXIT_WAIT: Duration = Duration::from_secs(20);
const LOOP_ROUNDS: usize = 30;

type Acked = Arc<Mutex<Vec<String>>>;

fn love_args(index: usize) -> Value {
    json!({ "songKey": song(index)["songKey"], "ref": song(index), "loved": true })
}

async fn pump(server: std::net::SocketAddr, device: Device, task: usize, stop: Arc<AtomicBool>, acked: Acked) {
    let mut sent = 0usize;
    while !stop.load(Ordering::Relaxed) {
        let index = task * KEYS_PER_TASK + sent;
        let device_copy = Device { id: device.id.clone(), token: device.token.clone(), user: device.user.clone(), instance: device.instance.clone() };
        let attempt = tokio::spawn(async move { push_to(server, &device_copy, sent as i64 + 1, vec![("love.set", love_args(index))]).await }).await;
        let Ok(reply) = attempt else { return };
        let applied = serde_json::from_slice::<Value>(&reply.body).ok().is_some_and(|body| body["results"][0]["status"] == "applied");
        if reply.status != 200 || !applied {
            return;
        }
        acked.lock().unwrap().push(song(index)["songKey"].as_str().unwrap().to_owned());
        sent += 1;
    }
}

async fn start_load(layout: &Layout, server: &ChildServer) -> (Arc<AtomicBool>, Acked, Vec<tokio::task::JoinHandle<()>>) {
    let stop = Arc::new(AtomicBool::new(false));
    let acked: Acked = Arc::new(Mutex::new(Vec::new()));
    let mut tasks = Vec::new();
    for task in 0..LOAD_TASKS {
        let device = layout.enroll(server, "alice", &format!("load-{task}")).await;
        tasks.push(tokio::spawn(pump(server.address, device, task, stop.clone(), acked.clone())));
    }
    (stop, acked, tasks)
}

async fn wait_for_acks(acked: &Acked, wanted: usize) {
    let started = Instant::now();
    while acked.lock().unwrap().len() < wanted {
        assert!(started.elapsed() < Duration::from_secs(30), "the load never reached {wanted} acknowledged mutations");
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
}

async fn finish_load(stop: Arc<AtomicBool>, tasks: Vec<tokio::task::JoinHandle<()>>) {
    stop.store(true, Ordering::Relaxed);
    for task in tasks {
        let _ = task.await;
    }
}

fn integrity(path: &Path) -> String {
    Connection::open(path).unwrap().query_row("PRAGMA integrity_check", [], |row| row.get(0)).unwrap()
}

fn loved_keys(path: &Path) -> HashSet<String> {
    let connection = Connection::open(path).unwrap();
    let mut statement = connection.prepare("SELECT song_key FROM loves WHERE loved = 1").unwrap();
    statement.query_map([], |row| row.get(0)).unwrap().collect::<Result<_, _>>().unwrap()
}

fn assert_every_acknowledged_mutation_is_there(layout: &Layout, acked: &Acked) -> usize {
    let present = loved_keys(&layout.state_file());
    let acked = acked.lock().unwrap();
    let missing = acked.iter().filter(|key| !present.contains(*key)).count();
    assert_eq!(missing, 0, "{missing} of {} acknowledged mutations are missing after the stop", acked.len());
    acked.len()
}

async fn killed_mid_load(round: usize) -> usize {
    let dir = TempDir::new("kill9");
    let layout = Layout::new(&dir);
    let mut server = layout.start();
    let (stop, acked, tasks) = start_load(&layout, &server).await;
    wait_for_acks(&acked, 10 + (round * 37) % 300).await;
    assert!(server.signal("KILL"), "the sandbox refused to signal the child");
    finish_load(stop, tasks).await;
    let status = server.wait_exit(EXIT_WAIT).expect("the killed server did not exit");
    assert!(!status.success());
    assert_eq!(integrity(&layout.state_file()), "ok");
    assert_eq!(integrity(&layout.data.join("security.sqlite")), "ok");
    assert_every_acknowledged_mutation_is_there(&layout, &acked)
}

#[tokio::test(flavor = "multi_thread")]
async fn sigterm_finishes_open_work_and_leaves_no_write_ahead_log() {
    let dir = TempDir::new("sigterm");
    let layout = Layout::new(&dir);
    let mut server = layout.start();
    let (stop, acked, tasks) = start_load(&layout, &server).await;
    wait_for_acks(&acked, 40).await;
    assert!(server.signal("TERM"), "the sandbox refused to signal the child");
    let status = server.wait_exit(EXIT_WAIT).expect("the server did not exit after SIGTERM");
    finish_load(stop, tasks).await;
    assert!(status.success(), "{status}");
    for name in ["state.sqlite-wal", "state.sqlite-shm", "security.sqlite-wal", "security.sqlite-shm"] {
        assert!(!layout.data.join(name).exists(), "{name} is left behind");
    }
    assert_eq!(integrity(&layout.state_file()), "ok");
    assert_every_acknowledged_mutation_is_there(&layout, &acked);
}

#[tokio::test(flavor = "multi_thread")]
async fn sigint_stops_the_server_the_same_way() {
    let dir = TempDir::new("sigint");
    let layout = Layout::new(&dir);
    let mut server = layout.start();
    let (stop, acked, tasks) = start_load(&layout, &server).await;
    wait_for_acks(&acked, 10).await;
    assert!(server.signal("INT"));
    let status = server.wait_exit(EXIT_WAIT).expect("the server did not exit after SIGINT");
    finish_load(stop, tasks).await;
    assert!(status.success() && !layout.data.join("state.sqlite-wal").exists());
    assert_every_acknowledged_mutation_is_there(&layout, &acked);
}

#[tokio::test(flavor = "multi_thread")]
async fn kill_nine_mid_load_keeps_every_acknowledged_mutation() {
    let acknowledged = killed_mid_load(0).await;
    assert!(acknowledged >= 10);
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "30 rounds of start, load and SIGKILL; run with --ignored --nocapture"]
async fn kill_nine_thirty_times_loses_nothing() {
    let mut total = 0;
    for round in 0..LOOP_ROUNDS {
        total += killed_mid_load(round).await;
    }
    let mut report = std::io::stdout();
    writeln!(report, "{LOOP_ROUNDS} kill -9 rounds passed; {total} acknowledged mutations all present").unwrap();
}

#[test]
fn a_second_server_on_the_same_data_folder_is_refused_with_the_first_ones_pid() {
    let dir = TempDir::new("two-servers");
    let layout = Layout::new(&dir);
    let first = layout.start();
    let second = layout.cli(&["serve"]);
    assert!(!second.status.success());
    let message = String::from_utf8_lossy(&second.stderr).into_owned();
    assert!(message.contains("Another Flaccy Server is already using") && message.contains(&format!("(pid {})", first.pid())), "{message}");
    let refused = layout.cli(&["restore", dir.file("nothing.sqlite").to_str().unwrap()]);
    let text = String::from_utf8_lossy(&refused.stderr).into_owned();
    assert!(!refused.status.success() && text.contains(&format!("pid {}", first.pid())) && text.contains("nothing was restored"), "{text}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_backup_taken_from_a_running_server_restores_into_a_new_incarnation() {
    let dir = TempDir::new("session");
    let layout = Layout::new(&dir);
    let mut server = layout.start();
    let alice = layout.enroll(&server, "alice", "phone").await;
    assert_eq!(server.push(&alice, 1, vec![("love.set", love_args(1)), ("playlist.create", json!({ "id": "mix", "name": "Mix" }))]).await.status, 200);
    let first = server.pull(&alice, 0, &[]).await.json();
    let old_incarnation = first["incarnation"].as_str().unwrap().to_owned();

    let backups = dir.file("backups");
    let printed = layout.cli_ok(&["backup", "--to", backups.to_str().unwrap()]);
    assert!(printed.contains("state-") && printed.contains("security-") && printed.contains("KB"), "{printed}");
    let state_backup = std::fs::read_dir(&backups).unwrap().flatten().map(|entry| entry.path()).find(|path| path.file_name().unwrap().to_string_lossy().starts_with("state-")).unwrap();

    assert_eq!(server.push(&alice, 3, vec![("love.set", love_args(2))]).await.status, 200);
    let status = layout.cli_ok(&["status", "--json"]);
    let report: Value = serde_json::from_str(&status).unwrap();
    assert_eq!(report["backup"]["ok"], true);
    assert!(report["backup"]["lastAt"].as_str().unwrap().ends_with('Z'));

    assert!(server.signal("TERM"));
    assert!(server.wait_exit(EXIT_WAIT).unwrap().success());
    for name in ["state.sqlite", "state.sqlite-wal", "state.sqlite-shm"] {
        let _ = std::fs::remove_file(layout.data.join(name));
    }
    let restored = layout.cli_ok(&["restore", state_backup.to_str().unwrap()]);
    assert!(restored.contains("Your devices will notice and re-send anything newer than this backup."), "{restored}");

    let server = layout.start();
    let stale = [("Flaccy-Incarnation", old_incarnation.as_str())];
    let refused = server.pull(&alice, 0, &stale).await;
    assert_eq!((refused.status, refused.code()), (409, "incarnation_changed".to_owned()));
    let pulled = server.pull(&alice, 0, &[]).await.json();
    assert_ne!(pulled["incarnation"], json!(old_incarnation));
    let ids: Vec<&str> = pulled["changes"].as_array().unwrap().iter().map(|change| change["id"].as_str().unwrap()).collect();
    assert!(ids.contains(&"mix") && ids.contains(&song(1)["songKey"].as_str().unwrap()) && !ids.contains(&song(2)["songKey"].as_str().unwrap()), "{ids:?}");
}
