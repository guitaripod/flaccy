//! The app's handle on the remote library: one shared `Remote`, started before
//! the player so a remote song's playback URL can be built from any thread,
//! and small questions the views ask about a song's source.

use crate::config::Config;
use flaccy_library::remote::service::{Availability, Paths, Remote};
use flaccy_shared::remote::remote_path;
use std::sync::{Arc, OnceLock};

static REMOTE: OnceLock<Arc<Remote>> = OnceLock::new();

/// Starts the remote library under the app's configuration, cache and data
/// folders, once. `None` when its proxy could not start.
pub fn start(config: &Config, db_path: &std::path::Path) -> Option<Arc<Remote>> {
    if let Some(existing) = REMOTE.get() {
        return Some(Arc::clone(existing));
    }
    let paths = Paths {
        config_dir: crate::config::config_dir(),
        cache_dir: dirs::cache_dir().unwrap_or_default().join("flaccy"),
        data_dir: dirs::data_dir().unwrap_or_default().join("flaccy"),
        db_path: db_path.to_path_buf(),
    };
    match Remote::start(paths, config.remote_cache_cap_bytes()) {
        Ok(remote) => {
            let _ = REMOTE.set(Arc::clone(&remote));
            Some(remote)
        }
        Err(err) => {
            crate::logger::error(
                "remote",
                &format!("the remote library could not start its local proxy: {err}"),
            );
            None
        }
    }
}

/// The running remote library, `None` before `start` or when it failed.
pub fn handle() -> Option<&'static Arc<Remote>> {
    REMOTE.get()
}

/// Whether the library row at `rel_path` is a song from a server.
pub fn is_remote(rel_path: &str) -> bool {
    remote_path::is_remote(rel_path)
}

/// The server id of a remote song's path.
pub fn server_of(rel_path: &str) -> Option<String> {
    remote_path::decode(rel_path).map(|(server, _)| server)
}

/// The loopback URL a remote song plays from.
pub fn proxy_uri(rel_path: &str) -> Option<String> {
    handle()?.proxy_url(rel_path)
}

/// The toast for a remote song that cannot play now, `None` when it can.
pub fn unplayable_message(rel_path: &str, title: &str) -> Option<String> {
    if !is_remote(rel_path) {
        return None;
    }
    handle()?.unplayable_message(rel_path, title)
}

/// Whether a remote song should look unavailable: its server is out of reach
/// and none of it is on this computer.
pub fn is_dimmed(rel_path: &str) -> bool {
    is_remote(rel_path)
        && handle().is_some_and(|remote| remote.availability(rel_path) == Availability::Offline)
}

/// Whether a remote song is kept on this computer.
pub fn is_downloaded(rel_path: &str) -> bool {
    is_remote(rel_path) && handle().is_some_and(|remote| remote.is_downloaded(rel_path))
}

/// Whether the person asked to keep a remote song.
pub fn is_pinned(rel_path: &str) -> bool {
    is_remote(rel_path) && handle().is_some_and(|remote| remote.is_pinned(rel_path))
}

/// The label of the source a Songs chip names: the server's name.
pub fn server_name(server: &str) -> String {
    handle()
        .map(|remote| remote.server_name(server))
        .unwrap_or_else(|| server.to_string())
}

/// What the Download entry of a menu should offer for these songs: `None` when
/// none is from a server, `Some(true)` when every remote one is already kept
/// (so the entry removes the download), `Some(false)` otherwise.
pub fn downloads_state<'a>(paths: impl IntoIterator<Item = &'a str>) -> Option<bool> {
    let mut any = false;
    let mut all_kept = true;
    for path in paths {
        if is_remote(path) {
            any = true;
            all_kept &= is_pinned(path);
        }
    }
    any.then_some(all_kept)
}

/// The remote songs among `paths`.
pub fn remote_paths<'a>(paths: impl IntoIterator<Item = &'a str>) -> Vec<String> {
    paths
        .into_iter()
        .filter(|path| is_remote(path))
        .map(str::to_string)
        .collect()
}
