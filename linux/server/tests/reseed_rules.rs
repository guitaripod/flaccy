//! `state.reseed` and the playlist limits: how big a reseed may be, how many entries a playlist keeps, and which stamps a
//! reseeded entity may carry.

mod common;

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;

use flaccy_server::dbthread::Durability;
use flaccy_server::security::{Clock, Principal};
use flaccy_server::sync::Store;
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{ErrorCode, Mutation, MutationStatus};
use serde_json::{json, Value};

use common::{member, mutation, request, song, TempDir, BASE_TIME_MS};

const INSTANCE: &str = "rules-instance";

struct Rig {
    dir: TempDir,
    store: Store,
    alice: Principal,
    next_id: AtomicI64,
    now: Arc<AtomicI64>,
}

impl Rig {
    async fn new() -> Self {
        let dir = TempDir::new("reseed-rules");
        let now = Arc::new(AtomicI64::new(BASE_TIME_MS + 1_000_000));
        let clock: Clock = {
            let now = now.clone();
            Arc::new(move || now.load(Ordering::SeqCst))
        };
        let store = Store::open_with(&dir.file("state.sqlite"), "incarnation".to_owned(), clock, Durability::Normal)
            .await
            .unwrap();
        Rig { dir, store, alice: member("alice", "phone"), next_id: AtomicI64::new(1), now }
    }

    async fn push(&self, name: &str, args: Value) -> (MutationStatus, Option<ErrorCode>) {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        self.send(mutation(id, name, args)).await
    }

    async fn push_at(&self, name: &str, args: Value, wall_ms: i64) -> (MutationStatus, Option<ErrorCode>) {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let mut stamped = mutation(id, name, args);
        stamped.stamp = Stamp::from_wall_ms(wall_ms);
        self.send(stamped).await
    }

    async fn send(&self, mutation: Mutation) -> (MutationStatus, Option<ErrorCode>) {
        let response = self.store.push(&self.alice, request("phone", INSTANCE, vec![mutation]), None).await.unwrap();
        (response.results[0].status, response.results[0].code)
    }

    fn later_wall_ms(&self) -> i64 {
        self.now.fetch_add(1_000_000, Ordering::SeqCst);
        self.now.load(Ordering::SeqCst) - 500_000
    }

    async fn entity(&self, kind: &str, id: &str) -> Value {
        let pulled = self.store.pull(&self.alice, INSTANCE, 0, 5000, None).await.unwrap();
        let kind: flaccy_server_core::model::EntityKind = serde_json::from_value(json!(kind)).unwrap();
        pulled.changes.iter().rev().find(|change| change.kind == kind && change.id == id).unwrap().value.clone()
    }

    async fn playlist_with_rows(&self, id: &str, alive: usize, dead: usize) {
        let (status, _) = self.push("playlist.create", json!({ "id": id, "name": id })).await;
        assert_eq!(status, MutationStatus::Applied);
        let connection = rusqlite::Connection::open(self.dir.file("state.sqlite")).unwrap();
        connection.busy_timeout(std::time::Duration::from_secs(10)).unwrap();
        let stamp = BASE_TIME_MS << 16;
        let transaction = connection.unchecked_transaction().unwrap();
        {
            let mut insert = transaction
                .prepare("INSERT INTO playlist_entries(id, playlist_id, ref_json, pos, alive, st_ref, st_pos, st_alive) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, ?6)")
                .unwrap();
            let reference = song(0).to_string();
            for index in 0..alive + dead {
                insert.execute((format!("{id}-{index}"), id, &reference, position(index), index < alive, stamp)).unwrap();
            }
        }
        transaction.commit().unwrap();
    }
}

fn position(index: usize) -> String {
    format!("Z{index:07}1")
}

fn love_entity(index: usize) -> Value {
    let key = song(index)["songKey"].clone();
    json!({ "kind": "love", "id": key, "value": { "songKey": key, "ref": song(index), "loved": true, "stamp": 7 } })
}

fn entry_entity(playlist: &str, id: &str, index: usize) -> Value {
    json!({
        "kind": "playlist_entry",
        "id": id,
        "value": { "id": id, "playlist": playlist, "ref": song(0), "pos": position(index), "alive": true, "stamps": { "ref": 1, "pos": 1, "alive": 1 } }
    })
}

fn scalar_entity(key: &str, value: Value, deleted: bool, stamp: i64) -> Value {
    json!({ "kind": "scalar", "id": key, "value": { "key": key, "value": value, "deleted": deleted, "stamp": stamp } })
}

fn fresh_entries(playlist: &str, count: usize, first_index: usize) -> Value {
    let entities: Vec<Value> = (0..count).map(|offset| entry_entity(playlist, &format!("new-{}", first_index + offset), first_index + offset)).collect();
    json!({ "entities": entities })
}

const TOO_LARGE: (MutationStatus, Option<ErrorCode>) = (MutationStatus::Invalid, Some(ErrorCode::TooLarge));
const APPLIED: (MutationStatus, Option<ErrorCode>) = (MutationStatus::Applied, None);

#[tokio::test(flavor = "multi_thread")]
async fn a_reseed_carries_at_most_a_thousand_entities() {
    let rig = Rig::new().await;
    let too_many: Vec<Value> = (0..1_001).map(love_entity).collect();
    assert_eq!(rig.push("state.reseed", json!({ "entities": too_many })).await, TOO_LARGE);
    let allowed: Vec<Value> = (0..1_000).map(love_entity).collect();
    assert_eq!(rig.push("state.reseed", json!({ "entities": allowed })).await, APPLIED);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reseed_carries_at_most_four_hundred_kilobytes() {
    let rig = Rig::new().await;
    let big = |count: usize| -> Value {
        let entities: Vec<Value> = (0..count).map(|index| scalar_entity(&format!("eq/k{index}"), json!("x".repeat(50_000)), false, 7)).collect();
        json!({ "entities": entities })
    };
    assert_eq!(rig.push("state.reseed", big(9)).await, TOO_LARGE);
    assert_eq!(rig.push("state.reseed", big(7)).await, APPLIED);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reseed_cannot_take_a_playlist_past_twenty_thousand_alive_entries() {
    let rig = Rig::new().await;
    rig.playlist_with_rows("full", 19_900, 0).await;
    assert_eq!(rig.push("state.reseed", fresh_entries("full", 101, 19_900)).await, TOO_LARGE);
    assert_eq!(rig.push("state.reseed", fresh_entries("full", 100, 19_900)).await, APPLIED);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_playlist_keeps_at_most_forty_thousand_entries_dead_ones_included() {
    let rig = Rig::new().await;
    rig.playlist_with_rows("graveyard", 100, 39_899).await;
    assert_eq!(rig.push("state.reseed", fresh_entries("graveyard", 2, 40_000)).await, TOO_LARGE);
    let many: Vec<Value> = (0..2).map(|index| json!({ "id": format!("many-{index}"), "ref": song(index) })).collect();
    let args = json!({ "playlist": "graveyard", "entries": many, "place": { "kind": "last" } });
    assert_eq!(rig.push("entry.insertMany", args).await, TOO_LARGE);
    let single = |id: &str| json!({ "id": id, "playlist": "graveyard", "ref": song(1), "place": { "kind": "last" } });
    assert_eq!(rig.push("entry.insert", single("last-one")).await, APPLIED);
    assert_eq!(rig.push("entry.insert", single("one-too-many")).await, TOO_LARGE);
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reseed_cannot_claim_a_stamp_from_the_future() {
    let rig = Rig::new().await;
    let squatting = scalar_entity("pref/theme", json!("dark"), false, i64::MAX);
    assert_eq!(rig.push("state.reseed", json!({ "entities": [squatting] })).await, APPLIED);
    let later = rig.later_wall_ms();
    assert_eq!(rig.push_at("scalar.set", json!({ "key": "pref/theme", "value": "light" }), later).await, APPLIED);
    assert_eq!(rig.entity("scalar", "pref/theme").await["value"], "light");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reseeded_playlist_cannot_pin_its_name_with_a_future_stamp() {
    let rig = Rig::new().await;
    let stamps = json!({ "name": i64::MAX, "cover": i64::MAX, "visibility": i64::MAX, "alive": i64::MAX });
    let playlist = json!({
        "kind": "playlist",
        "id": "pinned",
        "value": { "id": "pinned", "owner": "alice", "name": "Old", "coverBlob": null, "visibility": "private", "alive": true, "createdAt": 1, "stamps": stamps }
    });
    assert_eq!(rig.push("state.reseed", json!({ "entities": [playlist] })).await, APPLIED);
    let later = rig.later_wall_ms();
    assert_eq!(rig.push_at("playlist.rename", json!({ "id": "pinned", "name": "New" }), later).await, APPLIED);
    assert_eq!(rig.entity("playlist", "pinned").await["name"], "New");
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reseeded_tombstone_does_not_override_a_live_value_of_the_same_stamp() {
    let rig = Rig::new().await;
    assert_eq!(rig.push("scalar.set", json!({ "key": "pref/theme", "value": "dark" })).await, APPLIED);
    let live_stamp = (BASE_TIME_MS << 16) + 1;
    let same_stamp = scalar_entity("pref/theme", Value::Null, true, live_stamp);
    rig.push("state.reseed", json!({ "entities": [same_stamp] })).await;
    assert_eq!(rig.entity("scalar", "pref/theme").await["deleted"], false);
    let newer = scalar_entity("pref/theme", Value::Null, true, live_stamp + 5);
    assert_eq!(rig.push("state.reseed", json!({ "entities": [newer] })).await, APPLIED);
    assert_eq!(rig.entity("scalar", "pref/theme").await["deleted"], true);
}
