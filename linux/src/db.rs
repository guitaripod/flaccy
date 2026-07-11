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

pub struct AlbumRetitle {
    pub from_title: String,
    pub from_artist: String,
    pub to_title: String,
    pub to_artist: String,
}

pub struct KeeperUpdate {
    pub rel_path: String,
    pub loved: bool,
    pub play_count: i64,
}

pub struct AlbumInfoMerge {
    pub canonical_title: String,
    pub canonical_artist: String,
    /// `(variant_title, variant_artist)` pairs folded into the canonical album.
    pub variants: Vec<(String, String)>,
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
            CREATE INDEX IF NOT EXISTS scrobbles_on_trackTitle_artist ON scrobbles(trackTitle, artist);
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

    /// Clears the enrichment retry stamp for every album still missing cover
    /// art, so the next background pass re-attempts them immediately (e.g. after
    /// adding the Cover Art Archive source) instead of waiting out the 30-day
    /// retry window. Returns the number of albums queued for a retry.
    pub fn reset_missing_cover_retry(&self) -> usize {
        self.conn
            .execute(
                "UPDATE albumInfo SET lastFetched = NULL WHERE coverArtData IS NULL",
                [],
            )
            .unwrap_or(0)
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

    /// Backfills each track's play count and last-played time from the scrobble
    /// history (which includes imported Last.fm plays), so the Plays column and
    /// every play-based sort reflect a freshly imported history rather than only
    /// local playback.
    pub fn reconcile_play_counts_from_scrobbles(&self) {
        let result = self.conn.execute_batch(
            "UPDATE tracks SET
                playCount = (SELECT COUNT(*) FROM scrobbles s WHERE s.trackTitle = tracks.title AND s.artist = tracks.artist),
                lastPlayed = (SELECT MAX(s.timestamp) FROM scrobbles s WHERE s.trackTitle = tracks.title AND s.artist = tracks.artist)
             WHERE EXISTS (SELECT 1 FROM scrobbles s WHERE s.trackTitle = tracks.title AND s.artist = tracks.artist)",
        );
        if let Err(err) = result {
            crate::logger::error("import", &format!("play-count reconcile failed: {err}"));
        }
    }

    pub fn set_play_count(&self, rel_path: &str, count: i64) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE tracks SET playCount = ?1 WHERE fileURL = ?2",
            params![count, rel_path],
        )?;
        Ok(())
    }

    /// Retitles every track of a variant pressing onto the canonical album,
    /// converging the artist too so raw spellings that normalize-equal collapse
    /// to one. Diff-based rescans never re-read existing rows, so this persists.
    pub fn rewrite_album_title(
        &self,
        from_title: &str,
        from_artist: &str,
        to_title: &str,
        to_artist: &str,
    ) -> Result<usize, rusqlite::Error> {
        self.conn.execute(
            "UPDATE tracks SET albumTitle = ?1, artist = ?2 WHERE albumTitle = ?3 AND artist = ?4",
            params![to_title, to_artist, from_title, from_artist],
        )
    }

    /// COALESCE-folds each variant `albumInfo` row — including its `lastFetched`
    /// cache stamp, so a fused edition is not re-enriched — into the canonical
    /// album, then deletes the orphaned variant row. Runs on the current
    /// connection so `apply_cleanup` can wrap it in a single transaction.
    fn merge_album_info(
        &self,
        canonical_title: &str,
        canonical_artist: &str,
        variants: &[(String, String)],
    ) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "INSERT OR IGNORE INTO albumInfo (title, artist) VALUES (?1, ?2)",
            params![canonical_title, canonical_artist],
        )?;
        for (variant_title, variant_artist) in variants {
            if variant_title == canonical_title && variant_artist == canonical_artist {
                continue;
            }
            self.conn.execute(
                "UPDATE albumInfo SET
                    coverArtURL = COALESCE(coverArtURL, (SELECT coverArtURL FROM albumInfo WHERE title = ?1 AND artist = ?2)),
                    coverArtData = COALESCE(coverArtData, (SELECT coverArtData FROM albumInfo WHERE title = ?1 AND artist = ?2)),
                    musicBrainzID = COALESCE(musicBrainzID, (SELECT musicBrainzID FROM albumInfo WHERE title = ?1 AND artist = ?2)),
                    year = COALESCE(year, (SELECT year FROM albumInfo WHERE title = ?1 AND artist = ?2)),
                    genre = COALESCE(genre, (SELECT genre FROM albumInfo WHERE title = ?1 AND artist = ?2)),
                    lastFetched = COALESCE(lastFetched, (SELECT lastFetched FROM albumInfo WHERE title = ?1 AND artist = ?2))
                 WHERE title = ?3 AND artist = ?4",
                params![variant_title, variant_artist, canonical_title, canonical_artist],
            )?;
            self.conn.execute(
                "DELETE FROM albumInfo WHERE title = ?1 AND artist = ?2",
                params![variant_title, variant_artist],
            )?;
        }
        Ok(())
    }

    /// Applies a whole library-hygiene plan in ONE transaction (mirrors the
    /// macOS `applyHygiene`): losers are unlinked from playlists and the track
    /// table, each redundant variant's `albumInfo` is folded into the canonical
    /// album, variant tracks are retitled onto the canonical title/artist, and
    /// each surviving keeper inherits its group's loved flag and highest play
    /// count. Trashing the loser files happens after this commits — files can
    /// not join a DB transaction.
    pub fn apply_cleanup(
        &self,
        retitles: &[AlbumRetitle],
        keeper_updates: &[KeeperUpdate],
        album_info_merges: &[AlbumInfoMerge],
        loser_rel_paths: &[String],
    ) -> Result<(), rusqlite::Error> {
        let tx = self.conn.unchecked_transaction()?;
        for path in loser_rel_paths {
            self.delete_track_by_rel_path(path)?;
        }
        for merge in album_info_merges {
            self.merge_album_info(&merge.canonical_title, &merge.canonical_artist, &merge.variants)?;
        }
        for retitle in retitles {
            self.rewrite_album_title(
                &retitle.from_title,
                &retitle.from_artist,
                &retitle.to_title,
                &retitle.to_artist,
            )?;
        }
        for update in keeper_updates {
            self.set_play_count(&update.rel_path, update.play_count)?;
            tx.execute(
                "UPDATE tracks SET loved = ?1 WHERE fileURL = ?2",
                params![update.loved, update.rel_path],
            )?;
        }
        tx.commit()
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

    /// Inserts a page of imported scrobbles inside one transaction so a large
    /// history import commits per-page (hundreds) instead of per-row (tens of
    /// thousands), keeping the pull fast and easy on the disk.
    pub fn insert_scrobbles_batch(
        &self,
        rows: &[(String, String, String, i64, i64, bool)],
    ) -> Result<usize, rusqlite::Error> {
        if rows.is_empty() {
            return Ok(0);
        }
        let tx = self.conn.unchecked_transaction()?;
        let mut inserted = 0usize;
        {
            let mut stmt = tx.prepare(
                "INSERT INTO scrobbles (trackTitle, artist, albumTitle, timestamp, duration, submitted)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            )?;
            for (title, artist, album, timestamp_unix, duration, submitted) in rows {
                stmt.execute(params![
                    title,
                    artist,
                    album,
                    string_from_unix(*timestamp_unix),
                    duration,
                    submitted
                ])?;
                inserted += 1;
            }
        }
        tx.commit()?;
        Ok(inserted)
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

    pub fn rename_playlist(&self, id: i64, name: &str) -> Result<(), rusqlite::Error> {
        self.conn.execute(
            "UPDATE playlists SET name = ?1 WHERE id = ?2",
            params![name, id],
        )?;
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

    pub fn scrobble_count(&self) -> i64 {
        self.conn
            .query_row("SELECT COUNT(*) FROM scrobbles", [], |row| row.get(0))
            .unwrap_or(0)
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

#[cfg(test)]
mod cleanup_tests {
    use super::*;
    use crate::hygiene::{self, ConsolidationGroup, DuplicateGroup};
    use crate::library;

    struct TempDb {
        path: PathBuf,
        db: Db,
    }

    impl TempDb {
        fn open() -> Self {
            let path = std::env::temp_dir()
                .join(format!("flaccy-cleanup-test-{}.sqlite", std::process::id()));
            remove_all(&path);
            let db = Db::open(&path).expect("temp db opens");
            Self { path, db }
        }
    }

    impl Drop for TempDb {
        fn drop(&mut self) {
            remove_all(&self.path);
        }
    }

    fn remove_all(path: &Path) {
        let _ = std::fs::remove_file(path);
        for suffix in ["-wal", "-shm"] {
            let _ = std::fs::remove_file(PathBuf::from(format!("{}{}", path.display(), suffix)));
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn insert(
        db: &Db,
        rel_path: &str,
        title: &str,
        artist: &str,
        album: &str,
        track_number: i32,
        duration: f64,
        codec: &str,
        bit_depth: Option<i32>,
        sample_rate: Option<i32>,
    ) {
        db.insert_track(&NewTrack {
            rel_path: rel_path.to_string(),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            track_number,
            duration,
            codec: Some(codec.to_string()),
            bit_depth,
            sample_rate,
            channels: Some(2),
            artwork: None,
        })
        .expect("insert track");
    }

    fn plan_vectors(
        consolidations: &[ConsolidationGroup],
        duplicates: &[DuplicateGroup],
    ) -> (Vec<AlbumRetitle>, Vec<KeeperUpdate>, Vec<AlbumInfoMerge>, Vec<String>) {
        let retitles = consolidations
            .iter()
            .flat_map(|group| {
                group.variants.iter().map(move |variant| AlbumRetitle {
                    from_title: variant.title.clone(),
                    from_artist: variant.artist.clone(),
                    to_title: group.canonical_title.clone(),
                    to_artist: group.artist.clone(),
                })
            })
            .collect();
        let merges = consolidations
            .iter()
            .map(|group| AlbumInfoMerge {
                canonical_title: group.canonical_title.clone(),
                canonical_artist: group.artist.clone(),
                variants: group
                    .variants
                    .iter()
                    .map(|variant| (variant.title.clone(), variant.artist.clone()))
                    .collect(),
            })
            .collect();
        let keeper_updates = duplicates
            .iter()
            .map(|group| KeeperUpdate {
                rel_path: group.keeper.rel_path.clone(),
                loved: group.loved,
                play_count: group.play_count,
            })
            .collect();
        let loser_rel_paths = duplicates
            .iter()
            .flat_map(|group| group.losers.iter().map(|loser| loser.rel_path.clone()))
            .collect();
        (retitles, keeper_updates, merges, loser_rel_paths)
    }

    /// End-to-end proof of the "Clean Up Library" apply path against a real
    /// on-disk SQLite database: a Deluxe edition folds into its standard release
    /// (title AND normalize-equal artist converging), and two exact-duplicate
    /// pairs collapse to their highest-fidelity keeper, atomically and
    /// idempotently.
    #[test]
    fn apply_cleanup_folds_editions_and_dedupes() {
        let temp = TempDb::open();
        let db = &temp.db;
        let root = std::env::temp_dir();

        insert(db, "aurora/01.flac", "Opening", "Aurora Band", "Aurora", 1, 200.0, "flac", Some(24), Some(96000));
        insert(db, "aurora/02.flac", "Second", "Aurora Band", "Aurora", 2, 210.0, "flac", Some(24), Some(96000));
        insert(db, "aurora/03.flac", "Third", "Aurora Band", "Aurora", 3, 220.0, "flac", Some(24), Some(96000));
        insert(db, "aurora/04.flac", "Fourth", "Aurora Band", "Aurora", 4, 230.0, "flac", Some(24), Some(96000));
        insert(db, "aurora-deluxe/01.flac", "Opening", "aurora band", "Aurora (Deluxe Edition)", 1, 200.5, "flac", Some(16), Some(44100));
        insert(db, "aurora-deluxe/12.flac", "Bonus Cut", "aurora band", "Aurora (Deluxe Edition)", 12, 180.0, "flac", Some(16), Some(44100));

        insert(db, "nova/01.flac", "Dusk", "Nova", "Nightfall", 1, 250.0, "flac", Some(24), Some(96000));
        insert(db, "nova/01.mp3", "Dusk", "Nova", "Nightfall", 1, 250.0, "mp3", None, Some(44100));

        db.set_play_count("aurora/01.flac", 5).expect("play count");
        db.set_play_count("aurora-deluxe/01.flac", 9).expect("play count");
        db.set_loved("aurora-deluxe/01.flac", true, None).expect("loved");
        db.set_play_count("nova/01.flac", 3).expect("play count");
        db.set_play_count("nova/01.mp3", 1).expect("play count");
        db.set_loved("nova/01.mp3", true, None).expect("loved");

        db.apply_album_enrichment(
            "Aurora (Deluxe Edition)",
            "aurora band",
            Some("2021"),
            Some("Dream Pop"),
            None,
            None,
            None,
        )
        .expect("seed variant albumInfo");

        let raw = library::load(db, false);
        let consolidations = hygiene::consolidation_groups(&raw.albums);
        let duplicates = hygiene::find_duplicate_groups(&raw.tracks, &root);

        assert_eq!(consolidations.len(), 1, "one edition group");
        assert_eq!(consolidations[0].canonical_title, "Aurora", "standard is the fuller pressing");
        assert_eq!(consolidations[0].artist, "Aurora Band", "canonical carries the clean artist spelling");
        assert_eq!(consolidations[0].variants.len(), 1);
        assert_eq!(consolidations[0].variants[0].artist, "aurora band", "variant keeps its raw artist");
        assert_eq!(duplicates.len(), 2, "the shared track and the FLAC/MP3 pair");

        let (retitles, keeper_updates, merges, losers) = plan_vectors(&consolidations, &duplicates);
        db.apply_cleanup(&retitles, &keeper_updates, &merges, &losers)
            .expect("apply cleanup");

        let tracks = db.fetch_all_tracks();
        let by_path = |rel: &str| tracks.iter().find(|t| t.rel_path == rel);

        assert!(
            !tracks.iter().any(|t| t.album == "Aurora (Deluxe Edition)"),
            "no track keeps the Deluxe title"
        );
        let bonus = by_path("aurora-deluxe/12.flac").expect("bonus track survives");
        assert_eq!(bonus.album, "Aurora", "bonus track retitled to the canonical album");
        assert_eq!(bonus.artist, "Aurora Band", "bonus track artist converged to canonical");

        assert!(by_path("aurora-deluxe/01.flac").is_none(), "Deluxe duplicate loser is gone");
        assert!(by_path("nova/01.mp3").is_none(), "MP3 duplicate loser is gone");

        let nova_keeper = by_path("nova/01.flac").expect("FLAC keeper survives");
        assert_eq!(nova_keeper.codec.as_deref(), Some("flac"), "the FLAC is kept");
        assert_eq!(nova_keeper.play_count, 3, "keeper takes the max play count");
        assert!(nova_keeper.loved, "keeper takes the OR of loved");

        let aurora_keeper = by_path("aurora/01.flac").expect("Aurora keeper survives");
        assert_eq!(aurora_keeper.play_count, 9, "shared-track keeper takes the max play count");
        assert!(aurora_keeper.loved, "shared-track keeper inherits loved from the loser");

        let canonical_info = db
            .album_info_status("Aurora", "Aurora Band")
            .expect("canonical albumInfo exists");
        assert_eq!(canonical_info.year.as_deref(), Some("2021"), "variant year folded in");
        assert_eq!(canonical_info.genre.as_deref(), Some("Dream Pop"), "variant genre folded in");
        assert!(
            canonical_info.last_fetched_unix.is_some(),
            "variant lastFetched cache stamp preserved on the canonical row"
        );
        assert!(
            db.album_info_status("Aurora (Deluxe Edition)", "aurora band").is_none(),
            "variant albumInfo row removed"
        );

        let after = library::load(db, false);
        assert!(
            hygiene::consolidation_groups(&after.albums).is_empty(),
            "re-running finds no edition to merge"
        );
        assert!(
            hygiene::find_duplicate_groups(&after.tracks, &root).is_empty(),
            "re-running finds no duplicates"
        );
    }
}
