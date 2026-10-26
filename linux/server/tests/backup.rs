//! Backups, their status record and `restore`, against the real stores.

mod common;

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use chrono::Local;
use flaccy_server::backup::{self, back_up_files};
use flaccy_server::lock::DataDirLock;
use flaccy_server::restore;
use flaccy_server::security::Role;
use rusqlite::Connection;
use serde_json::{json, Value};

use common::http::{Device, Harness};
use common::song;

fn love(index: usize) -> Value {
    json!({ "songKey": song(index)["songKey"], "ref": song(index), "loved": true })
}

fn count(path: &Path, sql: &str) -> i64 {
    Connection::open(path).unwrap().query_row(sql, [], |row| row.get(0)).unwrap()
}

fn tables(path: &Path) -> Vec<String> {
    let connection = Connection::open(path).unwrap();
    let mut statement = connection.prepare("SELECT name FROM sqlite_master WHERE type = 'table'").unwrap();
    statement.query_map([], |row| row.get(0)).unwrap().collect::<Result<_, _>>().unwrap()
}

fn files_in(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = std::fs::read_dir(dir).unwrap().flatten().map(|entry| entry.file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    names
}

fn paths(harness: &Harness) -> (PathBuf, PathBuf) {
    let data = harness.dir.file("data");
    (data.join("state.sqlite"), data.join("security.sqlite"))
}

async fn alice_with_loves(harness: &Harness, loves: usize) -> Device {
    let alice = harness.enroll("alice", Role::Member).await;
    let first = harness.push(&alice, 1, (0..loves).map(|index| ("love.set", love(index))).collect()).await;
    assert_eq!(first.status, 200, "{}", String::from_utf8_lossy(&first.body));
    alice
}

#[tokio::test(flavor = "multi_thread")]
async fn a_backup_is_a_verified_private_copy_without_secrets_in_the_state_file() {
    let harness = Harness::start().await;
    alice_with_loves(&harness, 3).await;
    let (state, security) = paths(&harness);
    let out = harness.dir.file("backups");
    let set = back_up_files(&state, &security, &out, &Local::now()).unwrap();
    assert!(set.state.path.file_name().unwrap().to_string_lossy().starts_with("state-"));
    assert!(set.security.path.file_name().unwrap().to_string_lossy().starts_with("security-"));
    assert_eq!(files_in(&out).len(), 2, "no partial or journal file stays: {:?}", files_in(&out));
    for file in [&set.state, &set.security] {
        assert_eq!(std::fs::metadata(&file.path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(&file.path).unwrap().len(), file.bytes);
    }
    assert_eq!(count(&set.state.path, "SELECT COUNT(*) FROM loves WHERE loved = 1"), 3);
    assert!(tables(&set.state.path).iter().all(|table| !["devices", "users", "lastfm_sessions", "api_keys"].contains(&table.as_str())));
    assert!(tables(&set.security.path).contains(&"devices".to_owned()));
    assert_eq!(count(&set.security.path, "SELECT COUNT(*) FROM devices"), 1);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_security_backup_of_a_real_store_has_no_lastfm_keys_but_every_account_and_the_audit_chain() {
    let harness = Harness::start().await;
    let alice = alice_with_loves(&harness, 1).await;
    let security_store = &harness.state.0.security;
    let user = flaccy_server::security::UserId(alice.user.clone());
    security_store.set_lastfm_session(&user, "alice_fm", "LIVE-SESSION-KEY").await.unwrap();
    let audit_before = security_store.audit_len().await.unwrap();
    let (state, security) = paths(&harness);
    let set = back_up_files(&state, &security, &harness.dir.file("backups"), &Local::now()).unwrap();
    assert_eq!(count(&set.security.path, "SELECT COUNT(*) FROM lastfm_sessions"), 0);
    assert_eq!(count(&set.security.path, "SELECT COUNT(*) FROM users"), 1);
    assert_eq!(count(&set.security.path, "SELECT COUNT(*) FROM devices"), 1);
    assert_eq!(count(&set.security.path, "SELECT COUNT(*) FROM audit") as u64, audit_before);
    assert!(!std::fs::read(&set.security.path).unwrap().windows(16).any(|window| window == b"LIVE-SESSION-KEY"));
    assert!(security_store.lastfm_session(&user).await.unwrap().is_some(), "the live database keeps its connection");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_backup_taken_while_the_server_writes_is_consistent() {
    let harness = Harness::start().await;
    let alice = alice_with_loves(&harness, 200).await;
    let (state, security) = paths(&harness);
    let out = harness.dir.file("backups");
    let backing_up = tokio::task::spawn_blocking(move || back_up_files(&state, &security, &out, &Local::now()));
    for step in 0..40 {
        let pushed = harness.push(&alice, 201 + step, vec![("love.set", love(1000 + step as usize))]).await;
        assert_eq!(pushed.status, 200);
    }
    let set = backing_up.await.unwrap().unwrap();
    assert!(count(&set.state.path, "SELECT COUNT(*) FROM loves") >= 200);
    let verdict: String = Connection::open(&set.state.path).unwrap().query_row("PRAGMA integrity_check", [], |row| row.get(0)).unwrap();
    assert_eq!(verdict, "ok");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failed_backup_leaves_no_file_under_a_real_name() {
    let harness = Harness::start().await;
    alice_with_loves(&harness, 1).await;
    let (state, security) = paths(&harness);
    let out = harness.dir.file("backups");
    let missing = back_up_files(&harness.dir.file("none.sqlite"), &security, &out, &Local::now()).unwrap_err();
    assert!(missing.contains("nothing to back up"), "{missing}");
    let garbage = harness.dir.file("garbage.sqlite");
    std::fs::write(&garbage, vec![b'x'; 8192]).unwrap();
    let unreadable = back_up_files(&garbage, &security, &out, &Local::now());
    assert!(unreadable.is_err());
    let second_file_bad = back_up_files(&state, &garbage, &out, &Local::now());
    assert!(second_file_bad.is_err());
    assert!(files_in(&out).is_empty(), "{:?}", files_in(&out));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_status_record_survives_in_server_meta() {
    let harness = Harness::start().await;
    let security = &harness.state.0.security;
    assert_eq!(backup::last_status(security).await.unwrap(), backup::BackupStatus::default());
    let (state, security_file) = paths(&harness);
    let made = back_up_files(&state, &security_file, &harness.dir.file("backups"), &Local::now());
    backup::record_outcome(security, &made).await.unwrap();
    let ok = backup::last_status(security).await.unwrap();
    assert_eq!((ok.last_ok, ok.last_error.clone()), (Some(true), None));
    assert!(ok.last_at.unwrap().ends_with('Z'));
    backup::record_outcome(security, &Err("the disk is full.".to_owned())).await.unwrap();
    let failed = backup::last_status(security).await.unwrap();
    assert_eq!((failed.last_ok, failed.last_error), (Some(false), Some("the disk is full.".to_owned())));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn restore_replaces_the_state_changes_the_incarnation_and_keeps_every_account() {
    let harness = Harness::start().await;
    let alice = alice_with_loves(&harness, 2).await;
    let bob = harness.enroll("bob", Role::Member).await;
    harness.revoke(&bob.id).await;
    let before = harness.pull(&alice, 0).await.json();
    let old_incarnation = before["incarnation"].as_str().unwrap().to_owned();
    let (state, security) = paths(&harness);
    let set = back_up_files(&state, &security, &harness.dir.file("backups"), &Local::now()).unwrap();
    assert_eq!(harness.push(&alice, 3, vec![("love.set", love(7)), ("playlist.create", json!({ "id": "later", "name": "Later" }))]).await.status, 200);
    let users_before = harness.state.0.security.list_users().await.unwrap().len();

    let (dir, config) = harness.halt().await;
    let restored = restore::restore_into(&config, &set.state.path).await.unwrap();
    let kept = restored.kept_as.clone().unwrap();
    assert_eq!(count(&kept, "SELECT COUNT(*) FROM loves"), 3, "the replaced state is kept whole");
    assert_ne!(restored.incarnation, old_incarnation);
    assert!(!restored.security_created);
    let data = dir.file("data");
    assert!(!data.join("state.sqlite-wal").exists() || std::fs::metadata(data.join("state.sqlite-wal")).unwrap().len() == 0);
    assert_eq!(count(&data.join("state.sqlite"), "SELECT COUNT(*) FROM loves"), 2);

    let harness = Harness::start_in(dir, config).await;
    let stale = [("Flaccy-Incarnation", old_incarnation.as_str())];
    let refused = harness.call("GET", "/flaccy/v1/sync/pull", Some(&alice.token), &stale, &[]).await;
    assert_eq!((refused.status, refused.code()), (409, "incarnation_changed".to_owned()));
    assert_eq!(refused.json()["error"]["incarnation"], restored.incarnation.as_str());
    let pulled = harness.pull(&alice, 0).await.json();
    assert_eq!(pulled["incarnation"], restored.incarnation.as_str());
    let kinds: Vec<&str> = pulled["changes"].as_array().unwrap().iter().map(|change| change["kind"].as_str().unwrap()).collect();
    assert_eq!(kinds, ["love", "love"], "only what the backup held comes back");
    assert_eq!(harness.state.0.security.list_users().await.unwrap().len(), users_before);
    assert_eq!(harness.pull(&bob, 0).await.status, 401, "a revoked device stays revoked");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn restore_refuses_while_a_server_holds_the_data_folder() {
    let harness = Harness::start().await;
    alice_with_loves(&harness, 1).await;
    let (state, security) = paths(&harness);
    let set = back_up_files(&state, &security, &harness.dir.file("backups"), &Local::now()).unwrap();
    let (dir, config) = harness.halt().await;
    let before = std::fs::read(dir.file("data/state.sqlite")).unwrap();
    let lock = DataDirLock::acquire(&dir.file("data")).unwrap();
    let refused = restore::restore_into(&config, &set.state.path).await.unwrap_err();
    assert!(refused.contains("is running") && refused.contains(&format!("pid {}", std::process::id())) && refused.contains("nothing was restored"), "{refused}");
    assert_eq!(std::fs::read(dir.file("data/state.sqlite")).unwrap(), before);
    drop(lock);
    assert!(restore::restore_into(&config, &set.state.path).await.is_ok());
}

#[tokio::test(flavor = "multi_thread")]
async fn restore_checks_the_file_before_it_touches_anything() {
    let harness = Harness::start().await;
    alice_with_loves(&harness, 1).await;
    let (state, security) = paths(&harness);
    let set = back_up_files(&state, &security, &harness.dir.file("backups"), &Local::now()).unwrap();
    let (dir, config) = harness.halt().await;
    let current = std::fs::read(dir.file("data/state.sqlite")).unwrap();

    let garbage = dir.file("garbage.sqlite");
    std::fs::write(&garbage, vec![b'x'; 8192]).unwrap();
    let newer = dir.file("newer.sqlite");
    std::fs::copy(&set.state.path, &newer).unwrap();
    Connection::open(&newer).unwrap().execute("INSERT INTO schema_migrations(version, applied_at) VALUES (99, 0)", []).unwrap();

    let cases: [(PathBuf, &[&str]); 4] = [
        (dir.file("missing.sqlite"), &["no backup file"]),
        (garbage, &["integrity", "not"]),
        (set.security.path.clone(), &["security backup", "state-"]),
        (newer, &["99", "up to"]),
    ];
    for (file, expected) in cases {
        let error = restore::restore_into(&config, &file).await.unwrap_err();
        assert!(expected.iter().any(|word| error.contains(word)), "{error}");
        assert_eq!(std::fs::read(dir.file("data/state.sqlite")).unwrap(), current, "{error}");
    }
    assert!(files_in(&dir.file("data")).iter().all(|name| !name.contains("before-restore")));
}

#[tokio::test(flavor = "multi_thread")]
async fn restoring_into_an_empty_folder_makes_a_new_security_database() {
    let harness = Harness::start().await;
    alice_with_loves(&harness, 1).await;
    let (state, security) = paths(&harness);
    let set = back_up_files(&state, &security, &harness.dir.file("backups"), &Local::now()).unwrap();
    let (_kept, mut config) = harness.halt().await;
    let fresh = common::TempDir::new("fresh-restore");
    config.data_dir = Some(fresh.file("data"));
    let restored = restore::restore_into(&config, &set.state.path).await.unwrap();
    assert!(restored.security_created && restored.kept_as.is_none());
    assert_eq!(count(&fresh.file("data/state.sqlite"), "SELECT COUNT(*) FROM loves"), 1);
    assert!(fresh.file("data/security.sqlite").is_file());
}
