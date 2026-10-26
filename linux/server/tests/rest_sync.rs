//! The OpenSubsonic API and the native sync API are two doors onto one state: what a /rest call writes an enrolled
//! device pulls, and what a device pushes /rest shows.

mod common;

use flaccy_library::fingerprint::fixtures::{info_tags, tone, wav_bytes};
use flaccy_library::server_sync::song_key_of;
use flaccy_server::config::Config;
use flaccy_server::credentials::{self, Credentials};
use flaccy_server::refresh::refresh_now;
use flaccy_server::security::Role;
use serde_json::{json, Value};

use common::http::Harness;

const USER: &str = "tester";

struct Library {
    harness: Harness,
    key: String,
}

fn song_ref(title: &str, artist: &str, album: &str) -> Value {
    json!({ "songKey": song_key_of(title, artist), "title": title, "artist": artist, "album": album, "durationMs": 1000 })
}

fn prepare(key_slot: &std::sync::Mutex<String>) -> impl FnOnce(&Config) + '_ {
    move |config: &Config| {
        let mut account = Credentials {
            username: USER.to_owned(),
            password: "sesame-seed".to_owned(),
            keys: Vec::new(),
        };
        *key_slot.lock().unwrap() = account.add_key("phone", "2026-10-26T12:00:00Z").unwrap();
        credentials::save(&config.credentials_path(), &account).unwrap();
        for (path, title, artist, album, step) in [
            ("Drill Band/Rough Cuts/01 Opening.wav", "Opening", "Drill Band", "Rough Cuts", 7),
            ("Drill Band/Rough Cuts/02 Middle.wav", "Middle", "Drill Band", "Rough Cuts", 8),
            ("Drill Band/Rough Cuts/03 Closing.wav", "Closing", "Drill Band", "Rough Cuts", 9),
            ("The Echo/Second Light/01 Glow.wav", "Glow", "The Echo", "Second Light", 5),
        ] {
            let file = config.music_folder.join(path);
            std::fs::create_dir_all(file.parent().unwrap()).unwrap();
            std::fs::write(file, wav_bytes(&tone(8000, step), Some(&info_tags(title, artist, album)))).unwrap();
        }
    }
}

async fn library() -> Library {
    let key = std::sync::Mutex::new(String::new());
    let harness = Harness::start_with(prepare(&key)).await;
    let state = harness.state.clone();
    let summary = tokio::task::spawn_blocking(move || refresh_now(&state)).await.unwrap();
    assert_eq!(summary.added, 4, "{summary:?}");
    let key = key.into_inner().unwrap();
    Library { harness, key }
}

impl Library {
    async fn rest(&self, method: &str, query: &str) -> Value {
        let reply = self.harness.get(&format!("/rest/{method}?apiKey={}&f=json&c=itests&{query}", self.key), None).await;
        let body = reply.json();
        assert_eq!(body["subsonic-response"]["status"], "ok", "{method}: {body}");
        body["subsonic-response"].clone()
    }

    async fn song_id(&self, title: &str) -> String {
        let found = self.rest("search3", &format!("query={title}&songCount=20")).await;
        found["searchResult3"]["song"]
            .as_array()
            .unwrap()
            .iter()
            .find(|song| song["title"] == title)
            .unwrap()["id"]
            .as_str()
            .unwrap()
            .to_owned()
    }
}

fn changes_of<'a>(pull: &'a Value, kind: &str) -> Vec<&'a Value> {
    pull["changes"].as_array().unwrap().iter().filter(|change| change["kind"] == kind).collect()
}

#[tokio::test(flavor = "multi_thread")]
async fn what_a_rest_call_writes_an_enrolled_device_pulls() {
    let library = library().await;
    let (opening, middle, glow) = (library.song_id("Opening").await, library.song_id("Middle").await, library.song_id("Glow").await);

    library.rest("ping", "").await;
    library.rest("star", &format!("id={middle}")).await;
    library.rest("setRating", &format!("id={opening}&rating=4")).await;
    library.rest("scrobble", &format!("id={glow}&time=1700000000000")).await;
    let created = library.rest("createPlaylist", &format!("name=Mix&songId={opening}&songId={middle}")).await;
    let playlist = created["playlist"]["id"].as_str().unwrap().to_owned();
    library.rest("updatePlaylist", &format!("playlistId={playlist}&songIdToAdd={glow}")).await;
    let shown = library.rest("getPlaylist", &format!("id={playlist}")).await;
    let titles: Vec<&str> = shown["playlist"]["entry"].as_array().unwrap().iter().map(|entry| entry["title"].as_str().unwrap()).collect();
    assert_eq!(titles, vec!["Opening", "Middle", "Glow"]);
    library.rest("savePlayQueue", &format!("id={opening}&id={glow}&current={glow}&position=4200")).await;
    let queue = library.rest("getPlayQueue", "").await;
    assert_eq!(queue["playQueue"]["current"], glow);
    assert_eq!(queue["playQueue"]["position"], 4200);

    let device = library.harness.enroll(USER, Role::Admin).await;
    let pull = library.harness.pull(&device, 0).await;
    assert_eq!(pull.status, 200, "{}", String::from_utf8_lossy(&pull.body));
    let pull = pull.json();

    let loves = changes_of(&pull, "love");
    assert_eq!(loves.len(), 1);
    assert_eq!(loves[0]["id"], song_key_of("Middle", "Drill Band"));
    assert_eq!(loves[0]["value"]["loved"], true);
    assert_eq!(loves[0]["deleted"], false);

    let ratings = changes_of(&pull, "rating");
    assert_eq!(ratings.len(), 1);
    assert_eq!(ratings[0]["value"]["rating"], 4);
    assert_eq!(ratings[0]["value"]["ref"]["title"], "Opening");

    let playlists = changes_of(&pull, "playlist");
    assert_eq!(playlists.len(), 1);
    assert_eq!(playlists[0]["value"]["name"], "Mix");
    assert_eq!(playlist, format!("pl-{}", playlists[0]["id"].as_str().unwrap()));
    let entries = changes_of(&pull, "playlist_entry");
    assert_eq!(entries.len(), 3);
    assert!(entries.iter().all(|entry| entry["value"]["alive"] == true));

    let sessions = changes_of(&pull, "session");
    assert_eq!(sessions.len(), 1);
    assert_eq!(sessions[0]["value"]["session"]["positionMs"], 4200);
    assert_ne!(sessions[0]["id"], device.id.as_str(), "the REST key is its own device");

    let listens = library.harness.get("/flaccy/v1/listens?after=0&limit=10", Some(&device.token)).await.json();
    let plays = listens["listens"].as_array().unwrap();
    assert_eq!(plays.len(), 1);
    assert_eq!(plays[0]["source"], "opensubsonic");
    assert_eq!(plays[0]["ts"], 1_700_000_000);
    assert_eq!(plays[0]["ref"]["title"], "Glow");

    library.harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn what_a_device_pushes_rest_shows() {
    let library = library().await;
    let device = library.harness.enroll(USER, Role::Admin).await;
    let closing = song_ref("Closing", "Drill Band", "Rough Cuts");
    let glow = song_ref("Glow", "The Echo", "Second Light");
    let pushed = library
        .harness
        .push(
            &device,
            1,
            vec![
                ("love.set", json!({ "songKey": closing["songKey"], "ref": closing, "loved": true })),
                ("rating.set", json!({ "songKey": glow["songKey"], "ref": glow, "rating": 2 })),
                ("playlist.create", json!({ "id": "0190f3a2-7b1c-7d2e-8f3a-123456789abc", "name": "From Phone", "entries": [{ "id": "0190f3a2-7b1c-7d2e-8f3a-123456789abd", "ref": glow }] })),
            ],
        )
        .await;
    assert_eq!(pushed.status, 200, "{}", String::from_utf8_lossy(&pushed.body));

    let starred = library.rest("getStarred2", "").await;
    let titles: Vec<&str> = starred["starred2"]["song"].as_array().unwrap().iter().map(|song| song["title"].as_str().unwrap()).collect();
    assert_eq!(titles, vec!["Closing"]);
    let rated = library.rest("getSong", &format!("id={}", library.song_id("Glow").await)).await;
    assert_eq!(rated["song"]["userRating"], 2);
    let playlists = library.rest("getPlaylists", "").await;
    assert_eq!(playlists["playlists"]["playlist"][0]["name"], "From Phone");
    assert_eq!(playlists["playlists"]["playlist"][0]["songCount"], 1);
    assert_eq!(playlists["playlists"]["playlist"][0]["owner"], USER);

    library.rest("unstar", &format!("id={}", library.song_id("Closing").await)).await;
    let pulled = library.harness.pull(&device, 0).await.json();
    let loves = changes_of(&pulled, "love");
    assert_eq!(loves[0]["deleted"], true, "the unstar reached the device that had pushed the love");
    library.harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_device_token_works_as_an_api_key_and_dies_with_the_device() {
    let library = library().await;
    let device = library.harness.enroll(USER, Role::Admin).await;
    let as_device = |method: &'static str, query: String| {
        let harness = &library.harness;
        let token = device.token.clone();
        async move { harness.get(&format!("/rest/{method}?apiKey={token}&f=json&c=itests&{query}"), None).await.json()["subsonic-response"].clone() }
    };

    assert_eq!(as_device("ping", String::new()).await["status"], "ok");
    let albums = as_device("getAlbumList2", "type=alphabeticalByName&size=10".to_owned()).await;
    assert_eq!(albums["albumList2"]["album"].as_array().unwrap().len(), 2);
    let user = as_device("getUser", String::new()).await;
    assert_eq!(user["user"]["username"], USER);

    let glow = library.song_id("Glow").await;
    assert_eq!(as_device("scrobble", format!("id={glow}&time=1700000300000")).await["status"], "ok");
    let listens = library.harness.get("/flaccy/v1/listens?after=0&limit=10", Some(&device.token)).await.json();
    let play = &listens["listens"][0];
    assert_eq!(play["source"], "opensubsonic");
    assert_eq!(play["device"], device.id.as_str(), "the write carries the real device id");

    library.harness.revoke(&device.id).await;
    assert_eq!(as_device("ping", String::new()).await["error"]["code"], 44);
    library.harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_api_key_cannot_call_the_native_api() {
    let library = library().await;
    for path in ["/flaccy/v1/sync/pull?since=0", "/flaccy/v1/devices", "/flaccy/v1/me"] {
        let reply = library.harness.get(path, Some(&library.key)).await;
        assert_eq!(reply.status, 401, "{path}: {}", String::from_utf8_lossy(&reply.body));
    }
    library.harness.stop().await;
}
