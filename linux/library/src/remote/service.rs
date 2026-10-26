//! The remote library as the app sees it: the saved servers, the catalog sync,
//! the proxy URL for a song, what is downloaded, and the calls that tell a
//! server what was played or loved.
//!
//! Everything blocking runs on the caller's thread; the app calls the long ones
//! from workers. Changes reach the app through the listener, from any thread.

use super::cache::Store;
use super::client::{Client, RemoteError, ServerInfo};
use super::manager::{CacheEvent, ClientLookup, Manager, MetaLookup};
use super::proxy::Proxy;
use super::redact::redact;
use super::servers::{Server, ServerStore};
use super::sync::{self, SyncReport};
use crate::db::Db;
use flaccy_shared::remote::remote_path;
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

const COVER_SIZE: u32 = 600;
const COVER_PARALLELISM: usize = 4;
const PING_INTERVAL: Duration = Duration::from_secs(60);
const REFUSED_PING_EVERY: u64 = 10;

/// Where the remote library keeps things.
#[derive(Clone, Debug)]
pub struct Paths {
    pub config_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub data_dir: PathBuf,
    pub db_path: PathBuf,
}

/// What the app is told as it happens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemoteEvent {
    Changed,
    Toast(String),
    NewVersions(Vec<String>),
    CoversReady(Vec<(String, String)>),
}

pub type RemoteListener = Arc<dyn Fn(RemoteEvent) + Send + Sync>;

/// Whether a remote song can be played right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Availability {
    Kept,
    Cached,
    Online,
    Offline,
}

/// Why a sync did not finish.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncFailure {
    Busy,
    UnknownServer,
    Message(String),
}

impl SyncFailure {
    pub fn message(&self) -> String {
        match self {
            Self::Busy => "A refresh of this server is already running.".to_string(),
            Self::UnknownServer => "That server was removed. Add it again in Preferences.".to_string(),
            Self::Message(message) => message.clone(),
        }
    }
}

/// The remote library.
pub struct Remote {
    paths: Paths,
    store: ServerStore,
    servers: RwLock<Vec<Server>>,
    clients: Arc<RwLock<HashMap<String, Client>>>,
    manager: Arc<Manager>,
    proxy: Proxy,
    listener: RwLock<Option<RemoteListener>>,
    syncing: Mutex<HashSet<String>>,
    refused: Mutex<HashSet<String>>,
}

impl Remote {
    /// Loads the saved servers, opens the cache and starts the proxy.
    pub fn start(paths: Paths, cap_bytes: u64) -> std::io::Result<Arc<Self>> {
        let store = ServerStore::new(paths.config_dir.join("servers.toml"));
        let servers = store.load();
        let clients: Arc<RwLock<HashMap<String, Client>>> = Arc::new(RwLock::new(HashMap::new()));
        refresh_clients(&clients, &servers);

        let db_path = paths.db_path.clone();
        let meta: MetaLookup = Arc::new(move |server, song| {
            Db::open(&db_path)
                .ok()
                .and_then(|db| db.remote_song_meta(server, song))
        });
        let lookup_clients = Arc::clone(&clients);
        let client_lookup: ClientLookup = Arc::new(move |server| {
            lookup_clients
                .read()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .get(server)
                .cloned()
        });
        let cache = Store::new(
            paths.cache_dir.join("remote"),
            paths.data_dir.join("remote"),
        );
        let manager = Manager::new(cache, meta, client_lookup, cap_bytes);
        let proxy = Proxy::start(Arc::clone(&manager))?;
        let remote = Arc::new(Self {
            paths,
            store,
            servers: RwLock::new(servers),
            clients,
            manager,
            proxy,
            listener: RwLock::new(None),
            syncing: Mutex::new(HashSet::new()),
            refused: Mutex::new(HashSet::new()),
        });
        remote.wire_cache_events();
        crate::logger::info(
            "remote",
            &format!(
                "remote library ready: {} servers, proxy on 127.0.0.1:{}",
                remote.servers().len(),
                remote.proxy.port()
            ),
        );
        Ok(remote)
    }

    fn wire_cache_events(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        self.manager.set_listener(Arc::new(move |event| {
            let Some(remote) = weak.upgrade() else { return };
            match event {
                CacheEvent::Changed | CacheEvent::Reachability { .. } => remote.emit(RemoteEvent::Changed),
                CacheEvent::Toast(message) => remote.emit(RemoteEvent::Toast(message)),
                CacheEvent::NewVersion { server, .. } => remote.sync_in_background(server),
            }
        }));
    }

    /// Starts the work that keeps going while the app runs: finishing
    /// interrupted downloads and checking each server is still there.
    pub fn start_background(self: &Arc<Self>) {
        self.manager.enforce_cap_now();
        self.manager.resume_pins();
        let weak = Arc::downgrade(self);
        let _ = std::thread::Builder::new()
            .name("flaccy-remote-ping".into())
            .spawn(move || {
                let mut cycle: u64 = 0;
                loop {
                    let Some(remote) = weak.upgrade() else { return };
                    remote.ping_all(cycle);
                    drop(remote);
                    cycle += 1;
                    std::thread::sleep(PING_INTERVAL);
                }
            });
    }

    pub fn set_listener(&self, listener: RemoteListener) {
        *self.listener.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(listener);
    }

    fn emit(&self, event: RemoteEvent) {
        let listener = self
            .listener
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        if let Some(listener) = listener {
            listener(event);
        }
    }

    pub fn proxy_port(&self) -> u16 {
        self.proxy.port()
    }

    pub fn manager(&self) -> &Arc<Manager> {
        &self.manager
    }

    pub fn servers(&self) -> Vec<Server> {
        self.servers
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone()
    }

    pub fn server(&self, id: &str) -> Option<Server> {
        self.servers().into_iter().find(|server| server.id == id)
    }

    /// The name to show for a server id, the id itself when it is unknown.
    pub fn server_name(&self, id: &str) -> String {
        self.server(id).map(|server| server.name).unwrap_or_else(|| id.to_string())
    }

    /// Tests a server that may not be saved yet.
    pub fn test(server: &Server) -> Result<ServerInfo, RemoteError> {
        Client::new(server)?.test()
    }

    fn persist(&self, servers: &[Server]) -> Result<(), String> {
        self.store.save(servers).map_err(|error| {
            format!(
                "Couldn’t save the server list to {}: {}. Check the folder is writable, then try again.",
                self.store.path().display(),
                redact(&error.to_string())
            )
        })
    }

    /// Saves a new server.
    pub fn add_server(&self, server: Server) -> Result<(), String> {
        let mut servers = self.servers();
        servers.push(server);
        self.persist(&servers)?;
        refresh_clients(&self.clients, &servers);
        *self.servers.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = servers;
        self.emit(RemoteEvent::Changed);
        Ok(())
    }

    /// Gives a server a new name. Its id, and so its songs, stay.
    pub fn rename_server(&self, id: &str, name: &str) -> Result<(), String> {
        let mut servers = self.servers();
        let Some(server) = servers.iter_mut().find(|server| server.id == id) else {
            return Err(SyncFailure::UnknownServer.message());
        };
        server.name = name.trim().to_string();
        self.persist(&servers)?;
        *self.servers.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = servers;
        self.emit(RemoteEvent::Changed);
        Ok(())
    }

    /// Removes a server, its songs from the library and its cached and kept
    /// files. Returns how many songs left the library.
    pub fn remove_server(&self, id: &str) -> Result<usize, String> {
        let removed = Db::open(&self.paths.db_path)
            .and_then(|db| db.remove_remote_server(id))
            .map_err(|error| {
                format!(
                    "Couldn’t remove the server’s songs from the library: {error}. Nothing was changed; close other Flaccy windows and try again."
                )
            })?;
        let mut servers = self.servers();
        servers.retain(|server| server.id != id);
        self.persist(&servers)?;
        refresh_clients(&self.clients, &servers);
        *self.servers.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = servers;
        self.manager.drop_server(id);
        crate::logger::info("remote", &format!("server {id} removed with {removed} songs"));
        self.emit(RemoteEvent::Changed);
        Ok(removed)
    }

    fn client(&self, id: &str) -> Option<Client> {
        self.clients
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(id)
            .cloned()
    }

    /// Pulls the server's catalog and applies it to the library. `on_progress`
    /// receives the number of songs read so far.
    pub fn sync(&self, id: &str, on_progress: sync::Progress<'_>) -> Result<SyncReport, SyncFailure> {
        let server = self.server(id).ok_or(SyncFailure::UnknownServer)?;
        if !self.syncing.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).insert(id.to_string()) {
            return Err(SyncFailure::Busy);
        }
        let outcome = self.sync_locked(&server, on_progress);
        self.syncing.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(id);
        outcome
    }

    fn sync_locked(&self, server: &Server, on_progress: sync::Progress<'_>) -> Result<SyncReport, SyncFailure> {
        let client = self.client(&server.id).ok_or(SyncFailure::UnknownServer)?;
        let children = sync::fetch_catalog(&client, on_progress).map_err(|error| {
            if error.is_unusable() {
                self.manager.set_reachable(&server.id, false);
            }
            SyncFailure::Message(error.message())
        })?;
        self.manager.set_reachable(&server.id, true);
        let db = Db::open(&self.paths.db_path)
            .map_err(|error| SyncFailure::Message(sync::ApplyError::Database(error.to_string()).message(&server.name)))?;
        let (_, report) = sync::apply(&db, &server.id, &children)
            .map_err(|error| SyncFailure::Message(error.message(&server.name)))?;
        self.manager.drop_songs(&server.id, &report.applied.new_versions, true);
        self.manager.drop_songs(&server.id, &report.applied.removed, false);
        crate::logger::info(
            "remote",
            &format!(
                "synced {}: {} songs, {} added, {} updated, {} new versions, {} removed",
                server.name,
                report.songs,
                report.applied.inserted,
                report.applied.updated,
                report.applied.new_versions.len(),
                report.applied.removed.len()
            ),
        );
        if !report.applied.new_versions.is_empty() {
            self.emit(RemoteEvent::NewVersions(
                report
                    .applied
                    .new_versions
                    .iter()
                    .map(|song| remote_path::encode(&server.id, song))
                    .collect(),
            ));
        }
        self.fetch_missing_covers(&client, &server.id);
        Ok(report)
    }

    /// Syncs on a worker thread and reports through the listener; used when the
    /// proxy notices a song changed under the cache.
    pub fn sync_in_background(self: &Arc<Self>, id: String) {
        let remote = Arc::clone(self);
        let _ = std::thread::Builder::new().name("flaccy-remote-sync".into()).spawn(move || {
            match remote.sync(&id, &|_| {}) {
                Ok(_) => remote.emit(RemoteEvent::Changed),
                Err(SyncFailure::Busy) => {}
                Err(failure) => remote.emit(RemoteEvent::Toast(failure.message())),
            }
        });
    }

    fn fetch_missing_covers(&self, client: &Client, server: &str) {
        let Ok(db) = Db::open(&self.paths.db_path) else { return };
        let missing = db.albums_missing_remote_covers(server);
        if missing.is_empty() {
            return;
        }
        let queue = Mutex::new(missing.into_iter());
        let saved: Mutex<Vec<(String, String)>> = Mutex::new(Vec::new());
        std::thread::scope(|scope| {
            for _ in 0..COVER_PARALLELISM {
                scope.spawn(|| {
                    let Ok(db) = Db::open(&self.paths.db_path) else { return };
                    loop {
                        let next = queue.lock().unwrap_or_else(|p| p.into_inner()).next();
                        let Some(cover) = next else { return };
                        let Ok(bytes) = client.cover_art(&cover.cover_art, COVER_SIZE) else { continue };
                        if !looks_like_image(&bytes) {
                            continue;
                        }
                        if db.save_album_cover_if_missing(&cover.album, &cover.artist, &bytes).is_ok() {
                            saved.lock().unwrap_or_else(|p| p.into_inner()).push((cover.album, cover.artist));
                        }
                    }
                });
            }
        });
        let saved = saved.into_inner().unwrap_or_default();
        if !saved.is_empty() {
            self.emit(RemoteEvent::CoversReady(saved));
        }
    }

    /// True for the library of a Flaccy Server: its plays and loves travel as synced changes, so telling the OpenSubsonic API as well would record them twice.
    fn syncs_itself(&self, id: &str) -> bool {
        self.server(id).is_some_and(|server| server.flaccy_server)
    }

    /// Asks every server whether it answers. A server that refused the credentials is asked once in `REFUSED_PING_EVERY` rounds, because a server counts wrong keys from one address and locks it out.
    fn ping_all(&self, cycle: u64) {
        for server in self.servers() {
            let Some(client) = self.client(&server.id) else { continue };
            if self.is_refused(&server.id) && cycle % REFUSED_PING_EVERY != 0 {
                continue;
            }
            let outcome = client.call("ping", &[]);
            self.note_refusal(&server.id, matches!(outcome, Err(RemoteError::WrongCredentials { .. })));
            let reachable = !outcome.is_err_and(|error| error.is_unusable());
            self.manager.set_reachable(&server.id, reachable);
        }
    }

    fn is_refused(&self, id: &str) -> bool {
        self.refused.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).contains(id)
    }

    fn note_refusal(&self, id: &str, refused: bool) {
        let mut set = self.refused.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if refused {
            set.insert(id.to_string());
        } else {
            set.remove(id);
        }
    }

    /// The URL GStreamer plays a remote song from, `None` for a local path.
    pub fn proxy_url(&self, rel_path: &str) -> Option<String> {
        let (server, song) = remote_path::decode(rel_path)?;
        Some(self.proxy.url(&server, &song))
    }

    /// How a remote song can be played right now.
    pub fn availability(&self, rel_path: &str) -> Availability {
        if self.manager.is_downloaded(rel_path) {
            return Availability::Kept;
        }
        if self.manager.is_complete(rel_path) {
            return Availability::Cached;
        }
        match remote_path::decode(rel_path) {
            Some((server, _)) if !self.manager.is_reachable(&server) => Availability::Offline,
            _ => Availability::Online,
        }
    }

    /// The sentence to show when `title` is played while its server is out of
    /// reach and the song is not on this computer; `None` when it can play.
    pub fn unplayable_message(&self, rel_path: &str, title: &str) -> Option<String> {
        if self.availability(rel_path) != Availability::Offline {
            return None;
        }
        let (server, _) = remote_path::decode(rel_path)?;
        Some(format!(
            "“{title}” isn't downloaded and {} can't be reached. Connect to the network or Tailscale and try again.",
            self.server_name(&server)
        ))
    }

    pub fn is_downloaded(&self, rel_path: &str) -> bool {
        self.manager.is_downloaded(rel_path)
    }

    pub fn is_pinned(&self, rel_path: &str) -> bool {
        self.manager.is_pinned(rel_path)
    }

    /// Keeps the songs on this computer, downloading what is missing.
    pub fn pin(&self, rel_paths: &[String]) {
        let songs = decode_all(rel_paths);
        if songs.is_empty() {
            return;
        }
        let noun = if songs.len() == 1 { "song" } else { "songs" };
        self.emit(RemoteEvent::Toast(format!(
            "Downloading {} {noun} to keep on this computer. You can keep listening meanwhile.",
            songs.len()
        )));
        self.manager.pin(songs);
    }

    /// Stops keeping the songs and frees their space.
    pub fn unpin(&self, rel_paths: &[String]) {
        self.manager.unpin(&decode_all(rel_paths));
    }

    /// Tells the cache which song plays and which is next, so it fetches ahead.
    pub fn prefetch(&self, current: Option<&str>, next: Option<&str>) {
        let decode = |path: Option<&str>| path.and_then(remote_path::decode);
        self.manager.prefetch(decode(current), decode(next));
    }

    pub fn set_cap_bytes(&self, cap_bytes: u64) {
        self.manager.set_cap_bytes(cap_bytes);
        self.manager.enforce_cap_now();
    }

    /// Tells the server a song began (`submission` false) or was listened to
    /// past the scrobble point (`submission` true), without blocking.
    pub fn scrobble(&self, rel_path: &str, submission: bool) {
        let Some((server, song)) = remote_path::decode(rel_path) else { return };
        if self.syncs_itself(&server) {
            return;
        }
        let Some(client) = self.client(&server) else { return };
        let time_ms = crate::db::now_ms();
        let _ = std::thread::Builder::new().name("flaccy-remote-scrobble".into()).spawn(move || {
            if let Err(error) = client.scrobble(&song, time_ms, submission) {
                crate::logger::warn("remote", &format!("scrobble to {} failed: {}", client.host(), redact(&error.to_string())));
            }
        });
    }

    /// Stars or unstars a song on its server, without blocking.
    pub fn set_starred(&self, rel_path: &str, starred: bool) {
        let Some((server, song)) = remote_path::decode(rel_path) else { return };
        if self.syncs_itself(&server) {
            return;
        }
        let Some(client) = self.client(&server) else { return };
        let _ = std::thread::Builder::new().name("flaccy-remote-star".into()).spawn(move || {
            if let Err(error) = client.set_starred(&song, starred) {
                crate::logger::warn("remote", &format!("star on {} failed: {}", client.host(), redact(&error.to_string())));
            }
        });
    }

    /// Bytes held by the cache and by kept downloads.
    pub fn usage(&self) -> (u64, u64) {
        use super::cache::Location;
        let held = |location| {
            self.manager
                .store()
                .scan(location)
                .iter()
                .map(|(_, sidecar)| sidecar.ranges.covered_bytes())
                .sum::<u64>()
        };
        (held(Location::Cache), held(Location::Pinned))
    }

    /// A signed client for a saved server, for tools that need the raw API.
    pub fn client_for(&self, id: &str) -> Option<Client> {
        self.client(id)
    }
}

fn decode_all(rel_paths: &[String]) -> Vec<(String, String)> {
    rel_paths
        .iter()
        .filter_map(|path| remote_path::decode(path))
        .collect()
}

fn refresh_clients(clients: &Arc<RwLock<HashMap<String, Client>>>, servers: &[Server]) {
    let mut map = clients.write().unwrap_or_else(|poisoned| poisoned.into_inner());
    map.clear();
    for server in servers {
        match Client::new(server) {
            Ok(client) => {
                map.insert(server.id.clone(), client);
            }
            Err(error) => crate::logger::warn(
                "remote",
                &format!("server {} has an unusable address: {}", server.name, error),
            ),
        }
    }
}

fn looks_like_image(bytes: &[u8]) -> bool {
    bytes.starts_with(&[0xff, 0xd8])
        || bytes.starts_with(&[0x89, b'P', b'N', b'G'])
        || (bytes.len() > 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP")
        || bytes.starts_with(b"BM")
}

#[cfg(test)]
mod tests;
