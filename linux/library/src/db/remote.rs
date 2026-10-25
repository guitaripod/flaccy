//! The library rows that come from an OpenSubsonic server.
//!
//! A remote song is an ordinary `tracks` row whose `fileURL` is
//! `remote://<server>/<song>` and whose `remote*` columns say how to fetch it,
//! so search, filters, playlists, stats and the queue treat it like any file.
//! The folder scan never touches these rows: `fetch_relative_paths` leaves them
//! out, and this module is the only writer.

use super::{now_string, string_from_unix, unix_from_string, unix_ms_from_string, Db};
use crate::remote::catalog::RemoteSong;
use flaccy_shared::enrichment_job as job;
use flaccy_shared::remote::catalog_diff::{CatalogSong, Diff};
use flaccy_shared::remote::remote_path;
use rusqlite::{params, OptionalExtension};
use std::collections::HashMap;

/// What a catalog sync did to one server's rows. `new_versions` and `removed`
/// hold song ids, so the caller can drop their cached bytes.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ApplyReport {
    pub inserted: usize,
    pub updated: usize,
    pub new_versions: Vec<String>,
    pub removed: Vec<String>,
    /// Rows whose loved flag, play count or last-played time the server changed.
    pub listening_updated: usize,
}

/// What the proxy and the cache need to know about a song before its first
/// byte: the file suffix, the size the catalog last saw and the title for
/// messages.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteSongMeta {
    pub suffix: String,
    pub size: u64,
    pub title: String,
}

/// An album of a server whose cover is not stored yet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MissingCover {
    pub album: String,
    pub artist: String,
    pub cover_art: String,
}

impl Db {
    /// Adds the columns a remote song needs, on a new database and on one from
    /// before servers existed.
    pub(super) fn migrate_remote_columns(&self) -> Result<(), rusqlite::Error> {
        for column in [
            "remoteServer TEXT",
            "remoteSuffix TEXT",
            "remoteSize INTEGER",
            "remoteCoverArt TEXT",
            "remoteAlbumId TEXT",
            "remoteDisc INTEGER",
        ] {
            let _ = self
                .conn
                .execute(&format!("ALTER TABLE tracks ADD COLUMN {column}"), []);
        }
        self.conn.execute(
            "CREATE INDEX IF NOT EXISTS tracks_on_remoteServer ON tracks(remoteServer)",
            [],
        )?;
        Ok(())
    }

    /// The rows stored for `server`, as `catalog_diff` compares them.
    pub fn remote_catalog(&self, server: &str) -> Vec<CatalogSong> {
        let Ok(mut statement) = self.conn.prepare(
            "SELECT fileURL, remoteSize, duration, title, artist, albumTitle, trackNumber,
                    audioFingerprint
             FROM tracks WHERE remoteServer = ?1",
        ) else {
            return Vec::new();
        };
        let rows = statement.query_map(params![server], |row| {
            let path: String = row.get(0)?;
            let track: i64 = row.get(6)?;
            Ok(CatalogSong {
                id: remote_path::decode(&path)
                    .map(|(_, song)| song)
                    .unwrap_or_default(),
                size: row.get::<_, Option<i64>>(1)?.unwrap_or(0),
                duration: row.get(2)?,
                title: row.get(3)?,
                artist: row.get(4)?,
                album: row.get(5)?,
                track: Some(track).filter(|track| *track > 0),
                fingerprint: row.get(7)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().filter(|song| !song.id.is_empty()).collect(),
            Err(_) => Vec::new(),
        }
    }

    /// Applies what `catalog_diff` decided to the rows of `server` in one
    /// transaction. `songs` is the server's whole catalog: the diff names ids,
    /// and the fields come from here.
    pub fn apply_remote_catalog(
        &self,
        server: &str,
        songs: &[RemoteSong],
        diff: &Diff,
    ) -> Result<ApplyReport, rusqlite::Error> {
        let by_id: HashMap<&str, &RemoteSong> =
            songs.iter().map(|song| (song.id.as_str(), song)).collect();
        let tx = self.conn.unchecked_transaction()?;
        let mut report = ApplyReport::default();
        for id in &diff.inserted {
            if let Some(song) = by_id.get(id.as_str()) {
                report.inserted += insert_row(&tx, song)?;
            }
        }
        for id in &diff.updated {
            if let Some(song) = by_id.get(id.as_str()) {
                report.updated += refresh_row(&tx, song, false)?;
            }
        }
        for id in &diff.new_versions {
            if let Some(song) = by_id.get(id.as_str()) {
                if refresh_row(&tx, song, true)? > 0 {
                    report.new_versions.push(id.clone());
                }
            }
        }
        for id in &diff.removed {
            let path = remote_path::encode(server, id);
            tx.execute("DELETE FROM tracks WHERE fileURL = ?1", params![path])?;
            report.removed.push(id.clone());
        }
        if !diff.removed.is_empty() {
            tx.execute(
                "DELETE FROM playlistTracks WHERE trackFileURL NOT IN (SELECT fileURL FROM tracks)",
                [],
            )?;
            tx.execute(job::ORPHAN_SWEEP_SQL, [])?;
        }
        report.listening_updated = refresh_listening_state(&tx, server, songs)?;
        tx.commit()?;
        Ok(report)
    }

    /// The suffix, size and title of one remote song, `None` when no row has it.
    pub fn remote_song_meta(&self, server: &str, song: &str) -> Option<RemoteSongMeta> {
        self.conn
            .query_row(
                "SELECT remoteSuffix, remoteSize, title FROM tracks WHERE fileURL = ?1
                 AND remoteServer = ?2",
                params![remote_path::encode(server, song), server],
                |row| {
                    Ok(RemoteSongMeta {
                        suffix: row
                            .get::<_, Option<String>>(0)?
                            .unwrap_or_else(|| "bin".to_string()),
                        size: row.get::<_, Option<i64>>(1)?.unwrap_or(0).max(0) as u64,
                        title: row.get(2)?,
                    })
                },
            )
            .optional()
            .ok()
            .flatten()
    }

    /// Every remote song's path, for one server or for all of them.
    pub fn remote_rel_paths(&self, server: Option<&str>) -> Vec<String> {
        let Ok(mut statement) = self.conn.prepare(
            "SELECT fileURL FROM tracks WHERE remoteServer IS NOT NULL
             AND (?1 IS NULL OR remoteServer = ?1)",
        ) else {
            return Vec::new();
        };
        let rows = statement.query_map(params![server], |row| row.get::<_, String>(0));
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    /// How many songs each server has in the library.
    pub fn remote_song_counts(&self) -> HashMap<String, usize> {
        let mut counts = HashMap::new();
        let Ok(mut statement) = self.conn.prepare(
            "SELECT remoteServer, COUNT(*) FROM tracks WHERE remoteServer IS NOT NULL
             GROUP BY remoteServer",
        ) else {
            return counts;
        };
        let rows = statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?)));
        if let Ok(rows) = rows {
            for (server, count) in rows.flatten() {
                counts.insert(server, count.max(0) as usize);
            }
        }
        counts
    }

    /// Removes every song of `server` from the library, and from the playlists
    /// that held them. Returns how many songs went.
    pub fn remove_remote_server(&self, server: &str) -> Result<usize, rusqlite::Error> {
        let tx = self.conn.unchecked_transaction()?;
        let removed = tx.execute("DELETE FROM tracks WHERE remoteServer = ?1", params![server])?;
        tx.execute(
            "DELETE FROM playlistTracks WHERE trackFileURL NOT IN (SELECT fileURL FROM tracks)",
            [],
        )?;
        tx.execute(job::ORPHAN_SWEEP_SQL, [])?;
        tx.commit()?;
        Ok(removed)
    }

    /// The albums of `server` with no stored cover yet, with the cover id of
    /// their first song.
    pub fn albums_missing_remote_covers(&self, server: &str) -> Vec<MissingCover> {
        let Ok(mut statement) = self.conn.prepare(
            "SELECT t.albumTitle, t.artist, MIN(t.remoteCoverArt)
             FROM tracks t
             LEFT JOIN albumInfo ai ON ai.title = t.albumTitle AND ai.artist = t.artist
             WHERE t.remoteServer = ?1 AND t.remoteCoverArt IS NOT NULL
               AND (ai.coverArtData IS NULL AND ai.customCoverData IS NULL)
             GROUP BY t.albumTitle, t.artist",
        ) else {
            return Vec::new();
        };
        let rows = statement.query_map(params![server], |row| {
            Ok(MissingCover {
                album: row.get(0)?,
                artist: row.get(1)?,
                cover_art: row.get(2)?,
            })
        });
        match rows {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        }
    }

    /// When a remote song's latest version was recognised, for tests and the
    /// New mix chip's checks.
    pub fn remote_revision(&self, server: &str, song: &str) -> Option<(i64, Option<i64>)> {
        self.conn
            .query_row(
                "SELECT revision, revisedAt FROM tracks WHERE fileURL = ?1",
                params![remote_path::encode(server, song)],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)?,
                        row.get::<_, Option<String>>(1)?
                            .map(|text| unix_ms_from_string(&text)),
                    ))
                },
            )
            .optional()
            .ok()
            .flatten()
    }
}

/// The listening state a remote row holds: its loved flag, play count and
/// last-played time as Unix seconds.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ListeningState {
    loved: bool,
    play_count: i64,
    last_played: Option<i64>,
}

/// The listening state of every row of `server`, with whether a local love
/// change is still waiting to reach the server.
fn stored_listening_state(
    tx: &rusqlite::Transaction<'_>,
    server: &str,
) -> Result<HashMap<String, (ListeningState, bool)>, rusqlite::Error> {
    let mut statement = tx.prepare(
        "SELECT fileURL, loved, playCount, lastPlayed, lovedPendingOp IS NOT NULL
         FROM tracks WHERE remoteServer = ?1",
    )?;
    let rows = statement.query_map(params![server], |row| {
        let state = ListeningState {
            loved: row.get(1)?,
            play_count: row.get(2)?,
            last_played: row
                .get::<_, Option<String>>(3)?
                .map(|text| unix_from_string(&text)),
        };
        Ok((row.get::<_, String>(0)?, (state, row.get::<_, bool>(4)?)))
    })?;
    let collected = rows.collect();
    collected
}

/// The state a row holds once the server's song is merged into it. A local love
/// change still waiting for the server keeps the local flag; the play count
/// keeps the higher figure and the last-played time the later one.
fn merge_listening_state(local: ListeningState, pending: bool, song: &RemoteSong) -> ListeningState {
    ListeningState {
        loved: if pending { local.loved } else { song.starred },
        play_count: local.play_count.max(song.play_count),
        last_played: match (local.last_played, song.played_unix) {
            (Some(local), Some(server)) => Some(local.max(server)),
            (local, server) => local.or(server),
        },
    }
}

/// Writes the merged listening state of each song of `server` that changes it.
/// Rows that would be unchanged are not written, and the count is the number
/// written.
fn refresh_listening_state(
    tx: &rusqlite::Transaction<'_>,
    server: &str,
    songs: &[RemoteSong],
) -> Result<usize, rusqlite::Error> {
    let stored = stored_listening_state(tx, server)?;
    let mut changed = 0;
    for song in songs {
        let path = song.rel_path();
        let Some((local, pending)) = stored.get(&path) else {
            continue;
        };
        let merged = merge_listening_state(*local, *pending, song);
        if merged == *local {
            continue;
        }
        let played_changed = merged.last_played != local.last_played;
        tx.execute(
            "UPDATE tracks SET loved = ?1, playCount = ?2,
                lastPlayed = CASE WHEN ?3 THEN ?4 ELSE lastPlayed END
             WHERE fileURL = ?5",
            params![
                merged.loved,
                merged.play_count,
                played_changed,
                merged.last_played.map(string_from_unix),
                path,
            ],
        )?;
        changed += 1;
    }
    Ok(changed)
}

/// Inserts one new row, leaving an existing path alone.
fn insert_row(tx: &rusqlite::Transaction<'_>, song: &RemoteSong) -> Result<usize, rusqlite::Error> {
    tx.execute(
        "INSERT INTO tracks
         (fileURL, title, artist, albumTitle, albumArtist, trackNumber, duration, dateAdded,
          codec, bitDepth, sampleRate, channels, fileSize, audioFingerprint, revision,
          remoteServer, remoteSuffix, remoteSize, remoteCoverArt, remoteAlbumId, remoteDisc)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, 1,
                 ?15, ?16, ?17, ?18, ?19, ?20)
         ON CONFLICT(fileURL) DO NOTHING",
        params![
            song.rel_path(),
            song.title,
            song.artist,
            song.album,
            song.album_artist,
            song.track_number,
            song.duration,
            song.added_unix.map(string_from_unix).unwrap_or_else(now_string),
            song.codec,
            song.bit_depth,
            song.sample_rate,
            song.channels,
            song.size,
            song.fingerprint,
            song.server,
            song.suffix,
            song.size,
            song.cover_art,
            song.album_id,
            song.disc,
        ],
    )
}

/// Refreshes a row in place so its id, plays, loved flag and playlist rows
/// stay. A new version also takes the new audio fields, raises the revision and
/// stamps `revisedAt`, which is what makes the New mix chip appear.
fn refresh_row(
    tx: &rusqlite::Transaction<'_>,
    song: &RemoteSong,
    new_version: bool,
) -> Result<usize, rusqlite::Error> {
    let revised = if new_version {
        ", revision = revision + 1, revisedAt = ?15"
    } else {
        ""
    };
    let sql = format!(
        "UPDATE tracks SET title = ?1, artist = ?2, albumTitle = ?3,
            albumArtist = COALESCE(?4, albumArtist), trackNumber = ?5, duration = ?6,
            codec = ?7, bitDepth = ?8, sampleRate = ?9, channels = ?10,
            remoteSuffix = ?11, remoteSize = ?12, remoteCoverArt = ?13, remoteAlbumId = ?14,
            fileSize = ?12, audioFingerprint = COALESCE(?16, audioFingerprint),
            remoteDisc = ?18{revised}
         WHERE fileURL = ?17"
    );
    tx.execute(
        &sql,
        params![
            song.title,
            song.artist,
            song.album,
            song.album_artist,
            song.track_number,
            song.duration,
            song.codec,
            song.bit_depth,
            song.sample_rate,
            song.channels,
            song.suffix,
            song.size,
            song.cover_art,
            song.album_id,
            if new_version { Some(now_string()) } else { None::<String> },
            song.fingerprint,
            song.rel_path(),
            song.disc,
        ],
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_shared::remote::catalog_diff;
    use std::path::PathBuf;

    struct Scratch {
        path: PathBuf,
        db: Db,
    }

    impl Scratch {
        fn open(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "flaccy-remote-db-{name}-{}.sqlite",
                std::process::id()
            ));
            for suffix in ["", "-wal", "-shm"] {
                let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
            }
            let db = Db::open(&path).expect("temp db opens");
            Self { path, db }
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            for suffix in ["", "-wal", "-shm"] {
                let _ = std::fs::remove_file(format!("{}{suffix}", self.path.display()));
            }
        }
    }

    fn song(id: &str, title: &str, size: i64, duration: f64) -> RemoteSong {
        RemoteSong {
            server: "s1".to_string(),
            id: id.to_string(),
            title: title.to_string(),
            artist: "Band".to_string(),
            album: "Record".to_string(),
            album_artist: None,
            track_number: 1,
            duration,
            codec: Some("FLAC".to_string()),
            bit_depth: Some(16),
            sample_rate: Some(44100),
            channels: Some(2),
            suffix: "flac".to_string(),
            size,
            cover_art: Some(format!("al-{id}")),
            album_id: Some("al".to_string()),
            disc: Some(1),
            fingerprint: None,
            added_unix: Some(1_700_000_000),
            starred: false,
            play_count: 0,
            played_unix: None,
        }
    }

    fn sync(db: &Db, songs: &[RemoteSong]) -> ApplyReport {
        let server: Vec<CatalogSong> = songs.iter().map(RemoteSong::catalog_song).collect();
        let diff = catalog_diff::diff(&server, &db.remote_catalog("s1"));
        db.apply_remote_catalog("s1", songs, &diff).unwrap()
    }

    #[test]
    fn a_first_sync_inserts_every_song_as_a_remote_row() {
        let scratch = Scratch::open("insert");
        let report = sync(&scratch.db, &[song("a", "One", 100, 10.0), song("b", "Two", 200, 20.0)]);
        assert_eq!(report.inserted, 2);
        let rows = scratch.db.fetch_all_tracks();
        assert_eq!(rows.len(), 2);
        assert!(rows.iter().any(|row| row.rel_path == "remote://s1/a" && row.codec.as_deref() == Some("FLAC")));
        assert!(scratch.db.fetch_relative_paths().is_empty());
        let meta = scratch.db.remote_song_meta("s1", "a").unwrap();
        assert_eq!((meta.suffix.as_str(), meta.size, meta.title.as_str()), ("flac", 100, "One"));
    }

    #[test]
    fn a_second_identical_sync_changes_nothing() {
        let scratch = Scratch::open("idempotent");
        let songs = [song("a", "One", 100, 10.0)];
        sync(&scratch.db, &songs);
        assert_eq!(sync(&scratch.db, &songs), ApplyReport::default());
    }

    #[test]
    fn a_retag_updates_in_place_and_keeps_the_playlist_row_and_the_id() {
        let scratch = Scratch::open("retag");
        sync(&scratch.db, &[song("a", "One", 100, 10.0)]);
        let id_before = scratch.db.fetch_all_tracks()[0].id;
        let playlist = scratch.db.create_playlist("Mix").unwrap();
        scratch.db.add_track_to_playlist(playlist, "remote://s1/a").unwrap();
        let report = sync(&scratch.db, &[song("a", "One (Remaster)", 100, 10.0)]);
        assert_eq!(report.updated, 1);
        assert!(report.new_versions.is_empty());
        let row = &scratch.db.fetch_all_tracks()[0];
        assert_eq!((row.id, row.title.as_str(), row.revision), (id_before, "One (Remaster)", 1));
        assert_eq!(scratch.db.playlist_tracks(playlist).len(), 1);
    }

    #[test]
    fn a_new_version_bumps_the_revision_and_stamps_the_time() {
        let scratch = Scratch::open("version");
        sync(&scratch.db, &[song("a", "One", 100, 10.0)]);
        let report = sync(&scratch.db, &[song("a", "One", 150, 10.2)]);
        assert_eq!(report.new_versions, vec!["a".to_string()]);
        let row = &scratch.db.fetch_all_tracks()[0];
        assert_eq!(row.revision, 2);
        assert!(row.revised_at.is_some());
        let meta = scratch.db.remote_song_meta("s1", "a").unwrap();
        assert_eq!(meta.size, 150);
    }

    #[test]
    fn a_removed_song_leaves_the_library_and_its_playlists() {
        let scratch = Scratch::open("removed");
        sync(&scratch.db, &[song("a", "One", 100, 10.0), song("b", "Two", 200, 20.0)]);
        let playlist = scratch.db.create_playlist("Mix").unwrap();
        scratch.db.add_track_to_playlist(playlist, "remote://s1/b").unwrap();
        let report = sync(&scratch.db, &[song("a", "One", 100, 10.0)]);
        assert_eq!(report.removed, vec!["b".to_string()]);
        assert_eq!(scratch.db.fetch_all_tracks().len(), 1);
        assert!(scratch.db.playlist_tracks(playlist).is_empty());
    }

    #[test]
    fn removing_a_server_takes_only_its_songs() {
        let scratch = Scratch::open("server-removal");
        sync(&scratch.db, &[song("a", "One", 100, 10.0)]);
        let local = crate::db::NewTrack {
            rel_path: "Band/local.flac".to_string(),
            title: "Local".to_string(),
            artist: "Band".to_string(),
            album: "Record".to_string(),
            album_artist: None,
            track_number: 2,
            duration: 5.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            artwork: None,
            signature: None,
            fingerprint: None,
        };
        scratch.db.insert_track(&local).unwrap();
        assert_eq!(scratch.db.remove_remote_server("s1").unwrap(), 1);
        let rows = scratch.db.fetch_all_tracks();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].rel_path, "Band/local.flac");
    }

    #[test]
    fn the_folder_scan_neither_lists_nor_prunes_remote_rows() {
        let scratch = Scratch::open("scan-safe");
        sync(&scratch.db, &[song("a", "One", 100, 10.0)]);
        let keep = std::collections::HashSet::new();
        assert_eq!(scratch.db.delete_tracks_not_in(&keep).unwrap(), 0);
        assert_eq!(scratch.db.fetch_all_tracks().len(), 1);
    }

    #[test]
    fn two_albums_sharing_a_title_on_one_server_keep_their_own_credits() {
        let scratch = Scratch::open("credits");
        let mut first = song("a", "One", 100, 10.0);
        let mut second = song("b", "Two", 100, 10.0);
        first.album = "Greatest Hits".to_string();
        first.artist = "Alpha".to_string();
        first.album_id = Some("al-alpha".to_string());
        second.album = "Greatest Hits".to_string();
        second.artist = "Beta".to_string();
        second.album_id = Some("al-beta".to_string());
        sync(&scratch.db, &[first, second]);
        scratch.db.resolve_album_credits();
        let rows = scratch.db.fetch_all_tracks();
        let credit = |title: &str| {
            rows.iter()
                .find(|row| row.title == title)
                .and_then(|row| row.album_artist.clone())
        };
        assert_eq!(credit("One").as_deref(), Some("Alpha"));
        assert_eq!(credit("Two").as_deref(), Some("Beta"));
    }

    fn listened(id: &str, starred: bool, play_count: i64, played_unix: Option<i64>) -> RemoteSong {
        RemoteSong {
            starred,
            play_count,
            played_unix,
            ..song(id, "One", 100, 10.0)
        }
    }

    #[test]
    fn a_starred_song_on_the_server_becomes_loved_here() {
        let scratch = Scratch::open("starred");
        let report = sync(&scratch.db, &[listened("a", true, 0, None)]);
        assert_eq!(report.listening_updated, 1);
        assert!(scratch.db.fetch_all_tracks()[0].loved);
        let unstarred = sync(&scratch.db, &[listened("a", false, 0, None)]);
        assert_eq!(unstarred.listening_updated, 1);
        assert!(!scratch.db.fetch_all_tracks()[0].loved);
    }

    #[test]
    fn a_pending_local_unlove_is_not_overwritten_by_a_star_the_server_still_holds() {
        let scratch = Scratch::open("pending-unlove");
        sync(&scratch.db, &[listened("a", true, 0, None)]);
        scratch.db.set_loved("remote://s1/a", false, Some("unlove")).unwrap();
        let report = sync(&scratch.db, &[listened("a", true, 0, None)]);
        assert_eq!(report.listening_updated, 0);
        assert!(!scratch.db.fetch_all_tracks()[0].loved);
        assert_eq!(scratch.db.fetch_pending_love_ops().len(), 1);
    }

    #[test]
    fn a_pending_local_love_is_not_overwritten_by_a_server_without_the_star() {
        let scratch = Scratch::open("pending-love");
        sync(&scratch.db, &[listened("a", false, 0, None)]);
        scratch.db.set_loved("remote://s1/a", true, Some("love")).unwrap();
        sync(&scratch.db, &[listened("a", false, 0, None)]);
        assert!(scratch.db.fetch_all_tracks()[0].loved);
    }

    #[test]
    fn the_play_count_keeps_the_higher_of_local_and_server() {
        let scratch = Scratch::open("play-count");
        sync(&scratch.db, &[listened("a", false, 3, None)]);
        scratch.db.set_play_count("remote://s1/a", 5).unwrap();
        assert_eq!(sync(&scratch.db, &[listened("a", false, 3, None)]).listening_updated, 0);
        assert_eq!(scratch.db.fetch_all_tracks()[0].play_count, 5);
        assert_eq!(sync(&scratch.db, &[listened("a", false, 9, None)]).listening_updated, 1);
        assert_eq!(scratch.db.fetch_all_tracks()[0].play_count, 9);
    }

    #[test]
    fn the_last_played_time_keeps_the_later_of_local_and_server() {
        let scratch = Scratch::open("last-played");
        sync(&scratch.db, &[listened("a", false, 0, None)]);
        scratch
            .db
            .conn
            .execute(
                "UPDATE tracks SET lastPlayed = '2026-10-20 10:00:00.000' WHERE fileURL = ?1",
                ["remote://s1/a"],
            )
            .unwrap();
        sync(&scratch.db, &[listened("a", false, 0, Some(1_790_812_800))]);
        assert_eq!(scratch.db.fetch_all_tracks()[0].last_played, Some(1_792_490_400));
        sync(&scratch.db, &[listened("a", false, 0, Some(1_792_832_400))]);
        assert_eq!(scratch.db.fetch_all_tracks()[0].last_played, Some(1_792_832_400));
    }

    #[test]
    fn a_sync_with_nothing_new_writes_no_listening_state() {
        let scratch = Scratch::open("listening-idle");
        let songs = [listened("a", true, 4, Some(1_792_936_800))];
        sync(&scratch.db, &songs);
        assert_eq!(sync(&scratch.db, &songs), ApplyReport::default());
    }

    #[test]
    fn albums_without_a_cover_are_listed_until_one_is_saved() {
        let scratch = Scratch::open("covers");
        sync(&scratch.db, &[song("a", "One", 100, 10.0)]);
        let missing = scratch.db.albums_missing_remote_covers("s1");
        assert_eq!(missing.len(), 1);
        assert_eq!(missing[0].cover_art, "al-a");
        scratch.db.save_album_cover_if_missing("Record", "Band", &[1, 2, 3]).unwrap();
        assert!(scratch.db.albums_missing_remote_covers("s1").is_empty());
    }
}
