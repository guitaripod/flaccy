//! Housekeeping of the sync state: pruning old mutation results and emptying the write-ahead log.

mod common;

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use flaccy_server::security::Clock;
use flaccy_server::sync::{PushError, Store, KEEP_PER_DEVICE};
use rusqlite::Connection;
use serde_json::{json, Value};

use common::{member, mutation, request, song, TempDir, BASE_TIME_MS};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

struct Rig {
    dir: TempDir,
    store: Store,
    now: Arc<AtomicI64>,
}

impl Rig {
    async fn start(label: &str) -> Self {
        let dir = TempDir::new(label);
        let now = Arc::new(AtomicI64::new(BASE_TIME_MS));
        let reading = now.clone();
        let clock: Clock = Arc::new(move || reading.load(Ordering::SeqCst));
        let store = Store::open_with_clock(&dir.file("state.sqlite"), "incarnation".to_owned(), clock).await.unwrap();
        Self { dir, store, now }
    }

    async fn push_loves(&self, device: &str, first_id: i64, count: usize) {
        let mutations = (0..count)
            .map(|offset| {
                let index = first_id as usize + offset;
                let args: Value = json!({ "songKey": song(index)["songKey"], "ref": song(index), "loved": true });
                mutation(first_id + offset as i64, "love.set", args)
            })
            .collect();
        self.store.push(&member("alice", device), request(device, "instance", mutations), None).await.unwrap();
    }

    fn ids_of(&self, device: &str) -> Vec<i64> {
        let connection = Connection::open(self.dir.file("state.sqlite")).unwrap();
        let mut statement = connection.prepare("SELECT id FROM mutation_results WHERE device_id = ?1 ORDER BY id").unwrap();
        statement.query_map([device], |row| row.get(0)).unwrap().map(Result::unwrap).collect()
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn each_device_keeps_its_newest_thousand_results() {
    let rig = Rig::start("prune-count").await;
    for first in [1, 401, 801] {
        rig.push_loves("phone", first, 400).await;
    }
    rig.push_loves("tablet", 1, 10).await;
    assert_eq!(rig.ids_of("phone").len(), 1200);

    assert_eq!(rig.store.prune_mutation_results().await.unwrap(), 200);

    let phone = rig.ids_of("phone");
    assert_eq!((phone.len() as i64, phone.first().copied(), phone.last().copied()), (KEEP_PER_DEVICE, Some(201), Some(1200)));
    assert_eq!(rig.ids_of("tablet").len(), 10);
    assert_eq!(rig.store.prune_mutation_results().await.unwrap(), 0);
}

#[tokio::test(flavor = "multi_thread")]
async fn results_older_than_thirty_days_go_and_a_pruned_retry_asks_for_a_new_instance() {
    let rig = Rig::start("prune-age").await;
    rig.push_loves("phone", 1, 5).await;
    rig.now.fetch_add(29 * DAY_MS, Ordering::SeqCst);
    assert_eq!(rig.store.prune_mutation_results().await.unwrap(), 0);
    rig.now.fetch_add(2 * DAY_MS, Ordering::SeqCst);
    rig.push_loves("phone", 6, 3).await;
    assert_eq!(rig.store.prune_mutation_results().await.unwrap(), 5);
    assert_eq!(rig.ids_of("phone"), vec![6, 7, 8]);

    let retry = rig.store.push(&member("alice", "phone"), request("phone", "instance", vec![mutation(2, "love.set", json!({}))]), None).await;
    assert!(matches!(retry, Err(PushError::InstanceConflict)), "{retry:?}");
    let answered = rig.store.push(&member("alice", "phone"), request("phone", "instance", vec![mutation(7, "love.set", json!({ "songKey": song(7)["songKey"], "ref": song(7), "loved": true }))]), None).await;
    assert!(answered.is_ok(), "a retained result still answers a retry");
}

#[tokio::test(flavor = "multi_thread")]
async fn tidying_prunes_and_empties_the_write_ahead_log() {
    let rig = Rig::start("tidy").await;
    rig.push_loves("phone", 1, 300).await;
    let log = rig.dir.file("state.sqlite-wal");
    assert!(std::fs::metadata(&log).map(|meta| meta.len()).unwrap_or(0) > 0, "writes sit in the log first");
    let tidied = rig.store.tidy().await.unwrap();
    assert_eq!(tidied.results_pruned, 0);
    assert_eq!(std::fs::metadata(&log).map(|meta| meta.len()).unwrap_or(0), 0, "the log is truncated");
}
