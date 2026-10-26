use super::*;
use crate::remote::testing::{child_json, song_bytes, wait_until, FixtureServer};

struct Rig {
    base: PathBuf,
    remote: Arc<Remote>,
    fixture: FixtureServer,
    events: Arc<Mutex<Vec<RemoteEvent>>>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.base);
    }
}

fn rig(name: &str) -> Rig {
    let base = std::env::temp_dir().join(format!("flaccy-service-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let paths = Paths {
        config_dir: base.join("config"),
        cache_dir: base.join("cache"),
        data_dir: base.join("data"),
        db_path: base.join("data/library.sqlite"),
    };
    std::fs::create_dir_all(base.join("data")).unwrap();
    let remote = Remote::start(paths, u64::MAX).unwrap();
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&events);
    remote.set_listener(Arc::new(move |event| sink.lock().unwrap().push(event)));
    Rig {
        base,
        remote,
        fixture: FixtureServer::start(),
        events,
    }
}

fn add_fixture_server(rig: &Rig) -> String {
    let server = Server::new("Fixture", &rig.fixture.address(), "ana", "pw", false);
    let id = server.id.clone();
    rig.remote.add_server(server).unwrap();
    id
}

fn seed_songs(rig: &Rig, count: usize) {
    for index in 0..count {
        let id = format!("song-{index}");
        rig.fixture.put(&id, song_bytes(1_200_000 + index, index as u8));
        rig.fixture.add_child(child_json(&id, &format!("Title {index}"), "Album", index as i64 + 1, 1_200_000 + index));
    }
}

#[test]
fn adding_a_server_saves_it_privately_and_removing_it_clears_everything() {
    let rig = rig("lifecycle");
    seed_songs(&rig, 2);
    let id = add_fixture_server(&rig);
    let file = rig.base.join("config/servers.toml");
    let mode = std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&file).unwrap().permissions());
    assert_eq!(mode & 0o777, 0o600);

    let report = rig.remote.sync(&id, &|_| {}).unwrap();
    assert_eq!(report.applied.inserted, 2);
    let db = Db::open(&rig.base.join("data/library.sqlite")).unwrap();
    assert_eq!(db.fetch_all_tracks().len(), 2);
    let url = rig.remote.proxy_url(&format!("remote://{id}/song-0")).unwrap();
    assert!(url.starts_with(&format!("http://127.0.0.1:{}/", rig.remote.proxy_port())));
    let reply = crate::remote::testing::http_request(rig.remote.proxy_port(), "GET", &format!("/{id}/song-0"), None);
    assert_eq!(reply.status, 200);
    assert!(rig.remote.manager().is_complete(&format!("remote://{id}/song-0")));

    let removed = rig.remote.remove_server(&id).unwrap();
    assert_eq!(removed, 2);
    assert!(db.fetch_all_tracks().is_empty());
    assert!(rig.remote.servers().is_empty());
    assert!(!rig.base.join("cache/remote").join(&id).exists());
    assert!(!rig.remote.manager().is_complete(&format!("remote://{id}/song-0")));
}

#[test]
fn renaming_keeps_the_id_and_therefore_the_songs() {
    let rig = rig("rename");
    seed_songs(&rig, 1);
    let id = add_fixture_server(&rig);
    rig.remote.sync(&id, &|_| {}).unwrap();
    rig.remote.rename_server(&id, "Home Server").unwrap();
    assert_eq!(rig.remote.server_name(&id), "Home Server");
    let db = Db::open(&rig.base.join("data/library.sqlite")).unwrap();
    assert_eq!(db.fetch_all_tracks()[0].rel_path, format!("remote://{id}/song-0"));
}

#[test]
fn a_sync_stores_the_album_cover_once() {
    let rig = rig("covers");
    seed_songs(&rig, 3);
    let id = add_fixture_server(&rig);
    rig.remote.sync(&id, &|_| {}).unwrap();
    assert_eq!(rig.fixture.cover_requests(), 1);
    let db = Db::open(&rig.base.join("data/library.sqlite")).unwrap();
    assert!(db.fetch_album_artwork("Album", "Fixture Band").is_some());
    assert!(rig.events.lock().unwrap().iter().any(|event| matches!(event, RemoteEvent::CoversReady(_))));
    rig.remote.sync(&id, &|_| {}).unwrap();
    assert_eq!(rig.fixture.cover_requests(), 1);
}

#[test]
fn a_new_version_drops_the_cached_bytes_and_reports_the_song() {
    let rig = rig("newversion");
    seed_songs(&rig, 1);
    let id = add_fixture_server(&rig);
    rig.remote.sync(&id, &|_| {}).unwrap();
    let path = format!("remote://{id}/song-0");
    crate::remote::testing::http_request(rig.remote.proxy_port(), "GET", &format!("/{id}/song-0"), None);
    assert!(rig.remote.manager().is_complete(&path));
    rig.fixture.put("song-0", song_bytes(1_500_000, 99));
    rig.fixture.clear_catalog();
    rig.fixture.add_child(child_json("song-0", "Title 0", "Album", 1, 1_500_000));
    let report = rig.remote.sync(&id, &|_| {}).unwrap();
    assert_eq!(report.applied.new_versions, vec!["song-0".to_string()]);
    assert!(!rig.remote.manager().is_complete(&path));
    assert!(rig.events.lock().unwrap().contains(&RemoteEvent::NewVersions(vec![path])));
}

#[test]
fn a_kept_song_that_changes_on_the_server_is_downloaded_again_and_stays_kept() {
    let rig = rig("kept-new-version");
    seed_songs(&rig, 1);
    let id = add_fixture_server(&rig);
    rig.remote.sync(&id, &|_| {}).unwrap();
    let path = format!("remote://{id}/song-0");
    rig.remote.pin(std::slice::from_ref(&path));
    wait_until(|| rig.remote.is_downloaded(&path));
    let changed = song_bytes(1_500_000, 99);
    rig.fixture.put("song-0", changed.clone());
    rig.fixture.clear_catalog();
    rig.fixture.add_child(child_json("song-0", "Title 0", "Album", 1, 1_500_000));
    let report = rig.remote.sync(&id, &|_| {}).unwrap();
    assert_eq!(report.applied.new_versions, vec!["song-0".to_string()]);
    wait_until(|| rig.remote.is_downloaded(&path));
    assert!(rig.remote.is_pinned(&path));
    let kept = rig.base.join("data/remote").join(&id).join("song-0.flac");
    assert_eq!(std::fs::read(kept).unwrap(), changed);
}

#[test]
fn an_offline_server_dims_songs_that_are_not_on_this_computer() {
    let rig = rig("offline");
    seed_songs(&rig, 2);
    let id = add_fixture_server(&rig);
    rig.remote.sync(&id, &|_| {}).unwrap();
    let cached = format!("remote://{id}/song-0");
    let absent = format!("remote://{id}/song-1");
    crate::remote::testing::http_request(rig.remote.proxy_port(), "GET", &format!("/{id}/song-0"), None);
    assert_eq!(rig.remote.availability(&absent), Availability::Online);
    rig.fixture.go_offline();
    rig.remote.manager().set_reachable(&id, false);
    assert_eq!(rig.remote.availability(&cached), Availability::Cached);
    assert_eq!(rig.remote.availability(&absent), Availability::Offline);
    let message = rig.remote.unplayable_message(&absent, "Title 1").unwrap();
    assert_eq!(
        message,
        "“Title 1” isn't downloaded and Fixture can't be reached. Connect to the network or Tailscale and try again."
    );
    assert_eq!(rig.remote.unplayable_message(&cached, "Title 0"), None);
}

#[test]
fn keeping_songs_downloads_them_into_the_data_folder() {
    let rig = rig("keep");
    seed_songs(&rig, 2);
    let id = add_fixture_server(&rig);
    rig.remote.sync(&id, &|_| {}).unwrap();
    let paths: Vec<String> = (0..2).map(|index| format!("remote://{id}/song-{index}")).collect();
    rig.remote.pin(&paths);
    wait_until(|| paths.iter().all(|path| rig.remote.is_downloaded(path)));
    for index in 0..2 {
        let kept = rig.base.join("data/remote").join(&id).join(format!("song-{index}.flac"));
        assert_eq!(std::fs::read(kept).unwrap(), song_bytes(1_200_000 + index, index as u8));
    }
    rig.remote.unpin(&paths[..1]);
    assert!(!rig.remote.is_pinned(&paths[0]));
    assert!(rig.remote.is_downloaded(&paths[1]));
}

#[test]
fn scrobbles_and_stars_reach_the_server() {
    let rig = rig("state");
    seed_songs(&rig, 1);
    let id = add_fixture_server(&rig);
    let path = format!("remote://{id}/song-0");
    rig.remote.scrobble(&path, false);
    rig.remote.scrobble(&path, true);
    rig.remote.set_starred(&path, true);
    rig.remote.set_starred(&path, false);
    wait_until(|| rig.fixture.scrobbles().len() == 2 && rig.fixture.stars().len() == 2);
    let mut scrobbles = rig.fixture.scrobbles();
    scrobbles.sort();
    assert_eq!(scrobbles, vec![("song-0".to_string(), false), ("song-0".to_string(), true)]);
    let mut stars = rig.fixture.stars();
    stars.sort();
    assert_eq!(stars, vec![("song-0".to_string(), false), ("song-0".to_string(), true)]);
}

#[test]
fn a_second_sync_while_one_runs_is_refused() {
    let rig = rig("busy");
    seed_songs(&rig, 1);
    let id = add_fixture_server(&rig);
    rig.remote.syncing.lock().unwrap().insert(id.clone());
    assert_eq!(rig.remote.sync(&id, &|_| {}).unwrap_err(), SyncFailure::Busy);
}

#[test]
fn the_image_check_recognises_the_formats_covers_come_in() {
    assert!(looks_like_image(&[0xff, 0xd8, 0xff]));
    assert!(looks_like_image(&[0x89, b'P', b'N', b'G', 1]));
    assert!(!looks_like_image(b"<html>"));
}

#[test]
fn the_flaccy_servers_music_joins_as_one_marked_entry_and_leaves_with_its_songs() {
    use crate::server_sync::library;
    let rig = rig("flaccy-library");
    seed_songs(&rig, 2);
    let address = rig.fixture.address();
    assert!(library::attach(&rig.remote, "arch", &address, "tok").unwrap());
    assert!(!library::attach(&rig.remote, "arch", &address, "tok").unwrap());
    assert_eq!(rig.remote.servers().len(), 1);
    let server = library::find(&rig.remote).unwrap();
    assert!(server.flaccy_server && server.uses_api_key());
    rig.remote.sync(&server.id, &|_| {}).unwrap();
    let saved = std::fs::read_to_string(rig.base.join("config/servers.toml")).unwrap();
    assert!(saved.contains("flaccy_server = true"));
    assert_eq!(library::detach(&rig.remote).unwrap(), 2);
    assert!(library::find(&rig.remote).is_none());
    assert_eq!(library::detach(&rig.remote).unwrap(), 0);
}

#[test]
fn another_token_replaces_the_entry_and_another_name_only_renames_it() {
    use crate::server_sync::library;
    let rig = rig("flaccy-library-replace");
    let address = rig.fixture.address();
    library::attach(&rig.remote, "arch", &address, "tok").unwrap();
    let first = library::find(&rig.remote).unwrap().id;
    assert!(!library::attach(&rig.remote, "Arch Box", &address, "tok").unwrap());
    let renamed = library::find(&rig.remote).unwrap();
    assert_eq!((renamed.id.as_str(), renamed.name.as_str()), (first.as_str(), "Arch Box"));
    assert!(library::attach(&rig.remote, "Arch Box", &address, "other").unwrap());
    assert_ne!(library::find(&rig.remote).unwrap().id, first);
    assert_eq!(rig.remote.servers().len(), 1);
}

#[test]
fn plays_and_loves_of_the_flaccy_servers_music_are_left_to_the_sync() {
    use crate::server_sync::library;
    let rig = rig("flaccy-library-quiet");
    seed_songs(&rig, 2);
    library::attach(&rig.remote, "arch", &rig.fixture.address(), "tok").unwrap();
    let flaccy = library::find(&rig.remote).unwrap().id;
    let regular = add_fixture_server(&rig);
    rig.remote.scrobble(&format!("remote://{flaccy}/song-0"), true);
    rig.remote.set_starred(&format!("remote://{flaccy}/song-0"), true);
    rig.remote.scrobble(&format!("remote://{regular}/song-1"), true);
    rig.remote.set_starred(&format!("remote://{regular}/song-1"), true);
    wait_until(|| !rig.fixture.scrobbles().is_empty() && !rig.fixture.stars().is_empty());
    let scrobbled: Vec<String> = rig.fixture.scrobbles().into_iter().map(|(song, _)| song).collect();
    let starred: Vec<String> = rig.fixture.stars().into_iter().map(|(song, _)| song).collect();
    assert_eq!((scrobbled, starred), (vec!["song-1".to_string()], vec!["song-1".to_string()]));
}

#[test]
fn a_server_that_refuses_the_key_is_unreachable_and_asked_again_only_now_and_then() {
    use crate::server_sync::library;
    let rig = rig("flaccy-library-refused");
    let address = rig.fixture.address();
    library::attach(&rig.remote, "arch", &address, "revoked").unwrap();
    let id = library::find(&rig.remote).unwrap().id;
    rig.fixture.reject_logins();
    rig.remote.ping_all(0);
    assert!(!rig.remote.manager().is_reachable(&id));
    assert!(rig.remote.is_refused(&id));
    rig.remote.manager().set_reachable(&id, true);
    rig.remote.ping_all(1);
    assert!(rig.remote.manager().is_reachable(&id));
    rig.remote.ping_all(REFUSED_PING_EVERY);
    assert!(!rig.remote.manager().is_reachable(&id));
}
