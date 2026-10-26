use crate::rig::{padded_songs, png, songs, Device, Song};
use flaccy_library::server_sync::{SyncState, TokenStore, Transport};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

const BIG_SONGS: u32 = 5_000;
const ALBUM_PADDING: usize = 450;

fn binary() -> PathBuf {
    if let Ok(path) = std::env::var("FLACCY_SERVER_BIN") {
        return PathBuf::from(path);
    }
    let exe = std::env::current_exe().unwrap();
    let profile = exe.parent().unwrap().parent().unwrap();
    let same_profile = profile.join("flaccy-server");
    if same_profile.exists() {
        return same_profile;
    }
    profile
        .parent()
        .unwrap()
        .join("debug")
        .join("flaccy-server")
}

struct RealServer {
    dir: PathBuf,
    config: PathBuf,
    port: u16,
    child: Option<Child>,
}

impl RealServer {
    fn new(label: &str) -> RealServer {
        let dir = std::env::temp_dir().join(format!("flaccy-real-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("music")).unwrap();
        let port = std::net::TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        let config = dir.join("config.toml");
        let text = format!(
            "music_folder = \"{}\"\ndata_dir = \"{}\"\nport = {port}\n",
            dir.join("music").display(),
            dir.join("data").display()
        );
        std::fs::write(&config, text).unwrap();
        RealServer {
            dir,
            config,
            port,
            child: None,
        }
    }

    fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    fn cli(&self, args: &[&str]) -> String {
        let output = Command::new(binary())
            .arg("--config")
            .arg(&self.config)
            .args(args)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{args:?}: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    }

    fn start(&mut self) {
        let child = Command::new(binary())
            .arg("--config")
            .arg(&self.config)
            .arg("serve")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap_or_else(|error| {
                panic!(
                    "{} did not start ({error}); build it with `cargo build -p flaccy-server`",
                    binary().display()
                )
            });
        self.child = Some(child);
        let transport = Transport::new(&self.url());
        let started = Instant::now();
        while transport.hello().is_err() {
            assert!(
                started.elapsed() < Duration::from_secs(30),
                "the server did not come up"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
    }

    fn stop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    fn link(&self, user: &str) -> String {
        let made: Value = serde_json::from_str(&self.cli(&[
            "enroll",
            "--user",
            user,
            "--json",
            "--url",
            &self.url(),
        ]))
        .unwrap();
        made["link"].as_str().unwrap().to_owned()
    }

    fn state(&self) -> rusqlite::Connection {
        rusqlite::Connection::open(self.dir.join("data").join("state.sqlite")).unwrap()
    }

    fn backup(&self) -> PathBuf {
        let folder = self.dir.join("backups");
        self.cli(&["backup", "--to", folder.to_str().unwrap()]);
        let mut files: Vec<PathBuf> = std::fs::read_dir(&folder)
            .unwrap()
            .map(|entry| entry.unwrap().path())
            .filter(|path| {
                path.file_name()
                    .unwrap()
                    .to_string_lossy()
                    .starts_with("state-")
            })
            .collect();
        files.sort();
        files.pop().unwrap()
    }

    fn restore(&mut self, backup: &std::path::Path) {
        self.stop();
        self.cli(&["restore", backup.to_str().unwrap()]);
        self.start();
    }
}

impl Drop for RealServer {
    fn drop(&mut self) {
        self.stop();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn scalar(connection: &rusqlite::Connection, sql: &str) -> i64 {
    connection.query_row(sql, [], |row| row.get(0)).unwrap()
}

#[test]
#[ignore]
fn server_sync_real_server_takes_a_restore_reseed_of_5000_entities_in_chunks() {
    let mut server = RealServer::new("big");
    server.start();
    let library: Vec<Song> = padded_songs(BIG_SONGS, ALBUM_PADDING);
    let mut first = Device::new("real-a", &library);
    first.connect_link(&server.link("marcus"));
    let backup = server.backup();
    let playlist = first.db.create_playlist("Big").unwrap();
    let paths: Vec<String> = library.iter().map(|entry| entry.path.clone()).collect();
    first.db.add_tracks_to_playlist(playlist, &paths).unwrap();
    assert_eq!(first.sync().state, SyncState::UpToDate);
    assert_eq!(
        scalar(&server.state(), "SELECT COUNT(*) FROM playlist_entries"),
        BIG_SONGS as i64
    );
    server.restore(&backup);
    assert_eq!(
        scalar(&server.state(), "SELECT COUNT(*) FROM playlist_entries"),
        0
    );
    let started = Instant::now();
    let status = first.sync();
    flaccy_library::logger::info(
        "server_sync",
        &format!(
            "real server reseed of {BIG_SONGS} entities: {:.2}s, {:?}",
            started.elapsed().as_secs_f64(),
            status.state
        ),
    );
    assert_eq!(status.state, SyncState::UpToDate);
    assert_eq!(
        scalar(
            &server.state(),
            "SELECT COUNT(*) FROM playlist_entries WHERE alive = 1"
        ),
        BIG_SONGS as i64
    );
    let mut second = Device::new("real-b", &library);
    second.connect_link(&server.link("marcus"));
    assert_eq!(second.sync().state, SyncState::UpToDate);
    assert_eq!(second.playlists()["Big"].len(), BIG_SONGS as usize);
    assert_eq!(first.playlists()["Big"].len(), BIG_SONGS as usize);
}

#[test]
#[ignore]
fn server_sync_real_server_takes_a_reseeded_cover_after_the_blob_is_uploaded_again() {
    let mut server = RealServer::new("cover");
    server.start();
    let mut device = Device::new("real-cover", &songs(2));
    device.connect_link(&server.link("marcus"));
    let backup = server.backup();
    let local = device.db.create_playlist("Covered").unwrap();
    assert_eq!(device.sync().state, SyncState::UpToDate);
    let bytes = png();
    let hash = hex::encode(Sha256::digest(&bytes));
    device.db.set_playlist_cover(local, &bytes).unwrap();
    let token = TokenStore::new(device.dir.join("sync-token")).load();
    Transport::new(&server.url())
        .with_token(token)
        .put_blob(&hash, "image/png", &bytes)
        .unwrap();
    let id = device.sync_id("Covered");
    device.inject(
        "playlist.setCover",
        json!({ "id": id, "blob": hash }),
        &[format!("playlist:{id}")],
    );
    assert_eq!(device.sync().state, SyncState::UpToDate);
    assert_eq!(
        scalar(
            &server.state(),
            &format!("SELECT COUNT(*) FROM playlists WHERE cover_blob = '{hash}'")
        ),
        1
    );
    server.restore(&backup);
    assert_eq!(scalar(&server.state(), "SELECT COUNT(*) FROM playlists"), 0);
    assert_eq!(device.sync().state, SyncState::UpToDate);
    assert_eq!(
        scalar(
            &server.state(),
            &format!("SELECT COUNT(*) FROM playlists WHERE cover_blob = '{hash}'")
        ),
        1
    );
    assert_eq!(
        scalar(
            &server.state(),
            &format!("SELECT COUNT(*) FROM blobs WHERE hash = '{hash}'")
        ),
        1
    );
}
