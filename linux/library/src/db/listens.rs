//! The listening history as Flaccy counts it: every scrobble row carries the
//! listen keys of `crate::listen_history`, so a play pulled from Last.fm under
//! "Song - 2011 Remaster" by "Sigur Ros" counts toward the library's "Song" by
//! "Sigur Rós", and plays, charts and dedup all agree on what one song is.

use super::{string_from_unix, unix_from_string, Db};
use crate::listen_history::{fold_spellings, HistorySyncState, ListenKeyCache, Spelling, StoredListen};
use rusqlite::params;
use std::collections::HashMap;

/// One scrobble pulled from Last.fm.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PulledListen {
    pub timestamp_unix: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
}

/// A song's plays and the time of the latest one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ListenTally {
    pub plays: i64,
    pub last_unix: i64,
}

const LISTEN_KEY_COLUMNS: [&str; 3] = [
    "titleKey TEXT NOT NULL DEFAULT ''",
    "artistKey TEXT NOT NULL DEFAULT ''",
    "albumKey TEXT NOT NULL DEFAULT ''",
];

/// The start of year 1, below every stored timestamp.
const EARLIEST_UNIX: i64 = -62_135_596_800;

/// The `user_version` stage that fills the listen keys of rows stored before
/// the columns existed.
pub(crate) const LISTEN_KEYS_STAGE: i64 = 3;

impl Db {
    pub(crate) fn migrate_listen_key_columns(&self) -> Result<(), rusqlite::Error> {
        for column in LISTEN_KEY_COLUMNS {
            let _ = self
                .conn
                .execute(&format!("ALTER TABLE scrobbles ADD COLUMN {column}"), []);
        }
        self.conn.execute_batch(
            "CREATE INDEX IF NOT EXISTS scrobbles_on_listen_key ON scrobbles(titleKey, artistKey);
             CREATE INDEX IF NOT EXISTS scrobbles_on_artistKey ON scrobbles(artistKey);
             CREATE TABLE IF NOT EXISTS listenSync (
                 account TEXT PRIMARY KEY,
                 state TEXT NOT NULL
             );",
        )
    }

    /// Where the history sync stands for `account` in this database, if it
    /// ever ran here.
    pub fn listen_sync_state(&self, account: &str) -> Option<HistorySyncState> {
        let text: String = self
            .conn
            .query_row(
                "SELECT state FROM listenSync WHERE account = ?1",
                params![account],
                |row| row.get(0),
            )
            .ok()?;
        serde_json::from_str(&text).ok()
    }

    pub fn save_listen_sync_state(&self, state: &HistorySyncState) -> Result<(), rusqlite::Error> {
        let text = serde_json::to_string(state).unwrap_or_default();
        self.conn.execute(
            "INSERT INTO listenSync (account, state) VALUES (?1, ?2)
             ON CONFLICT(account) DO UPDATE SET state = excluded.state",
            params![state.account, text],
        )?;
        Ok(())
    }

    /// Fills the listen keys of every stored scrobble, in one transaction.
    pub(crate) fn backfill_listen_keys(&self) -> Result<usize, rusqlite::Error> {
        let rows: Vec<(i64, String, String, String)> = {
            let mut stmt = self
                .conn
                .prepare("SELECT id, trackTitle, artist, albumTitle FROM scrobbles")?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })?;
            rows.flatten().collect()
        };
        let tx = self.conn.unchecked_transaction()?;
        {
            let mut update = tx.prepare(
                "UPDATE scrobbles SET titleKey = ?1, artistKey = ?2, albumKey = ?3 WHERE id = ?4",
            )?;
            let mut cache = ListenKeyCache::default();
            for (id, title, artist, album) in &rows {
                let keys = cache.keys(title, artist, album);
                update.execute(params![keys.title, keys.artist, keys.album, id])?;
            }
        }
        tx.commit()?;
        Ok(rows.len())
    }

    /// The stored plays from `since_unix` on, as dedup reads them.
    pub fn stored_listens_since(&self, since_unix: i64) -> Vec<StoredListen> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT timestamp, titleKey, artistKey, duration FROM scrobbles WHERE timestamp >= ?1",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map(params![string_from_unix(since_unix)], |row| {
            Ok(StoredListen {
                timestamp_unix: unix_from_string(&row.get::<_, String>(0)?),
                title_key: row.get(1)?,
                artist_key: row.get(2)?,
                played_here: row.get::<_, i64>(3)? > 0,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Stores scrobbles pulled from Last.fm (already deduped by the caller's
    /// ledger) in one transaction, as submitted plays of unknown length. Each
    /// insert also skips a play already stored at the same second under the
    /// same title key, so two syncs that run at once (a headless pull beside
    /// the app) cannot store a page twice. Answers how many were stored.
    pub fn insert_pulled_listens(&self, listens: &[PulledListen]) -> Result<usize, rusqlite::Error> {
        if listens.is_empty() {
            return Ok(0);
        }
        let tx = self.conn.unchecked_transaction()?;
        let mut stored = 0;
        {
            let mut insert = tx.prepare_cached(
                "INSERT INTO scrobbles
                 (trackTitle, artist, albumTitle, timestamp, duration, submitted, titleKey, artistKey, albumKey)
                 SELECT ?1, ?2, ?3, ?4, 0, 1, ?5, ?6, ?7
                 WHERE NOT EXISTS (SELECT 1 FROM scrobbles WHERE timestamp = ?4 AND titleKey = ?5)",
            )?;
            let mut cache = ListenKeyCache::default();
            for listen in listens {
                let keys = cache.keys(&listen.title, &listen.artist, &listen.album);
                stored += insert.execute(params![
                    listen.title,
                    listen.artist,
                    listen.album,
                    string_from_unix(listen.timestamp_unix),
                    keys.title,
                    keys.artist,
                    keys.album,
                ])?;
            }
        }
        tx.commit()?;
        Ok(stored)
    }

    /// The newest play that came from Last.fm rather than from this computer.
    pub fn newest_pulled_listen(&self) -> Option<i64> {
        self.conn
            .query_row(
                "SELECT MAX(timestamp) FROM scrobbles WHERE duration = 0",
                [],
                |row| row.get::<_, Option<String>>(0),
            )
            .ok()
            .flatten()
            .map(|text| unix_from_string(&text))
    }

    /// Plays per song since `since_unix` (all of history when `None`), keyed by
    /// `listen_history::track_listen_key`. Grouped by the database on the key
    /// columns, so the cost is the number of distinct songs.
    pub fn listen_tallies(&self, since_unix: Option<i64>) -> HashMap<String, ListenTally> {
        let mut tallies = HashMap::new();
        let sql = if since_unix.is_some() {
            "SELECT titleKey, artistKey, COUNT(*), MAX(timestamp) FROM scrobbles
             WHERE timestamp >= ?1 GROUP BY titleKey, artistKey"
        } else {
            "SELECT titleKey, artistKey, COUNT(*), MAX(timestamp) FROM scrobbles
             GROUP BY titleKey, artistKey"
        };
        let Ok(mut stmt) = self.conn.prepare(sql) else {
            return tallies;
        };
        let map = |row: &rusqlite::Row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, String>(3)?,
            ))
        };
        let rows = match since_unix {
            Some(since) => stmt.query_map(params![string_from_unix(since)], map),
            None => stmt.query_map([], map),
        };
        if let Ok(rows) = rows {
            for (title, artist, plays, last) in rows.flatten() {
                let mut key = title;
                key.push('\u{0}');
                key.push_str(&artist);
                tallies.insert(
                    key,
                    ListenTally {
                        plays,
                        last_unix: unix_from_string(&last),
                    },
                );
            }
        }
        tallies
    }

    /// The plays in `[from, to)` stored without a length (pulled from
    /// Last.fm), counted per listen key, so their minutes can be estimated
    /// from the library.
    pub fn unmeasured_listens_between(&self, from_unix: i64, to_unix: i64) -> Vec<(String, i64)> {
        let Ok(mut stmt) = self.conn.prepare(
            "SELECT titleKey || char(0) || artistKey, COUNT(*) FROM scrobbles
             WHERE duration = 0 AND timestamp >= ?1 AND timestamp < ?2
             GROUP BY titleKey, artistKey",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map(
            params![string_from_unix(from_unix), string_from_unix(to_unix)],
            |row| Ok((row.get(0)?, row.get(1)?)),
        );
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Plays per song since `since_unix`, by listen key.
    pub fn listen_counts_since(&self, since_unix: Option<i64>) -> HashMap<String, i64> {
        self.listen_tallies(since_unix)
            .into_iter()
            .map(|(key, tally)| (key, tally.plays))
            .collect()
    }

    /// Rewrites each song's play count and last-played time from the whole
    /// history, matched by listen key, touching only the rows that change.
    /// Songs a server supplies keep the counts the server keeps. Returns how
    /// many rows changed.
    pub fn reconcile_play_counts_from_scrobbles(&self) -> usize {
        match self.reconcile_listen_tallies() {
            Ok(changed) => changed,
            Err(err) => {
                crate::logger::error("import", &format!("play-count reconcile failed: {err}"));
                0
            }
        }
    }

    fn reconcile_listen_tallies(&self) -> Result<usize, rusqlite::Error> {
        let tallies = self.listen_tallies(None);
        if tallies.is_empty() {
            return Ok(0);
        }
        let tracks: Vec<(i64, String, String, i64, Option<String>)> = {
            let mut stmt = self.conn.prepare(
                "SELECT id, title, artist, playCount, lastPlayed FROM tracks
                 WHERE fileURL NOT LIKE 'remote://%'",
            )?;
            let rows = stmt.query_map([], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?, row.get(4)?))
            })?;
            rows.flatten().collect()
        };
        let tx = self.conn.unchecked_transaction()?;
        let mut changed = 0;
        {
            let mut update =
                tx.prepare("UPDATE tracks SET playCount = ?1, lastPlayed = ?2 WHERE id = ?3")?;
            for (id, title, artist, plays, last_played) in &tracks {
                let key = crate::listen_history::track_listen_key(title, artist);
                let Some(tally) = tallies.get(&key) else {
                    continue;
                };
                let last = string_from_unix(tally.last_unix);
                if *plays == tally.plays && last_played.as_deref() == Some(last.as_str()) {
                    continue;
                }
                update.execute(params![tally.plays, last, id])?;
                changed += 1;
            }
        }
        tx.commit()?;
        Ok(changed)
    }

    /// How many times a release was played: plays of its songs that were
    /// scrobbled from this release (or from no release at all).
    pub fn album_listen_count(&self, album_title: &str, songs: &[(String, String)]) -> i64 {
        let album_key = crate::listen_history::album_listen_key(album_title);
        let Ok(mut stmt) = self.conn.prepare_cached(
            "SELECT COUNT(*) FROM scrobbles
             WHERE titleKey = ?1 AND artistKey = ?2 AND (albumKey = ?3 OR albumKey = '')",
        ) else {
            return 0;
        };
        let mut seen = std::collections::HashSet::new();
        let mut total = 0;
        for (title, artist) in songs {
            let title_key = crate::listen_history::title_key(title);
            let artist_key = crate::listen_history::artist_listen_key(artist);
            if !seen.insert((title_key.clone(), artist_key.clone())) {
                continue;
            }
            total += stmt
                .query_row(params![title_key, artist_key, album_key], |row| row.get::<_, i64>(0))
                .unwrap_or(0);
        }
        total
    }

    /// The most played artists since `since_unix`, one entry per listen key,
    /// named by the spelling heard most: `(name, plays, seconds)`.
    pub fn top_listen_artists(&self, since_unix: Option<i64>, limit: usize) -> Vec<(String, i64, i64)> {
        let mut folded = fold_spellings(self.spellings(
            "SELECT artistKey, artist, COUNT(*), COALESCE(SUM(duration), 0), MAX(timestamp)
             FROM scrobbles WHERE timestamp >= ?1 GROUP BY artistKey, artist",
            since_unix,
        ));
        folded.truncate(limit);
        folded
    }

    /// The most played releases since `since_unix` as `("Album — Artist",
    /// plays)`, grouped by release and lead artist.
    pub fn top_listen_albums(&self, since_unix: Option<i64>, limit: usize) -> Vec<(String, i64)> {
        let mut folded = fold_spellings(self.spellings(
            "SELECT albumKey || char(0) || artistKey, albumTitle || ' — ' || artist, COUNT(*), 0,
                    MAX(timestamp)
             FROM scrobbles WHERE timestamp >= ?1 AND albumKey <> ''
             GROUP BY albumKey, artistKey, albumTitle, artist",
            since_unix,
        ));
        folded.truncate(limit);
        folded.into_iter().map(|(name, plays, _)| (name, plays)).collect()
    }

    /// The most played songs since `since_unix` as `("Title — Artist", plays)`.
    pub fn top_listen_tracks(&self, since_unix: Option<i64>, limit: usize) -> Vec<(String, i64)> {
        let mut folded = fold_spellings(self.spellings(
            "SELECT titleKey || char(0) || artistKey, trackTitle || ' — ' || artist, COUNT(*), 0,
                    MAX(timestamp)
             FROM scrobbles WHERE timestamp >= ?1
             GROUP BY titleKey, artistKey, trackTitle, artist",
            since_unix,
        ));
        folded.truncate(limit);
        folded.into_iter().map(|(name, plays, _)| (name, plays)).collect()
    }

    /// Runs a `key, name, plays, seconds, latest` grouping over the plays
    /// since `since_unix` (all of them when `None`).
    fn spellings(&self, sql: &str, since_unix: Option<i64>) -> Vec<Spelling<String>> {
        let Ok(mut stmt) = self.conn.prepare(sql) else {
            return Vec::new();
        };
        let since = string_from_unix(since_unix.unwrap_or(EARLIEST_UNIX));
        let rows = stmt.query_map(params![since], |row| {
            Ok(Spelling {
                key: row.get(0)?,
                name: row.get(1)?,
                plays: row.get(2)?,
                seconds: row.get(3)?,
                latest_unix: unix_from_string(&row.get::<_, String>(4)?),
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDb {
        dir: std::path::PathBuf,
        db: Db,
    }

    impl TempDb {
        fn open() -> Self {
            static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let unique = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let dir = std::env::temp_dir().join(format!("flaccy-listens-{}-{unique}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            let db = Db::open(&dir.join("library.sqlite")).expect("temp db opens");
            Self { dir, db }
        }

        fn insert_track(&self, rel_path: &str, title: &str, artist: &str, album: &str) {
            self.db
                .conn
                .execute(
                    "INSERT INTO tracks (fileURL, title, artist, albumTitle, trackNumber, duration, dateAdded)
                     VALUES (?1, ?2, ?3, ?4, 1, 200, '2024-01-01 00:00:00.000')",
                    params![rel_path, title, artist, album],
                )
                .expect("track inserts");
        }

        fn play_count(&self, rel_path: &str) -> i64 {
            self.db
                .conn
                .query_row("SELECT playCount FROM tracks WHERE fileURL = ?1", params![rel_path], |row| {
                    row.get(0)
                })
                .expect("track exists")
        }
    }

    impl Drop for TempDb {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn pulled(timestamp_unix: i64, title: &str, artist: &str, album: &str) -> PulledListen {
        PulledListen {
            timestamp_unix,
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
        }
    }

    #[test]
    fn plays_count_under_one_song_whatever_the_spelling() {
        let temp = TempDb::open();
        let db = &temp.db;
        db.insert_pulled_listens(&[
            pulled(1_700_000_000, "Hoppípolla", "Sigur Rós", "Takk..."),
            pulled(1_700_000_100, "Hoppipolla - 2011 Remaster", "Sigur Ros", "Takk... (Remastered)"),
            pulled(1_700_000_200, "HOPPIPOLLA", "sigur rós", "Takk..."),
            pulled(1_700_000_250, "Hoppípolla", "Sigur Rós", "Takk..."),
        ])
        .unwrap();
        db.insert_scrobble("Glósóli", "Sigur Rós", "Takk...", 1_700_000_300, 370, false)
            .unwrap();

        let tallies = db.listen_tallies(None);
        let key = crate::listen_history::track_listen_key("Hoppípolla", "Sigur Rós");
        assert_eq!(tallies[&key], ListenTally { plays: 4, last_unix: 1_700_000_250 });

        let artists = db.top_listen_artists(None, 10);
        assert_eq!(artists, vec![("Sigur Rós".to_string(), 5, 370)]);
        let tracks = db.top_listen_tracks(None, 10);
        assert_eq!(tracks[0], ("Hoppípolla — Sigur Rós".to_string(), 4));
        let albums = db.top_listen_albums(Some(1_700_000_050), 10);
        assert_eq!(albums, vec![("Takk... — Sigur Rós".to_string(), 4)]);
    }

    #[test]
    fn reconcile_matches_library_songs_by_listen_key_and_touches_only_changes() {
        let temp = TempDb::open();
        let db = &temp.db;
        temp.insert_track("a.flac", "Song (feat. Guest)", "Lead feat. Guest", "Record");
        temp.insert_track("b.flac", "Other", "Lead", "Record");
        db.insert_pulled_listens(&[
            pulled(1_700_000_000, "Song", "Lead", "Record"),
            pulled(1_700_000_500, "song - remastered", "LEAD", "Record"),
        ])
        .unwrap();

        assert_eq!(db.reconcile_play_counts_from_scrobbles(), 1);
        assert_eq!(temp.play_count("a.flac"), 2);
        assert_eq!(temp.play_count("b.flac"), 0);
        assert_eq!(db.reconcile_play_counts_from_scrobbles(), 0);
    }

    #[test]
    fn an_album_counts_plays_of_its_songs_from_that_release_or_none() {
        let temp = TempDb::open();
        let db = &temp.db;
        db.insert_pulled_listens(&[
            pulled(1, "Song", "Band", "Record (Deluxe Edition)"),
            pulled(2, "Song", "Band", ""),
            pulled(3, "Song", "Band", "Greatest Hits"),
            pulled(4, "Other", "Band", "Record"),
            pulled(5, "Unrelated", "Band", "Record"),
        ])
        .unwrap();
        let songs = vec![
            ("Song".to_string(), "Band".to_string()),
            ("Other".to_string(), "Band".to_string()),
            ("Song".to_string(), "Band".to_string()),
        ];
        assert_eq!(db.album_listen_count("Record", &songs), 3);
    }

    #[test]
    fn stored_listens_mark_the_plays_flaccy_recorded() {
        let temp = TempDb::open();
        let db = &temp.db;
        db.insert_scrobble("Here", "A", "", 1_700_000_000, 200, true).unwrap();
        db.insert_pulled_listens(&[pulled(1_700_000_100, "There", "A", "")]).unwrap();
        let stored = db.stored_listens_since(1_699_999_999);
        assert_eq!(stored.len(), 2);
        assert!(stored.iter().any(|listen| listen.played_here && listen.title_key == "here"));
        assert!(stored.iter().any(|listen| !listen.played_here && listen.title_key == "there"));
        assert_eq!(db.newest_pulled_listen(), Some(1_700_000_100));
    }

    #[test]
    fn a_page_stored_twice_by_overlapping_syncs_lands_once() {
        let temp = TempDb::open();
        let db = &temp.db;
        let page = [
            pulled(1_700_000_000, "Song", "A", ""),
            pulled(1_700_000_000, "Other", "A", ""),
        ];
        assert_eq!(db.insert_pulled_listens(&page).unwrap(), 2);
        assert_eq!(db.insert_pulled_listens(&page).unwrap(), 0);
        assert_eq!(db.scrobble_count(), 2);
    }

    #[test]
    fn the_sync_state_round_trips_per_account() {
        let temp = TempDb::open();
        let db = &temp.db;
        assert_eq!(db.listen_sync_state("listener"), None);
        let mut state = HistorySyncState::default().for_account("listener");
        state.backfill_page = 7;
        state.backfill_anchor = Some(1_800_000_000);
        db.save_listen_sync_state(&state).unwrap();
        state.backfill_page = 8;
        db.save_listen_sync_state(&state).unwrap();
        assert_eq!(db.listen_sync_state("listener"), Some(state));
        assert_eq!(db.listen_sync_state("someone else"), None);
    }

    #[test]
    fn rows_stored_before_the_key_columns_get_their_keys() {
        let temp = TempDb::open();
        let db = &temp.db;
        db.conn
            .execute(
                "INSERT INTO scrobbles (trackTitle, artist, albumTitle, timestamp, duration, submitted)
                 VALUES ('Song (Remastered)', 'Beyoncé', 'Lemonade', '2024-01-01 00:00:00.000', 0, 1)",
                [],
            )
            .unwrap();
        assert_eq!(db.backfill_listen_keys().unwrap(), 1);
        let keys: (String, String, String) = db
            .conn
            .query_row("SELECT titleKey, artistKey, albumKey FROM scrobbles", [], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?))
            })
            .unwrap();
        assert_eq!(keys, ("song".to_string(), "beyonce".to_string(), "lemonade".to_string()));
    }
}

