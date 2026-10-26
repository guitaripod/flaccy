//! Throughput smoke tests with generous bounds, and the numbers the report quotes.

mod common;

use std::io::Write;
use std::time::{Duration, Instant};

use flaccy_server::sync::Store;
use flaccy_server_core::wire::MutationStatus;
use serde_json::json;

use common::{member, mutation, request, song, TempDir};

const INSTANCE: &str = "perf-instance";
const SEED_INSTANCE: &str = "seed-instance";

fn report(line: &str) {
    let _ = writeln!(std::io::stdout(), "{line}");
}

async fn open(dir: &TempDir) -> Store {
    Store::open(&dir.file("state.sqlite"), "incarnation".to_owned()).await.unwrap()
}

fn playlist_with_inserts(count: usize) -> Vec<flaccy_server_core::wire::Mutation> {
    let mut mutations = vec![mutation(1, "playlist.create", json!({ "id": "mix", "name": "Mix" }))];
    for index in 0..count - 1 {
        mutations.push(mutation(
            index as i64 + 2,
            "entry.insert",
            json!({ "id": format!("e{index}"), "playlist": "mix", "ref": song(index), "place": { "kind": "last" } }),
        ));
    }
    mutations
}

async fn push_batch(store: &Store, first_id: i64, count: usize) -> Duration {
    let mutations = (0..count)
        .map(|offset| {
            let index = first_id as usize + offset;
            mutation(first_id + offset as i64, "love.set", json!({ "songKey": song(index)["songKey"], "ref": song(index), "loved": true }))
        })
        .collect();
    let started = Instant::now();
    store.push(&member("alice", "phone"), request("phone", INSTANCE, mutations), None).await.unwrap();
    started.elapsed()
}

async fn seed_twenty_thousand_entities(store: &Store) {
    let principal = member("alice", "phone");
    let mut next_id = 1;
    for batch in 0..4 {
        let mutations = (0..10)
            .map(|offset| {
                let playlist = batch * 10 + offset;
                let entries: Vec<_> = (0..500).map(|entry| json!({ "id": format!("p{playlist}e{entry}"), "ref": song(entry) })).collect();
                let mutation = mutation(next_id, "playlist.create", json!({ "id": format!("p{playlist}"), "name": "Mix", "entries": entries }));
                next_id += 1;
                mutation
            })
            .collect();
        store.push(&principal, request("phone", SEED_INSTANCE, mutations), None).await.unwrap();
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn five_hundred_mutations_push_in_under_three_seconds() {
    let dir = TempDir::new("perf-push");
    let store = open(&dir).await;
    let started = Instant::now();
    let response = store
        .push(&member("alice", "phone"), request("phone", INSTANCE, playlist_with_inserts(500)), None)
        .await
        .unwrap();
    let elapsed = started.elapsed();
    assert_eq!(response.results.len(), 500);
    assert!(response.results.iter().all(|result| result.status == MutationStatus::Applied));
    assert!(elapsed < Duration::from_secs(3), "500 mutations took {elapsed:?}");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_thousand_changes_pull_from_twenty_thousand_entities_in_under_a_second() {
    let dir = TempDir::new("perf-pull");
    let store = open(&dir).await;
    seed_twenty_thousand_entities(&store).await;
    let started = Instant::now();
    let page = store.pull(&member("alice", "phone"), INSTANCE, 0, 1000, None).await.unwrap();
    let elapsed = started.elapsed();
    assert_eq!(page.changes.len(), 1000);
    assert!(page.more);
    assert!(page.head >= 20_000, "head {}", page.head);
    assert!(elapsed < Duration::from_secs(1), "the pull took {elapsed:?}");
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "prints throughput numbers for the report"]
async fn bench_numbers() {
    let dir = TempDir::new("perf-bench");
    let store = open(&dir).await;
    let singles = push_batch(&store, 1, 500).await;
    report(&format!("push 500 love.set (one request): {:.0} mutations/s ({singles:?})", 500.0 / singles.as_secs_f64()));
    let started = Instant::now();
    store
        .push(&member("alice", "tablet"), request("tablet", INSTANCE, playlist_with_inserts(500)), None)
        .await
        .unwrap();
    let inserts = started.elapsed();
    report(&format!("push playlist.create + 499 entry.insert (one request): {:.0} mutations/s ({inserts:?})", 500.0 / inserts.as_secs_f64()));
    let started = Instant::now();
    for index in 0..100 {
        push_batch(&store, 501 + index, 1).await;
    }
    let one_at_a_time = started.elapsed();
    report(&format!("push 100 requests of 1 love.set: {:.0} requests/s ({one_at_a_time:?})", 100.0 / one_at_a_time.as_secs_f64()));
    seed_twenty_thousand_entities(&store).await;
    let principal = member("alice", "phone");
    let started = Instant::now();
    let first = store.pull(&principal, INSTANCE, 0, 1000, None).await.unwrap();
    report(&format!("pull 1000 of 20,000+ entities (since 0): {:?}", started.elapsed()));
    let started = Instant::now();
    let mut since = 0;
    let mut pages = 0;
    loop {
        let page = store.pull(&principal, INSTANCE, since, 5000, None).await.unwrap();
        pages += 1;
        since = page.changes.last().map_or(page.head, |change| change.seq);
        if !page.more {
            break;
        }
    }
    report(&format!("pull everything in {pages} pages of 5000: {:?}", started.elapsed()));
    let started = Instant::now();
    let tail = store.pull(&principal, INSTANCE, first.head, 1000, None).await.unwrap();
    report(&format!("pull at head ({} changes): {:?}", tail.changes.len(), started.elapsed()));
}
