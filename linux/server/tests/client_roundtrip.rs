//! One pass over the wire: the server indexes a music folder, the Flaccy client
//! adds it with a password and syncs it, a song is cached, and a re-export made
//! on the server arrives as revision 2 of the same client row.

use std::net::SocketAddr;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use flaccy_library::db::{now_ms, Db};
use flaccy_library::fingerprint::fixtures::{info_tags, tone, wav_bytes, TempDir};
use flaccy_library::library::TrackRow;
use flaccy_library::remote::servers::Server;
use flaccy_library::remote::service::{Paths, Remote};
use flaccy_library::remote::sync::SyncReport;
use flaccy_server::api;
use flaccy_server::config::{Config, Mode};
use flaccy_server::credentials::{self, Credentials};
use flaccy_server::refresh::{refresh_now, ScanSummary};
use flaccy_server::state::AppState;
use flaccy_shared::remote::remote_path;
use flaccy_shared::track_revision::shows_new_mix;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

const USER: &str = "tester";
const PASSWORD: &str = "sesame-seed";
const ROUGH: &str = "Band/Album/01 Rough Mix.wav";
const OTHER: &str = "Band/Album/02 Other.wav";

/// Writes a WAV with the given samples and title tag, creating its folders.
fn write_wav(path: &Path, samples: &[i16], title: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let tags = info_tags(title, "Band", "Album");
    std::fs::write(path, wav_bytes(samples, Some(&tags))).unwrap();
}

/// Runs the server's scan and revision pass on a blocking thread, as the server does.
async fn scan(state: &AppState) -> ScanSummary {
    let state = state.clone();
    tokio::task::spawn_blocking(move || refresh_now(&state)).await.unwrap()
}

/// Serves the API on a loopback port the OS picks until the returned sender fires.
async fn serve(state: AppState) -> (String, oneshot::Sender<()>, JoinHandle<std::io::Result<()>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = format!("http://{}", listener.local_addr().unwrap());
    let (stop, stopped) = oneshot::channel::<()>();
    let serving = tokio::spawn(async move {
        axum::serve(
            listener,
            api::router(state).into_make_service_with_connect_info::<SocketAddr>(),
        )
        .with_graceful_shutdown(async move {
            let _ = stopped.await;
        })
        .await
    });
    (address, stop, serving)
}

/// The client's stored row titled `title`, and the server's id for that song.
fn stored_song(db: &Db, title: &str) -> (TrackRow, String) {
    let row = db
        .fetch_all_tracks()
        .into_iter()
        .find(|row| row.title == title)
        .unwrap_or_else(|| panic!("no stored row titled {title}"));
    let (_, song) = remote_path::decode(&row.rel_path).expect("a remote row");
    (row, song)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_re_export_on_the_server_reaches_the_client_as_revision_two_of_the_same_row() {
    let root = TempDir::new("client-roundtrip");
    let music = root.path().join("music");
    write_wav(&music.join(ROUGH), &tone(8000, 7), "Rough Mix");
    write_wav(&music.join(OTHER), &tone(8000, 9), "Other");

    let config = Config {
        music_folder: music.clone(),
        address: "127.0.0.1".to_string(),
        port: 0,
        data_dir: Some(root.path().join("server-data")),
        behind_proxy: false,
        mode: Mode::Easy,
        hosts: Vec::new(),
    };
    let account = Credentials {
        username: USER.to_string(),
        password: PASSWORD.to_string(),
        keys: Vec::new(),
    };
    credentials::save(&config.credentials_path(), &account).unwrap();
    let state = AppState::open(config).await.unwrap();
    let summary = scan(&state).await;
    assert_eq!(summary.added, 2, "{summary:?}");

    let (address, stop, serving) = serve(state.clone()).await;

    let client = root.path().join("client");
    let paths = Paths {
        config_dir: client.join("config"),
        cache_dir: client.join("cache"),
        data_dir: client.join("data"),
        db_path: client.join("library.sqlite"),
    };
    for dir in [&paths.config_dir, &paths.cache_dir, &paths.data_dir] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let remote = Remote::start(paths.clone(), 1 << 30).unwrap();

    let server = Server::new("Home", &address, USER, PASSWORD, false);
    let server_id = server.id.clone();
    let first = {
        let remote = Arc::clone(&remote);
        let server_id = server_id.clone();
        tokio::task::spawn_blocking(move || {
            Remote::test(&server).expect("the password signs in");
            remote.add_server(server).unwrap();
            remote.sync(&server_id, &|_| {}).unwrap()
        })
        .await
        .unwrap()
    };
    assert_eq!(first.songs, 2, "{first:?}");
    assert_eq!(first.applied.inserted, 2, "{first:?}");

    let db = Db::open(&paths.db_path).unwrap();
    let (rough_before, rough_song) = stored_song(&db, "Rough Mix");
    let (other_before, other_song) = stored_song(&db, "Other");
    assert_eq!(remote_path::decode(&rough_before.rel_path).unwrap().0, server_id);
    assert_eq!(db.remote_revision(&server_id, &rough_song), Some((1, None)));
    assert_eq!(db.remote_revision(&server_id, &other_song), Some((1, None)));
    assert_eq!(rough_before.duration, 1.0);

    let manager = Arc::clone(remote.manager());
    let rough_rel = remote_path::encode(&server_id, &rough_song);
    let original_rough = std::fs::read(music.join(ROUGH)).unwrap();
    {
        let manager = Arc::clone(&manager);
        let server_id = server_id.clone();
        let rough_song = rough_song.clone();
        tokio::task::spawn_blocking(move || {
            let entry = manager.entry(&server_id, &rough_song).unwrap();
            let total = manager.ensure_total(&entry).unwrap();
            manager.fill(&entry, 0..total, total).unwrap();
        })
        .await
        .unwrap();
    }
    assert!(manager.is_complete(&rough_rel));
    let (_, cached_before, _) = manager
        .store()
        .find(&server_id, &rough_song)
        .expect("the song is cached before the re-export");
    assert_eq!(std::fs::read(&cached_before).unwrap(), original_rough);

    std::thread::sleep(Duration::from_millis(30));
    write_wav(&music.join(ROUGH), &tone(12000, 11), "Rough Mix");
    let summary = scan(&state).await;
    assert_eq!(summary.new_versions, 1, "{summary:?}");

    let second: SyncReport = {
        let remote = Arc::clone(&remote);
        let server_id = server_id.clone();
        tokio::task::spawn_blocking(move || remote.sync(&server_id, &|_| {}).unwrap())
            .await
            .unwrap()
    };
    assert_eq!(second.applied.new_versions, vec![rough_song.clone()], "{second:?}");
    assert!(second.applied.removed.is_empty(), "{second:?}");

    let db = Db::open(&paths.db_path).unwrap();
    let (rough_after, same_song) = stored_song(&db, "Rough Mix");
    assert_eq!(same_song, rough_song);
    assert_eq!(rough_after.id, rough_before.id);
    assert_eq!(rough_after.revision, 2);
    assert!(rough_after.revised_at.is_some());
    assert!(shows_new_mix(rough_after.revised_at, now_ms()));
    assert_eq!(rough_after.duration, 2.0);
    assert_eq!(db.remote_revision(&server_id, &rough_song).map(|(revision, _)| revision), Some(2));

    let (other_after, other_song_after) = stored_song(&db, "Other");
    assert_eq!(other_song_after, other_song);
    assert_eq!(other_after.id, other_before.id);
    assert_eq!(db.remote_revision(&server_id, &other_song), Some((1, None)));
    assert_eq!(db.fetch_all_tracks().len(), 2);

    assert!(!manager.is_complete(&rough_rel));
    assert!(manager.store().find(&server_id, &rough_song).is_none());
    assert!(!cached_before.exists());

    let _ = stop.send(());
    tokio::time::timeout(Duration::from_secs(10), serving)
        .await
        .expect("the server stops within ten seconds")
        .unwrap()
        .unwrap();
}
