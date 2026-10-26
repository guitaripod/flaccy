//! Backups of `state.sqlite` and `security.sqlite` through SQLite's online backup API.
//!
//! The copy is read from its own read-only connection in small steps with a
//! short pause between them, so the server's writer is never held up for
//! long and the server can keep running. Every copy is written beside its
//! final name, checked with `PRAGMA integrity_check` and only then renamed
//! into place, so a backup folder never holds a half-written file under a
//! real name.
//!
//! `state-*.sqlite` holds playlists, loves, ratings, history and the like and
//! no secrets. `security-*.sqlite` holds users, devices and token hashes, so
//! keep that folder as private as the data folder. Last.fm session keys never
//! leave the live database: the copy is emptied of them before it is published.

use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use chrono::{DateTime, Local, SecondsFormat, Utc};
use rusqlite::backup::{Backup, StepResult};
use rusqlite::{Connection, OpenFlags};

use crate::admin::say;
use crate::config::Config;
use crate::security;

const PAGES_PER_STEP: i32 = 128;
const MAX_RESTARTS: usize = 3;
const PAUSE_BETWEEN_STEPS: Duration = Duration::from_millis(5);
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const STALE_PARTIAL_AGE: Duration = Duration::from_secs(60 * 60);
const PARTIAL_SUFFIX: &str = ".partial";
const STAMP_FORMAT: &str = "%Y%m%d-%H%M%S";
const LAST_AT_KEY: &str = "last_backup_at";
const LAST_OK_KEY: &str = "last_backup_ok";
const LAST_ERROR_KEY: &str = "last_backup_error";

/// One file a backup wrote.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackupFile {
    pub path: PathBuf,
    pub bytes: u64,
}

/// The two files one backup writes, stamped with the same moment.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BackupSet {
    pub state: BackupFile,
    pub security: BackupFile,
}

/// What `server_meta` remembers about the last backup, for `status` and `doctor`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct BackupStatus {
    /// When the last attempt ran, RFC 3339 in UTC.
    pub last_at: Option<String>,
    /// Whether that attempt succeeded.
    pub last_ok: Option<bool>,
    /// Why it failed, empty when it did not.
    pub last_error: Option<String>,
}

/// The name of a backup file: `<kind>-YYYYMMDD-HHMMSS.sqlite`.
pub fn backup_name(kind: &str, at: &DateTime<Local>) -> String {
    format!("{kind}-{}.sqlite", at.format(STAMP_FORMAT))
}

/// Copies `source` to `target` with the online backup API and leaves `target` a single rollback-journal file.
pub(crate) fn copy_online(source: &Path, target: &Path) -> Result<(), String> {
    let describe = |what: &str, error: rusqlite::Error| format!("Could not {what} ({}): {error}.", source.display());
    let reader = Connection::open_with_flags(source, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .map_err(|error| describe("open the database to copy", error))?;
    reader.busy_timeout(BUSY_TIMEOUT).map_err(|error| describe("set the busy timeout on", error))?;
    let mut writer = Connection::open(target).map_err(|error| describe("create the copy of", error))?;
    {
        let backup = Backup::new(&reader, &mut writer).map_err(|error| describe("start copying", error))?;
        copy_in_steps(&backup).map_err(|error| describe("finish copying", error))?;
    }
    writer
        .pragma_update_and_check(None, "journal_mode", "DELETE", |row| row.get::<_, String>(0))
        .map_err(|error| describe("settle the copy of", error))?;
    writer.close().map_err(|(_, error)| describe("close the copy of", error))
}

/// Copies in short steps with a pause between them. SQLite starts over whenever another connection writes mid-copy, so
/// after a few restarts the rest goes in one step: a WAL reader never blocks the writer, and one step cannot be restarted.
fn copy_in_steps(backup: &Backup<'_, '_>) -> rusqlite::Result<()> {
    let (mut restarts, mut previous_remaining) = (0, i32::MAX);
    loop {
        match backup.step(PAGES_PER_STEP)? {
            StepResult::Done => return Ok(()),
            _ => {
                let remaining = backup.progress().remaining;
                restarts += usize::from(remaining > previous_remaining);
                previous_remaining = remaining;
                if restarts > MAX_RESTARTS {
                    return finish_in_one_step(backup);
                }
                std::thread::sleep(PAUSE_BETWEEN_STEPS);
            }
        }
    }
}

fn finish_in_one_step(backup: &Backup<'_, '_>) -> rusqlite::Result<()> {
    loop {
        match backup.step(-1)? {
            StepResult::Done => return Ok(()),
            _ => std::thread::sleep(PAUSE_BETWEEN_STEPS),
        }
    }
}

/// Runs `PRAGMA integrity_check` on the file at `path`, read-only, and fails with SQLite's first complaints.
pub(crate) fn verify_integrity(path: &Path) -> Result<(), String> {
    let describe = |error: rusqlite::Error| format!("The database {} could not be checked: {error}.", path.display());
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(describe)?;
    let mut statement = connection.prepare("PRAGMA integrity_check").map_err(describe)?;
    let lines = statement
        .query_map([], |row| row.get::<_, String>(0))
        .map_err(describe)?
        .collect::<Result<Vec<_>, _>>()
        .map_err(describe)?;
    if lines == ["ok"] {
        Ok(())
    } else {
        let shown: Vec<&str> = lines.iter().take(3).map(String::as_str).collect();
        Err(format!("The database {} failed its integrity check: {}.", path.display(), shown.join("; ")))
    }
}

/// Flushes a file's contents to disk.
pub(crate) fn sync_file(path: &Path) -> Result<(), String> {
    std::fs::File::open(path)
        .and_then(|file| file.sync_all())
        .map_err(|error| format!("Could not flush {} to disk: {error}.", path.display()))
}

/// Flushes a folder's entries, so a rename inside it survives a power cut.
pub(crate) fn sync_folder(dir: &Path) -> Result<(), String> {
    sync_file(dir)
}

fn partial_path(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("{name}.{}{PARTIAL_SUFFIX}", std::process::id()))
}

pub(crate) fn remove_with_journal(path: &Path) {
    let _ = std::fs::remove_file(path);
    let _ = std::fs::remove_file(format!("{}-journal", path.display()));
}

fn write_verified_copy(source: &Path, partial: &Path, scrub: fn(&Path) -> Result<(), String>) -> Result<(), String> {
    remove_with_journal(partial);
    security::prepare_private_file(partial).map_err(|error| format!("Could not create {}: {error}.", partial.display()))?;
    copy_online(source, partial)?;
    scrub(partial)?;
    verify_integrity(partial)?;
    sync_file(partial)
}

fn keep_everything(_partial: &Path) -> Result<(), String> {
    Ok(())
}

/// Empties `lastfm_sessions` in a copy of `security.sqlite`, so a session key never leaves the live database through a backup.
fn strip_lastfm_sessions(partial: &Path) -> Result<(), String> {
    let describe = |error: rusqlite::Error| {
        format!("Could not remove the Last.fm session keys from the backup {}: {error}.", partial.display())
    };
    let connection = Connection::open(partial).map_err(describe)?;
    connection.execute_batch("DELETE FROM lastfm_sessions; VACUUM;").map_err(describe)
}

fn publish_copy(source: &Path, dir: &Path, name: &str, scrub: fn(&Path) -> Result<(), String>) -> Result<BackupFile, String> {
    let partial = partial_path(dir, name);
    let path = dir.join(name);
    let outcome = write_verified_copy(source, &partial, scrub).and_then(|()| {
        std::fs::rename(&partial, &path).map_err(|error| format!("Could not move the finished backup to {}: {error}.", path.display()))
    });
    if let Err(error) = outcome {
        remove_with_journal(&partial);
        return Err(error);
    }
    let bytes = std::fs::metadata(&path).map(|metadata| metadata.len()).unwrap_or(0);
    Ok(BackupFile { path, bytes })
}

fn remove_stale_partials(dir: &Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let stale = entry.file_name().to_string_lossy().contains(PARTIAL_SUFFIX)
            && entry
                .metadata()
                .and_then(|metadata| metadata.modified())
                .ok()
                .and_then(|modified| SystemTime::now().duration_since(modified).ok())
                .is_some_and(|age| age > STALE_PARTIAL_AGE);
        if stale {
            remove_with_journal(&entry.path());
        }
    }
}

fn require_file(path: &Path, what: &str) -> Result<(), String> {
    if path.is_file() {
        Ok(())
    } else {
        Err(format!(
            "There is no {what} at {}, so there is nothing to back up. Check `data_dir` in the configuration file, and start `flaccy-server serve` once to create it.",
            path.display()
        ))
    }
}

/// Backs up `state` and `security` into `dir` under names stamped with `at`. A failure leaves nothing behind under a real name.
pub fn back_up_files(state: &Path, security: &Path, dir: &Path, at: &DateTime<Local>) -> Result<BackupSet, String> {
    require_file(state, "state.sqlite")?;
    require_file(security, "security.sqlite")?;
    std::fs::create_dir_all(dir).map_err(|error| {
        format!("Could not create the backup folder {}: {error}. Make it writable, or point `backup_dir` somewhere that is.", dir.display())
    })?;
    remove_stale_partials(dir);
    let state_copy = publish_copy(state, dir, &backup_name("state", at), keep_everything)?;
    let security_copy = match publish_copy(security, dir, &backup_name("security", at), strip_lastfm_sessions) {
        Ok(copy) => copy,
        Err(error) => {
            let _ = std::fs::remove_file(&state_copy.path);
            return Err(error);
        }
    };
    sync_folder(dir)?;
    Ok(BackupSet { state: state_copy, security: security_copy })
}

/// Backs up the databases `config` names into `dir`, on a blocking thread.
pub async fn back_up(config: &Config, dir: PathBuf) -> Result<BackupSet, String> {
    let (state, security) = (config.state_path(), config.security_path());
    tokio::task::spawn_blocking(move || back_up_files(&state, &security, &dir, &Local::now()))
        .await
        .map_err(|error| format!("The backup thread stopped unexpectedly: {error}."))?
}

async fn put_meta(security: &security::Store, pairs: Vec<(&'static str, String)>) -> Result<(), security::SecurityError> {
    security
        .write(move |transaction, _| {
            for (key, value) in &pairs {
                transaction.execute(
                    "INSERT INTO server_meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    (key, value),
                )?;
            }
            Ok(())
        })
        .await
}

/// Writes `last_backup_at`, `last_backup_ok` and `last_backup_error` into `security.sqlite`, which a restore never replaces.
pub async fn record_outcome(security: &security::Store, outcome: &Result<BackupSet, String>) -> Result<(), String> {
    let at = Utc::now().to_rfc3339_opts(SecondsFormat::Secs, true);
    let (ok, error) = match outcome {
        Ok(_) => ("1", String::new()),
        Err(error) => ("0", error.clone()),
    };
    let pairs = vec![(LAST_AT_KEY, at), (LAST_OK_KEY, ok.to_owned()), (LAST_ERROR_KEY, error)];
    put_meta(security, pairs).await.map_err(|error| error.to_string())
}

/// What the last backup attempt left in `server_meta`.
pub async fn last_status(security: &security::Store) -> Result<BackupStatus, String> {
    let values = security
        .read(|connection| {
            let mut statement = connection.prepare("SELECT key, value FROM server_meta WHERE key IN (?1, ?2, ?3)")?;
            let rows = statement
                .query_map([LAST_AT_KEY, LAST_OK_KEY, LAST_ERROR_KEY], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
        .map_err(|error| error.to_string())?;
    let find = |key: &str| values.iter().find(|(name, _)| name == key).map(|(_, value)| value.clone());
    Ok(BackupStatus {
        last_at: find(LAST_AT_KEY),
        last_ok: find(LAST_OK_KEY).map(|value| value == "1"),
        last_error: find(LAST_ERROR_KEY).filter(|text| !text.is_empty()),
    })
}

fn human_size(bytes: u64) -> String {
    if bytes >= 1_048_576 {
        format!("{:.1} MB", bytes as f64 / 1_048_576.0)
    } else {
        format!("{:.1} KB", bytes as f64 / 1024.0)
    }
}

fn announce(set: &BackupSet) {
    say(&format!("Backed up the sync state to {} ({}).", set.state.path.display(), human_size(set.state.bytes)));
    say(&format!(
        "Backed up users, devices and keys to {} ({}). Keep that file as private as the data folder.",
        set.security.path.display(),
        human_size(set.security.bytes)
    ));
}

/// `backup [--to DIR]`: one backup now, while the server may be running.
pub async fn command(config: &Config, to: Option<PathBuf>) -> Result<(), String> {
    let dir = to.or_else(|| config.backup_dir()).ok_or_else(|| {
        "Backups are turned off by an empty `backup_dir` in the configuration file. Pass `--to DIR`, or set `backup_dir` to a folder.".to_owned()
    })?;
    let outcome = back_up(config, dir).await;
    if let Ok(store) = security::Store::open(&config.security_path()).await {
        if let Err(error) = record_outcome(&store, &outcome).await {
            say(&format!("The backup is made, but its status could not be recorded: {error}"));
        }
        let _ = store.close().await;
    }
    announce(&outcome?);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    #[test]
    fn names_carry_the_kind_and_the_local_stamp() {
        let at = Local.with_ymd_and_hms(2026, 10, 26, 3, 30, 7).unwrap();
        assert_eq!(backup_name("state", &at), "state-20261026-033007.sqlite");
        assert_eq!(backup_name("security", &at), "security-20261026-033007.sqlite");
    }

    #[test]
    fn a_copy_finishes_while_another_connection_writes_without_pause() {
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;
        let dir = std::env::temp_dir().join(format!("flaccy-backup-busy-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("busy.sqlite");
        let mut writer = Connection::open(&source).unwrap();
        writer.pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get::<_, String>(0)).unwrap();
        writer.execute_batch("CREATE TABLE rows(n INTEGER PRIMARY KEY, filler BLOB)").unwrap();
        let seeding = writer.transaction().unwrap();
        for _ in 0..4000 {
            seeding.execute("INSERT INTO rows(filler) VALUES (zeroblob(2000))", []).unwrap();
        }
        seeding.commit().unwrap();
        let running = Arc::new(AtomicBool::new(true));
        let hammer = {
            let running = running.clone();
            let path = source.clone();
            std::thread::spawn(move || {
                let connection = Connection::open(&path).unwrap();
                while running.load(Ordering::Relaxed) {
                    connection.execute("INSERT INTO rows(filler) VALUES (zeroblob(2000))", []).unwrap();
                }
            })
        };
        let target = dir.join("copy.sqlite");
        copy_online(&source, &target).unwrap();
        running.store(false, Ordering::Relaxed);
        hammer.join().unwrap();
        verify_integrity(&target).unwrap();
        let copied: i64 = Connection::open(&target).unwrap().query_row("SELECT COUNT(*) FROM rows", [], |row| row.get(0)).unwrap();
        assert!(copied >= 4000);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn sizes_read_in_kilobytes_then_megabytes() {
        assert_eq!(human_size(2048), "2.0 KB");
        assert_eq!(human_size(3 * 1_048_576), "3.0 MB");
    }
}
