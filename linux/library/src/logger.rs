use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

const MAX_LOG_BYTES: u64 = 1_048_576;

struct LogFile {
    path: PathBuf,
    file: File,
}

static LOGGER: OnceLock<Mutex<Option<LogFile>>> = OnceLock::new();

/// Opens `flaccy.log` inside `directory`, creating the directory first. The app
/// passes its data directory so the library never reads app configuration.
pub fn init(directory: &Path) {
    if fs::create_dir_all(directory).is_err() {
        return;
    }
    let path = directory.join("flaccy.log");
    let Ok(file) = OpenOptions::new().create(true).append(true).open(&path) else {
        return;
    };
    let _ = LOGGER.set(Mutex::new(Some(LogFile { path, file })));
}

/// Writes one INFO line to stderr and the log file.
pub fn info(category: &str, message: &str) {
    write_line("INFO", category, message);
}

/// Writes one WARN line to stderr and the log file.
pub fn warn(category: &str, message: &str) {
    write_line("WARN", category, message);
}

/// Writes one ERROR line to stderr and the log file.
pub fn error(category: &str, message: &str) {
    write_line("ERROR", category, message);
}

fn write_line(level: &str, category: &str, message: &str) {
    let stamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
    let line = format!("{stamp} [{level}] [{category}] {message}\n");
    eprint!("{line}");
    let Some(mutex) = LOGGER.get() else { return };
    let Ok(mut guard) = mutex.lock() else { return };
    let Some(log) = guard.as_mut() else { return };
    let _ = log.file.write_all(line.as_bytes());
    rotate_if_needed(log);
}

fn rotate_if_needed(log: &mut LogFile) {
    let Ok(meta) = log.file.metadata() else {
        return;
    };
    if meta.len() < MAX_LOG_BYTES {
        return;
    }
    let previous = log.path.with_extension("log.1");
    let _ = fs::rename(&log.path, &previous);
    if let Ok(file) = OpenOptions::new().create(true).append(true).open(&log.path) {
        log.file = file;
    }
}
