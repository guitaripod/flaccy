use super::error::Result;
use crate::hygiene::is_lossless;
use crate::listen_history::{album_listen_key, artist_listen_key, title_key, ListenKeyCache};
use flaccy_server_core::model::SongRef;
use flaccy_server_core::song::song_key;
use rusqlite::{params, Connection, OptionalExtension};

const REMOTE_PREFIX: &str = "remote://";
const DURATION_TOLERANCE_MS: i64 = 2_000;

/// The song key every client shares: the SHA-256 identity of the artist and title listen keys.
pub fn song_key_of(title: &str, artist: &str) -> String {
    song_key(&artist_listen_key(artist), &title_key(title))
}

/// A reference to a song known only by what a play recorded.
pub(crate) fn ref_for_play(title: &str, artist: &str, album: &str) -> SongRef {
    SongRef {
        song_key: song_key_of(title, artist),
        title: title.to_owned(),
        artist: artist.to_owned(),
        album: album.to_owned(),
        duration_ms: 0,
        fp: None,
        mbid: None,
        album_key: Some(album_listen_key(album)).filter(|key| !key.is_empty()),
        rel_path: None,
    }
}

/// The reference for a library track, by its `fileURL`; a remote song carries no path because the path names one server.
pub(crate) fn ref_for_track(conn: &Connection, file_url: &str) -> Result<Option<SongRef>> {
    let row = conn
        .prepare_cached(
            "SELECT title, artist, albumTitle, duration, audioFingerprint, musicBrainzID
             FROM tracks WHERE fileURL = ?1",
        )?
        .query_row(params![file_url], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, f64>(3)?,
                row.get::<_, Option<String>>(4)?,
                row.get::<_, Option<String>>(5)?,
            ))
        })
        .optional()?;
    Ok(row.map(|(title, artist, album, duration, fp, mbid)| {
        let mut song = ref_for_play(&title, &artist, &album);
        song.duration_ms = (duration * 1000.0).round() as i64;
        song.fp = fp.filter(|text| !text.is_empty());
        song.mbid = mbid.filter(|text| !text.is_empty());
        song.rel_path = Some(file_url.to_owned()).filter(|path| !path.starts_with(REMOTE_PREFIX));
        song
    }))
}

/// Brings `sync_song_keys` level with `tracks`, computing keys only for rows that are new or retitled.
pub(crate) fn refresh_index(conn: &Connection) -> Result<()> {
    conn.execute(
        "DELETE FROM sync_song_keys WHERE trackId NOT IN (SELECT id FROM tracks)",
        [],
    )?;
    let stale: Vec<(i64, String, String)> = {
        let mut stmt = conn.prepare_cached(
            "SELECT t.id, t.title, t.artist FROM tracks t
             LEFT JOIN sync_song_keys k ON k.trackId = t.id
             WHERE k.trackId IS NULL OR k.title <> t.title OR k.artist <> t.artist",
        )?;
        let rows = stmt.query_map([], |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    let mut cache = ListenKeyCache::default();
    let mut upsert = conn.prepare_cached(
        "INSERT INTO sync_song_keys (trackId, title, artist, songKey) VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(trackId) DO UPDATE SET
            title = excluded.title, artist = excluded.artist, songKey = excluded.songKey",
    )?;
    for (id, title, artist) in stale {
        let artist_key = cache.artist(&artist).to_owned();
        let key = song_key(&artist_key, cache.title(&title));
        upsert.execute(params![id, title, artist, key])?;
    }
    Ok(())
}

struct Candidate {
    path: String,
    album: String,
    duration_ms: i64,
    lossless: bool,
}

/// Finds the local track a reference names.
pub(crate) struct Resolver<'c> {
    conn: &'c Connection,
}

impl<'c> Resolver<'c> {
    pub(crate) fn new(conn: &'c Connection) -> Self {
        Resolver { conn }
    }

    /// True when `file_url` is a track of `song_key`: the check that keeps an entry on the file the person chose.
    pub(crate) fn path_has_song_key(&self, file_url: &str, song_key: &str) -> Result<bool> {
        Ok(self
            .conn
            .prepare_cached(
                "SELECT 1 FROM sync_song_keys k JOIN tracks t ON t.id = k.trackId
                 WHERE t.fileURL = ?1 AND k.songKey = ?2",
            )?
            .exists(params![file_url, song_key])?)
    }

    /// The `fileURL` of the track `song` names, by the ladder fingerprint, MusicBrainz id, song key with album and duration, song key alone, relative path.
    pub(crate) fn resolve(&self, song: &SongRef) -> Result<Option<String>> {
        if let Some(fp) = song.fp.as_deref().filter(|text| !text.is_empty()) {
            if let Some(found) = self.best(self.by_column("audioFingerprint", fp)?, song) {
                return Ok(Some(found));
            }
        }
        if let Some(mbid) = song.mbid.as_deref().filter(|text| !text.is_empty()) {
            if let Some(found) = self.best(self.by_column("musicBrainzID", mbid)?, song) {
                return Ok(Some(found));
            }
        }
        let by_key = self.by_song_key(&song.song_key)?;
        if let Some(found) = self.exact_edition(&by_key, song) {
            return Ok(Some(found));
        }
        if let Some(found) = self.best(by_key, song) {
            return Ok(Some(found));
        }
        self.by_path(song.rel_path.as_deref())
    }

    fn by_column(&self, column: &str, value: &str) -> Result<Vec<Candidate>> {
        let sql =
            format!("SELECT fileURL, albumTitle, duration, codec FROM tracks WHERE {column} = ?1");
        self.candidates(&sql, value)
    }

    fn by_song_key(&self, song_key: &str) -> Result<Vec<Candidate>> {
        self.candidates(
            "SELECT t.fileURL, t.albumTitle, t.duration, t.codec FROM sync_song_keys k
             JOIN tracks t ON t.id = k.trackId WHERE k.songKey = ?1",
            song_key,
        )
    }

    fn candidates(&self, sql: &str, value: &str) -> Result<Vec<Candidate>> {
        let mut stmt = self.conn.prepare_cached(sql)?;
        let rows = stmt.query_map(params![value], |row| {
            let codec: Option<String> = row.get(3)?;
            Ok(Candidate {
                path: row.get(0)?,
                album: row.get(1)?,
                duration_ms: (row.get::<_, f64>(2)? * 1000.0).round() as i64,
                lossless: is_lossless(codec.as_deref()),
            })
        })?;
        Ok(rows.collect::<std::result::Result<_, _>>()?)
    }

    fn exact_edition(&self, candidates: &[Candidate], song: &SongRef) -> Option<String> {
        let album_key = song.album_key.as_deref()?;
        let matching: Vec<&Candidate> = candidates
            .iter()
            .filter(|candidate| album_listen_key(&candidate.album) == album_key)
            .filter(|candidate| {
                (candidate.duration_ms - song.duration_ms).abs() <= DURATION_TOLERANCE_MS
            })
            .collect();
        rank(matching, song).map(|candidate| candidate.path.clone())
    }

    fn best(&self, candidates: Vec<Candidate>, song: &SongRef) -> Option<String> {
        rank(candidates.iter().collect(), song).map(|candidate| candidate.path.clone())
    }

    fn by_path(&self, rel_path: Option<&str>) -> Result<Option<String>> {
        let Some(path) = rel_path.filter(|path| !path.is_empty()) else {
            return Ok(None);
        };
        Ok(self
            .conn
            .prepare_cached("SELECT fileURL FROM tracks WHERE fileURL = ?1")?
            .query_row(params![path], |row| row.get(0))
            .optional()?)
    }
}

/// Same album first, lossless over lossy, a local file over a server's, then the lowest path.
fn rank<'a>(mut candidates: Vec<&'a Candidate>, song: &SongRef) -> Option<&'a Candidate> {
    let wanted = song
        .album_key
        .clone()
        .unwrap_or_else(|| album_listen_key(&song.album));
    candidates.sort_by(|a, b| {
        let order = |candidate: &Candidate| {
            (
                album_listen_key(&candidate.album) != wanted,
                !candidate.lossless,
                candidate.path.starts_with(REMOTE_PREFIX),
                candidate.path.clone(),
            )
        };
        order(a).cmp(&order(b))
    });
    candidates.into_iter().next()
}
