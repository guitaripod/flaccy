//! The data-directory lock: one `serve` per data folder, and no `restore` under a running server.
//!
//! The lock is an advisory `flock` on `server.lock`, so the operating system
//! drops it when the process ends, however it ends. The holder writes its
//! process id into the file for the error message of whoever is refused.

use std::fs::{File, OpenOptions, TryLockError};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const LOCK_FILE: &str = "server.lock";

/// Why the lock could not be taken.
#[derive(Debug)]
pub enum LockError {
    /// Another process holds it; `pid` is what it wrote, when it had written it yet.
    Held { dir: PathBuf, pid: Option<u32> },
    /// The lock file could not be opened or locked.
    Io { path: PathBuf, message: String },
}

impl LockError {
    /// The holder's process id, if it is known.
    pub fn pid(&self) -> Option<u32> {
        match self {
            LockError::Held { pid, .. } => *pid,
            LockError::Io { .. } => None,
        }
    }
}

impl std::fmt::Display for LockError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            LockError::Held { dir, pid } => write!(
                formatter,
                "Another Flaccy Server is already using {} ({}). Stop it first, or give this one its own `data_dir` in the configuration file.",
                dir.display(),
                describe_pid(*pid)
            ),
            LockError::Io { path, message } => write!(
                formatter,
                "Could not lock {}: {message}. Check that the data folder exists and your user may write to it.",
                path.display()
            ),
        }
    }
}

impl std::error::Error for LockError {}

fn describe_pid(pid: Option<u32>) -> String {
    match pid {
        Some(pid) => format!("pid {pid}"),
        None => "pid unknown".to_owned(),
    }
}

/// Holds the lock until it is dropped.
#[derive(Debug)]
pub struct DataDirLock {
    _file: File,
}

impl DataDirLock {
    /// Creates `dir` when missing and takes the exclusive lock, or says who holds it.
    pub fn acquire(dir: &Path) -> Result<Self, LockError> {
        let path = dir.join(LOCK_FILE);
        let io_error = |error: std::io::Error| LockError::Io { path: path.clone(), message: error.to_string() };
        std::fs::create_dir_all(dir).map_err(io_error)?;
        let mut file = open_lock_file(&path).map_err(io_error)?;
        match file.try_lock() {
            Ok(()) => {}
            Err(TryLockError::WouldBlock) => return Err(LockError::Held { dir: dir.to_path_buf(), pid: holder_pid(&path) }),
            Err(TryLockError::Error(error)) => return Err(io_error(error)),
        }
        write_pid(&mut file).map_err(io_error)?;
        Ok(Self { _file: file })
    }
}

fn open_lock_file(path: &Path) -> std::io::Result<File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    options.open(path)
}

fn write_pid(file: &mut File) -> std::io::Result<()> {
    file.set_len(0)?;
    file.seek(SeekFrom::Start(0))?;
    write!(file, "{}", std::process::id())?;
    file.sync_all()
}

fn holder_pid(path: &Path) -> Option<u32> {
    let mut text = String::new();
    File::open(path).ok()?.read_to_string(&mut text).ok()?;
    text.trim().parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(label: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("flaccy-lock-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn a_second_holder_is_refused_with_the_first_ones_pid() {
        let dir = scratch("second");
        let first = DataDirLock::acquire(&dir).unwrap();
        let refused = DataDirLock::acquire(&dir).unwrap_err();
        assert_eq!(refused.pid(), Some(std::process::id()));
        let text = refused.to_string();
        assert!(text.starts_with("Another Flaccy Server is already using "), "{text}");
        assert!(text.contains(&format!("(pid {})", std::process::id())), "{text}");
        drop(first);
        assert!(DataDirLock::acquire(&dir).is_ok(), "dropping the lock frees it");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_folder_is_created_when_missing() {
        let dir = scratch("create").join("nested");
        let lock = DataDirLock::acquire(&dir).unwrap();
        assert!(dir.join(LOCK_FILE).is_file());
        drop(lock);
        std::fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    }
}
