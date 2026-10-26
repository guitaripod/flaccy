use crate::double::Double;
use flaccy_library::db::{Db, NewTrack};
use flaccy_library::server_sync::{
    Backoff, Driver, ImportReport, ServerLink, SyncState, SyncStatus, TokenStore,
};
use std::collections::{BTreeMap, HashMap};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU32, Ordering};

static COUNTER: AtomicU32 = AtomicU32::new(0);

#[derive(Clone)]
pub struct Song {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub path: String,
}

pub fn song(number: u32) -> Song {
    Song {
        title: format!("Song {number}"),
        artist: "The Artist".into(),
        album: "The Album".into(),
        path: format!("The Artist/The Album/{number:02} Song {number}.flac"),
    }
}

pub const PNG_HEX: &str = "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da636460f85f0f0002870180eb47ba920000000049454e44ae426082";

pub fn png() -> Vec<u8> {
    hex::decode(PNG_HEX).unwrap()
}

pub fn padded_songs(count: u32, padding: usize) -> Vec<Song> {
    (1..=count)
        .map(|number| {
            let mut entry = song(number);
            entry.album = format!("{} {}", entry.album, "x".repeat(padding));
            entry
        })
        .collect()
}

pub fn songs(count: u32) -> Vec<Song> {
    (1..=count).map(song).collect()
}

pub struct Device {
    pub db: Db,
    pub driver: Driver,
    pub dir: PathBuf,
    catalog: HashMap<String, String>,
}

impl Device {
    pub fn new(label: &str, library: &[Song]) -> Device {
        let dir = std::env::temp_dir().join(format!(
            "flaccy-sync-{label}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::SeqCst)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let db = Db::open(&dir.join("library.sqlite")).unwrap();
        let driver =
            Driver::new(TokenStore::new(dir.join("sync-token")), None).with_backoff(Backoff::NONE);
        let mut device = Device {
            db,
            driver,
            dir,
            catalog: HashMap::new(),
        };
        for entry in library {
            device.add_song(entry);
        }
        device
    }

    pub fn add_song(&mut self, entry: &Song) {
        self.db
            .insert_track(&NewTrack {
                rel_path: entry.path.clone(),
                title: entry.title.clone(),
                artist: entry.artist.clone(),
                album: entry.album.clone(),
                album_artist: None,
                track_number: 1,
                duration: 200.0,
                codec: Some("FLAC".into()),
                bit_depth: None,
                sample_rate: None,
                channels: None,
                artwork: None,
                signature: None,
                fingerprint: None,
            })
            .unwrap();
        self.catalog.insert(entry.path.clone(), entry.title.clone());
    }

    pub fn raw(&self) -> rusqlite::Connection {
        rusqlite::Connection::open(self.dir.join("library.sqlite")).unwrap()
    }

    pub fn connect_link(&mut self, link: &str) -> ImportReport {
        let link = ServerLink::parse(link).unwrap();
        self.driver.enroll(&self.db, &link, "Test device").unwrap()
    }

    pub fn inject(&self, name: &str, args: serde_json::Value, touches: &[String]) {
        let raw = self.raw();
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
            "INSERT INTO sync_pending (mutation_id, name, stamp, args_json, touches_json) VALUES (?1, ?2, ?3, ?4, ?5)",
            rusqlite::params![next, name, (flaccy_library::db::now_ms() << 16) + next, args.to_string(), serde_json::to_string(touches).unwrap()],
        )
        .unwrap();
        raw.execute(
            "UPDATE sync_meta SET value = ?1 WHERE key = 'next_mutation_id'",
            [(next + 1).to_string()],
        )
        .unwrap();
    }

    pub fn sync_id(&self, playlist: &str) -> String {
        self.raw()
            .query_row(
                "SELECT syncId FROM playlists WHERE name = ?1",
                [playlist],
                |row| row.get(0),
            )
            .unwrap()
    }

    pub fn connect(&mut self, double: &Double, user: &str) -> ImportReport {
        let link = ServerLink::parse(&double.link(user)).unwrap();
        self.driver.enroll(&self.db, &link, "Test device").unwrap()
    }

    pub fn sync(&mut self) -> SyncStatus {
        let mut status = self.driver.run_once(&self.db);
        for _ in 0..5 {
            if status.state != SyncState::UpToDate || status.pending == 0 {
                break;
            }
            status = self.driver.run_once(&self.db);
        }
        status
    }

    pub fn playlist_id(&self, name: &str) -> i64 {
        self.db
            .fetch_playlists()
            .into_iter()
            .find(|p| p.name == name)
            .unwrap()
            .id
    }

    pub fn playlists(&self) -> BTreeMap<String, Vec<String>> {
        self.db
            .fetch_playlists()
            .into_iter()
            .map(|playlist| {
                let titles = self
                    .db
                    .playlist_tracks(playlist.id)
                    .into_iter()
                    .map(|row| self.catalog[&row.rel_path].clone())
                    .collect();
                (playlist.name, titles)
            })
            .collect()
    }

    pub fn loved(&self) -> Vec<String> {
        let mut titles: Vec<String> = self
            .db
            .fetch_all_tracks()
            .into_iter()
            .filter(|track| track.loved)
            .map(|track| track.title)
            .collect();
        titles.sort();
        titles
    }

    pub fn play(&self, entry: &Song, ts: i64) {
        self.db
            .insert_scrobble(&entry.title, &entry.artist, &entry.album, ts, 180, false)
            .unwrap();
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}
