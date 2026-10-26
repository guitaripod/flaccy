use crate::double::Double;
use crate::rig::{song, songs, Device};
use flaccy_library::server_sync::SyncState;
use flaccy_server_core::digest::state_digest;

fn titles(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

fn server_digest(double: &Double) -> String {
    double.with(|state| state_digest(&state.model.store.entities()))
}

#[test]
fn two_devices_converge_on_playlists_entries_loves_and_listens() {
    let double = Double::start();
    let library = songs(5);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    let playlist = first.db.create_playlist("Road").unwrap();
    first
        .db
        .add_tracks_to_playlist(
            playlist,
            &[
                library[0].path.clone(),
                library[1].path.clone(),
                library[2].path.clone(),
            ],
        )
        .unwrap();
    first.db.set_loved(&library[3].path, true, None).unwrap();
    first.play(&library[0], 1_700_000_000);
    first.play(&library[1], 1_700_000_100);
    assert_eq!(first.sync().state, SyncState::UpToDate);
    second.connect(&double, "marcus");
    assert_eq!(second.sync().state, SyncState::UpToDate);
    assert_eq!(
        second.playlists()["Road"],
        titles(&["Song 1", "Song 2", "Song 3"])
    );
    assert_eq!(second.loved(), titles(&["Song 4"]));
    assert_eq!(second.db.scrobble_count(), 2);
    second.db.set_loved(&library[3].path, false, None).unwrap();
    let road = second.playlist_id("Road");
    let rows = second.db.playlist_tracks(road);
    second
        .db
        .reorder_playlist(road, &[rows[2].row_id, rows[0].row_id, rows[1].row_id])
        .unwrap();
    second.sync();
    first.sync();
    assert_eq!(
        first.playlists()["Road"],
        titles(&["Song 3", "Song 1", "Song 2"])
    );
    assert!(first.loved().is_empty());
}

#[test]
fn offline_edits_wait_and_arrive_after_reconnecting() {
    let double = Double::start();
    let library = songs(3);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    first.sync();
    second.sync();
    double.set_offline(true);
    let playlist = first.db.create_playlist("Later").unwrap();
    first
        .db
        .add_track_to_playlist(playlist, &library[1].path)
        .unwrap();
    let status = first.sync();
    assert_eq!(status.state, SyncState::Offline);
    assert!(status.pending >= 2);
    double.set_offline(false);
    assert_eq!(first.sync().state, SyncState::UpToDate);
    second.sync();
    assert_eq!(second.playlists()["Later"], titles(&["Song 2"]));
}

#[test]
fn a_rename_on_one_device_and_a_delete_on_the_other_leave_the_playlist_deleted_everywhere() {
    let double = Double::start();
    let library = songs(2);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    let playlist = first.db.create_playlist("Doomed").unwrap();
    first
        .db
        .add_track_to_playlist(playlist, &library[0].path)
        .unwrap();
    first.sync();
    second.sync();
    first
        .db
        .rename_playlist(first.playlist_id("Doomed"), "Renamed")
        .unwrap();
    second
        .db
        .delete_playlist(second.playlist_id("Doomed"))
        .unwrap();
    second.sync();
    first.sync();
    second.sync();
    assert!(first.playlists().is_empty());
    assert!(second.playlists().is_empty());
}

#[test]
fn a_copied_database_moves_to_a_new_instance_and_loses_nothing() {
    let double = Double::start();
    let library = songs(4);
    let mut original = Device::new("a", &library);
    original.connect(&double, "marcus");
    original.db.create_playlist("Base").unwrap();
    original.sync();
    let copy_dir = original.dir.join("copy");
    std::fs::create_dir_all(&copy_dir).unwrap();
    original
        .raw()
        .execute(
            "VACUUM INTO ?1",
            [copy_dir.join("library.sqlite").to_str().unwrap()],
        )
        .unwrap();
    let mut copy = Device::new("copy", &[]);
    copy.db = flaccy_library::db::Db::open(&copy_dir.join("library.sqlite")).unwrap();
    original.db.create_playlist("From original").unwrap();
    original.sync();
    copy.db.create_playlist("From copy").unwrap();
    copy.driver = flaccy_library::server_sync::Driver::new(
        flaccy_library::server_sync::TokenStore::new(original.dir.join("sync-token")),
        None,
    )
    .with_backoff(flaccy_library::server_sync::Backoff::NONE);
    assert_eq!(copy.sync().state, SyncState::UpToDate);
    original.sync();
    let names: Vec<String> = original.playlists().into_keys().collect();
    assert_eq!(names, titles(&["Base", "From copy", "From original"]));
    assert_eq!(copy.playlists().into_keys().collect::<Vec<_>>(), names);
}

#[test]
fn a_restored_server_with_a_new_incarnation_gets_the_clients_state_back() {
    let double = Double::start();
    let library = songs(4);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    first.db.create_playlist("Before").unwrap();
    first.sync();
    let saved = double.snapshot();
    let after = first.db.create_playlist("After backup").unwrap();
    first
        .db
        .add_track_to_playlist(after, &library[2].path)
        .unwrap();
    first.db.set_loved(&library[1].path, true, None).unwrap();
    first.play(&library[0], 1_700_000_500);
    first.sync();
    second.sync();
    double.restore(saved, "incarnation-2");
    assert_eq!(first.sync().state, SyncState::UpToDate);
    second.sync();
    first.sync();
    for device in [&first, &second] {
        assert_eq!(device.playlists()["After backup"], titles(&["Song 3"]));
        assert_eq!(device.loved(), titles(&["Song 2"]));
    }
    assert_eq!(double.with(|state| state.listens.rows.len()), 1);
}

#[test]
fn a_restore_that_keeps_the_incarnation_is_caught_by_the_cursor() {
    let double = Double::start();
    let library = songs(2);
    let mut first = Device::new("a", &library);
    first.connect(&double, "marcus");
    first.db.create_playlist("Kept").unwrap();
    first.sync();
    let saved = double.snapshot();
    first.db.create_playlist("Lost").unwrap();
    first.db.create_playlist("Lost too").unwrap();
    first.sync();
    double.restore(saved, "incarnation-1");
    assert_eq!(first.sync().state, SyncState::UpToDate);
    let names = double.with(|state| {
        state
            .model
            .store
            .playlists
            .values()
            .map(|p| p.name.clone())
            .collect::<Vec<_>>()
    });
    assert_eq!(names.len(), 3);
}

#[test]
fn an_entry_without_its_file_stays_hidden_until_the_file_appears() {
    let double = Double::start();
    let library = songs(3);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library[..2]);
    first.connect(&double, "marcus");
    let playlist = first.db.create_playlist("Mix").unwrap();
    first
        .db
        .add_tracks_to_playlist(
            playlist,
            &library.iter().map(|s| s.path.clone()).collect::<Vec<_>>(),
        )
        .unwrap();
    first.sync();
    second.connect(&double, "marcus");
    second.sync();
    assert_eq!(second.playlists()["Mix"], titles(&["Song 1", "Song 2"]));
    let ghosts: i64 = second
        .raw()
        .query_row("SELECT COUNT(*) FROM sync_ghosts", [], |row| row.get(0))
        .unwrap();
    assert_eq!(ghosts, 1);
    second.add_song(&library[2]);
    let dirty = flaccy_library::server_sync::resolve_ghosts(&second.db).unwrap();
    assert_eq!(dirty.playlists.len(), 1);
    assert_eq!(
        second.playlists()["Mix"],
        titles(&["Song 1", "Song 2", "Song 3"])
    );
    let ghosts: i64 = second
        .raw()
        .query_row("SELECT COUNT(*) FROM sync_ghosts", [], |row| row.get(0))
        .unwrap();
    assert_eq!(ghosts, 0);
}

#[test]
fn the_first_connect_import_is_idempotent() {
    let double = Double::start();
    let library = songs(3);
    let mut device = Device::new("a", &library);
    let playlist = device.db.create_playlist("Old").unwrap();
    device
        .db
        .add_tracks_to_playlist(
            playlist,
            &[
                library[0].path.clone(),
                library[0].path.clone(),
                library[1].path.clone(),
            ],
        )
        .unwrap();
    device.db.set_loved(&library[2].path, true, None).unwrap();
    device.play(&library[0], 1_600_000_000);
    let report = device.connect(&double, "marcus");
    assert_eq!(
        (
            report.playlists,
            report.entries,
            report.loves,
            report.listens
        ),
        (1, 3, 1, 1)
    );
    device.sync();
    let digest = server_digest(&double);
    let mut again = Device::new("again", &library);
    again.db = flaccy_library::db::Db::open(&device.dir.join("library.sqlite")).unwrap();
    again.driver = flaccy_library::server_sync::Driver::new(
        flaccy_library::server_sync::TokenStore::new(device.dir.join("sync-token-2")),
        None,
    )
    .with_backoff(flaccy_library::server_sync::Backoff::NONE);
    again.connect(&double, "marcus");
    again.sync();
    assert_eq!(server_digest(&double), digest);
    assert_eq!(double.with(|state| state.listens.rows.len()), 1);
    assert_eq!(
        again.playlists()["Old"],
        titles(&["Song 1", "Song 1", "Song 2"])
    );
}

#[test]
fn two_devices_importing_the_same_playlist_converge_without_duplicates() {
    let double = Double::start();
    let library = songs(4);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    let a = first.db.create_playlist("Road Trip").unwrap();
    first
        .db
        .add_tracks_to_playlist(
            a,
            &[
                library[0].path.clone(),
                library[1].path.clone(),
                library[2].path.clone(),
            ],
        )
        .unwrap();
    let b = second.db.create_playlist("  road trip ").unwrap();
    second
        .db
        .add_tracks_to_playlist(
            b,
            &[
                library[1].path.clone(),
                library[2].path.clone(),
                library[3].path.clone(),
            ],
        )
        .unwrap();
    first.db.set_loved(&library[0].path, true, None).unwrap();
    second.db.set_loved(&library[1].path, true, None).unwrap();
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    first.sync();
    second.sync();
    first.sync();
    second.sync();
    let first_list = first.playlists().into_values().next().unwrap();
    assert_eq!(first_list.len(), 4);
    assert_eq!(first.playlists().len(), 1);
    assert_eq!(first_list, second.playlists().into_values().next().unwrap());
    assert_eq!(first.loved(), titles(&["Song 1", "Song 2"]));
    assert_eq!(second.loved(), first.loved());
    let _ = song(1);
}
