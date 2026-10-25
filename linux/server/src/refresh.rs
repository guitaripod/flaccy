//! Keeping the library current: a scan and revision pass at start and again,
//! three seconds after the last change, whenever the music folder changes.

use std::path::Path;
use std::time::Duration;

use flaccy_library::logger;
use flaccy_library::scanner::{spawn_scan, ScanEvent};
use notify::{EventKind, RecursiveMode, Watcher};
use tokio::sync::mpsc;

use crate::state::AppState;

const SETTLE: Duration = Duration::from_secs(3);

/// What one scan and revision pass found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ScanSummary {
    pub added: usize,
    pub removed: usize,
    pub new_versions: usize,
    pub retagged: bool,
    pub failure: Option<String>,
}

impl ScanSummary {
    /// One line for the log and for `status`.
    pub fn describe(&self, songs: usize) -> String {
        match &self.failure {
            Some(failure) => format!("scan failed: {failure}"),
            None => format!(
                "scan finished: {} added, {} removed, {} new versions{}, {songs} songs in the library",
                self.added,
                self.removed,
                self.new_versions,
                if self.retagged { ", tags refreshed" } else { "" }
            ),
        }
    }
}

/// Scans the music folder, runs the revision pass behind it and rebuilds the
/// catalog. Blocks until all of it is done, so call it from a blocking thread.
pub fn refresh_now(state: &AppState) -> ScanSummary {
    let _only_one = state
        .0
        .refresh_gate
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let (sender, receiver) = async_channel::unbounded();
    spawn_scan(
        state.music_root().to_path_buf(),
        state.0.config.database_path(),
        sender,
    );
    let mut summary = ScanSummary::default();
    while let Ok(event) = receiver.recv_blocking() {
        match event {
            ScanEvent::Done { added, removed } => {
                summary.added = added;
                summary.removed = removed;
            }
            ScanEvent::Revised(paths) => summary.new_versions = paths.len(),
            ScanEvent::Retagged => summary.retagged = true,
            ScanEvent::Failed(message) => {
                summary.failure = Some(format!(
                    "{message}. Check that the music folder {} is readable and the data folder is writable, then touch a file in the music folder to scan again",
                    state.music_root().display()
                ));
            }
            ScanEvent::Progress(_) | ScanEvent::CoversHoisted(_) => {}
        }
    }
    state.rebuild_catalog();
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

async fn refresh_in_background(state: &AppState) {
    let state = state.clone();
    if let Err(err) = tokio::task::spawn_blocking(move || refresh_now(&state)).await {
        logger::error(
            "server",
            &format!("the scan thread stopped unexpectedly: {err}; the next change to the music folder starts a new one"),
        );
    }
}

/// Scans once at start, then again after every burst of changes to the music
/// folder, until the task is dropped. Runs the scans on blocking threads so
/// requests are never held up.
pub async fn keep_current(state: AppState) {
    let (sender, mut changes) = mpsc::unbounded_channel::<()>();
    let _watcher = watch_folder(&state, sender);
    refresh_in_background(&state).await;
    while changes.recv().await.is_some() {
        while let Ok(Some(())) = tokio::time::timeout(SETTLE, changes.recv()).await {}
        logger::info("server", "the music folder changed; scanning");
        refresh_in_background(&state).await;
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
