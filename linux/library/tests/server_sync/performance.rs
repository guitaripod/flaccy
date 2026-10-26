use crate::double::{Double, StoredListen};
use crate::rig::{songs, Device};
use flaccy_library::server_sync::{Engine, PullOutcome, SyncState, TokenStore, Transport};
use flaccy_server_core::apply::Caller;
use flaccy_server_core::model::SongRef;
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{Mutation, PushRequest};
use serde_json::json;
use std::time::Instant;

const LISTENS: i64 = 165_000;

fn seeded_listens() -> Vec<StoredListen> {
    (0..LISTENS)
        .map(|n| StoredListen {
            seq: n + 1,
            event_id: format!("{n:024x}"),
            ts: 1_500_000_000 + n * 7,
            song: SongRef {
                song_key: format!("{n:032x}"),
                title: format!("Title {}", n % 3_000),
                artist: format!("Artist {}", n % 400),
                album: format!("Album {}", n % 900),
                duration_ms: 200_000,
                ..SongRef::default()
            },
            played_s: 180,
            recorded: false,
            suppressed: false,
            title_key: format!("title{}", n % 3_000),
            artist_key: format!("artist{}", n % 400),
        })
        .collect()
}

#[test]
#[ignore]
fn server_sync_backfill_of_165000_listens_finishes_inside_a_minute() {
    let double = Double::start();
    double.with(|state| state.listens.insert_raw(seeded_listens()));
    let mut device = Device::new("fresh", &[]);
    device.connect(&double, "marcus");
    let started = Instant::now();
    let status = device.sync();
    let elapsed = started.elapsed();
    let stored = device.db.scrobble_count();
    println!(
        "server_sync backfill: {stored} listens in {:.2}s ({:.0} listens/s)",
        elapsed.as_secs_f64(),
        stored as f64 / elapsed.as_secs_f64()
    );
    assert_eq!(status.state, SyncState::UpToDate);
    assert_eq!(stored, LISTENS);
    assert!(elapsed.as_secs() < 60);
}

fn seed_playlists(double: &Double, library: &[crate::rig::Song]) -> usize {
    let caller = Caller::member("marcus", "seeder");
    let mut mutations = Vec::new();
    let mut id = 0;
    let mut changes = 0;
    for playlist in 0..50 {
        id += 1;
        mutations.push(Mutation {
            id,
            name: "playlist.create".into(),
            stamp: Stamp::from_wall_ms(1_700_000_000_000 + id),
            args: json!({ "id": format!("p{playlist}"), "name": format!("List {playlist}") }),
        });
        changes += 1;
        let entries: Vec<_> = (0..99)
            .map(|n| {
                let song = &library[n % library.len()];
                json!({ "id": format!("e{playlist}-{n}"), "ref": { "songKey": flaccy_library::server_sync::song_key_of(&song.title, &song.artist),
                        "title": song.title, "artist": song.artist, "album": song.album, "durationMs": 200000 } })
            })
            .collect();
        id += 1;
        mutations.push(Mutation { id, name: "entry.insertMany".into(), stamp: Stamp::from_wall_ms(1_700_000_000_000 + id), args: json!({ "playlist": format!("p{playlist}"), "entries": entries, "place": { "kind": "last" } }) });
        changes += 99;
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
    changes
}

#[test]
#[ignore]
fn server_sync_applies_a_5000_change_page_in_under_500_ms() {
    let double = Double::start();
    let library = songs(300);
    let changes = seed_playlists(&double, &library);
    let mut device = Device::new("page", &library);
    device.connect(&double, "marcus");
    let mut engine = Engine::new();
    let tr = Transport::new(&double.url)
        .with_token(TokenStore::new(device.dir.join("sync-token")).load());
    let mut request = engine.pull_request(&device.db).unwrap();
    request.limit = 5_000;
    let page = tr.pull(&request).unwrap();
    assert_eq!(page.changes.len(), changes);
    let started = Instant::now();
    let outcome = engine.on_pull_page(&device.db, &request, &page, 0).unwrap();
    let elapsed = started.elapsed();
    println!(
        "server_sync page: {} changes applied in {} ms",
        page.changes.len(),
        elapsed.as_millis()
    );
    assert!(matches!(outcome, PullOutcome::Applied { more: false, .. }));
    assert_eq!(device.playlists().len(), 50);
    assert!(elapsed.as_millis() < 500);
}
