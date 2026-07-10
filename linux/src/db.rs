use crate::library::TrackRow;
use chrono::{DateTime, NaiveDateTime, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

pub struct Db {
    conn: Connection,
}

pub struct NewTrack {
    pub rel_path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub track_number: i32,
    pub duration: f64,
    pub codec: Option<String>,
    pub bit_depth: Option<i32>,
    pub sample_rate: Option<i32>,
    pub channels: Option<i32>,
    pub artwork: Option<Vec<u8>>,
}

pub struct PendingScrobble {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub timestamp_unix: i64,
    pub duration: i64,
}

pub struct PendingLoveOp {
    pub rel_path: String,
    pub title: String,
    pub artist: String,
    pub op: String,
}

pub struct PlaylistRow {
    pub id: i64,
    pub name: String,
    pub track_count: i64,
}

pub struct PlaylistTrackRow {
    pub row_id: i64,
    pub rel_path: String,
}

pub struct LyricsRow {
    pub synced: Option<String>,
    pub plain: Option<String>,
    pub instrumental: bool,
}

pub fn default_db_path() -> PathBuf {
    dirs::data_dir()
        .unwrap_or_default()
        .join("flaccy")
        .join("library.sqlite")
}

pub fn now_string() -> String {
    Utc::now().format("%Y-%m-%d %H:%M:%S%.3f").to_string()
}

pub fn string_from_unix(ts: i64) -> String {
    DateTime::<Utc>::from_timestamp(ts, 0)
        .unwrap_or_default()
        .format("%Y-%m-%d %H:%M:%S%.3f")
        .to_string()
}

pub fn unix_from_string(text: &str) -> i64 {
    NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S%.3f")
        .or_else(|_| NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S"))
        .map(|naive| naive.and_utc().timestamp())
        .unwrap_or(0)
}

impl Db {
    pub fn open(path: &Path) -> Result<Self, rusqlite::Error> {
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let conn = Connection::open(path)?;
        let _ = conn.busy_timeout(std::time::Duration::from_secs(5));
        let _ = conn.pragma_update(None, "journal_mode", "WAL");
        let _ = conn.pragma_update(None, "foreign_keys", "ON");
        let db = Self { conn };
        db.migrate()?;
        Ok(db)
    }

    /// Opens the library database, renaming a corrupt file aside and recreating
    /// it when the initial open or migration fails (ports the iOS recovery path).
    pub fn open_with_recovery(path: &Path) -> Result<Self, rusqlite::Error> {
        match Self::open(path) {
            Ok(db) => Ok(db),
            Err(err) => {
                crate::logger::error("database", &format!("open failed, recreating: {err}"));
                let stamp = Utc::now().timestamp();
                let corrupt = path.with_file_name(format!("library.sqlite.corrupt-{stamp}"));
                let _ = std::fs::rename(path, &corrupt);
                for suffix in ["-wal", "-shm"] {
                    let side = PathBuf::from(format!("{}{}", path.display(), suffix));
                    let _ = std::fs::remove_file(side);
                }
                Self::open(path)
            }
        }
    }

    fn migrate(&self) -> Result<(), rusqlite::Error> {
        self.conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS tracks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fileURL TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                albumTitle TEXT NOT NULL,
                trackNumber INTEGER NOT NULL,
                duration DOUBLE NOT NULL,
                artworkData BLOB,
                lastFMArtworkURL TEXT,
                musicBrainzID TEXT,
                albumMusicBrainzID TEXT,
                dateAdded DATETIME NOT NULL,
                lastPlayed DATETIME,
                playCount INTEGER NOT NULL DEFAULT 0,
                aiAnalyzed BOOLEAN NOT NULL DEFAULT 0,
                analysisAttemptedAt DATETIME,
                codec TEXT,
                bitDepth INTEGER,
                sampleRate INTEGER,
                channels INTEGER,
                loved BOOLEAN NOT NULL DEFAULT 0,
                lovedPendingOp TEXT
            );
            CREATE INDEX IF NOT EXISTS tracks_on_artist ON tracks(artist);
            CREATE INDEX IF NOT EXISTS tracks_on_albumTitle_artist ON tracks(albumTitle, artist);
            CREATE INDEX IF NOT EXISTS tracks_on_loved ON tracks(loved);
            CREATE TABLE IF NOT EXISTS albumInfo (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                coverArtURL TEXT,
                coverArtData BLOB,
                musicBrainzID TEXT,
                year TEXT,
                genre TEXT,
                lastFetched DATETIME,
                UNIQUE(title, artist)
            );
            CREATE INDEX IF NOT EXISTS albumInfo_on_artist ON albumInfo(artist);
            CREATE TABLE IF NOT EXISTS scrobbles (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trackTitle TEXT NOT NULL,
                artist TEXT NOT NULL,
                albumTitle TEXT NOT NULL,
                timestamp DATETIME NOT NULL,
                duration INTEGER NOT NULL,
                submitted BOOLEAN NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS scrobbles_on_submitted_timestamp ON scrobbles(submitted, timestamp);
            CREATE INDEX IF NOT EXISTS scrobbles_on_timestamp ON scrobbles(timestamp);
            CREATE TABLE IF NOT EXISTS playlists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                createdAt DATETIME NOT NULL
            );
            CREATE TABLE IF NOT EXISTS playlistTracks (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                playlistId INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
                trackFileURL TEXT NOT NULL,
                position INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS playlistTracks_on_playlistId ON playlistTracks(playlistId);
            CREATE TABLE IF NOT EXISTS lyrics (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                trackTitle TEXT NOT NULL,
                artist TEXT NOT NULL,
                syncedLyrics TEXT,
                plainLyrics TEXT,
                instrumental BOOLEAN NOT NULL DEFAULT 0,
                UNIQUE(trackTitle, artist)
            );",
        )
    }

    pub fn fetch_relative_paths(&self) -> HashSet<String> {
        let mut result = HashSet::new();
        let Ok(mut stmt) = self.conn.prepare("SELECT fileURL FROM tracks") else {
            return result;
        };
        let rows = stmt.query_map([], |row| row.get::<_, String>(0));
        if let Ok(rows) = rows {
            for row in rows.flatten() {
                result.insert(row);
            }
        }
        result
    }

    pub fn insert_track(&self, track: &NewTrack) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR REPLACE INTO tracks
             (fileURL, title, artist, albumTitle, trackNumber, duration, dateAdded,
              codec, bitDepth, sampleRate, channels)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
            params![
                track.rel_path,
                track.title,
                track.artist,
                track.album,
                track.track_number,
                track.duration,
                now_string(),
                track.codec,
                track.bit_depth,
                track.sample_rate,
                track.channels,
            ],
        )?;
        if let Some(artwork) = &track.artwork {
            self.save_album_cover_if_missing(&track.album, &track.artist, artwork)?;
        }
        Ok(())
    }

    pub fn save_album_cover_if_missing(
        &self,
        title: &str,
        artist: &str,
        data: &[u8],
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO albumInfo (title, artist, coverArtData, lastFetched)
             VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
             WHERE albumInfo.coverArtData IS NULL",
            params![title, artist, data, now_string()],
        )?;
        Ok(())
    }

    pub fn fetch_album_artwork(&self, title: &str, artist: &str) -> Option<Vec<u8>> {
        self.conn
            .query_row(
                "SELECT coverArtData FROM albumInfo WHERE title = ?1 AND artist = ?2",
                params![title, artist],
                |row| row.get::<_, Option<Vec<u8>>>(0),
            )
            .optional()
            .ok()
            .flatten()
            .flatten()
    }

    pub fn delete_tracks_not_in(&self, keep: &HashSet<String>) -> Result<usize, rusqlite::Error> {
        let existing = self.fetch_relative_paths();
        let mut removed = 0;
        for path in existing {
            if !keep.contains(&path) {
                removed += self
                    .conn
                    .execute("DELETE FROM tracks WHERE fileURL = ?1", params![path])?;
            }
        }
        self.conn.execute(
            "DELETE FROM playlistTracks WHERE trackFileURL NOT IN (SELECT fileURL FROM tracks)",
            [],
        )?;
        Ok(removed)
    }

    pub fn fetch_all_tracks(&self) -> Vec<TrackRow> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT id, fileURL, title, artist, albumTitle, trackNumber, duration,
                    codec, bitDepth, sampleRate, channels, loved, playCount
             FROM tracks ORDER BY albumTitle, trackNumber, title",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(TrackRow {
                id: row.get(0)?,
                rel_path: row.get(1)?,
                title: row.get(2)?,
                artist: row.get(3)?,
                album: row.get(4)?,
                track_number: row.get(5)?,
                duration: row.get(6)?,
                codec: row.get(7)?,
                bit_depth: row.get(8)?,
                sample_rate: row.get(9)?,
                channels: row.get(10)?,
                loved: row.get(11)?,
                play_count: row.get(12)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn album_meta(&self) -> HashMap<(String, String), (Option<String>, Option<String>)> {
        let mut result = HashMap::new();
        let Ok(mut stmt) = self
            .conn
            .prepare("SELECT title, artist, year, genre FROM albumInfo")
        else {
            return result;
        };
        let rows = stmt.query_map([], |row| {
            Ok((
                (row.get::<_, String>(0)?, row.get::<_, String>(1)?),
                (
                    row.get::<_, Option<String>>(2)?,
                    row.get::<_, Option<String>>(3)?,
                ),
            ))
        });
        if let Ok(rows) = rows {
            for (key, value) in rows.flatten() {
                result.insert(key, value);
            }
        }
        result
    }

    pub fn set_loved(
        &self,
        rel_path: &str,
        loved: bool,
        pending_op: Option<&str>,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE tracks SET loved = ?1, lovedPendingOp = ?2 WHERE fileURL = ?3",
            params![loved, pending_op, rel_path],
        )?;
        Ok(())
    }

    pub fn clear_pending_love_op(&self, rel_path: &str) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE tracks SET lovedPendingOp = NULL WHERE fileURL = ?1",
            params![rel_path],
        )?;
        Ok(())
    }

    pub fn fetch_pending_love_ops(&self) -> Vec<PendingLoveOp> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT fileURL, title, artist, lovedPendingOp FROM tracks
             WHERE lovedPendingOp IS NOT NULL",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(PendingLoveOp {
                rel_path: row.get(0)?,
                title: row.get(1)?,
                artist: row.get(2)?,
                op: row.get(3)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn increment_play_count(&self, rel_path: &str) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE tracks SET playCount = playCount + 1, lastPlayed = ?1 WHERE fileURL = ?2",
            params![now_string(), rel_path],
        )?;
        Ok(())
    }

    pub fn insert_scrobble(
        &self,
        title: &str,
        artist: &str,
        album: &str,
        timestamp_unix: i64,
        duration: i64,
        submitted: bool,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO scrobbles (trackTitle, artist, albumTitle, timestamp, duration, submitted)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![
                title,
                artist,
                album,
                string_from_unix(timestamp_unix),
                duration,
                submitted
            ],
        )?;
        Ok(())
    }

    pub fn fetch_pending_scrobbles(&self) -> Vec<PendingScrobble> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT id, trackTitle, artist, albumTitle, timestamp, duration
             FROM scrobbles WHERE submitted = 0 ORDER BY timestamp",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(PendingScrobble {
                id: row.get(0)?,
                title: row.get(1)?,
                artist: row.get(2)?,
                album: row.get(3)?,
                timestamp_unix: unix_from_string(&row.get::<_, String>(4)?),
                duration: row.get(5)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn mark_scrobbles_submitted(&self, ids: &[i64]) -> Result<(), rusqlite::Error> {
        for id in ids {
            self.conn.execute(
                "UPDATE scrobbles SET submitted = 1 WHERE id = ?1",
                params![id],
            )?;
        }
        Ok(())
    }

    pub fn retire_pending_scrobbles_older_than(&self, cutoff_unix: i64) -> usize {
        self.conn
            .execute(
                "UPDATE scrobbles SET submitted = 1 WHERE submitted = 0 AND timestamp < ?1",
                params![string_from_unix(cutoff_unix)],
            )
            .unwrap_or(0)
    }

    pub fn retire_all_pending_scrobbles(&self) -> usize {
        self.conn
            .execute("UPDATE scrobbles SET submitted = 1 WHERE submitted = 0", [])
            .unwrap_or(0)
    }

    pub fn create_playlist(&self, name: &str) -> Result<i64, rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO playlists (name, createdAt) VALUES (?1, ?2)",
            params![name, now_string()],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    pub fn delete_playlist(&self, id: i64) -> Result<(), rusqlite::Error> {
        self.conn
            .execute("DELETE FROM playlists WHERE id = ?1", params![id])?;
        Ok(())
    }

    pub fn fetch_playlists(&self) -> Vec<PlaylistRow> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT p.id, p.name,
                    (SELECT COUNT(*) FROM playlistTracks pt WHERE pt.playlistId = p.id)
             FROM playlists p ORDER BY p.createdAt",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(PlaylistRow {
                id: row.get(0)?,
                name: row.get(1)?,
                track_count: row.get(2)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn add_track_to_playlist(
        &self,
        playlist_id: i64,
        rel_path: &str,
    ) -> Result<(), rusqlite::Error> {
        let next: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(MAX(position), -1) + 1 FROM playlistTracks WHERE playlistId = ?1",
                params![playlist_id],
                |row| row.get(0),
            )
            .unwrap_or(0);
        self.conn.execute(
            "INSERT INTO playlistTracks (playlistId, trackFileURL, position) VALUES (?1, ?2, ?3)",
            params![playlist_id, rel_path, next],
        )?;
        Ok(())
    }

    pub fn playlist_tracks(&self, playlist_id: i64) -> Vec<PlaylistTrackRow> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT id, trackFileURL FROM playlistTracks
             WHERE playlistId = ?1 ORDER BY position",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map(params![playlist_id], |row| {
            Ok(PlaylistTrackRow {
                row_id: row.get(0)?,
                rel_path: row.get(1)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn remove_playlist_track(&self, row_id: i64) -> Result<(), rusqlite::Error> {
        self.conn
            .execute("DELETE FROM playlistTracks WHERE id = ?1", params![row_id])?;
        Ok(())
    }

    pub fn reorder_playlist(
        &self,
        playlist_id: i64,
        ordered_row_ids: &[i64],
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        for (position, row_id) in ordered_row_ids.iter().enumerate() {
            let result = self.conn.execute(
                "UPDATE playlistTracks SET position = ?1 WHERE id = ?2 AND playlistId = ?3",
                params![position as i64, row_id, playlist_id],
            );
            if let Err(err) = result {
                let _ = self.conn.execute_batch("ROLLBACK");
                return Err(err);
            }
        }
        self.conn.execute_batch("COMMIT")
    }

    pub fn playlist_name(&self, playlist_id: i64) -> Option<String> {
        self.conn
            .query_row(
                "SELECT name FROM playlists WHERE id = ?1",
                params![playlist_id],
                |row| row.get(0),
            )
            .optional()
            .ok()
            .flatten()
    }

    pub fn fetch_lyrics(&self, title: &str, artist: &str) -> Option<LyricsRow> {
        self.conn
            .query_row(
                "SELECT syncedLyrics, plainLyrics, instrumental FROM lyrics
                 WHERE trackTitle = ?1 AND artist = ?2",
                params![title, artist],
                |row| {
                    Ok(LyricsRow {
                        synced: row.get(0)?,
                        plain: row.get(1)?,
                        instrumental: row.get(2)?,
                    })
                },
            )
            .optional()
            .ok()
            .flatten()
    }

    pub fn save_lyrics(
        &self,
        title: &str,
        artist: &str,
        synced: Option<&str>,
        plain: Option<&str>,
        instrumental: bool,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO lyrics (trackTitle, artist, syncedLyrics, plainLyrics, instrumental)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(trackTitle, artist) DO UPDATE SET
                syncedLyrics = excluded.syncedLyrics,
                plainLyrics = excluded.plainLyrics,
                instrumental = excluded.instrumental",
            params![title, artist, synced, plain, instrumental],
        )?;
        Ok(())
    }

    pub fn scrobble_stats(&self) -> ScrobbleStats {
        let total_plays: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM scrobbles", [], |row| row.get(0))
            .unwrap_or(0);
        let total_minutes: i64 = self
            .conn
            .query_row(
                "SELECT COALESCE(SUM(duration), 0) / 60 FROM scrobbles",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0);
        let top_artists = self.top_rows(
            "SELECT artist, COUNT(*) c FROM scrobbles GROUP BY artist ORDER BY c DESC LIMIT 10",
        );
        let top_albums = self.top_rows(
            "SELECT albumTitle || ' — ' || artist, COUNT(*) c FROM scrobbles
             GROUP BY albumTitle, artist ORDER BY c DESC LIMIT 10",
        );
        let top_tracks = self.top_rows(
            "SELECT trackTitle || ' — ' || artist, COUNT(*) c FROM scrobbles
             GROUP BY trackTitle, artist ORDER BY c DESC LIMIT 10",
        );
        let mut clock = [0i64; 24];
        if let Ok(mut stmt) = self.conn.prepare(
            "SELECT CAST(strftime('%H', timestamp, 'localtime') AS INTEGER), COUNT(*)
             FROM scrobbles GROUP BY 1",
        ) {
            let rows =
                stmt.query_map([], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)));
            if let Ok(rows) = rows {
                for (hour, count) in rows.flatten() {
                    clock[(hour.rem_euclid(24)) as usize] += count;
                }
            }
        }
        ScrobbleStats {
            total_plays,
            total_minutes,
            top_artists,
            top_albums,
            top_tracks,
            clock,
        }
    }

    fn top_rows(&self, sql: &str) -> Vec<(String, i64)> {
        let Ok(mut stmt) = self.conn.prepare(sql) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)));
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }
}

pub struct ScrobbleStats {
    pub total_plays: i64,
    pub total_minutes: i64,
    pub top_artists: Vec<(String, i64)>,
    pub top_albums: Vec<(String, i64)>,
    pub top_tracks: Vec<(String, i64)>,
    pub clock: [i64; 24],
}
