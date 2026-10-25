//! The byte cache in motion: which songs are open, what is fetched from the
//! server when, which songs are kept for good and which go when space runs out.
//!
//! A song is one [`Entry`]. Reads ask [`Manager::fill`] for a range and get it
//! from the file, with the missing parts fetched first from the server's
//! untranscoded stream. The validator the server sent with a song's first bytes
//! rides along as `If-Range`; a full answer to it means the song changed on the
//! server, so what was cached is dropped and the new bytes are kept instead.

use super::cache::{Location, Sidecar, Store};
use super::client::{Client, RemoteError, Streamed};
use super::redact::redact;
use crate::db::RemoteSongMeta;
use flaccy_shared::remote::remote_path;
use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::ops::Range;
use std::os::unix::fs::FileExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant};

/// How much one request asks for while a song is playing.
pub const FETCH_BLOCK: u64 = 1 << 20;
/// How much one request asks for when nothing is waiting on it.
pub const BACKGROUND_BLOCK: u64 = 4 << 20;
/// How much of the next queued song is fetched ahead of its turn.
pub const PREFETCH_HEAD: u64 = 4 << 20;
const COPY_CHUNK: usize = 64 * 1024;
const ENFORCE_SPACING: Duration = Duration::from_secs(3);

/// Why bytes could not be had.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FetchError {
    UnknownSong,
    UnknownServer,
    Remote(RemoteError),
    Disk(String),
    BadResponse(String),
    Changed,
    Stalled,
}

impl std::fmt::Display for FetchError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnknownSong => formatter.write_str("the library has no such remote song"),
            Self::UnknownServer => formatter.write_str("the server was removed"),
            Self::Remote(error) => formatter.write_str(&error.message()),
            Self::Disk(cause) => write!(formatter, "the cache file couldn't be used: {cause}"),
            Self::BadResponse(cause) => write!(formatter, "the server's answer was unusable: {cause}"),
            Self::Changed => formatter.write_str("the song changed on the server while it was being read"),
            Self::Stalled => formatter.write_str("the server returned no new bytes"),
        }
    }
}

/// What the manager tells whoever listens.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CacheEvent {
    Changed,
    NewVersion { server: String, song: String },
    Reachability { server: String, reachable: bool },
    Toast(String),
}

pub type Listener = Arc<dyn Fn(CacheEvent) + Send + Sync>;
pub type MetaLookup = Arc<dyn Fn(&str, &str) -> Option<RemoteSongMeta> + Send + Sync>;
pub type ClientLookup = Arc<dyn Fn(&str) -> Option<Client> + Send + Sync>;

struct State {
    location: Location,
    path: PathBuf,
    file: Arc<File>,
    sidecar: Sidecar,
}

/// One song's file and what is known of it.
pub struct Entry {
    key: String,
    server: String,
    song: String,
    state: Mutex<State>,
    readers: AtomicUsize,
}

impl Entry {
    pub fn key(&self) -> &str {
        &self.key
    }

    pub fn suffix(&self) -> String {
        self.lock().sidecar.suffix.clone()
    }

    pub fn total(&self) -> u64 {
        self.lock().sidecar.total
    }

    pub fn location(&self) -> Location {
        self.lock().location
    }

    pub fn is_complete(&self) -> bool {
        self.lock().sidecar.is_complete()
    }

    pub fn covered(&self) -> Vec<Range<u64>> {
        self.lock().sidecar.ranges.ranges().to_vec()
    }

    pub fn path(&self) -> PathBuf {
        self.lock().path.clone()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Reads exactly `buffer.len()` bytes at `offset`; the range must be held.
    pub fn read_at(&self, buffer: &mut [u8], offset: u64) -> std::io::Result<()> {
        let file = Arc::clone(&self.lock().file);
        file.read_exact_at(buffer, offset)
    }

    /// Marks the entry as being read, so eviction passes it by, until the
    /// guard drops.
    pub fn reading(self: &Arc<Self>) -> ReadGuard {
        self.readers.fetch_add(1, Ordering::SeqCst);
        ReadGuard {
            entry: Arc::clone(self),
        }
    }
}

/// Keeps an entry out of eviction while a reader holds it.
pub struct ReadGuard {
    entry: Arc<Entry>,
}

impl Drop for ReadGuard {
    fn drop(&mut self) {
        self.entry.readers.fetch_sub(1, Ordering::SeqCst);
    }
}

/// The cache of every remote song, shared by the proxy, the prefetcher and the
/// download worker.
pub struct Manager {
    store: Store,
    meta: MetaLookup,
    clients: ClientLookup,
    listener: RwLock<Option<Listener>>,
    entries: Mutex<HashMap<String, Arc<Entry>>>,
    protected: Mutex<HashSet<String>>,
    generation: AtomicU64,
    complete: RwLock<HashSet<String>>,
    pinned: RwLock<HashSet<String>>,
    cap_bytes: AtomicU64,
    reachable: Mutex<HashMap<String, bool>>,
    last_enforced: Mutex<Option<Instant>>,
}

impl Manager {
    pub fn new(store: Store, meta: MetaLookup, clients: ClientLookup, cap_bytes: u64) -> Arc<Self> {
        let manager = Arc::new(Self {
            store,
            meta,
            clients,
            listener: RwLock::new(None),
            entries: Mutex::new(HashMap::new()),
            protected: Mutex::new(HashSet::new()),
            generation: AtomicU64::new(0),
            complete: RwLock::new(HashSet::new()),
            pinned: RwLock::new(HashSet::new()),
            cap_bytes: AtomicU64::new(cap_bytes),
            reachable: Mutex::new(HashMap::new()),
            last_enforced: Mutex::new(None),
        });
        manager.index_existing();
        manager
    }

    pub fn store(&self) -> &Store {
        &self.store
    }

    pub fn set_listener(&self, listener: Listener) {
        *self.listener.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(listener);
    }

    fn emit(&self, event: CacheEvent) {
        let listener = self
            .listener
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        if let Some(listener) = listener {
            listener(event);
        }
    }

    pub fn set_cap_bytes(&self, cap_bytes: u64) {
        self.cap_bytes.store(cap_bytes, Ordering::SeqCst);
    }

    /// Reads the folders once at start so the answers to "is it downloaded"
    /// need no disk access afterwards.
    fn index_existing(&self) {
        let mut complete = HashSet::new();
        let mut pinned = HashSet::new();
        for location in [Location::Cache, Location::Pinned] {
            for (_, sidecar) in self.store.scan(location) {
                if sidecar.is_complete() {
                    complete.insert(sidecar.rel_path());
                }
                if location == Location::Pinned {
                    pinned.insert(sidecar.rel_path());
                }
            }
        }
        *self.complete.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = complete;
        *self.pinned.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = pinned;
    }

    /// Whether all of the song's bytes are on this computer, cached or kept.
    pub fn is_complete(&self, rel_path: &str) -> bool {
        self.complete
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(rel_path)
    }

    /// Whether the person asked to keep the song.
    pub fn is_pinned(&self, rel_path: &str) -> bool {
        self.pinned
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .contains(rel_path)
    }

    /// Whether the song is kept and fully downloaded.
    pub fn is_downloaded(&self, rel_path: &str) -> bool {
        self.is_pinned(rel_path) && self.is_complete(rel_path)
    }

    /// The paths of every kept song.
    pub fn pinned_paths(&self) -> Vec<String> {
        self.pinned
            .read()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .iter()
            .cloned()
            .collect()
    }

    /// Whether the last request to `server` got through. A server nobody has
    /// asked yet counts as reachable.
    pub fn is_reachable(&self, server: &str) -> bool {
        self.reachable
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .get(server)
            .copied()
            .unwrap_or(true)
    }

    /// Records the outcome of a request to `server`, announcing a change.
    pub fn set_reachable(&self, server: &str, reachable: bool) {
        let changed = {
            let mut map = self.reachable.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            map.insert(server.to_string(), reachable) != Some(reachable)
        };
        if changed {
            self.emit(CacheEvent::Reachability {
                server: server.to_string(),
                reachable,
            });
        }
    }

    fn note_completeness(&self, entry: &Entry) {
        let complete = entry.is_complete();
        let changed = {
            let mut set = self.complete.write().unwrap_or_else(|poisoned| poisoned.into_inner());
            if complete {
                set.insert(entry.key.clone())
            } else {
                set.remove(&entry.key)
            }
        };
        if changed {
            self.emit(CacheEvent::Changed);
        }
    }

    /// The entry for a song, opening its file and sidecar from disk when it was
    /// cached before, or starting a fresh one in the cache folder.
    pub fn entry(&self, server: &str, song: &str) -> Result<Arc<Entry>, FetchError> {
        let key = remote_path::encode(server, song);
        let mut entries = self.entries.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if let Some(entry) = entries.get(&key) {
            return Ok(Arc::clone(entry));
        }
        let (location, path, sidecar) = match self.store.find(server, song) {
            Some(found) => found,
            None => {
                let meta = (self.meta)(server, song).ok_or(FetchError::UnknownSong)?;
                let path = self.store.file_path(Location::Cache, server, song, &meta.suffix);
                (Location::Cache, path, Sidecar::new(server, song, &meta.suffix))
            }
        };
        let file = open_file(&path)?;
        let mut sidecar = sidecar;
        if sidecar.total > 0 && file.metadata().map(|meta| meta.len()).unwrap_or(0) != sidecar.total {
            sidecar.ranges = Default::default();
            sidecar.validator = None;
            sidecar.total = 0;
        }
        let entry = Arc::new(Entry {
            key: key.clone(),
            server: server.to_string(),
            song: song.to_string(),
            state: Mutex::new(State {
                location,
                path,
                file: Arc::new(file),
                sidecar,
            }),
            readers: AtomicUsize::new(0),
        });
        entries.insert(key, Arc::clone(&entry));
        Ok(entry)
    }

    fn save(&self, entry: &Entry) {
        let state = entry.lock();
        if state.sidecar.total == 0 {
            return;
        }
        if let Err(err) = Store::write_sidecar(&state.path, &state.sidecar) {
            crate::logger::warn(
                "remote",
                &format!("cache sidecar for {} not saved: {}", entry.key, redact(&err.to_string())),
            );
        }
    }

    /// Notes that the song was just used, for least recently used eviction.
    pub fn touch(&self, entry: &Entry) {
        entry.lock().sidecar.last_used_ms = crate::db::now_ms();
        self.save(entry);
    }

    /// The song's length, asking the server for its first block when nothing is
    /// known yet.
    pub fn ensure_total(&self, entry: &Entry) -> Result<u64, FetchError> {
        let total = entry.total();
        if total > 0 {
            return Ok(total);
        }
        self.fetch(entry, 0..FETCH_BLOCK)?;
        match entry.total() {
            0 => Err(FetchError::BadResponse("the song is empty".to_string())),
            total => Ok(total),
        }
    }

    /// Makes every byte of `range` readable from the file, fetching `block`
    /// bytes at a time from the first gap onward.
    pub fn fill(&self, entry: &Entry, range: Range<u64>, block: u64) -> Result<(), FetchError> {
        loop {
            let (total, covered_before, gap) = {
                let state = entry.lock();
                let total = state.sidecar.total;
                let wanted = range.start.min(total)..range.end.min(total);
                (
                    total,
                    state.sidecar.ranges.covered_bytes(),
                    state.sidecar.ranges.missing(wanted).into_iter().next(),
                )
            };
            let Some(gap) = gap else { return Ok(()) };
            let reach = (gap.start + block.max(1)).min(total);
            let fetch_range = {
                let state = entry.lock();
                state
                    .sidecar
                    .ranges
                    .missing(gap.start..reach)
                    .into_iter()
                    .next()
                    .unwrap_or(gap)
            };
            self.fetch(entry, fetch_range)?;
            let covered_after = entry.lock().sidecar.ranges.covered_bytes();
            if covered_after <= covered_before {
                return Err(FetchError::Stalled);
            }
        }
    }

    /// One request to the server for `range`, written into the file as it
    /// arrives. A full answer to a conditional request resets the entry to the
    /// new version.
    pub fn fetch(&self, entry: &Entry, range: Range<u64>) -> Result<(), FetchError> {
        let client = (self.clients)(&entry.server).ok_or(FetchError::UnknownServer)?;
        let (validator, known_total) = {
            let state = entry.lock();
            (state.sidecar.validator.clone(), state.sidecar.total)
        };
        let asked = if known_total > 0 {
            range.start.min(known_total)..range.end.min(known_total)
        } else {
            0..range.end.max(FETCH_BLOCK)
        };
        let sent_if_range = validator.is_some() && known_total > 0;
        let streamed = match client.stream(&entry.song, Some(asked.clone()), validator.as_deref()) {
            Ok(streamed) => streamed,
            Err(RemoteError::RangeRefused { .. }) => {
                self.reset(entry, 0, None);
                self.announce_new_version(entry);
                return Err(FetchError::Changed);
            }
            Err(error) => {
                if error.is_connection_failure() {
                    self.set_reachable(&entry.server, false);
                }
                return Err(FetchError::Remote(error));
            }
        };
        self.set_reachable(&entry.server, true);
        let outcome = match streamed.status {
            206 => self.write_partial(entry, streamed, known_total),
            200 => self.write_whole(entry, streamed, sent_if_range),
            other => Err(FetchError::BadResponse(format!("HTTP status {other}"))),
        };
        self.save(entry);
        self.note_completeness(entry);
        if entry.is_complete() {
            self.enforce_cap();
        }
        outcome
    }

    fn write_partial(&self, entry: &Entry, streamed: Streamed, known_total: u64) -> Result<(), FetchError> {
        let (first, last, total) = streamed
            .content_range
            .ok_or_else(|| FetchError::BadResponse("no Content-Range on a partial answer".to_string()))?;
        if known_total > 0 && total != known_total {
            self.reset(entry, total, streamed.validator.clone());
            self.announce_new_version(entry);
            self.copy_into(entry, streamed.reader, first, last + 1 - first)?;
            return Err(FetchError::Changed);
        }
        {
            let mut state = entry.lock();
            if state.sidecar.total == 0 {
                state.sidecar.total = total;
                state.sidecar.validator = streamed.validator.clone();
                let _ = state.file.set_len(total);
            }
        }
        self.copy_into(entry, streamed.reader, first, last + 1 - first)
    }

    fn write_whole(&self, entry: &Entry, streamed: Streamed, sent_if_range: bool) -> Result<(), FetchError> {
        let length = streamed
            .content_length
            .ok_or_else(|| FetchError::BadResponse("no Content-Length on a full answer".to_string()))?;
        self.reset(entry, length, streamed.validator.clone());
        let copied = self.copy_into(entry, streamed.reader, 0, length);
        if sent_if_range {
            self.announce_new_version(entry);
            copied?;
            return Err(FetchError::Changed);
        }
        copied
    }

    fn announce_new_version(&self, entry: &Entry) {
        crate::logger::info("remote", &format!("{} changed on its server; cached bytes dropped", entry.key));
        self.emit(CacheEvent::NewVersion {
            server: entry.server.clone(),
            song: entry.song.clone(),
        });
    }

    fn reset(&self, entry: &Entry, total: u64, validator: Option<String>) {
        {
            let mut state = entry.lock();
            state.sidecar.ranges = Default::default();
            state.sidecar.total = total;
            state.sidecar.validator = validator;
            let _ = state.file.set_len(total);
        }
        self.note_completeness(entry);
    }

    fn copy_into(&self, entry: &Entry, mut reader: Box<dyn Read + Send>, start: u64, length: u64) -> Result<(), FetchError> {
        let file = Arc::clone(&entry.lock().file);
        let mut buffer = vec![0u8; COPY_CHUNK];
        let mut position = start;
        let end = start + length;
        while position < end {
            let wanted = ((end - position) as usize).min(COPY_CHUNK);
            let read = match reader.read(&mut buffer[..wanted]) {
                Ok(0) => break,
                Ok(read) => read,
                Err(error) => {
                    return Err(FetchError::Remote(RemoteError::Incomplete {
                        host: entry.server.clone(),
                        cause: redact(&error.to_string()),
                    }))
                }
            };
            file.write_all_at(&buffer[..read], position)
                .map_err(|error| FetchError::Disk(error.to_string()))?;
            entry.lock().sidecar.ranges.insert(position..position + read as u64);
            position += read as u64;
        }
        if position < end {
            return Err(FetchError::Remote(RemoteError::Incomplete {
                host: entry.server.clone(),
                cause: "the connection closed early".to_string(),
            }));
        }
        Ok(())
    }

    /// Starts fetching the rest of the playing song and the start of the next
    /// one, protecting both from eviction. A newer call retires an older one.
    pub fn prefetch(self: &Arc<Self>, current: Option<(String, String)>, next: Option<(String, String)>) {
        let generation = self.generation.fetch_add(1, Ordering::SeqCst) + 1;
        {
            let mut protected = self.protected.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            protected.clear();
            for (server, song) in current.iter().chain(next.iter()) {
                protected.insert(remote_path::encode(server, song));
            }
        }
        let manager = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("flaccy-prefetch".into())
            .spawn(move || {
                for (target, limit) in [(current, None), (next, Some(PREFETCH_HEAD))] {
                    let Some((server, song)) = target else { continue };
                    if let Err(error) = manager.prefetch_one(&server, &song, limit, generation) {
                        crate::logger::warn("remote", &format!("prefetch stopped: {error}"));
                    }
                }
                manager.enforce_cap_now();
            });
        if spawned.is_err() {
            crate::logger::warn("remote", "prefetch thread could not start");
        }
    }

    fn prefetch_one(&self, server: &str, song: &str, limit: Option<u64>, generation: u64) -> Result<(), FetchError> {
        let entry = self.entry(server, song)?;
        let _reading = entry.reading();
        let total = self.ensure_total(&entry)?;
        let end = limit.map_or(total, |limit| limit.min(total));
        let mut position = 0;
        while position < end {
            if self.generation.load(Ordering::SeqCst) != generation {
                return Ok(());
            }
            let stop = (position + BACKGROUND_BLOCK).min(end);
            self.fill(&entry, position..stop, BACKGROUND_BLOCK)?;
            position = stop;
        }
        Ok(())
    }

    /// `enforce_cap_now`, unless it ran a moment ago. Called as songs finish
    /// downloading, which can be many times a second.
    pub fn enforce_cap(&self) {
        {
            let mut last = self.last_enforced.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if last.is_some_and(|at| at.elapsed() < ENFORCE_SPACING) {
                return;
            }
            *last = Some(Instant::now());
        }
        self.enforce_cap_now();
    }

    /// Deletes least recently used cache files until the cache fits its cap,
    /// passing by the playing and next songs and any song being read.
    pub fn enforce_cap_now(&self) {
        let mut protected = self
            .protected
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .clone();
        protected.extend(
            self.entries
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .values()
                .filter(|entry| entry.readers.load(Ordering::SeqCst) > 0)
                .map(|entry| entry.key.clone()),
        );
        let victims = self.store.eviction_victims(self.cap_bytes.load(Ordering::SeqCst), &protected);
        if victims.is_empty() {
            return;
        }
        for key in &victims {
            if let Some((server, song)) = remote_path::decode(key) {
                self.forget(&server, &song, Location::Cache);
            }
        }
        crate::logger::info("remote", &format!("cache over its cap: evicted {} songs", victims.len()));
        self.emit(CacheEvent::Changed);
    }

    fn forget(&self, server: &str, song: &str, location: Location) {
        let key = remote_path::encode(server, song);
        {
            let mut entries = self.entries.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if entries.get(&key).is_some_and(|entry| entry.location() == location) {
                entries.remove(&key);
            }
        }
        self.store.remove(location, server, song);
        if location == Location::Pinned {
            self.pinned.write().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&key);
        }
        if self.store.find(server, song).is_none() {
            self.complete.write().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&key);
        }
    }

    /// Drops everything held for songs that changed or left a server. Kept songs
    /// that changed are downloaded again.
    pub fn drop_songs(self: &Arc<Self>, server: &str, songs: &[String], redownload_kept: bool) {
        let mut kept_again = Vec::new();
        for song in songs {
            let key = remote_path::encode(server, song);
            if redownload_kept && self.is_pinned(&key) {
                kept_again.push((server.to_string(), song.clone()));
            }
            self.entries.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&key);
            self.store.remove_everywhere(server, song);
            self.pinned.write().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&key);
            self.complete.write().unwrap_or_else(|poisoned| poisoned.into_inner()).remove(&key);
        }
        self.emit(CacheEvent::Changed);
        if !kept_again.is_empty() {
            self.pin(kept_again);
        }
    }

    /// Deletes a server's cached and kept files and forgets its songs.
    pub fn drop_server(&self, server: &str) {
        let prefix = format!("{}{}/", remote_path::SCHEME, super::encode_segment(server));
        self.entries
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .retain(|key, _| !key.starts_with(&prefix));
        for set in [&self.complete, &self.pinned] {
            set.write()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .retain(|key| !key.starts_with(&prefix));
        }
        self.store.remove_server(server);
        self.emit(CacheEvent::Changed);
    }

    /// Keeps the songs on this computer: moves what is cached into the kept
    /// folder and downloads the rest, on a worker thread.
    pub fn pin(self: &Arc<Self>, songs: Vec<(String, String)>) {
        if songs.is_empty() {
            return;
        }
        let manager = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("flaccy-download".into())
            .spawn(move || manager.pin_all(songs));
        if spawned.is_err() {
            crate::logger::warn("remote", "download thread could not start");
        }
    }

    fn pin_all(&self, songs: Vec<(String, String)>) {
        let total = songs.len();
        let mut done = 0;
        let mut first_failure: Option<String> = None;
        for (server, song) in songs {
            match self.pin_one(&server, &song) {
                Ok(()) => done += 1,
                Err(error) => {
                    crate::logger::warn(
                        "remote",
                        &format!("download of {} failed: {}", remote_path::encode(&server, &song), redact(&error.to_string())),
                    );
                    if first_failure.is_none() {
                        let title = (self.meta)(&server, &song)
                            .map(|meta| meta.title)
                            .unwrap_or_else(|| "a song".to_string());
                        first_failure = Some(format!(
                            "Couldn’t download “{title}” — {error} Check the connection and choose Download again."
                        ));
                    }
                }
            }
        }
        if let Some(message) = first_failure {
            self.emit(CacheEvent::Toast(message));
        } else if total > 0 {
            let noun = if done == 1 { "song" } else { "songs" };
            self.emit(CacheEvent::Toast(format!(
                "Downloaded {done} {noun}. They stay on this computer until you remove the download."
            )));
        }
        self.emit(CacheEvent::Changed);
    }

    fn pin_one(&self, server: &str, song: &str) -> Result<(), FetchError> {
        let entry = self.entry(server, song)?;
        self.move_to_pinned(&entry)?;
        self.pinned
            .write()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .insert(entry.key.clone());
        self.emit(CacheEvent::Changed);
        let _reading = entry.reading();
        let mut attempts = 0;
        loop {
            let total = self.ensure_total(&entry)?;
            match self.fill(&entry, 0..total, BACKGROUND_BLOCK) {
                Err(FetchError::Changed) if attempts < 2 => attempts += 1,
                other => return other,
            }
        }
    }

    fn move_to_pinned(&self, entry: &Entry) -> Result<(), FetchError> {
        let mut state = entry.lock();
        if state.location == Location::Pinned {
            return Ok(());
        }
        let target = self
            .store
            .file_path(Location::Pinned, &entry.server, &entry.song, &state.sidecar.suffix);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent).map_err(|error| FetchError::Disk(error.to_string()))?;
        }
        move_file(&state.path, &target).map_err(|error| FetchError::Disk(error.to_string()))?;
        let old_sidecar = Store::sidecar_path(&state.path);
        let _ = std::fs::remove_file(old_sidecar);
        state.file = Arc::new(open_file(&target)?);
        state.path = target;
        state.location = Location::Pinned;
        if state.sidecar.total > 0 {
            let _ = Store::write_sidecar(&state.path, &state.sidecar);
        }
        Ok(())
    }

    /// Stops keeping the songs: their kept files are deleted and they are
    /// fetched again, into the cache, when next played.
    pub fn unpin(&self, songs: &[(String, String)]) {
        for (server, song) in songs {
            self.forget(server, song, Location::Pinned);
        }
        self.emit(CacheEvent::Changed);
    }

    /// Carries on with kept songs whose download was cut short.
    pub fn resume_pins(self: &Arc<Self>) {
        let unfinished: Vec<(String, String)> = self
            .store
            .scan(Location::Pinned)
            .into_iter()
            .filter(|(_, sidecar)| !sidecar.is_complete())
            .map(|(_, sidecar)| (sidecar.server, sidecar.song))
            .collect();
        self.pin(unfinished);
    }
}

fn open_file(path: &Path) -> Result<File, FetchError> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| FetchError::Disk(error.to_string()))?;
    }
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(path)
        .map_err(|error| FetchError::Disk(error.to_string()))
}

fn move_file(from: &Path, to: &Path) -> std::io::Result<()> {
    if std::fs::rename(from, to).is_ok() {
        return Ok(());
    }
    std::fs::copy(from, to)?;
    std::fs::remove_file(from)
}
