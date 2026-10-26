//! Enrollment codes: guessing is limited per source address and across all of them, and a code is only spent by an
//! enrollment that finished.

mod common;

use flaccy_server::config::{Config, Mode};
use flaccy_server::security::Role;
use serde_json::json;

use common::http::{Harness, Reply};
use common::TempDir;

async fn behind_a_proxy() -> Harness {
    let dir = TempDir::new("enroll-limits");
    let music = dir.file("music");
    std::fs::create_dir_all(&music).unwrap();
    let config = Config {
        music_folder: music,
        address: "127.0.0.1".to_owned(),
        port: 0,
        data_dir: Some(dir.file("data")),
        behind_proxy: true,
        mode: Mode::Easy,
        lastfm: Default::default(),
        hosts: Vec::new(),
        backup_dir: None,
    };
    Harness::start_in(dir, config).await
}

async fn enroll_from(harness: &Harness, source: &str, code: &str) -> Reply {
    let body = json!({ "enroll": code, "name": "iPhone", "platform": "ios", "instance": "i1" });
    harness.post_json("/flaccy/v1/devices", None, &[("X-Forwarded-For", source)], &body).await
}

#[tokio::test(flavor = "multi_thread")]
async fn five_wrong_codes_lock_one_source_and_leave_another_enrolling() {
    let harness = behind_a_proxy().await;
    let user = harness.user("alice", Role::Member).await;
    let code = harness.enroll_code(&user).await;
    for _ in 0..5 {
        assert_eq!(enroll_from(&harness, "100.64.0.9", &"0".repeat(26)).await.status, 401);
    }
    let locked = enroll_from(&harness, "100.64.0.9", &code).await;
    assert_eq!((locked.status, locked.code()), (429, "rate_limited".to_owned()));
    assert!(locked.header("retry-after").is_some());
    let other = enroll_from(&harness, "100.64.0.10", &code).await;
    assert_eq!(other.status, 201, "{}", String::from_utf8_lossy(&other.body));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn sixty_wrong_codes_from_many_sources_lock_everyone_for_a_minute() {
    let harness = behind_a_proxy().await;
    let user = harness.user("alice", Role::Member).await;
    let code = harness.enroll_code(&user).await;
    for guess in 0..60 {
        let source = format!("100.64.1.{}", guess / 4);
        let reply = enroll_from(&harness, &source, &"0".repeat(26)).await;
        assert_eq!(reply.status, 401, "guess {guess}");
    }
    let everyone = enroll_from(&harness, "100.64.2.1", &code).await;
    assert_eq!((everyone.status, everyone.code()), (429, "rate_limited".to_owned()));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_failure_after_the_code_was_found_good_leaves_the_code_unspent() {
    let harness = behind_a_proxy().await;
    let user = harness.user("alice", Role::Member).await;
    let code = harness.enroll_code(&user).await;
    let security = harness.dir.path().join("data").join("security.sqlite");
    rusqlite::Connection::open(&security).unwrap().execute_batch("ALTER TABLE devices RENAME TO devices_away").unwrap();
    let failed = enroll_from(&harness, "100.64.0.9", &code).await;
    assert_eq!(failed.status, 500, "{}", String::from_utf8_lossy(&failed.body));
    let connection = rusqlite::Connection::open(&security).unwrap();
    let spent: Option<i64> = connection.query_row("SELECT used_at FROM enrollments", [], |row| row.get(0)).unwrap();
    assert_eq!(spent, None, "the code was burned by an enrollment that never finished");
    connection.execute_batch("ALTER TABLE devices_away RENAME TO devices").unwrap();
    let retry = enroll_from(&harness, "100.64.0.9", &code).await;
    assert_eq!(retry.status, 201, "{}", String::from_utf8_lossy(&retry.body));
    harness.stop().await;
}
