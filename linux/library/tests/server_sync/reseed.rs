use crate::double::{Double, ListenStore};
use crate::rig::{png, songs, Device};
use flaccy_server_core::apply::Caller;
use flaccy_server_core::sim::server::Snapshot;
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{Mutation, PushRequest};
use serde_json::json;
use sha2::{Digest, Sha256};

const PLAYLISTS: usize = 50;
const ENTRIES_EACH: usize = 100;

fn seed_big_base(double: &Double, user: &str) {
    let caller = Caller::member(user, "seeder");
    let mut mutations = Vec::new();
    for playlist in 0..PLAYLISTS {
        let id = mutations.len() as i64 + 1;
        mutations.push(Mutation {
            id,
            name: "playlist.create".into(),
            stamp: Stamp::from_wall_ms(1_700_000_000_000 + id),
            args: json!({ "id": format!("p{playlist:02}"), "name": format!("List {playlist}") }),
        });
        let entries: Vec<_> = (0..ENTRIES_EACH)
            .map(|n| {
                json!({ "id": format!("e{playlist:02}-{n:03}"), "ref": {
                    "songKey": format!("{:032x}", playlist * 1000 + n),
                    "title": format!("Title {playlist} {n}"), "artist": "Artist",
                    "album": format!("Album {}", "x".repeat(450)), "durationMs": 200000 } })
            })
            .collect();
        let id = mutations.len() as i64 + 1;
        mutations.push(Mutation {
            id,
            name: "entry.insertMany".into(),
            stamp: Stamp::from_wall_ms(1_700_000_000_000 + id),
            args: json!({ "playlist": format!("p{playlist:02}"), "entries": entries, "place": { "kind": "last" } }),
        });
    }
    double.with(|state| {
        let request = PushRequest {
            device: "seeder".into(),
            instance: "seed".into(),
            mutations,
        };
        state
            .model
            .push(&caller, &request, 1_700_000_100_000)
            .unwrap();
    });
}

#[test]
fn a_reset_over_a_base_of_5000_entities_and_3_megabytes_is_sent_in_reseeds_within_the_limits() {
    let double = Double::start();
    let empty = double.snapshot();
    seed_big_base(&double, "marcus");
    let mut device = Device::new("big", &songs(3));
    device.connect(&double, "marcus");
    device.sync();
    assert_eq!(
        double.with(|state| state.model.store.entries.len()),
        PLAYLISTS * ENTRIES_EACH
    );
    double.restore(empty, "incarnation-2");
    double.with(|state| state.reseeds.clear());
    let status = device.sync();
    assert_eq!(
        status.state,
        flaccy_library::server_sync::SyncState::UpToDate
    );
    let sent = double.with(|state| state.reseeds.clone());
    let entities: usize = sent.iter().map(|(count, _)| count).sum();
    let bytes: usize = sent.iter().map(|(_, size)| size).sum();
    assert_eq!(entities, PLAYLISTS + PLAYLISTS * ENTRIES_EACH);
    assert!(bytes >= 3_000_000, "{bytes}");
    assert!(sent.len() >= 8, "{}", sent.len());
    assert!(
        sent.iter()
            .all(|(count, size)| *count <= 1_000 && *size <= 400_000),
        "{sent:?}"
    );
    assert_eq!(
        double.with(|state| state.model.store.entries.len()),
        PLAYLISTS * ENTRIES_EACH
    );
    assert_eq!(
        double.with(|state| state.model.store.playlists.len()),
        PLAYLISTS
    );
}

fn covered_playlist(
    double: &Double,
    keep_local_copy: bool,
) -> (Device, String, (Snapshot, ListenStore)) {
    let empty = double.snapshot();
    let mut device = Device::new("cover", &songs(2));
    device.connect(double, "marcus");
    let local = device.db.create_playlist("Covered").unwrap();
    device.sync();
    let bytes = png();
    let hash = hex::encode(Sha256::digest(&bytes));
    if keep_local_copy {
        device.db.set_playlist_cover(local, &bytes).unwrap();
    }
    let caller = Caller::member("marcus", "seeder");
    let id = device.sync_id("Covered");
    double.with(|state| {
        let mutation = Mutation {
            id: 1,
            name: "playlist.setCover".into(),
            stamp: Stamp::from_wall_ms(1_900_000_000_000),
            args: json!({ "id": id, "blob": hash }),
        };
        let request = PushRequest {
            device: "seeder".into(),
            instance: "seed".into(),
            mutations: vec![mutation],
        };
        state
            .model
            .push(&caller, &request, 1_900_000_000_000)
            .unwrap();
        state.blobs.insert(hash.clone(), bytes);
    });
    device.sync();
    double.with(|state| state.blobs.clear());
    (device, hash, empty)
}

fn cover_of(double: &Double) -> Option<String> {
    double.with(|state| {
        state
            .model
            .store
            .playlists
            .values()
            .next()
            .and_then(|p| p.cover_blob.clone())
    })
}

#[test]
fn a_reseeded_cover_is_uploaded_from_the_local_copy_first() {
    let double = Double::start();
    let (mut device, hash, empty) = covered_playlist(&double, true);
    double.restore(empty, "incarnation-2");
    assert_eq!(
        device.sync().state,
        flaccy_library::server_sync::SyncState::UpToDate
    );
    assert!(double.with(|state| state.blobs.contains_key(&hash)));
    assert_eq!(cover_of(&double), Some(hash));
}

#[test]
fn a_cover_without_a_local_copy_is_reseeded_without_its_picture() {
    let double = Double::start();
    let (mut device, _, empty) = covered_playlist(&double, false);
    double.restore(empty, "incarnation-2");
    assert_eq!(
        device.sync().state,
        flaccy_library::server_sync::SyncState::UpToDate
    );
    assert_eq!(double.with(|state| state.model.store.playlists.len()), 1);
    assert_eq!(cover_of(&double), None);
}

#[test]
fn a_reseed_refused_for_a_cover_the_new_server_lacks_uploads_again_and_is_retried_once() {
    let double = Double::start();
    let (mut device, hash, empty) = covered_playlist(&double, true);
    double.restore(empty, "incarnation-2");
    double.with(|state| state.forget_next_blob = true);
    assert_eq!(
        device.sync().state,
        flaccy_library::server_sync::SyncState::UpToDate
    );
    assert!(double.with(|state| state.blobs.contains_key(&hash)));
    assert_eq!(cover_of(&double), Some(hash));
    assert_eq!(device.playlists().len(), 1);
}
