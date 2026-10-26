//! `flaccy-server restore FILE`: put a backup of `state.sqlite` back, with the server stopped.
//!
//! Users, devices, tokens and revocations live in `security.sqlite` and stay
//! exactly as they are. Only the incarnation changes, so every device learns
//! that the history moved and sends again whatever the backup lacks.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use chrono::Local;
use rusqlite::{Connection, OpenFlags};

use crate::admin::say;
use crate::backup::{copy_online, remove_with_journal, sync_file, sync_folder, verify_integrity};
use crate::config::Config;
use crate::dbthread::{self, DbError};
use crate::lock::{DataDirLock, LockError};
use crate::security;
use crate::sync;

const STAMP_FORMAT: &str = "%Y%m%d-%H%M%S";
const STATE_TABLES: [&str; 4] = ["schema_migrations", "changes", "playlists", "listens"];
const SECURITY_TABLES: [&str; 2] = ["users", "devices"];

/// What a restore did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Restored {
    /// Where the replaced `state.sqlite` was kept, when there was one.
    pub kept_as: Option<PathBuf>,
    /// The server's new incarnation.
    pub incarnation: String,
    /// True when there was no `security.sqlite` and a new one was made.
    pub security_created: bool,
}

fn table_names(connection: &Connection) -> Result<BTreeSet<String>, rusqlite::Error> {
    let mut statement = connection.prepare("SELECT name FROM sqlite_master WHERE type = 'table'")?;
    let names = statement.query_map([], |row| row.get::<_, String>(0))?.collect::<Result<BTreeSet<_>, _>>()?;
    Ok(names)
}

fn wrong_kind(file: &Path, found: &str) -> String {
    format!(
        "{} is {found}, not a state backup. Restore a file named state-YYYYMMDD-HHMMSS.sqlite from the backup folder.",
        file.display()
    )
}

fn check_tables(file: &Path, connection: &Connection) -> Result<(), String> {
    let names = table_names(connection).map_err(|error| format!("Could not read {}: {error}.", file.display()))?;
    if SECURITY_TABLES.iter().all(|table| names.contains(*table)) {
        return Err(wrong_kind(file, "a security backup (users and devices)"));
    }
    if STATE_TABLES.iter().all(|table| names.contains(*table)) {
        Ok(())
    } else {
        Err(wrong_kind(file, "not a Flaccy Server database"))
    }
}

/// Checks that `file` is an intact state backup this build can use; changes nothing.
pub fn check_backup(file: &Path) -> Result<(), String> {
    if !file.is_file() {
        return Err(format!("There is no backup file at {}. Check the path; the backup folder holds files named state-YYYYMMDD-HHMMSS.sqlite.", file.display()));
    }
    verify_integrity(file)?;
    let connection = Connection::open_with_flags(file, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| format!("Could not open {}: {error}.", file.display()))?;
    check_tables(file, &connection)?;
    let found = dbthread::schema_version(&connection).map_err(|error| error.to_string())?;
    let supported = sync::CURRENT_VERSION;
    if found > supported {
        return Err(DbError::SchemaTooNew { file: file.to_path_buf(), found, supported }.to_string());
    }
    Ok(())
}

fn unused_path(base: PathBuf) -> PathBuf {
    if !base.exists() {
        return base;
    }
    let name = base.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    (2..)
        .map(|number| base.with_file_name(format!("{name}.{number}")))
        .find(|candidate| !candidate.exists())
        .unwrap_or(base)
}

fn copy_raw(state: &Path, aside: &Path) -> Result<(), String> {
    std::fs::copy(state, aside).map_err(|error| format!("Could not copy {} to {}: {error}.", state.display(), aside.display()))?;
    let wal = PathBuf::from(format!("{}-wal", state.display()));
    if wal.exists() {
        let kept = PathBuf::from(format!("{}-wal", aside.display()));
        std::fs::copy(&wal, &kept).map_err(|error| format!("Could not copy {} to {}: {error}.", wal.display(), kept.display()))?;
    }
    Ok(())
}

/// Copies the current `state.sqlite` to `state.before-restore-<stamp>.sqlite`, through SQLite so its log is included, or byte for byte when the file is too damaged for that.
fn set_aside(state: &Path) -> Result<Option<PathBuf>, String> {
    if !state.is_file() {
        return Ok(None);
    }
    let stamp = Local::now().format(STAMP_FORMAT);
    let aside = unused_path(state.with_file_name(format!("state.before-restore-{stamp}.sqlite")));
    security::prepare_private_file(&aside).map_err(|error| format!("Could not create {}: {error}.", aside.display()))?;
    if copy_online(state, &aside).is_err() {
        remove_with_journal(&aside);
        copy_raw(state, &aside)?;
    }
    sync_file(&aside)?;
    Ok(Some(aside))
}

fn remove_if_present(path: &Path) -> Result<(), String> {
    match std::fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("Could not remove {}: {error}. Nothing else was changed; check the folder permissions and run the restore again.", path.display())),
    }
}

fn stage_copy(file: &Path, staging: &Path) -> Result<(), String> {
    remove_with_journal(staging);
    security::prepare_private_file(staging).map_err(|error| format!("Could not create {}: {error}.", staging.display()))?;
    copy_online(file, staging)?;
    verify_integrity(staging)?;
    sync_file(staging)
}

/// Writes the backup beside `state`, flushes it, drops the old log files and renames it into place.
fn replace_state(file: &Path, state: &Path) -> Result<(), String> {
    let staging = state.with_file_name(format!("state.sqlite.restoring-{}", std::process::id()));
    let outcome = stage_copy(file, &staging).and_then(|()| {
        remove_if_present(&PathBuf::from(format!("{}-wal", state.display())))?;
        remove_if_present(&PathBuf::from(format!("{}-shm", state.display())))?;
        std::fs::rename(&staging, state).map_err(|error| format!("Could not move the restored copy into place at {}: {error}.", state.display()))
    });
    if outcome.is_err() {
        remove_with_journal(&staging);
    }
    outcome?;
    state.parent().map_or(Ok(()), sync_folder)
}

async fn new_incarnation(security_path: &Path) -> Result<String, String> {
    let store = security::Store::open(security_path).await.map_err(|error| error.to_string())?;
    let bumped = store.bump_incarnation().await.map_err(|error| error.to_string());
    let _ = store.close().await;
    bumped
}

fn lock_refusal(error: LockError, dir: &Path) -> String {
    match error {
        LockError::Held { pid, .. } => format!(
            "A Flaccy Server is running on {} ({}), so nothing was restored. Stop it first (for the service: `systemctl --user stop flaccy-server`), run the restore again, then start it.",
            dir.display(),
            pid.map_or("pid unknown".to_owned(), |pid| format!("pid {pid}"))
        ),
        other => other.to_string(),
    }
}

/// Restores `file` into the data folder of `config`, holding the data-folder lock throughout.
pub async fn restore_into(config: &Config, file: &Path) -> Result<Restored, String> {
    let dir = config.data_dir();
    let _lock = DataDirLock::acquire(&dir).map_err(|error| lock_refusal(error, &dir))?;
    check_backup(file)?;
    let state = config.state_path();
    let kept_as = set_aside(&state)?;
    replace_state(file, &state)?;
    let security_path = config.security_path();
    let security_created = !security_path.exists();
    let incarnation = new_incarnation(&security_path).await.map_err(|error| {
        format!("The sync state is restored, but the incarnation could not be changed: {error} Run the restore again to finish.")
    })?;
    Ok(Restored { kept_as, incarnation, security_created })
}

/// `restore FILE`
pub async fn command(config: &Config, file: &Path) -> Result<(), String> {
    let restored = restore_into(config, file).await?;
    say(&format!(
        "Restored from {}. Your devices will notice and re-send anything newer than this backup.",
        file.display()
    ));
    if let Some(kept) = &restored.kept_as {
        say(&format!("The sync state it replaced is kept as {}.", kept.display()));
    }
    if restored.security_created {
        say("There was no security database, so a new one was made: enroll your devices again with `flaccy-server enroll --user NAME`, or copy a security-*.sqlite backup to the data folder as security.sqlite first.");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unused_path_is_numbered_when_taken() {
        let dir = std::env::temp_dir().join(format!("flaccy-restore-unused-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let first = dir.join("a.sqlite");
        assert_eq!(unused_path(first.clone()), first);
        std::fs::write(&first, b"x").unwrap();
        assert_eq!(unused_path(first.clone()), dir.join("a.sqlite.2"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_missing_file_is_named_in_the_error() {
        let error = check_backup(Path::new("/nonexistent/state-20260101-000000.sqlite")).unwrap_err();
        assert!(error.contains("/nonexistent/state-20260101-000000.sqlite") && error.contains("no backup file"), "{error}");
    }
}
