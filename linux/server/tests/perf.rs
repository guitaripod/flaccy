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

const BIG_PLAYLIST: usize = 19_850;

fn seed_entries(path: &std::path::Path, playlist: &str, count: usize) {
    let connection = rusqlite::Connection::open(path).unwrap();
    connection.busy_timeout(Duration::from_secs(10)).unwrap();
    let keys = flaccy_server_core::position::rebalance(count);
    let stamp = common::BASE_TIME_MS << 16;
    let transaction = connection.unchecked_transaction().unwrap();
    {
        let mut insert = transaction
            .prepare("INSERT INTO playlist_entries(id, playlist_id, ref_json, pos, alive, st_ref, st_pos, st_alive) VALUES (?1, ?2, ?3, ?4, 1, ?5, ?5, ?5)")
            .unwrap();
        for (index, key) in keys.iter().enumerate() {
            insert.execute((format!("e{index}"), playlist, song(index).to_string(), key, stamp)).unwrap();
        }
    }
    transaction.commit().unwrap();
}

async fn timed_push(store: &Store, id: i64, name: &str, args: serde_json::Value) -> Duration {
    let started = Instant::now();
    let response = store.push(&member("alice", "phone"), request("phone", INSTANCE, vec![mutation(id, name, args)]), None).await.unwrap();
    let elapsed = started.elapsed();
    assert_eq!(response.results[0].status, MutationStatus::Applied, "{name}: {:?}", response.results[0].code);
    elapsed
}

fn spread(label: &str, mut samples: Vec<Duration>) {
    samples.sort();
    report(&format!("{label}: min {:?}, median {:?}, max {:?} over {} edits", samples[0], samples[samples.len() / 2], samples[samples.len() - 1], samples.len()));
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "prints the cost of one edit on a 20,000-entry playlist; run with --release"]
async fn bench_edits_on_a_twenty_thousand_entry_playlist() {
    let dir = TempDir::new("perf-big");
    let store = open(&dir).await;
    timed_push(&store, 1, "playlist.create", json!({ "id": "big", "name": "Big" })).await;
    seed_entries(&dir.file("state.sqlite"), "big", BIG_PLAYLIST);
    let mut next = 2;
    let mut inserts_middle = Vec::new();
    let mut inserts_last = Vec::new();
    let mut moves = Vec::new();
    let mut removes = Vec::new();
    let mut renames = Vec::new();
    for round in 0..15 {
        let anchor = format!("e{}", 5_000 + round * 700);
        let place = json!({ "kind": "after", "id": anchor });
        inserts_middle.push(timed_push(&store, next, "entry.insert", json!({ "id": format!("m{round}"), "playlist": "big", "ref": song(round), "place": place })).await);
        inserts_last.push(timed_push(&store, next + 1, "entry.insert", json!({ "id": format!("l{round}"), "playlist": "big", "ref": song(round), "place": { "kind": "last" } })).await);
        moves.push(timed_push(&store, next + 2, "entry.move", json!({ "id": format!("e{}", 100 + round), "place": { "kind": "after", "id": format!("e{}", 15_000 + round) } })).await);
        removes.push(timed_push(&store, next + 3, "entry.remove", json!({ "id": format!("e{}", 200 + round) })).await);
        renames.push(timed_push(&store, next + 4, "playlist.rename", json!({ "id": "big", "name": format!("Big {round}") })).await);
        next += 5;
    }
    spread("entry.insert after a middle entry", inserts_middle);
    spread("entry.insert at the end", inserts_last);
    spread("entry.move", moves);
    spread("entry.remove", removes);
    spread("playlist.rename", renames);
    let batch: Vec<_> = (0..90)
        .map(|offset| mutation(next + offset, "entry.insert", json!({ "id": format!("b{offset}"), "playlist": "big", "ref": song(offset as usize), "place": { "kind": "last" } })))
        .collect();
    let started = Instant::now();
    let response = store.push(&member("alice", "phone"), request("phone", INSTANCE, batch), None).await.unwrap();
    assert!(response.results.iter().all(|result| result.status == MutationStatus::Applied));
    report(&format!("one request of 90 entry.insert at the end: {:?}", started.elapsed()));
}
