//! The OpenSubsonic writes land in the sync state as the mutations a device would push.

use flaccy_library::server_sync::song_key_of;
use flaccy_server_core::model::{EntityKind, Source};
use flaccy_server_core::song::event_id_rec;
use serde_json::Value;

use super::TestServer;
use crate::credentials;
use crate::security::{Role, UserId};
use crate::sync::Store;

pub async fn owner(server: &TestServer) -> UserId {
    server.state.0.security.owner().await.unwrap().unwrap().id
}

async fn member_with_key(server: &TestServer, name: &str, role: Role) -> (UserId, String) {
    let security = &server.state.0.security;
    let user = security.create_user(name, role).await.unwrap().id;
    let (_, key) = security.create_api_key(&user, "phone").await.unwrap();
    (user, key)
}

async fn call_as(server: &TestServer, key: &str, method: &str, query: &str) -> Value {
    let reply = server.get(&format!("/rest/{method}?apiKey={key}&f=json&c=tablet&{query}")).await;
    let body: Value = serde_json::from_slice(&reply.body).unwrap();
    body["subsonic-response"].clone()
}

fn titles(playlist: &Value) -> Vec<&str> {
    playlist["entry"]
        .as_array()
        .map(|entries| entries.iter().map(|entry| entry["title"].as_str().unwrap()).collect())
        .unwrap_or_default()
}

fn sync(server: &TestServer) -> &Store {
    &server.state.0.sync
}

#[tokio::test]
async fn a_star_is_a_love_with_the_song_as_the_library_knows_it() {
    let server = TestServer::new().await;
    server.standard_library();
    let id = server.song_id("Middle").await;
    server.json("star", &format!("id={id}")).await.ok();

    let key = song_key_of("Middle", "Drill Band");
    let user = owner(&server).await;
    let love = sync(&server).entity(&user, EntityKind::Love, &key).await.unwrap().unwrap();
    assert!(!love.deleted);
    assert_eq!(love.value["loved"], true);
    let song = &love.value["ref"];
    assert_eq!(song["songKey"], key);
    assert_eq!(song["title"], "Middle");
    assert_eq!(song["artist"], "Drill Band");
    assert_eq!(song["album"], "Rough Cuts");
    assert_eq!(song["durationMs"], 1000);
    assert_eq!(song["relPath"], "Drill Band/Rough Cuts/02 Middle.wav");
    assert!(song["fp"].as_str().unwrap().starts_with("sha256:"));

    server.json("unstar", &format!("id={id}")).await.ok();
    let gone = sync(&server).entity(&user, EntityKind::Love, &key).await.unwrap().unwrap();
    assert!(gone.deleted);
    assert!(server.json("getStarred2", "").await.ok().raw["starred2"].get("song").is_none());
}

#[tokio::test]
async fn a_rating_is_a_rating_and_zero_clears_it() {
    let server = TestServer::new().await;
    server.standard_library();
    let id = server.song_id("Glow").await;
    server.json("setRating", &format!("id={id}&rating=5")).await.ok();
    let key = song_key_of("Glow", "The Echo");
    let user = owner(&server).await;
    let rated = sync(&server).entity(&user, EntityKind::Rating, &key).await.unwrap().unwrap();
    assert_eq!(rated.value["rating"], 5);
    assert_eq!(rated.value["ref"]["title"], "Glow");

    server.json("setRating", &format!("id={id}&rating=0")).await.ok();
    let cleared = sync(&server).entity(&user, EntityKind::Rating, &key).await.unwrap().unwrap();
    assert!(cleared.deleted && cleared.value["rating"].is_null());
}

#[tokio::test]
async fn a_scrobble_is_an_opensubsonic_listen_numbered_by_the_logins_counter() {
    let server = TestServer::new().await;
    server.standard_library();
    let opening = server.song_id("Opening").await;
    let glow = server.song_id("Glow").await;
    server.json("scrobble", &format!("id={opening}&time=1700000000000")).await.ok();
    server.json("scrobble", &format!("id={glow}&time=1700000100000&id={opening}&time=1700000200000")).await.ok();
    server.json("scrobble", &format!("id={opening}&submission=false")).await.ok();

    let user = owner(&server).await;
    let device = format!("pw-{user}");
    let page = sync(&server).listens_after(&user, 0, 50).await.unwrap();
    assert_eq!(page.listens.len(), 3, "now playing stores nothing");
    let plays: Vec<(i64, &str)> = page.listens.iter().map(|row| (row.listen.ts, row.listen.song.title.as_str())).collect();
    assert_eq!(plays, vec![(1_700_000_000, "Opening"), (1_700_000_100, "Glow"), (1_700_000_200, "Opening")]);
    for (index, row) in page.listens.iter().enumerate() {
        assert_eq!(row.listen.event_id, event_id_rec(&device, "rest", index as u64 + 1));
        assert_eq!(row.listen.source, Source::Opensubsonic);
        assert!(row.listen.recorded && !row.listen.suppressed);
        assert_eq!(row.listen.device.as_deref(), Some(device.as_str()));
        assert_eq!(row.listen.played_s, 1);
    }
}

#[tokio::test]
async fn two_api_keys_of_one_user_write_as_two_devices_with_their_own_counters() {
    let server = TestServer::new().await;
    server.standard_library();
    let user = owner(&server).await;
    let security = &server.state.0.security;
    let (tablet, tablet_key) = security.create_api_key(&user, "tablet").await.unwrap();
    let opening = server.song_id("Opening").await;
    let glow = server.song_id("Glow").await;

    let phone = &server.api_key;
    call_as(&server, phone, "scrobble", &format!("id={opening}&time=1700000000000")).await;
    call_as(&server, &tablet_key, "scrobble", &format!("id={glow}&time=1700000100000")).await;
    call_as(&server, phone, "scrobble", &format!("id={glow}&time=1700000200000")).await;

    let page = sync(&server).listens_after(&user, 0, 50).await.unwrap();
    let devices: Vec<String> = page.listens.iter().map(|row| row.listen.device.clone().unwrap()).collect();
    assert_eq!(devices.len(), 3);
    assert_eq!(devices[0], devices[2]);
    assert_eq!(devices[1], tablet.to_string());
    assert_ne!(devices[0], devices[1]);
    assert_eq!(page.listens[0].listen.event_id, event_id_rec(&devices[0], "rest", 1));
    assert_eq!(page.listens[2].listen.event_id, event_id_rec(&devices[0], "rest", 2));
    assert_eq!(page.listens[1].listen.event_id, event_id_rec(&tablet.to_string(), "rest", 1));

    let known = security.list_devices(Some(&user)).await.unwrap();
    let names: Vec<(&str, &str)> = known.iter().map(|device| (device.name.as_str(), device.platform.as_str())).collect();
    assert!(names.contains(&("opensubsonic:phone", "other")), "{names:?}");
    assert!(names.contains(&("opensubsonic:tablet", "other")), "{names:?}");
}

#[tokio::test]
async fn songs_removed_by_index_are_found_in_the_order_the_client_saw_even_with_duplicates() {
    let server = TestServer::new().await;
    server.standard_library();
    let a = server.song_id("Opening").await;
    let b = server.song_id("Middle").await;
    let c = server.song_id("Closing").await;
    let created = server
        .json("createPlaylist", &format!("name=Dupes&songId={a}&songId={b}&songId={a}&songId={c}&songId={a}"))
        .await;
    let playlist = created.raw["playlist"].clone();
    let id = playlist["id"].as_str().unwrap().to_string();
    assert_eq!(titles(&playlist), vec!["Opening", "Middle", "Opening", "Closing", "Opening"]);

    server
        .json("updatePlaylist", &format!("playlistId={id}&songIndexToRemove=0&songIndexToRemove=2&songIndexToRemove=2&songIndexToRemove=9"))
        .await
        .ok();
    let after = server.json("getPlaylist", &format!("id={id}")).await;
    assert_eq!(titles(&after.raw["playlist"]), vec!["Middle", "Closing", "Opening"]);

    server
        .json("updatePlaylist", &format!("playlistId={id}&songIndexToRemove=1&songIdToAdd={b}&songIdToAdd={a}"))
        .await
        .ok();
    let again = server.json("getPlaylist", &format!("id={id}")).await;
    assert_eq!(titles(&again.raw["playlist"]), vec!["Middle", "Opening", "Middle", "Opening"]);

    let user = owner(&server).await;
    let doc = sync(&server).playlist_for(&user, id.strip_prefix("pl-").unwrap()).await.unwrap().unwrap();
    assert_eq!(doc.visible().len(), 4);
    assert_eq!(doc.entries.len(), 7, "removed entries stay as tombstones");
}

#[tokio::test]
async fn a_second_user_never_sees_the_first_users_private_playlists() {
    let server = TestServer::new().await;
    server.standard_library();
    let (_, bob) = member_with_key(&server, "bob", Role::Member).await;
    let song = server.song_id("Solo").await;
    let created = server.json("createPlaylist", &format!("name=Mine&songId={song}")).await;
    let id = created.raw["playlist"]["id"].as_str().unwrap().to_string();

    let listed = call_as(&server, &bob, "getPlaylists", "").await;
    assert_eq!(listed["status"], "ok");
    assert!(listed["playlists"].get("playlist").is_none());
    assert_eq!(call_as(&server, &bob, "getPlaylist", &format!("id={id}")).await["error"]["code"], 70);
    assert_eq!(call_as(&server, &bob, "deletePlaylist", &format!("id={id}")).await["error"]["code"], 70);
    assert_eq!(call_as(&server, &bob, "updatePlaylist", &format!("playlistId={id}&name=Stolen")).await["error"]["code"], 70);

    let bobs = call_as(&server, &bob, "createPlaylist", &format!("name=Bobs&songId={song}")).await;
    assert_eq!(bobs["playlist"]["owner"], "bob");
    let owners_view = server.json("getPlaylists", "").await;
    let names: Vec<&str> = owners_view.raw["playlists"]["playlist"].as_array().unwrap().iter().map(|p| p["name"].as_str().unwrap()).collect();
    assert_eq!(names, vec!["Mine"], "an admin has no access to another user's private playlist");
}

#[tokio::test]
async fn a_household_playlist_is_shared_for_editing_but_only_its_owner_removes_it() {
    let server = TestServer::new().await;
    server.standard_library();
    let (_, bob) = member_with_key(&server, "bob", Role::Member).await;
    let opening = server.song_id("Opening").await;
    let solo = server.song_id("Solo").await;
    let created = server.json("createPlaylist", &format!("name=Together&songId={opening}")).await;
    let id = created.raw["playlist"]["id"].as_str().unwrap().to_string();
    assert_eq!(created.raw["playlist"]["public"], false);
    server.json("updatePlaylist", &format!("playlistId={id}&public=true")).await.ok();

    let seen = call_as(&server, &bob, "getPlaylist", &format!("id={id}")).await;
    assert_eq!(seen["playlist"]["public"], true);
    assert_eq!(seen["playlist"]["owner"], "tester");
    assert_eq!(titles(&seen["playlist"]), vec!["Opening"]);

    let edited = call_as(&server, &bob, "updatePlaylist", &format!("playlistId={id}&name=Both&songIdToAdd={solo}")).await;
    assert_eq!(edited["status"], "ok", "{edited}");
    let back = server.json("getPlaylist", &format!("id={id}")).await;
    assert_eq!(back.raw["playlist"]["name"], "Both");
    assert_eq!(titles(&back.raw["playlist"]), vec!["Opening", "Solo"]);

    assert_eq!(call_as(&server, &bob, "deletePlaylist", &format!("id={id}")).await["error"]["code"], 50);
    assert_eq!(call_as(&server, &bob, "updatePlaylist", &format!("playlistId={id}&public=false")).await["error"]["code"], 50);

    server.json("updatePlaylist", &format!("playlistId={id}&public=false")).await.ok();
    assert_eq!(call_as(&server, &bob, "getPlaylist", &format!("id={id}")).await["error"]["code"], 70);
}

#[tokio::test]
async fn each_user_has_their_own_stars_ratings_and_plays() {
    let server = TestServer::new().await;
    server.standard_library();
    let (_, bob) = member_with_key(&server, "bob", Role::Member).await;
    let id = server.song_id("Middle").await;
    server.json("star", &format!("id={id}")).await.ok();
    server.json("setRating", &format!("id={id}&rating=4")).await.ok();
    server.json("scrobble", &format!("id={id}")).await.ok();

    let theirs = call_as(&server, &bob, "getSong", &format!("id={id}")).await;
    assert!(theirs["song"].get("starred").is_none());
    assert!(theirs["song"].get("userRating").is_none());
    assert_eq!(theirs["song"]["playCount"], 0);
    let mine = server.json("getSong", &format!("id={id}")).await;
    assert_eq!(mine.raw["song"]["userRating"], 4);
    assert_eq!(mine.raw["song"]["playCount"], 1);

    call_as(&server, &bob, "star", &format!("id={id}")).await;
    let starred = call_as(&server, &bob, "getStarred2", "").await;
    assert_eq!(starred["starred2"]["song"].as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn a_guest_reads_but_may_not_write() {
    let server = TestServer::new().await;
    server.standard_library();
    let (_, guest) = member_with_key(&server, "visitor", Role::Guest).await;
    let id = server.song_id("Middle").await;
    assert_eq!(call_as(&server, &guest, "ping", "").await["status"], "ok");
    assert_eq!(call_as(&server, &guest, "star", &format!("id={id}")).await["error"]["code"], 50);
    assert_eq!(call_as(&server, &guest, "scrobble", &format!("id={id}")).await["error"]["code"], 50);
    assert_eq!(call_as(&server, &guest, "createPlaylist", &format!("name=X&songId={id}")).await["error"]["code"], 50);
    assert_eq!(call_as(&server, &guest, "getUser", "").await["user"]["playlistRole"], false);
}

#[tokio::test]
async fn the_play_queue_is_the_freshest_session_and_names_who_saved_it() {
    let server = TestServer::new().await;
    server.standard_library();
    let user = owner(&server).await;
    let (_, tablet) = server.state.0.security.create_api_key(&user, "tablet").await.unwrap();
    let opening = server.song_id("Opening").await;
    let glow = server.song_id("Glow").await;
    let solo = server.song_id("Solo").await;

    server.json("savePlayQueue", &format!("id={opening}&id={glow}&current={opening}&position=1500")).await.ok();
    call_as(&server, &tablet, "savePlayQueue", &format!("id={glow}&id={solo}&current={solo}&position=9000")).await;
    let fresh = server.json("getPlayQueue", "").await;
    assert_eq!(fresh.raw["playQueue"]["current"], solo);
    assert_eq!(fresh.raw["playQueue"]["position"], 9000);
    assert_eq!(fresh.raw["playQueue"]["changedBy"], "tablet");

    server.json("savePlayQueue", &format!("id={opening}&current={opening}&position=1")).await.ok();
    let latest = server.json("getPlayQueue", "").await;
    assert_eq!(latest.raw["playQueue"]["current"], opening);
    assert_eq!(latest.raw["playQueue"]["changedBy"], "tests");

    let sessions = sync(&server).sessions_of(&user).await.unwrap();
    assert_eq!(sessions.len(), 2, "one session per synthesized device");
    server.json("savePlayQueue", "").await.ok();
    assert!(server.json("getPlayQueue", "").await.ok().raw.get("playQueue").is_none());
}

#[tokio::test]
async fn a_key_revoked_in_credentials_toml_stays_refused_after_it_was_copied_into_the_store() {
    let server = TestServer::new().await;
    assert_eq!(call_as(&server, &server.api_key, "ping", "").await["status"], "ok");
    let path = server.state.0.config.credentials_path();
    let mut account = credentials::load(&path).unwrap().unwrap();
    assert!(account.revoke_key("phone"));
    credentials::save(&path, &account).unwrap();
    assert_eq!(call_as(&server, &server.api_key, "ping", "").await["error"]["code"], 44);
}
