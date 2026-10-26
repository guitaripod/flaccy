//! Listens belong to the user who recorded them: one user's event id never blocks another's, and the table that
//! guaranteed it is rebuilt without losing a row.

mod common;

use std::time::{Duration, Instant};

use flaccy_server::security::UserId;
use flaccy_server::sync::{Store, CURRENT_VERSION};
use flaccy_server_core::wire::MutationStatus;
use serde_json::json;

use common::{member, mutation, request, song, TempDir};

const EVENT_ID: &str = "0123456789abcdef01234567";
const ROWS: usize = 200_000;

fn listen(event_id: &str, ts: i64, index: usize) -> serde_json::Value {
    json!({ "listens": [{ "eventId": event_id, "ts": ts, "ref": song(index), "playedS": 200, "recorded": true }] })
}

#[tokio::test(flavor = "multi_thread")]
async fn two_users_record_the_same_event_id_independently() {
    let dir = TempDir::new("listen-keys");
    let store = Store::open(&dir.file("state.sqlite"), "incarnation".to_owned()).await.unwrap();
    let (alice, bob) = (member("alice", "phone"), member("bob", "tablet"));
    let squat = store.push(&alice, request("phone", "i1", vec![mutation(1, "listen.record", listen(EVENT_ID, 1_700_000_000, 1))]), None).await.unwrap();
    assert_eq!(squat.results[0].status, MutationStatus::Applied);
    let victim = store.push(&bob, request("tablet", "i2", vec![mutation(1, "listen.record", listen(EVENT_ID, 1_700_000_500, 2))]), None).await.unwrap();
    assert_eq!(victim.results[0].status, MutationStatus::Applied);
    for (user, ts) in [("alice", 1_700_000_000), ("bob", 1_700_000_500)] {
        let page = store.listens_before(&UserId(user.to_owned()), i64::MAX, 10).await.unwrap();
        assert_eq!(page.listens.len(), 1, "{user}");
        assert_eq!((page.listens[0].listen.event_id.as_str(), page.listens[0].listen.ts), (EVENT_ID, ts));
    }
    let again = store.push(&alice, request("phone", "i1", vec![mutation(2, "listen.record", listen(EVENT_ID, 1_700_000_000, 1))]), None).await.unwrap();
    assert_eq!(again.results[0].status, MutationStatus::Noop);
}

fn downgrade_to_version_three(path: &std::path::Path, rows: usize) {
    let connection = rusqlite::Connection::open(path).unwrap();
    connection
        .execute_batch(
            "DROP TABLE listens;
             DROP TABLE IF EXISTS blob_uploads;
             CREATE TABLE listens(event_id TEXT PRIMARY KEY, user_id TEXT NOT NULL, ts INTEGER NOT NULL, song_key TEXT NOT NULL,
                 title_key TEXT NOT NULL, artist_key TEXT NOT NULL, ref_json TEXT NOT NULL, played_s INTEGER NOT NULL, source TEXT NOT NULL,
                 recorded INTEGER NOT NULL, device_id TEXT, suppressed INTEGER NOT NULL, seq INTEGER NOT NULL);
             CREATE INDEX listens_user_ts ON listens(user_id, ts);
             CREATE INDEX listens_user_seq ON listens(user_id, seq);
             CREATE INDEX listens_user_song_ts ON listens(user_id, song_key, ts);
             DELETE FROM schema_migrations WHERE version > 3;",
        )
        .unwrap();
    let transaction = connection.unchecked_transaction().unwrap();
    {
        let mut insert = transaction
            .prepare("INSERT INTO listens VALUES (?1, ?2, ?3, ?4, 't', 'a', '{}', 100, 'flaccy', 1, NULL, 0, ?5)")
            .unwrap();
        for index in 0..rows {
            let user = format!("user{}", index % 4);
            insert.execute((format!("{index:024x}"), user, 1_600_000_000 + index as i64, format!("{:032x}", index % 500), index as i64)).unwrap();
        }
    }
    transaction.commit().unwrap();
}

fn primary_key_columns(path: &std::path::Path) -> Vec<String> {
    let connection = rusqlite::Connection::open(path).unwrap();
    let mut statement = connection.prepare("SELECT name FROM pragma_table_info('listens') WHERE pk > 0 ORDER BY pk").unwrap();
    statement.query_map([], |row| row.get(0)).unwrap().map(Result::unwrap).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn migration_four_rebuilds_two_hundred_thousand_listens_in_seconds_keeping_rows_and_indexes() {
    let dir = TempDir::new("listen-migration");
    let path = dir.file("state.sqlite");
    Store::open(&path, "incarnation".to_owned()).await.unwrap().close().await.unwrap();
    downgrade_to_version_three(&path, ROWS);
    assert_eq!(primary_key_columns(&path), ["event_id"]);

    let started = Instant::now();
    let store = Store::open(&path, "incarnation".to_owned()).await.unwrap();
    let took = started.elapsed();
    assert!(took < Duration::from_secs(5), "the migration took {took:?}");
    store.close().await.unwrap();

    assert_eq!(primary_key_columns(&path), ["user_id", "event_id"]);
    let connection = rusqlite::Connection::open(&path).unwrap();
    let count: i64 = connection.query_row("SELECT COUNT(*) FROM listens", [], |row| row.get(0)).unwrap();
    assert_eq!(count, ROWS as i64);
    let indexes: Vec<String> = connection
        .prepare("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'listens' AND name LIKE 'listens_user_%' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect();
    assert_eq!(indexes, ["listens_user_seq", "listens_user_song_ts", "listens_user_ts"]);
    let version: u32 = connection.query_row("SELECT MAX(version) FROM schema_migrations", [], |row| row.get(0)).unwrap();
    assert_eq!(version, CURRENT_VERSION);
    assert!(dir.file("state.sqlite.premigrate-3.bak").exists());
}
