use crate::double::Double;
use crate::rig::{png, songs, Device};
use flaccy_library::server_sync::{
    ApiError, Backoff, Driver, ListensRequest, PullRequest, SyncState, TokenStore, Transport,
};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{Mutation, PushRequest};
use serde_json::json;
use sha2::{Digest, Sha256};

const ROUNDS: usize = 25;

fn signed_in(double: &Double) -> (Device, Transport) {
    let mut device = Device::new("cut", &songs(3));
    device.connect(double, "marcus");
    let playlist = device.db.create_playlist("Cut").unwrap();
    device
        .db
        .add_track_to_playlist(playlist, &songs(3)[0].path)
        .unwrap();
    device.play(&songs(3)[1], 1_700_000_000);
    device.sync();
    let token = TokenStore::new(device.dir.join("sync-token")).load();
    let transport = Transport::new(&double.url).with_token(token);
    (device, transport)
}

fn assert_cut_is_transient<T: std::fmt::Debug>(name: &str, outcome: Result<T, ApiError>) {
    match outcome {
        Err(error) => assert!(error.is_transient(), "{name}: {error:?}"),
        Ok(value) => panic!("{name}: a cut body was accepted: {value:?}"),
    }
}

#[test]
fn a_body_cut_at_a_random_length_is_a_transient_failure_on_every_endpoint() {
    let double = Double::start();
    let (device, transport) = signed_in(&double);
    let bytes = png();
    let hash = hex::encode(Sha256::digest(&bytes));
    let device_id = double.with(|state| state.model.store.playlists.len());
    assert_eq!(device_id, 1);
    for round in 0..ROUNDS {
        double.cut_responses("", 1);
        assert_cut_is_transient("hello", transport.hello());
        double.cut_responses("", 1);
        let pull = PullRequest {
            since: 0,
            limit: 100,
            instance: "cut".into(),
            incarnation: None,
        };
        assert_cut_is_transient("pull", transport.pull(&pull));
        double.cut_responses("", 1);
        let push = PushRequest {
            device: "device-1".into(),
            instance: format!("cut-{round}"),
            mutations: vec![Mutation {
                id: 1,
                name: "scalar.set".into(),
                stamp: Stamp::from_wall_ms(1_900_000_000_000),
                args: json!({ "key": "pref/x", "value": round }),
            }],
        };
        assert_cut_is_transient("push", transport.push(&push, None));
        double.cut_responses("", 1);
        let listens = ListensRequest {
            before: Some(4_000_000_000),
            after: None,
            limit: 100,
        };
        assert_cut_is_transient("listens", transport.listens(&listens, None));
        double.cut_responses("", 1);
        assert_cut_is_transient("devices", transport.devices());
        double.cut_responses("", 1);
        assert_cut_is_transient("blob", transport.put_blob(&hash, "image/png", &bytes));
        assert_eq!(double.cuts_left(), 0);
    }
    assert!(transport.hello().is_ok());
    assert!(transport.devices().is_ok());
    drop(device);
}

#[test]
fn a_push_whose_answer_was_cut_is_sent_again_with_the_same_ids_and_applies_once() {
    let double = Double::start();
    let library = songs(3);
    let mut device = Device::new("resend", &library);
    device.connect(&double, "marcus");
    device.sync();
    device.driver =
        Driver::new(TokenStore::new(device.dir.join("sync-token")), None).with_backoff(Backoff {
            base_ms: 0,
            max_ms: 0,
            attempts: 6,
        });
    let instance_before: String = device
        .raw()
        .query_row(
            "SELECT value FROM sync_meta WHERE key = 'instance'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let playlist = device.db.create_playlist("Once").unwrap();
    device
        .db
        .add_track_to_playlist(playlist, &library[0].path)
        .unwrap();
    device.db.set_loved(&library[1].path, true, None).unwrap();
    double.cut_responses("/sync/push", 2);
    let status = device.sync();
    assert_eq!(status.state, SyncState::UpToDate);
    assert_eq!(double.cuts_left(), 0);
    assert_eq!(double.with(|state| state.model.store.playlists.len()), 1);
    assert_eq!(double.with(|state| state.model.store.entries.len()), 1);
    assert_eq!(double.with(|state| state.model.store.loves.len()), 1);
    let instance_after: String = device
        .raw()
        .query_row(
            "SELECT value FROM sync_meta WHERE key = 'instance'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(instance_before, instance_after);
    assert!(double.with(|state| state.pushes) >= 3);
}

#[test]
fn a_cut_pull_shows_offline_and_the_next_round_catches_up() {
    let double = Double::start();
    let (mut device, _) = signed_in(&double);
    double.cut_responses("/sync/pull", 1);
    assert_eq!(device.driver.run_once(&device.db).state, SyncState::Offline);
    assert_eq!(device.sync().state, SyncState::UpToDate);
}

#[test]
fn a_complete_but_unreadable_answer_is_offline_twice_and_needs_attention_the_third_round() {
    let double = Double::start();
    let (mut device, transport) = signed_in(&double);
    double.set_garbage(true);
    assert!(matches!(transport.hello(), Err(ApiError::Malformed(_))));
    assert_eq!(device.driver.run_once(&device.db).state, SyncState::Offline);
    assert_eq!(device.driver.run_once(&device.db).state, SyncState::Offline);
    match device.driver.run_once(&device.db).state {
        SyncState::NeedsAttention(text) => assert!(text.contains("cannot read"), "{text}"),
        other => panic!("{other:?}"),
    }
    double.set_garbage(false);
    assert_eq!(device.sync().state, SyncState::UpToDate);
    double.set_garbage(true);
    assert_eq!(device.driver.run_once(&device.db).state, SyncState::Offline);
}

#[test]
fn a_content_length_longer_than_the_bytes_that_arrive_is_a_transient_failure() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = [0u8; 2048];
        let _ = stream.read(&mut request);
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 500\r\n\r\n{\"protocol\":[1]}")
            .unwrap();
    });
    let outcome = Transport::new(&url).hello();
    server.join().unwrap();
    assert_cut_is_transient("hello", outcome);
}
