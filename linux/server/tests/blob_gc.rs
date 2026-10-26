//! Blobs nobody uses are deleted by the daily tidy once they are a week old.

mod common;

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use flaccy_server::dbthread::Durability;
use flaccy_server::security::Clock;
use flaccy_server::sync::{Store, ORPHAN_BLOB_DAYS};
use flaccy_server_core::wire::MutationStatus;
use serde_json::json;
use sha2::{Digest, Sha256};

use common::images::png;
use common::{member, mutation, request, BASE_TIME_MS, TempDir};

const DAY_MS: i64 = 24 * 60 * 60 * 1000;

fn hash_of(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn unused_blobs_go_after_a_week_and_a_cover_in_use_stays() {
    let dir = TempDir::new("blob-gc");
    let now = Arc::new(AtomicI64::new(BASE_TIME_MS));
    let clock: Clock = {
        let now = now.clone();
        Arc::new(move || now.load(Ordering::SeqCst))
    };
    let store = Store::open_with(&dir.file("state.sqlite"), "incarnation".to_owned(), clock, Durability::Normal).await.unwrap();
    let (used, unused) = (png(8, 8), png(9, 9));
    for bytes in [&used, &unused] {
        store.put_blob("alice", &hash_of(bytes), "image/png", bytes.clone()).await.unwrap();
    }
    let alice = member("alice", "phone");
    let mutations = vec![
        mutation(1, "playlist.create", json!({ "id": "mix", "name": "Mix" })),
        mutation(2, "playlist.setCover", json!({ "id": "mix", "blob": hash_of(&used) })),
    ];
    let pushed = store.push(&alice, request("phone", "i1", mutations), None).await.unwrap();
    assert!(pushed.results.iter().all(|result| result.status == MutationStatus::Applied));

    now.fetch_add((ORPHAN_BLOB_DAYS - 1) * DAY_MS, Ordering::SeqCst);
    assert_eq!(store.tidy().await.unwrap().blobs_removed, 0);
    assert!(store.get_blob(&hash_of(&unused)).await.unwrap().is_some());

    store.put_blob("alice", &hash_of(&unused), "image/png", unused.clone()).await.unwrap();
    now.fetch_add(2 * DAY_MS, Ordering::SeqCst);
    assert_eq!(store.tidy().await.unwrap().blobs_removed, 0, "a fresh upload restarts the week");

    now.fetch_add(ORPHAN_BLOB_DAYS * DAY_MS, Ordering::SeqCst);
    assert_eq!(store.tidy().await.unwrap().blobs_removed, 1);
    assert!(store.get_blob(&hash_of(&unused)).await.unwrap().is_none());
    assert!(store.get_blob(&hash_of(&used)).await.unwrap().is_some());
}
