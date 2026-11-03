use crate::double::Double;
use crate::rig::{songs, Device};
use flaccy_library::db::LyricsContent;
use flaccy_library::server_sync::{
    clear_scalar, record_scalar, Backoff, Driver, ScalarSink, SyncState, TokenStore,
};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};

fn count(device: &Device, sql: &str) -> i64 {
    device.raw().query_row(sql, [], |row| row.get(0)).unwrap()
}

#[test]
fn recording_costs_nothing_while_no_server_is_configured() {
    let library = songs(2);
    let device = Device::new("plain", &library);
    let playlist = device.db.create_playlist("Local").unwrap();
    device
        .db
        .add_track_to_playlist(playlist, &library[0].path)
        .unwrap();
    device.db.set_loved(&library[1].path, true, None).unwrap();
    device.play(&library[0], 1_700_000_000);
    record_scalar(&device.db, "pref/x", json!(1)).unwrap();
    assert_eq!(count(&device, "SELECT COUNT(*) FROM sync_pending"), 0);
    assert_eq!(count(&device, "SELECT COUNT(*) FROM sync_meta"), 0);
    assert_eq!(
        count(
            &device,
            "SELECT COUNT(*) FROM playlists WHERE syncId IS NOT NULL"
        ),
        0
    );
    assert_eq!(
        count(
            &device,
            "SELECT COUNT(*) FROM scrobbles WHERE eventId IS NOT NULL"
        ),
        0
    );
    assert_eq!(
        device.driver.status(&device.db).state,
        SyncState::NeedsAttention(
            "No Flaccy Server is connected. Open a server link to connect.".into()
        )
    );
}

#[test]
fn plays_merge_into_queued_batches_of_at_most_200() {
    let double = Double::start();
    let library = songs(1);
    let mut device = Device::new("plays", &library);
    device.connect(&double, "marcus");
    for second in 0..450 {
        device.play(&library[0], 1_700_000_000 + second * 10);
    }
    let raw = device.raw();
    let mut stmt = raw
        .prepare(
            "SELECT args_json FROM sync_pending WHERE name = 'listen.record' ORDER BY mutation_id",
        )
        .unwrap();
    let sizes: Vec<usize> = stmt
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .map(|text| {
            serde_json::from_str::<Value>(&text.unwrap()).unwrap()["listens"]
                .as_array()
                .unwrap()
                .len()
        })
        .collect();
    assert_eq!(sizes, vec![200, 200, 50]);
    device.sync();
    assert_eq!(double.with(|state| state.listens.rows.len()), 450);
}

#[test]
fn suppressed_plays_stay_out_of_every_counter() {
    let double = Double::start();
    let library = songs(2);
    let mut device = Device::new("suppressed", &library);
    device.connect(&double, "marcus");
    device.play(&library[0], 1_700_000_000);
    device.play(&library[1], 1_700_000_100);
    assert_eq!(device.db.scrobble_count(), 2);
    device
        .raw()
        .execute(
            "UPDATE scrobbles SET suppressed = 1 WHERE trackTitle = 'Song 2'",
            [],
        )
        .unwrap();
    assert_eq!(device.db.scrobble_count(), 1);
    assert_eq!(device.db.fetch_all_scrobble_rows().len(), 1);
    assert_eq!(device.db.listen_counts_since(None).len(), 1);
    assert_eq!(device.db.scrobble_totals_between(0, 2_000_000_000).0, 1);
}

#[test]
fn the_ledger_hides_a_repeat_on_the_server_and_the_device_learns_it() {
    let double = Double::start();
    let library = songs(1);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    first.play(&library[0], 1_700_000_000);
    second.play(&library[0], 1_700_000_000);
    first.sync();
    second.sync();
    first.sync();
    assert_eq!(first.db.scrobble_count(), 1);
    assert_eq!(second.db.scrobble_count(), 1);
}

#[test]
fn the_device_token_never_reaches_the_database() {
    let double = Double::start();
    let mut device = Device::new("secret", &songs(1));
    device.connect(&double, "marcus");
    device.sync();
    let token = TokenStore::new(device.dir.join("sync-token"))
        .load()
        .unwrap();
    for name in ["library.sqlite", "library.sqlite-wal"] {
        let bytes = std::fs::read(device.dir.join(name)).unwrap_or_default();
        assert!(!String::from_utf8_lossy(&bytes).contains(&token), "{name}");
    }
    let mode = std::os::unix::fs::PermissionsExt::mode(
        &std::fs::metadata(device.dir.join("sync-token"))
            .unwrap()
            .permissions(),
    );
    assert_eq!(mode & 0o777, 0o600);
}

#[test]
fn a_lyrics_offset_follows_the_song_to_the_other_device() {
    let double = Double::start();
    let library = songs(1);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    let content = LyricsContent {
        synced: Some("[00:01.00]hi".into()),
        plain: None,
        lyricsfile: None,
        instrumental: false,
        revision: 1,
    };
    first
        .db
        .save_lyrics("Song 1", "The Artist", &content)
        .unwrap();
    first
        .db
        .save_lyrics_offset("Song 1", "The Artist", 250)
        .unwrap();
    first
        .db
        .save_lyrics_offset("Song 1", "The Artist", -50)
        .unwrap();
    first.sync();
    second
        .db
        .save_lyrics("Song 1", "The Artist", &content)
        .unwrap();
    second.sync();
    flaccy_library::server_sync::resolve_ghosts(&second.db).unwrap();
    assert_eq!(
        second
            .db
            .fetch_lyrics("Song 1", "The Artist")
            .unwrap()
            .offset_ms,
        250
    );
}

#[test]
fn a_song_volume_follows_the_song_to_the_other_device_and_back_to_zero() {
    let double = Double::start();
    let library = songs(2);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    assert_eq!(first.db.set_song_gain("Song 1", "The Artist", 35).unwrap(), 35);
    first.db.set_song_gain("Song 1", "The Artist", 35).unwrap();
    first.db.set_song_gain("Song 2", "The Artist", 0).unwrap();
    assert_eq!(count(&first, "SELECT COUNT(*) FROM sync_pending"), 1, "an unchanged level queues nothing");
    assert_eq!(first.db.set_song_gain("Song 2", "The Artist", -400).unwrap(), -120);
    first.sync();
    second.sync();
    assert_eq!(second.db.song_gain("Song 1", "The Artist").unwrap(), 35);
    assert_eq!(second.db.song_gain("Song 2", "The Artist").unwrap(), -120);
    assert_eq!(second.db.song_gain("Song 1", "Someone Else").unwrap(), 0);

    second.db.set_song_gain("Song 1", "The Artist", 0).unwrap();
    second.sync();
    first.sync();
    assert_eq!(first.db.song_gain("Song 1", "The Artist").unwrap(), 0);
    assert_eq!(first.db.song_gains().unwrap().len(), 1);
    assert_eq!(count(&first, "SELECT COUNT(*) FROM songGains"), 1);
}

#[test]
fn a_song_volume_set_before_connecting_reaches_the_other_device() {
    let double = Double::start();
    let library = songs(1);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.db.set_song_gain("Song 1", "The Artist", 60).unwrap();
    assert_eq!(count(&first, "SELECT COUNT(*) FROM sync_pending"), 0);
    let report = first.connect(&double, "marcus");
    assert_eq!(report.song_gains, 1);
    first.sync();
    second.connect(&double, "marcus");
    second.sync();
    assert_eq!(second.db.song_gain("Song 1", "The Artist").unwrap(), 60);
}

#[test]
fn a_later_song_volume_wins_over_an_imported_one() {
    let double = Double::start();
    let library = songs(1);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.db.set_song_gain("Song 1", "The Artist", 60).unwrap();
    second.connect(&double, "marcus");
    second.db.set_song_gain("Song 1", "The Artist", -15).unwrap();
    second.sync();
    first.connect(&double, "marcus");
    first.sync();
    second.sync();
    assert_eq!(first.db.song_gain("Song 1", "The Artist").unwrap(), -15);
    assert_eq!(second.db.song_gain("Song 1", "The Artist").unwrap(), -15);
}

#[derive(Default)]
struct Collected(Mutex<Vec<(String, Option<Value>)>>);

impl ScalarSink for Collected {
    fn apply(&self, key: &str, value: Option<&Value>) {
        self.0
            .lock()
            .unwrap()
            .push((key.to_owned(), value.cloned()));
    }
}

#[test]
fn settings_reach_the_sink_of_the_other_device() {
    let double = Double::start();
    let mut first = Device::new("a", &[]);
    let mut second = Device::new("b", &[]);
    let sink = Arc::new(Collected::default());
    second.driver = Driver::new(
        TokenStore::new(second.dir.join("sync-token")),
        Some(sink.clone()),
    )
    .with_backoff(Backoff::NONE);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    record_scalar(&first.db, "pref/home-layout", json!({ "rows": 3 })).unwrap();
    record_scalar(&first.db, "bogus/key", json!(1)).unwrap();
    first.sync();
    second.sync();
    clear_scalar(&first.db, "pref/home-layout").unwrap();
    first.sync();
    second.sync();
    let seen = sink.0.lock().unwrap().clone();
    assert_eq!(
        seen,
        vec![
            ("pref/home-layout".to_owned(), Some(json!({ "rows": 3 }))),
            ("pref/home-layout".to_owned(), None)
        ]
    );
}
