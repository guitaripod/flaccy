//! The state store on its own: persistence across restarts, files and migrations.

mod common;

use std::os::unix::fs::PermissionsExt;

use flaccy_server::sync::Store;
use serde_json::json;

use common::{member, mutation, request, song, TempDir};

#[tokio::test(flavor = "multi_thread")]
async fn state_counters_and_progress_survive_a_restart() {
    let dir = TempDir::new("reopen");
    let path = dir.file("state.sqlite");
    let principal = member("alice", "phone");
    let store = Store::open(&path, "inc".to_owned()).await.unwrap();
    let args = json!({ "id": "mix", "name": "Mix", "entries": [{ "id": "e1", "ref": song(0) }] });
    store.push(&principal, request("phone", "i1", vec![mutation(1, "playlist.create", args.clone())]), None).await.unwrap();
    let before = store.pull(&principal, "i1", 0, 100, None).await.unwrap();
    store.close().await.unwrap();

    let reopened = Store::open(&path, "inc".to_owned()).await.unwrap();
    let after = reopened.pull(&principal, "i1", 0, 100, None).await.unwrap();
    assert_eq!(serde_json::to_value(&before.changes).unwrap(), serde_json::to_value(&after.changes).unwrap());
    assert_eq!(before.head, after.head);
    assert_eq!(after.last_mutation_id, 1);
    let retry = reopened.push(&principal, request("phone", "i1", vec![mutation(1, "playlist.create", args)]), None).await.unwrap();
    assert_eq!(retry.results.len(), 1);
    let next = reopened.push(&principal, request("phone", "i1", vec![mutation(2, "love.set", json!({ "songKey": song(1)["songKey"], "ref": song(1), "loved": true }))]), None).await.unwrap();
    assert_eq!(serde_json::to_value(next.results[0].status).unwrap(), "applied");
    let pulled = reopened.pull(&principal, "i1", after.head, 100, None).await.unwrap();
    assert_eq!(pulled.changes.len(), 1);
    assert!(pulled.changes[0].seq > after.head, "sequence numbers keep rising after a restart");
}

#[tokio::test(flavor = "multi_thread")]
async fn the_state_file_is_private_and_records_its_schema() {
    let dir = TempDir::new("private");
    let path = dir.file("state.sqlite");
    let store = Store::open(&path, "inc".to_owned()).await.unwrap();
    let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
    store.close().await.unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    let version: i64 = connection.query_row("SELECT MAX(version) FROM schema_migrations", [], |row| row.get(0)).unwrap();
    assert_eq!(version, 1);
    let tables: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('server_meta','changes','playlists','playlist_entries','loves','ratings','scalars','sessions','listens','device_progress','mutation_results','blobs')",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(tables, 12);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_file_from_a_newer_server_is_refused_untouched() {
    let dir = TempDir::new("newer");
    let path = dir.file("state.sqlite");
    Store::open(&path, "inc".to_owned()).await.unwrap().close().await.unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection.execute("INSERT INTO schema_migrations(version, applied_at) VALUES (99, 0)", []).unwrap();
    drop(connection);
    let refused = Store::open(&path, "inc".to_owned()).await.err().unwrap().to_string();
    assert!(refused.contains("99") && refused.contains("newer"), "{refused}");
}

#[tokio::test(flavor = "multi_thread")]
async fn an_incarnation_change_is_answered_with_the_current_one() {
    let dir = TempDir::new("incarnation");
    let store = Store::open(&dir.file("state.sqlite"), "first".to_owned()).await.unwrap();
    let principal = member("alice", "phone");
    store.set_incarnation("second".to_owned());
    let refused = store.pull(&principal, "i1", 0, 10, Some("first")).await.err().unwrap();
    assert!(matches!(refused, flaccy_server::sync::PullError::IncarnationChanged { ref current } if current == "second"));
    assert!(store.pull(&principal, "i1", 0, 10, Some("second")).await.is_ok());
}
