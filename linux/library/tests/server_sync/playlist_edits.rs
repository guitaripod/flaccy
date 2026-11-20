use crate::double::Double;
use crate::rig::{songs, Device};
use flaccy_library::server_sync::SyncState;
use flaccy_shared::playlist_editing;
use std::collections::HashSet;

fn titles(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

#[test]
fn removed_songs_come_back_where_they_stood_on_every_device() {
    let double = Double::start();
    let library = songs(5);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    let paths: Vec<String> = library.iter().map(|song| song.path.clone()).collect();
    let playlist = first.db.create_playlist_with_tracks("Mix", &paths).unwrap();
    assert_eq!(first.sync().state, SyncState::UpToDate);
    second.sync();
    let rows = first.db.playlist_tracks(playlist);
    let removed = first
        .db
        .remove_playlist_entries(playlist, &[rows[3].row_id, rows[0].row_id])
        .unwrap();
    assert_eq!(removed.iter().map(|entry| entry.index).collect::<Vec<_>>(), vec![0, 3]);
    first.sync();
    second.sync();
    assert_eq!(second.playlists()["Mix"], titles(&["Song 2", "Song 3", "Song 5"]));
    first.db.restore_playlist_entries(playlist, &removed).unwrap();
    first.sync();
    second.sync();
    let all = titles(&["Song 1", "Song 2", "Song 3", "Song 4", "Song 5"]);
    assert_eq!(first.playlists()["Mix"], all);
    assert_eq!(second.playlists()["Mix"], all);
}

#[test]
fn one_dragged_row_reaches_the_other_device_in_its_new_place() {
    let double = Double::start();
    let library = songs(5);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    let paths: Vec<String> = library.iter().map(|song| song.path.clone()).collect();
    let playlist = first.db.create_playlist_with_tracks("Mix", &paths).unwrap();
    first.sync();
    second.sync();
    let ids: Vec<i64> = first.db.playlist_tracks(playlist).iter().map(|row| row.row_id).collect();
    let order = playlist_editing::moved(&ids, &HashSet::from([ids[0]]), playlist_editing::insertion_index(0, 3));
    first.db.reorder_playlist(playlist, &order).unwrap();
    first.sync();
    second.sync();
    assert_eq!(second.playlists()["Mix"], titles(&["Song 2", "Song 3", "Song 4", "Song 1", "Song 5"]));
}

#[test]
fn an_addition_skips_what_the_playlist_holds_and_a_copy_keeps_the_order() {
    let double = Double::start();
    let library = songs(3);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    let path = |index: usize| library[index].path.clone();
    let playlist = first.db.create_playlist_with_tracks("Mix", &[path(2), path(2)]).unwrap();
    let addition = first
        .db
        .add_missing_tracks_to_playlist(playlist, &[path(0), path(2), path(1), path(0)])
        .unwrap();
    assert_eq!(addition.added, vec![path(0), path(1)]);
    assert_eq!(addition.already_in, vec![path(2)]);
    assert_eq!(first.db.playlists_containing(&path(1)), HashSet::from([playlist]));
    let copy = first.db.duplicate_playlist(playlist, "Mix Copy").unwrap();
    assert_ne!(copy, playlist);
    first.sync();
    second.sync();
    assert_eq!(second.playlists()["Mix"], titles(&["Song 3", "Song 1", "Song 2"]));
    assert_eq!(second.playlists()["Mix Copy"], titles(&["Song 3", "Song 1", "Song 2"]));
}
