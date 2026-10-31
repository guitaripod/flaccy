//! Keeping the library current: a scan and revision pass at start and again,
//! three seconds after the last change, whenever the music folder changes.

use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use flaccy_library::logger;
use flaccy_library::scanner::{spawn_scan_with, ScanEvent, ScanOptions};
use notify::{EventKind, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use crate::scan_progress::ScanReporter;
use crate::state::AppState;

const SETTLE: Duration = Duration::from_secs(3);
/// How long one background scan may spend hashing the audio of files that have no MD5 of their own, before it
/// lets the next change to the music folder in.
const FINGERPRINT_SLICE: Duration = Duration::from_secs(60);
/// The pause between two slices of that hashing.
const FINGERPRINT_PAUSE: Duration = Duration::from_secs(1);

/// What one scan and revision pass found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScanSummary {
    pub added: usize,
    pub removed: usize,
    pub new_versions: usize,
    pub retagged: bool,
    /// Songs whose audio still has to be fingerprinted by a later background scan.
    pub backlog: usize,
    pub failure: Option<String>,
}

impl ScanSummary {
    /// One line for the log and for `status`.
    pub fn describe(&self, songs: usize) -> String {
        match &self.failure {
            Some(failure) => format!("scan failed: {failure}"),
            None => format!(
                "scan finished: {} added, {} removed, {} new versions{}, {songs} songs in the library{}",
                self.added,
                self.removed,
                self.new_versions,
                if self.retagged { ", tags refreshed" } else { "" },
                match self.backlog {
                    0 => String::new(),
                    left => format!("; {} still being fingerprinted in the background", crate::setup::grouped(left)),
                }
            ),
        }
    }
}

/// Scans the music folder, runs the revision pass behind it and rebuilds the
/// catalog. Blocks until all of it is done, so call it from a blocking thread.
pub fn refresh_now(state: &AppState) -> ScanSummary {
    refresh_with(state, ScanOptions::default())
}

/// [`refresh_now`] for the running server: the hashing of audio that has no MD5 of its own gets a minute at a
/// time, so a change to the music folder is never kept waiting for hours behind a first scan.
fn refresh_slice(state: &AppState) -> ScanSummary {
    refresh_with(
        state,
        ScanOptions { revision_budget: Some(FINGERPRINT_SLICE), backlog: Some(Arc::new(AtomicUsize::new(0))) },
    )
}

fn refresh_with(state: &AppState, options: ScanOptions) -> ScanSummary {
    let _only_one = state
        .0
        .refresh_gate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let (sender, receiver) = async_channel::unbounded();
    let backlog = options.backlog.clone();
    spawn_scan_with(
        state.music_root().to_path_buf(),
        state.0.config.database_path(),
        sender,
        options,
    );
    let mut summary = ScanSummary::default();
    state.0.scan.begin();
    let mut reporter = ScanReporter::new(Instant::now());
    while let Ok(event) = receiver.recv_blocking() {
        match event {
            ScanEvent::Done { added, removed } => {
                summary.added = added;
                summary.removed = removed;
                reporter.finished(state);
                state.rebuild_catalog();
            }
            ScanEvent::Revised(paths) => summary.new_versions = paths.len(),
            ScanEvent::Retagged => summary.retagged = true,
            ScanEvent::Failed(message) => {
                summary.failure = Some(format!(
                    "{message}. Check that the music folder {} is readable and the data folder is writable, then touch a file in the music folder to scan again",
                    state.music_root().display()
                ));
            }
            ScanEvent::Progress(progress) => reporter.observe(state, &progress),
            ScanEvent::CoversHoisted(_) => {}
        }
    }
    summary.backlog = backlog.map_or(0, |left| left.load(Ordering::SeqCst));
    reporter.finished(state);
    if summary.backlog == 0 || summary.retagged || summary.new_versions > 0 {
        state.rebuild_catalog();
    }
    let songs = state.catalog().song_count();
    let line = summary.describe(songs);
    match summary.failure {
        Some(_) => logger::error("server", &line),
        None => logger::info("server", &line),
    }
    state.0.store.set_state(
        "lastScanAt",
        &chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    );
    state.0.store.set_state("lastScanSummary", &line);
    summary
}

async fn refresh_in_background(state: &AppState) -> usize {
    let state = state.clone();
    match tokio::task::spawn_blocking(move || refresh_slice(&state)).await {
        Ok(summary) => summary.backlog,
        Err(err) => {
            logger::error(
                "server",
                &format!("the scan thread stopped unexpectedly: {err}; the next change to the music folder starts a new one"),
            );
            0
        }
    }
}

/// Scans once at start, then again after every burst of changes to the music
/// folder, until the task is dropped, and keeps going through the hashing a big
/// first scan leaves behind. Runs the scans on blocking threads so requests are
/// never held up.
pub async fn keep_current(state: AppState) {
    let (sender, mut changes) = mpsc::unbounded_channel::<()>();
    let _watcher = watch_folder(&state, sender);
    let mut backlog = refresh_in_background(&state).await;
    loop {
        let changed = if backlog > 0 {
            match tokio::time::timeout(FINGERPRINT_PAUSE, changes.recv()).await {
                Ok(None) => return,
                Ok(Some(())) => true,
                Err(_) => false,
            }
        } else {
            match changes.recv().await {
                Some(()) => true,
                None => return,
            }
        };
        if changed {
            while let Ok(Some(())) = tokio::time::timeout(SETTLE, changes.recv()).await {}
            logger::info("server", "the music folder changed; scanning");
        }
        backlog = refresh_in_background(&state).await;
    }
}

fn watch_folder(state: &AppState, sender: mpsc::UnboundedSender<()>) -> Option<notify::RecommendedWatcher> {
    let data_dir = state.0.config.data_dir();
    let root = state.music_root().to_path_buf();
    let handler = move |event: notify::Result<notify::Event>| {
        if let Ok(event) = event {
            if is_content_change(&event, &data_dir) {
                let _ = sender.send(());
            }
        }
    };
    let mut watcher = match notify::recommended_watcher(handler) {
        Ok(watcher) => watcher,
        Err(err) => {
            logger::warn(
                "server",
                &format!("could not start watching the music folder: {err}; changes are picked up only when the server restarts or `flaccy-server scan` runs"),
            );
            return None;
        }
    };
    if let Err(err) = watcher.watch(&root, RecursiveMode::Recursive) {
        logger::warn(
            "server",
            &format!("could not watch {}: {err}; if the folder has too many subfolders raise fs.inotify.max_user_watches, otherwise run `flaccy-server scan` after adding music", root.display()),
        );
        return None;
    }
    Some(watcher)
}

fn is_content_change(event: &notify::Event, data_dir: &Path) -> bool {
    if matches!(event.kind, EventKind::Access(_) | EventKind::Other) {
        return false;
    }
    event.paths.iter().any(|path| {
        let hidden = path
            .file_name()
            .is_some_and(|name| name.to_string_lossy().starts_with('.'));
        !hidden && !path.starts_with(data_dir)
    })
}
