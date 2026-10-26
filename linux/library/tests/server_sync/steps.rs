use crate::double::Double;
use crate::rig::{songs, Device};
use flaccy_library::server_sync::{
    Engine, PullOutcome, PushFailure, PushRecovery, TokenStore, Transport,
};
use flaccy_server_core::wire::MutationStatus;
use serde_json::json;

fn transport(double: &Double, device: &Device) -> Transport {
    Transport::new(&double.url).with_token(TokenStore::new(device.dir.join("sync-token")).load())
}

fn pending(device: &Device) -> i64 {
    device
        .raw()
        .query_row("SELECT COUNT(*) FROM sync_pending", [], |row| row.get(0))
        .unwrap()
}

fn inject(device: &Device, name: &str, args: serde_json::Value) {
    let raw = device.raw();
    let next: i64 = raw
        .query_row(
            "SELECT value FROM sync_meta WHERE key = 'next_mutation_id'",
            [],
            |row| row.get::<_, String>(0),
        )
        .unwrap()
        .parse()
        .unwrap();
    raw.execute(
        "INSERT INTO sync_pending (mutation_id, name, stamp, args_json, touches_json) VALUES (?1, ?2, ?3, ?4, '[]')",
        rusqlite::params![next, name, 1i64 << 40, args.to_string()],
    )
    .unwrap();
    raw.execute(
        "UPDATE sync_meta SET value = ?1 WHERE key = 'next_mutation_id'",
        [(next + 1).to_string()],
    )
    .unwrap();
}

#[test]
fn a_mutation_leaves_the_queue_only_on_the_final_page_of_a_pull() {
    let double = Double::start();
    let mut device = Device::new("a", &songs(1));
    device.connect(&double, "marcus");
    device.db.create_playlist("One").unwrap();
    device.db.create_playlist("Two").unwrap();
    let engine = Engine::new();
    let tr = transport(&double, &device);
    let request = engine.next_push(&device.db).unwrap().unwrap();
    let response = tr.push(&request, None).unwrap();
    engine
        .on_push_response(&device.db, &request.instance, &response, 0)
        .unwrap();
    assert_eq!(pending(&device), 2);
    let mut engine = engine;
    let mut first = engine.pull_request(&device.db).unwrap();
    first.limit = 1;
    let page = tr.pull(&first).unwrap();
    assert!(page.more);
    assert!(matches!(
        engine.on_pull_page(&device.db, &first, &page, 0).unwrap(),
        PullOutcome::Applied { more: true, .. }
    ));
    assert_eq!(pending(&device), 2);
    let mut second = engine.pull_request(&device.db).unwrap();
    second.limit = 1;
    let page = tr.pull(&second).unwrap();
    assert!(!page.more);
    engine.on_pull_page(&device.db, &second, &page, 0).unwrap();
    assert_eq!(pending(&device), 0);
    assert_eq!(
        engine.on_pull_page(&device.db, &second, &page, 0).unwrap(),
        PullOutcome::Stale
    );
    device.sync();
}

#[test]
fn refused_mutations_are_marked_failed_and_leave_the_visible_value_equal_to_the_base() {
    let double = Double::start();
    let mut device = Device::new("a", &songs(1));
    device.connect(&double, "marcus");
    device.db.create_playlist("Stable").unwrap();
    device.sync();
    let before = device.playlists();
    inject(&device, "future.thing", json!({}));
    inject(
        &device,
        "entry.move",
        json!({ "id": "missing", "place": { "kind": "first" } }),
    );
    inject(
        &device,
        "playlist.rename",
        json!({ "id": "nowhere", "name": "x" }),
    );
    let engine = Engine::new();
    let tr = transport(&double, &device);
    let request = engine.next_push(&device.db).unwrap().unwrap();
    assert_eq!(request.mutations.len(), 3);
    let response = tr.push(&request, None).unwrap();
    let statuses: Vec<MutationStatus> = response.results.iter().map(|r| r.status).collect();
    assert_eq!(
        statuses,
        vec![
            MutationStatus::Unsupported,
            MutationStatus::Invalid,
            MutationStatus::Invalid
        ]
    );
    engine
        .on_push_response(&device.db, &request.instance, &response, 0)
        .unwrap();
    let failed: i64 = device
        .raw()
        .query_row(
            "SELECT COUNT(*) FROM sync_pending WHERE failed = 1",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(failed, 3);
    assert_eq!(device.playlists(), before);
    assert_eq!(device.sync().pending, 0);
    assert_eq!(device.playlists(), before);
}

#[test]
fn a_gap_resends_from_what_the_server_has_and_a_gap_below_the_retired_resets() {
    let double = Double::start();
    let mut device = Device::new("a", &songs(1));
    device.connect(&double, "marcus");
    for name in ["A", "B", "C"] {
        device.db.create_playlist(name).unwrap();
    }
    let engine = Engine::new();
    let tr = transport(&double, &device);
    let request = engine.next_push(&device.db).unwrap().unwrap();
    let response = tr.push(&request, None).unwrap();
    engine
        .on_push_response(&device.db, &request.instance, &response, 0)
        .unwrap();
    assert_eq!(engine.unsent_count(&device.db).unwrap(), 0);
    assert_eq!(
        engine
            .on_push_error(
                &device.db,
                &request.instance,
                &PushFailure::MutationGap { have: 1 }
            )
            .unwrap(),
        PushRecovery::Resend
    );
    assert_eq!(engine.unsent_count(&device.db).unwrap(), 2);
    device.sync();
    device.db.create_playlist("D").unwrap();
    assert_eq!(
        engine
            .on_push_error(
                &device.db,
                &request.instance,
                &PushFailure::MutationGap { have: 0 }
            )
            .unwrap(),
        PushRecovery::Reset
    );
    assert_eq!(device.sync().pending, 0);
    assert_eq!(double.with(|state| state.model.store.playlists.len()), 4);
}
