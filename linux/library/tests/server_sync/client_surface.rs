use crate::double::Double;
use crate::rig::{songs, Device};
use flaccy_library::server_sync::{
    files_for_loves, ApiError, Dirty, Driver, ServerLink, SyncError, TokenStore,
};
use std::sync::{Arc, Mutex};

#[test]
fn a_wrong_code_is_refused_with_the_unauthorized_error_not_a_string() {
    let double = Double::start();
    let mut device = Device::new("wrong-code", &songs(1));
    let link = ServerLink::new(&double.url, Some("NOSUCHCODE"), None);
    let outcome = device.driver.enroll(&device.db, &link, "Test device");
    assert!(matches!(
        outcome,
        Err(SyncError::Api(ApiError::Unauthorized))
    ));
}

#[test]
fn an_address_nobody_answers_is_offline() {
    let device = Device::new("nobody", &songs(1));
    let outcome = device.driver.probe("http://127.0.0.1:9");
    assert!(matches!(outcome, Err(SyncError::Api(ApiError::Offline(_)))));
}

#[test]
fn probing_a_flaccy_server_names_it() {
    let double = Double::start();
    let device = Device::new("probe", &songs(1));
    let identity = device.driver.probe(&double.url).unwrap();
    assert_eq!(identity.name, "double");
}

#[test]
fn a_server_that_is_not_flaccy_is_malformed_or_refused() {
    let page = Double::start();
    let device = Device::new("not-flaccy", &songs(1));
    let outcome = device.driver.probe(&format!("{}/nowhere", page.url));
    assert!(matches!(
        outcome,
        Err(SyncError::Api(
            ApiError::Refused { .. } | ApiError::Malformed(_)
        ))
    ));
}

#[test]
fn the_devices_call_lists_this_device_as_current() {
    let double = Double::start();
    let mut first = Device::new("devices-a", &songs(1));
    let mut second = Device::new("devices-b", &songs(1));
    first.connect(&double, "marcus");
    second.connect(&double, "marcus");
    let listed = first.driver.devices(&first.db).unwrap();
    assert_eq!(listed.len(), 2);
    assert_eq!(listed.iter().filter(|device| device.current).count(), 1);
}

#[test]
fn the_dirty_listener_hears_each_applied_page() {
    let double = Double::start();
    let library = songs(3);
    let mut writer = Device::new("listener-w", &library);
    let mut reader = Device::new("listener-r", &library);
    writer.connect(&double, "marcus");
    let playlist = writer.db.create_playlist("Road").unwrap();
    writer
        .db
        .add_tracks_to_playlist(playlist, &[library[0].path.clone()])
        .unwrap();
    writer.sync();
    reader.connect(&double, "marcus");
    let heard: Arc<Mutex<Vec<Dirty>>> = Arc::default();
    let sink = Arc::clone(&heard);
    reader
        .driver
        .on_dirty(move |dirty| sink.lock().unwrap().push(dirty.clone()));
    reader.sync();
    let heard = heard.lock().unwrap();
    assert!(heard.iter().any(|dirty| !dirty.playlists.is_empty()));
}

#[test]
fn the_files_behind_a_pulled_love_are_found() {
    let double = Double::start();
    let library = songs(3);
    let mut writer = Device::new("loves-w", &library);
    let mut reader = Device::new("loves-r", &library);
    writer.connect(&double, "marcus");
    writer.db.set_loved(&library[1].path, true, None).unwrap();
    writer.sync();
    reader.connect(&double, "marcus");
    let heard: Arc<Mutex<Vec<Dirty>>> = Arc::default();
    let sink = Arc::clone(&heard);
    reader
        .driver
        .on_dirty(move |dirty| sink.lock().unwrap().push(dirty.clone()));
    reader.sync();
    let keys = heard
        .lock()
        .unwrap()
        .iter()
        .flat_map(|dirty| dirty.loves.clone())
        .collect();
    let files = files_for_loves(&reader.db, &keys).unwrap();
    assert_eq!(files, vec![(library[1].path.clone(), true)]);
}

#[test]
fn a_driver_with_no_server_has_no_devices() {
    let driver = Driver::new(
        TokenStore::new(std::env::temp_dir().join("flaccy-none")),
        None,
    );
    let device = Device::new("none", &songs(1));
    assert!(matches!(
        driver.devices(&device.db),
        Err(SyncError::NotConfigured)
    ));
}
