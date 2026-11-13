//! The library by the numbers for the overview atop Library preferences, read
//! in one grouped pass over `tracks`: the mirror of
//! `DatabaseManager.libraryOverview()` and `LibraryOverviewTotals` in FlaccyEngine.

use super::Db;

/// Songs, formats, length and size of the whole library.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct LibraryOverviewTotals {
    pub tracks: usize,
    pub lossless: usize,
    pub hi_res: usize,
    pub seconds: f64,
    /// Bytes of the files in the music folder; songs on a server are not here.
    pub local_bytes: i64,
    pub server_tracks: usize,
    /// Songs per codec, upper-cased, most songs first; "?" for songs whose
    /// codec is unknown.
    pub codecs: Vec<(String, usize)>,
}

impl LibraryOverviewTotals {
    /// The share of songs in lossless formats, 0 for an empty library.
    pub fn lossless_share(&self) -> f64 {
        if self.tracks == 0 {
            0.0
        } else {
            self.lossless as f64 / self.tracks as f64
        }
    }
}

/// The formats the overview counts as lossless, the Apple clients'
/// `Track.losslessCodecs`.
const LOSSLESS_CODECS: [&str; 4] = ["FLAC", "ALAC", "WAV", "AIFF"];

/// One row per codec; a lossless song deeper than CD (more than 16 bits or
/// faster than 48 kHz) counts as hi-res.
const OVERVIEW_SQL: &str = "
    SELECT UPPER(COALESCE(NULLIF(TRIM(codec), ''), '?')) AS codec,
           COUNT(*) AS tracks,
           COALESCE(SUM(CASE WHEN UPPER(codec) IN ('FLAC', 'ALAC', 'WAV', 'AIFF')
                              AND (COALESCE(bitDepth, 0) > 16 OR COALESCE(sampleRate, 0) > 48000)
                             THEN 1 ELSE 0 END), 0) AS hiRes,
           COALESCE(SUM(duration), 0) AS seconds,
           COALESCE(SUM(CASE WHEN remoteServer IS NULL THEN fileSize ELSE 0 END), 0) AS localBytes,
           COALESCE(SUM(CASE WHEN remoteServer IS NULL THEN 0 ELSE 1 END), 0) AS serverTracks
    FROM tracks
    GROUP BY 1
    ORDER BY tracks DESC, codec";

impl Db {
    pub fn library_overview(&self) -> LibraryOverviewTotals {
        let mut totals = LibraryOverviewTotals::default();
        let Ok(mut statement) = self.conn.prepare(OVERVIEW_SQL) else {
            return totals;
        };
        let rows = statement.query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, i64>(1)?,
                row.get::<_, i64>(2)?,
                row.get::<_, f64>(3)?,
                row.get::<_, i64>(4)?,
                row.get::<_, i64>(5)?,
            ))
        });
        let Ok(rows) = rows else {
            return totals;
        };
        for (codec, tracks, hi_res, seconds, local_bytes, server_tracks) in rows.flatten() {
            let tracks = tracks.max(0) as usize;
            totals.tracks += tracks;
            if LOSSLESS_CODECS.contains(&codec.as_str()) {
                totals.lossless += tracks;
            }
            totals.hi_res += hi_res.max(0) as usize;
            totals.seconds += seconds;
            totals.local_bytes += local_bytes;
            totals.server_tracks += server_tracks.max(0) as usize;
            totals.codecs.push((codec, tracks));
        }
        totals
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::db::NewTrack;
    use flaccy_shared::track_revision::FileSignature;
    use rusqlite::params;
    use std::path::PathBuf;

    struct TempDb {
        path: PathBuf,
        db: Db,
    }

    impl TempDb {
        fn open() -> Self {
            static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let unique = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let path = std::env::temp_dir().join(format!(
                "flaccy-overview-test-{}-{unique}.sqlite",
                std::process::id()
            ));
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

    fn remove_all(path: &std::path::Path) {
        let _ = std::fs::remove_file(path);
        for suffix in ["-wal", "-shm"] {
            let _ = std::fs::remove_file(PathBuf::from(format!("{}{}", path.display(), suffix)));
        }
    }

    fn song(path: &str, codec: Option<&str>, bits: Option<i32>, rate: Option<i32>, size: i64) -> NewTrack {
        NewTrack {
            rel_path: path.into(),
            title: path.into(),
            artist: "Band".into(),
            album: "Record".into(),
            album_artist: None,
            track_number: 1,
            duration: 200.0,
            codec: codec.map(str::to_string),
            bit_depth: bits,
            sample_rate: rate,
            channels: Some(2),
            artwork: None,
            signature: Some(FileSignature { size, modified_ms: 1 }),
            fingerprint: None,
        }
    }

    #[test]
    fn an_empty_library_has_nothing_and_no_share() {
        let temp = TempDb::open();
        let totals = temp.db.library_overview();
        assert_eq!(totals, LibraryOverviewTotals::default());
        assert_eq!(totals.lossless_share(), 0.0);
    }

    #[test]
    fn one_pass_counts_formats_depth_length_and_local_bytes() {
        let temp = TempDb::open();
        let db = &temp.db;
        db.insert_track(&song("a.flac", Some("FLAC"), Some(16), Some(44_100), 30)).unwrap();
        db.insert_track(&song("b.flac", Some("flac"), Some(24), Some(96_000), 70)).unwrap();
        db.insert_track(&song("c.flac", Some("FLAC"), Some(16), Some(88_200), 50)).unwrap();
        db.insert_track(&song("d.mp3", Some("MP3"), None, Some(44_100), 10)).unwrap();
        db.insert_track(&song("e.m4a", Some("ALAC"), Some(24), Some(48_000), 40)).unwrap();
        db.insert_track(&song("f.ogg", None, None, None, 5)).unwrap();
        db.insert_track(&song("g.mp3", Some("MP3"), Some(24), Some(96_000), 20)).unwrap();
        db.insert_track(&song("h.flac", Some("FLAC"), Some(24), Some(96_000), 999)).unwrap();
        db.conn
            .execute(
                "UPDATE tracks SET remoteServer = ?1 WHERE fileURL = ?2",
                params!["home", "h.flac"],
            )
            .unwrap();

        let totals = db.library_overview();

        assert_eq!(totals.tracks, 8);
        assert_eq!(totals.lossless, 5, "FLAC in any case and ALAC count, MP3 and unknown do not");
        assert_eq!(totals.hi_res, 4, "24-bit or above 48 kHz, lossless only, server songs included");
        assert_eq!(totals.seconds, 1_600.0);
        assert_eq!(totals.local_bytes, 225, "a server song's bytes stay on the server");
        assert_eq!(totals.server_tracks, 1);
        assert_eq!(
            totals.codecs,
            vec![
                ("FLAC".to_string(), 4),
                ("MP3".to_string(), 2),
                ("?".to_string(), 1),
                ("ALAC".to_string(), 1),
            ]
        );
        assert!((totals.lossless_share() - 0.625).abs() < 1e-9);
    }
}
