//! The index of prepared music video files. A row says which video was
//! fetched for which quality ceiling, how many bytes it holds, and, for a file
//! that could not be prepared, why and when to try again. The files
//! themselves live in the cache folder; startup reconciles the two.

use super::Db;
use rusqlite::{params, OptionalExtension};

pub const STATE_PART: &str = "part";
pub const STATE_READY: &str = "ready";
pub const STATE_FAILED: &str = "failed";

#[derive(Clone, Debug, PartialEq)]
pub struct VideoCacheRow {
    pub video_id: String,
    /// The quality ceiling the file was fetched under, which is also the one
    /// that may play it.
    pub ceiling: i32,
    pub height: i32,
    pub codec: String,
    pub bytes: u64,
    pub expected_bytes: u64,
    pub state: String,
    pub file_name: String,
    pub pinned: bool,
    pub plays: i64,
    pub created_at: i64,
    pub last_played_at: Option<i64>,
    pub attempts: u32,
    pub next_attempt_at: Option<i64>,
    pub failure_class: Option<String>,
    pub failure: Option<String>,
}

const COLUMNS: &str = "videoId, ceiling, height, codec, bytes, expectedBytes, state, fileName,
    pinned, plays, createdAt, lastPlayedAt, attempts, nextAttemptAt, failureClass, failure";

fn read(row: &rusqlite::Row) -> rusqlite::Result<VideoCacheRow> {
    Ok(VideoCacheRow {
        video_id: row.get(0)?,
        ceiling: row.get(1)?,
        height: row.get(2)?,
        codec: row.get(3)?,
        bytes: row.get::<_, i64>(4)?.max(0) as u64,
        expected_bytes: row.get::<_, i64>(5)?.max(0) as u64,
        state: row.get(6)?,
        file_name: row.get(7)?,
        pinned: row.get(8)?,
        plays: row.get(9)?,
        created_at: row.get(10)?,
        last_played_at: row.get(11)?,
        attempts: row.get::<_, i64>(12)?.max(0) as u32,
        next_attempt_at: row.get(13)?,
        failure_class: row.get(14)?,
        failure: row.get(15)?,
    })
}

impl Db {
    pub fn video_cache_entry(&self, video_id: &str, ceiling: i32) -> Option<VideoCacheRow> {
        self.conn
            .query_row(
                &format!("SELECT {COLUMNS} FROM videoCache WHERE videoId = ?1 AND ceiling = ?2"),
                params![video_id, ceiling],
                read,
            )
            .optional()
            .ok()
            .flatten()
    }

    pub fn video_cache_all(&self) -> Vec<VideoCacheRow> {
        let Ok(mut stmt) = self
            .conn
            .prepare(&format!("SELECT {COLUMNS} FROM videoCache ORDER BY createdAt"))
        else {
            return Vec::new();
        };
        let Ok(rows) = stmt.query_map([], read) else {
            return Vec::new();
        };
        rows.flatten().collect()
    }

    /// Records a download in progress: the file exists as `<name>.part` and
    /// `bytes` of `expected_bytes` are on disk.
    pub fn video_cache_progress(
        &self,
        video_id: &str,
        ceiling: i32,
        height: i32,
        codec: &str,
        file_name: &str,
        bytes: u64,
        expected_bytes: u64,
        now: i64,
    ) {
        let _ = self.conn.execute(
            "INSERT INTO videoCache
                (videoId, ceiling, height, codec, bytes, expectedBytes, state, fileName, createdAt)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'part', ?7, ?8)
             ON CONFLICT(videoId, ceiling) DO UPDATE SET
                height = excluded.height, codec = excluded.codec, bytes = excluded.bytes,
                expectedBytes = excluded.expectedBytes, state = 'part', fileName = excluded.fileName,
                failureClass = NULL, failure = NULL, nextAttemptAt = NULL",
            params![
                video_id,
                ceiling,
                height,
                codec,
                bytes as i64,
                expected_bytes as i64,
                file_name,
                now
            ],
        );
    }

    /// Marks a verified file complete.
    pub fn video_cache_ready(&self, video_id: &str, ceiling: i32, bytes: u64) {
        let _ = self.conn.execute(
            "UPDATE videoCache SET state = 'ready', bytes = ?3, expectedBytes = ?3,
                attempts = 0, nextAttemptAt = NULL, failureClass = NULL, failure = NULL
             WHERE videoId = ?1 AND ceiling = ?2",
            params![video_id, ceiling, bytes as i64],
        );
    }

    /// Records why a video could not be prepared and when to try again. A
    /// partial download keeps its bytes so the retry resumes.
    pub fn video_cache_failed(
        &self,
        video_id: &str,
        ceiling: i32,
        failure_class: &str,
        failure: &str,
        next_attempt_at: i64,
        now: i64,
    ) -> u32 {
        let _ = self.conn.execute(
            "INSERT INTO videoCache
                (videoId, ceiling, state, createdAt, attempts, nextAttemptAt, failureClass, failure)
             VALUES (?1, ?2, 'failed', ?6, 1, ?5, ?3, ?4)
             ON CONFLICT(videoId, ceiling) DO UPDATE SET
                state = CASE WHEN state = 'ready' THEN 'ready' ELSE
                    CASE WHEN bytes > 0 AND state = 'part' THEN 'part' ELSE 'failed' END END,
                attempts = attempts + 1, nextAttemptAt = ?5, failureClass = ?3, failure = ?4",
            params![video_id, ceiling, failure_class, failure, next_attempt_at, now],
        );
        self.video_cache_entry(video_id, ceiling)
            .map_or(1, |row| row.attempts)
    }

    pub fn video_cache_played(&self, video_id: &str, ceiling: i32, now: i64) {
        let _ = self.conn.execute(
            "UPDATE videoCache SET plays = plays + 1, lastPlayedAt = ?3
             WHERE videoId = ?1 AND ceiling = ?2",
            params![video_id, ceiling, now],
        );
    }

    pub fn video_cache_set_pinned(&self, video_id: &str, ceiling: i32, pinned: bool) {
        let _ = self.conn.execute(
            "UPDATE videoCache SET pinned = ?3 WHERE videoId = ?1 AND ceiling = ?2",
            params![video_id, ceiling, pinned],
        );
    }

    pub fn video_cache_delete(&self, video_id: &str, ceiling: i32) {
        let _ = self.conn.execute(
            "DELETE FROM videoCache WHERE videoId = ?1 AND ceiling = ?2",
            params![video_id, ceiling],
        );
    }

    pub fn video_cache_clear(&self) -> usize {
        self.conn.execute("DELETE FROM videoCache", []).unwrap_or(0)
    }

    /// Prepared files and the bytes they hold.
    pub fn video_cache_totals(&self) -> (usize, u64) {
        self.conn
            .query_row(
                "SELECT COUNT(*), COALESCE(SUM(bytes), 0) FROM videoCache WHERE state = 'ready'",
                [],
                |row| Ok((row.get::<_, i64>(0)? as usize, row.get::<_, i64>(1)?.max(0) as u64)),
            )
            .unwrap_or((0, 0))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct TempDb {
        dir: std::path::PathBuf,
        db: Db,
    }

    impl std::ops::Deref for TempDb {
        type Target = Db;

        fn deref(&self) -> &Db {
            &self.db
        }
    }

    impl Drop for TempDb {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn db() -> TempDb {
        static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let unique = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let dir = std::env::temp_dir().join(format!("flaccy-video-cache-{}-{unique}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let db = Db::open(&dir.join("library.sqlite")).expect("temp db opens");
        TempDb { dir, db }
    }

    #[test]
    fn a_download_goes_from_part_to_ready_and_counts_in_the_totals() {
        let db = db();
        db.video_cache_progress("abc", 720, 720, "AV1", "abc.720.webm", 10, 100, 1_000);
        assert_eq!(db.video_cache_entry("abc", 720).unwrap().state, STATE_PART);
        assert_eq!(db.video_cache_totals(), (0, 0));
        db.video_cache_ready("abc", 720, 100);
        let row = db.video_cache_entry("abc", 720).unwrap();
        assert_eq!(row.state, STATE_READY);
        assert_eq!(row.bytes, 100);
        assert_eq!(db.video_cache_totals(), (1, 100));
    }

    #[test]
    fn one_video_holds_one_file_per_quality_ceiling() {
        let db = db();
        db.video_cache_progress("abc", 720, 720, "AV1", "abc.720.webm", 1, 1, 1);
        db.video_cache_progress("abc", 1080, 1080, "AV1", "abc.1080.webm", 1, 1, 1);
        assert_eq!(db.video_cache_all().len(), 2);
        db.video_cache_delete("abc", 720);
        assert!(db.video_cache_entry("abc", 720).is_none());
        assert!(db.video_cache_entry("abc", 1080).is_some());
    }

    #[test]
    fn a_failure_counts_attempts_and_keeps_the_partial_download() {
        let db = db();
        db.video_cache_progress("abc", 720, 720, "AV1", "abc.720.webm", 50, 100, 1);
        let first = db.video_cache_failed("abc", 720, "transient", "timed out", 90, 60);
        let second = db.video_cache_failed("abc", 720, "throttled", "429", 400, 100);
        assert_eq!((first, second), (1, 2));
        let row = db.video_cache_entry("abc", 720).unwrap();
        assert_eq!(row.state, STATE_PART);
        assert_eq!(row.bytes, 50);
        assert_eq!(row.failure_class.as_deref(), Some("throttled"));
        assert_eq!(row.next_attempt_at, Some(400));
    }

    #[test]
    fn a_failure_with_no_bytes_is_recorded_without_a_file() {
        let db = db();
        let attempts = db.video_cache_failed("gone", 720, "not-found", "removed", 700, 100);
        assert_eq!(attempts, 1);
        assert_eq!(db.video_cache_entry("gone", 720).unwrap().state, STATE_FAILED);
    }

    #[test]
    fn a_failure_never_demotes_a_ready_file() {
        let db = db();
        db.video_cache_progress("abc", 720, 720, "AV1", "abc.720.webm", 100, 100, 1);
        db.video_cache_ready("abc", 720, 100);
        db.video_cache_failed("abc", 720, "transient", "blip", 50, 10);
        assert_eq!(db.video_cache_entry("abc", 720).unwrap().state, STATE_READY);
    }

    #[test]
    fn plays_and_pins_are_kept() {
        let db = db();
        db.video_cache_progress("abc", 720, 720, "AV1", "abc.720.webm", 1, 1, 1);
        db.video_cache_played("abc", 720, 500);
        db.video_cache_played("abc", 720, 600);
        db.video_cache_set_pinned("abc", 720, true);
        let row = db.video_cache_entry("abc", 720).unwrap();
        assert_eq!((row.plays, row.last_played_at, row.pinned), (2, Some(600), true));
    }
}
