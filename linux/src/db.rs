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

#[derive(Clone, Debug)]
pub struct ScrobbleRow {
    pub title: String,
    pub artist: String,
    pub album: String,
    pub timestamp_unix: i64,
    pub duration: i64,
}

pub struct AlbumInfoStatus {
    pub year: Option<String>,
    pub genre: Option<String>,
    pub has_cover: bool,
    pub last_fetched_unix: Option<i64>,
}

#[derive(Clone, Debug)]
pub struct WantlistItemRow {
    pub norm_key: String,
    pub kind: String,
    pub title: String,
    pub artist: String,
    pub image_url: Option<String>,
    pub source: String,
    pub score: f64,
    pub reason: String,
    pub play_count: i64,
}

#[derive(Clone, Debug)]
pub struct NewReleaseRow {
    pub artist: String,
    pub album: String,
    pub release_unix: i64,
    pub image_url: Option<String>,
    pub store_url: Option<String>,
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
        db.backfill_enrichment_markers()?;
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

    /// One-time backfill (guarded by user_version): scan-era albumInfo rows
    /// carry a lastFetched stamped by the cover hoist, which would wrongly
    /// suppress the first metadata enrichment pass — clear it for rows that
    /// have never been enriched.
    fn backfill_enrichment_markers(&self) -> Result<(), rusqlite::Error> {
        let version: i64 = self
            .conn
            .query_row("PRAGMA user_version", [], |row| row.get(0))
            .unwrap_or(0);
        if version >= 1 {
            return Ok(());
        }
        self.conn.execute(
            "UPDATE albumInfo SET lastFetched = NULL
             WHERE coverArtURL IS NULL AND musicBrainzID IS NULL
               AND year IS NULL AND genre IS NULL",
            [],
        )?;
        self.conn.pragma_update(None, "user_version", 1)?;
        Ok(())
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
            );
            CREATE TABLE IF NOT EXISTS artists (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL UNIQUE,
                bio TEXT,
                imageURL TEXT,
                musicBrainzID TEXT,
                lastFetched DATETIME
            );
            CREATE TABLE IF NOT EXISTS similarArtistCache (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                artist TEXT NOT NULL,
                similarName TEXT NOT NULL,
                \"match\" DOUBLE NOT NULL DEFAULT 0,
                fetchedAt DATETIME NOT NULL,
                UNIQUE(artist, similarName)
            );
            CREATE TABLE IF NOT EXISTS wantlist (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                normKey TEXT NOT NULL UNIQUE,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                artist TEXT NOT NULL,
                imageURL TEXT,
                state TEXT NOT NULL,
                source TEXT NOT NULL,
                score DOUBLE NOT NULL DEFAULT 0,
                reason TEXT NOT NULL DEFAULT '',
                playCount INTEGER NOT NULL DEFAULT 0,
                addedAt DATETIME NOT NULL,
                resolvedAt DATETIME,
                acknowledged BOOLEAN NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS wantlist_on_state ON wantlist(state);
            CREATE TABLE IF NOT EXISTS newReleaseCache (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                artist TEXT NOT NULL,
                albumTitle TEXT NOT NULL,
                releaseDate DATETIME NOT NULL,
                imageURL TEXT,
                storeURL TEXT,
                fetchedAt DATETIME NOT NULL,
                UNIQUE(artist, albumTitle)
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
            "INSERT INTO albumInfo (title, artist, coverArtData)
             VALUES (?1, ?2, ?3)
             ON CONFLICT(title, artist) DO UPDATE SET coverArtData = excluded.coverArtData
             WHERE albumInfo.coverArtData IS NULL",
            params![title, artist, data],
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

    pub fn set_play_count(&self, rel_path: &str, count: i64) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE tracks SET playCount = ?1 WHERE fileURL = ?2",
            params![count, rel_path],
        )?;
        Ok(())
    }

    /// Rewrites the album title of every track in a variant pressing to the
    /// canonical title, physically fusing library editions. Diff-based rescans
    /// never re-read existing rows, so this persists.
    pub fn rewrite_album_title(
        &self,
        from_title: &str,
        to_title: &str,
        artist: &str,
    ) -> Result<usize, rusqlite::Error> {
        self.conn.execute(
            "UPDATE tracks SET albumTitle = ?1 WHERE artist = ?2 AND albumTitle = ?3",
            params![to_title, artist, from_title],
        )
    }

    /// Folds the enrichment fields of variant `albumInfo` rows into the
    /// canonical row (COALESCE, mirroring `apply_album_enrichment`) then deletes
    /// the now-orphaned variant rows.
    pub fn merge_album_info(
        &self,
        canonical_title: &str,
        variant_titles: &[String],
        artist: &str,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute_batch("BEGIN IMMEDIATE")?;
        let result = self.merge_album_info_inner(canonical_title, variant_titles, artist);
        match result {
            Ok(()) => self.conn.execute_batch("COMMIT").map(|_| ()),
            Err(err) => {
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(err)
            }
        }
    }

    fn merge_album_info_inner(
        &self,
        canonical_title: &str,
        variant_titles: &[String],
        artist: &str,
    ) -> Result<(), rusqlite::Error> {
        for variant in variant_titles {
            if variant == canonical_title {
                continue;
            }
            self.conn.execute(
                "INSERT INTO albumInfo
                    (title, artist, year, genre, coverArtURL, coverArtData, musicBrainzID, lastFetched)
                 SELECT ?1, ?2, year, genre, coverArtURL, coverArtData, musicBrainzID, lastFetched
                 FROM albumInfo WHERE title = ?3 AND artist = ?2
                 ON CONFLICT(title, artist) DO UPDATE SET
                    year = COALESCE(albumInfo.year, excluded.year),
                    genre = COALESCE(albumInfo.genre, excluded.genre),
                    coverArtURL = COALESCE(albumInfo.coverArtURL, excluded.coverArtURL),
                    coverArtData = COALESCE(albumInfo.coverArtData, excluded.coverArtData),
                    musicBrainzID = COALESCE(albumInfo.musicBrainzID, excluded.musicBrainzID)",
                params![canonical_title, artist, variant],
            )?;
            self.conn.execute(
                "DELETE FROM albumInfo WHERE title = ?1 AND artist = ?2",
                params![variant, artist],
            )?;
        }
        Ok(())
    }

    pub fn delete_track_by_rel_path(&self, rel_path: &str) -> Result<(), rusqlite::Error> {
        self.conn
            .execute("DELETE FROM tracks WHERE fileURL = ?1", params![rel_path])?;
        self.conn.execute(
            "DELETE FROM playlistTracks WHERE trackFileURL = ?1",
            params![rel_path],
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

    pub fn fetch_all_scrobble_rows(&self) -> Vec<ScrobbleRow> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT trackTitle, artist, albumTitle, timestamp, duration
             FROM scrobbles ORDER BY timestamp",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(ScrobbleRow {
                title: row.get(0)?,
                artist: row.get(1)?,
                album: row.get(2)?,
                timestamp_unix: unix_from_string(&row.get::<_, String>(3)?),
                duration: row.get(4)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn play_counts_by_track(&self) -> Vec<(String, String, i64)> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT trackTitle, artist, COUNT(*) FROM scrobbles GROUP BY trackTitle, artist",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok((row.get(0)?, row.get(1)?, row.get(2)?))
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn track_sort_keys(&self) -> HashMap<String, Option<i64>> {
        let mut result = HashMap::new();
        let Ok(mut stmt) = self.conn.prepare("SELECT fileURL, lastPlayed FROM tracks") else {
            return result;
        };
        let rows = stmt.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, Option<String>>(1)?,
            ))
        });
        if let Ok(rows) = rows {
            for (path, last_played) in rows.flatten() {
                result.insert(path, last_played.map(|s| unix_from_string(&s)));
            }
        }
        result
    }

    pub fn album_info_status(&self, title: &str, artist: &str) -> Option<AlbumInfoStatus> {
        self.conn
            .query_row(
                "SELECT year, genre, coverArtData IS NOT NULL, lastFetched
                 FROM albumInfo WHERE title = ?1 AND artist = ?2",
                params![title, artist],
                |row| {
                    Ok(AlbumInfoStatus {
                        year: row.get(0)?,
                        genre: row.get(1)?,
                        has_cover: row.get(2)?,
                        last_fetched_unix: row
                            .get::<_, Option<String>>(3)?
                            .map(|s| unix_from_string(&s)),
                    })
                },
            )
            .optional()
            .ok()
            .flatten()
    }

    /// Writes enrichment results into albumInfo, only filling fields that are
    /// still missing (iOS fill-missing semantics), and always bumping
    /// lastFetched so failed/empty lookups are not retried immediately.
    pub fn apply_album_enrichment(
        &self,
        title: &str,
        artist: &str,
        year: Option<&str>,
        genre: Option<&str>,
        cover_url: Option<&str>,
        cover_data: Option<&[u8]>,
        mbid: Option<&str>,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO albumInfo (title, artist, year, genre, coverArtURL, coverArtData, musicBrainzID, lastFetched)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(title, artist) DO UPDATE SET
                year = COALESCE(albumInfo.year, excluded.year),
                genre = COALESCE(albumInfo.genre, excluded.genre),
                coverArtURL = COALESCE(albumInfo.coverArtURL, excluded.coverArtURL),
                coverArtData = COALESCE(albumInfo.coverArtData, excluded.coverArtData),
                musicBrainzID = COALESCE(albumInfo.musicBrainzID, excluded.musicBrainzID),
                lastFetched = excluded.lastFetched",
            params![title, artist, year, genre, cover_url, cover_data, mbid, now_string()],
        )?;
        Ok(())
    }

    pub fn upsert_artist_info(
        &self,
        name: &str,
        bio: Option<&str>,
        image_url: Option<&str>,
        mbid: Option<&str>,
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT INTO artists (name, bio, imageURL, musicBrainzID, lastFetched)
             VALUES (?1, ?2, ?3, ?4, ?5)
             ON CONFLICT(name) DO UPDATE SET
                bio = COALESCE(excluded.bio, artists.bio),
                imageURL = COALESCE(excluded.imageURL, artists.imageURL),
                musicBrainzID = COALESCE(excluded.musicBrainzID, artists.musicBrainzID),
                lastFetched = excluded.lastFetched",
            params![name, bio, image_url, mbid, now_string()],
        )?;
        Ok(())
    }

    pub fn artist_bio(&self, name: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT bio FROM artists WHERE name = ?1",
                params![name],
                |row| row.get(0),
            )
            .optional()
            .ok()
            .flatten()
            .flatten()
    }

    pub fn artist_image_url(&self, name: &str) -> Option<String> {
        self.conn
            .query_row(
                "SELECT imageURL FROM artists WHERE name = ?1",
                params![name],
                |row| row.get(0),
            )
            .optional()
            .ok()
            .flatten()
            .flatten()
    }

    pub fn similar_artists(&self, artist: &str) -> Vec<(String, f64, i64)> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT similarName, \"match\", fetchedAt FROM similarArtistCache
             WHERE artist = ?1 ORDER BY \"match\" DESC",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map(params![artist], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, f64>(1)?,
                unix_from_string(&row.get::<_, String>(2)?),
            ))
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn mark_loved(&self, rel_paths: &[String], loved: bool) -> Result<(), rusqlite::Error> {
        for rel_path in rel_paths {
            self.conn.execute(
                "UPDATE tracks SET loved = ?1 WHERE fileURL = ?2 AND lovedPendingOp IS NULL",
                params![loved, rel_path],
            )?;
        }
        Ok(())
    }

    pub fn fetch_wanted_items(&self) -> Vec<WantlistItemRow> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT normKey, kind, title, artist, imageURL, source, score, reason, playCount
             FROM wantlist WHERE state = 'wanted' ORDER BY score DESC, addedAt DESC",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(WantlistItemRow {
                norm_key: row.get(0)?,
                kind: row.get(1)?,
                title: row.get(2)?,
                artist: row.get(3)?,
                image_url: row.get(4)?,
                source: row.get(5)?,
                score: row.get(6)?,
                reason: row.get(7)?,
                play_count: row.get(8)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Upserts computed suggestions without resurrecting dismissed or acquired
    /// rows (iOS mergeWantlistSuggestions semantics): fresh metadata only lands
    /// on rows still in the wanted state; unknown keys insert as wanted.
    pub fn merge_wantlist_suggestions(
        &self,
        suggestions: &[WantlistItemRow],
    ) -> Result<(), rusqlite::Error> {
        let now = now_string();
        for item in suggestions {
            self.conn.execute(
                "INSERT INTO wantlist
                 (normKey, kind, title, artist, imageURL, state, source, score, reason, playCount, addedAt, acknowledged)
                 VALUES (?1, ?2, ?3, ?4, ?5, 'wanted', ?6, ?7, ?8, ?9, ?10, ?11)
                 ON CONFLICT(normKey) DO UPDATE SET
                    score = excluded.score,
                    reason = excluded.reason,
                    playCount = excluded.playCount,
                    imageURL = COALESCE(excluded.imageURL, wantlist.imageURL)
                 WHERE wantlist.state = 'wanted'",
                params![
                    item.norm_key,
                    item.kind,
                    item.title,
                    item.artist,
                    item.image_url,
                    item.source,
                    item.score,
                    item.reason,
                    item.play_count,
                    now,
                    item.source == "manual",
                ],
            )?;
        }
        Ok(())
    }

    pub fn set_wantlist_state(&self, norm_key: &str, state: &str) -> Result<(), rusqlite::Error> {
        let resolved_at = if state == "wanted" {
            None
        } else {
            Some(now_string())
        };
        self.conn.execute(
            "UPDATE wantlist SET state = ?1, resolvedAt = ?2 WHERE normKey = ?3",
            params![state, resolved_at, norm_key],
        )?;
        Ok(())
    }

    pub fn unseen_wanted_count(&self) -> i64 {
        self.conn
            .query_row(
                "SELECT COUNT(*) FROM wantlist WHERE state = 'wanted' AND acknowledged = 0",
                [],
                |row| row.get(0),
            )
            .unwrap_or(0)
    }

    pub fn acknowledge_wantlist(&self) -> Result<(), rusqlite::Error> {
        self.conn
            .execute("UPDATE wantlist SET acknowledged = 1 WHERE state = 'wanted'", [])?;
        Ok(())
    }

    pub fn fetch_new_releases(&self) -> Vec<NewReleaseRow> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT artist, albumTitle, releaseDate, imageURL, storeURL FROM newReleaseCache
             ORDER BY releaseDate DESC",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |row| {
            Ok(NewReleaseRow {
                artist: row.get(0)?,
                album: row.get(1)?,
                release_unix: unix_from_string(&row.get::<_, String>(2)?),
                image_url: row.get(3)?,
                store_url: row.get(4)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    pub fn new_releases_fetched_at(&self) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT MAX(fetchedAt) FROM newReleaseCache",
                [],
                |row| row.get::<_, Option<String>>(0),
            )
            .ok()
            .flatten()
            .map(|s| unix_from_string(&s))
    }

    pub fn replace_new_releases(&self, releases: &[NewReleaseRow]) -> Result<(), rusqlite::Error> {
        let now = now_string();
        self.conn.execute("DELETE FROM newReleaseCache", [])?;
        for release in releases {
            self.conn.execute(
                "INSERT OR REPLACE INTO newReleaseCache
                 (artist, albumTitle, releaseDate, imageURL, storeURL, fetchedAt)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                params![
                    release.artist,
                    release.album,
                    string_from_unix(release.release_unix),
                    release.image_url,
                    release.store_url,
                    now
                ],
            )?;
        }
        Ok(())
    }

    pub fn replace_similar_artists(
        &self,
        artist: &str,
        entries: &[(String, f64)],
    ) -> Result<(), rusqlite::Error> {
        let now = now_string();
        self.conn.execute(
            "DELETE FROM similarArtistCache WHERE artist = ?1",
            params![artist],
        )?;
        for (name, matched) in entries {
            self.conn.execute(
                "INSERT INTO similarArtistCache (artist, similarName, \"match\", fetchedAt)
                 VALUES (?1, ?2, ?3, ?4)
                 ON CONFLICT(artist, similarName) DO UPDATE SET
                    \"match\" = excluded.\"match\", fetchedAt = excluded.fetchedAt",
                params![artist, name, matched, now],
            )?;
        }
        Ok(())
    }
}

