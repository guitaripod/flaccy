use crate::double::Double;
use crate::rig::{songs, Device};
use flaccy_library::server_sync::{
    song_key_of, Backoff, Blocker, Driver, MergeReport, SyncState, TokenStore,
};
use std::time::Duration;

fn titles(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).to_owned()).collect()
}

fn key_of(number: u32) -> String {
    let entry = crate::rig::song(number);
    song_key_of(&entry.title, &entry.artist)
}

struct Overlap {
    double: Double,
    second: Device,
    report: MergeReport,
}

fn overlap() -> Overlap {
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
    first.db.set_loved(&library[0].path, true, None).unwrap();
    first.connect(&double, "marcus");
    first.sync();
    let b = second.db.create_playlist("road trip").unwrap();
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
    second.db.set_loved(&library[1].path, true, None).unwrap();
    second.connect(&double, "marcus");
    second.sync();
    let report = second.driver.take_merge().expect("a merge happened");
    Overlap {
        double,
        second,
        report,
    }
}

#[test]
fn the_first_connect_reports_the_playlists_and_loves_it_combined() {
    let rig = overlap();
    assert_eq!(rig.report.playlists.len(), 1);
    let merged = &rig.report.playlists[0];
    assert_eq!(merged.name, "Road Trip");
    assert_eq!(rig.report.loves, vec![key_of(1)]);
    assert_eq!(rig.second.loved(), titles(&["Song 1", "Song 2"]));
    assert!(rig.double.with(|state| state.pushes) > 0);
}

#[test]
fn the_report_is_given_once() {
    let mut rig = overlap();
    rig.second.sync();
    assert!(rig.second.driver.take_merge().is_none());
}

#[test]
fn a_connect_that_combined_nothing_reports_nothing() {
    let double = Double::start();
    let library = songs(3);
    let mut empty = Device::new("a", &library);
    empty.connect(&double, "marcus");
    empty.sync();
    let mut device = Device::new("b", &library);
    let playlist = device.db.create_playlist("Only Mine").unwrap();
    device
        .db
        .add_tracks_to_playlist(playlist, &[library[0].path.clone()])
        .unwrap();
    device.connect(&double, "marcus");
    device.sync();
    assert!(device.driver.take_merge().is_none());
}

#[test]
fn a_server_that_leaves_protocol_one_pauses_sync_with_the_right_words_and_resumes() {
    let double = Double::start();
    let library = songs(1);
    let mut device = Device::new("a", &library);
    device.driver = Driver::new(TokenStore::new(device.dir.join("sync-token")), None)
        .with_backoff(Backoff::NONE)
        .with_version_recheck(Duration::ZERO);
    device.connect(&double, "marcus");
    assert_eq!(device.sync().state, SyncState::UpToDate);
    double.with(|state| state.protocol = vec![2]);
    assert_eq!(
        device.driver.run_once(&device.db).state,
        SyncState::Blocked(Blocker::AppTooOld)
    );
    double.with(|state| state.protocol = Vec::new());
    assert_eq!(
        device.driver.run_once(&device.db).state,
        SyncState::Blocked(Blocker::ServerTooOld)
    );
    double.with(|state| state.protocol = vec![1]);
    assert_eq!(
        device.driver.run_once(&device.db).state,
        SyncState::UpToDate
    );
}

#[test]
fn a_full_server_disk_is_a_blocker_that_clears_when_space_is_back() {
    let double = Double::start();
    let library = songs(2);
    let mut device = Device::new("a", &library);
    device.connect(&double, "marcus");
    device.sync();
    device.db.set_loved(&library[0].path, true, None).unwrap();
    double.with(|state| state.disk_full = true);
    let blocked = device.driver.run_once(&device.db);
    assert_eq!(blocked.state, SyncState::Blocked(Blocker::DiskFull));
    assert_eq!(blocked.pending, 1);
    assert_eq!(double.with(|state| state.pushes), 0);
    double.with(|state| state.disk_full = false);
    assert_eq!(device.sync().state, SyncState::UpToDate);
}

#[test]
fn devices_are_renamed_and_removed_through_the_driver() {
    let double = Double::start();
    let library = songs(1);
    let mut first = Device::new("a", &library);
    let mut second = Device::new("b", &library);
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    let listed = first.driver.devices(&first.db).unwrap();
    assert_eq!(listed.len(), 2);
    let current = listed.iter().find(|device| device.current).unwrap();
    first
        .driver
        .rename_device(&first.db, &current.id, "Desk")
        .unwrap();
    let other = first
        .driver
        .devices(&first.db)
        .unwrap()
        .into_iter()
        .find(|device| !device.current)
        .unwrap();
    first.driver.remove_device(&first.db, &other.id).unwrap();
    let after = first.driver.devices(&first.db).unwrap();
    assert_eq!(after.len(), 1);
    assert_eq!(after[0].name, "Desk");
    assert_eq!(
        second.driver.run_once(&second.db).state,
        SyncState::Blocked(Blocker::DeviceRevoked)
    );
}
