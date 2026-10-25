//! Where the bytes of remote songs live on disk.
//!
//! Each song is one sparse file named `<song>.<suffix>` with a `.ranges.json`
//! sidecar that says which bytes of it are real, which validator the server
//! gave for that version and how long the whole file is. Songs the person asked
//! to keep sit in a second folder under the data directory and are never
//! evicted; everything else sits under the cache directory and goes, least
//! recently used first, once the cache is over its cap.

use super::catalog::{cache_file_name, song_from_cache_file_name};
use super::encode_segment;
use flaccy_shared::remote::byte_ranges::ByteRangeSet;
use flaccy_shared::remote::cache_policy::{self, Entry};
use flaccy_shared::remote::remote_path;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const SIDECAR_SUFFIX: &str = ".ranges.json";

/// The two places a song's file can be.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Location {
    Cache,
    Pinned,
}

/// What is known about one song's file: the bytes held, the validator of the
/// version they belong to and the length of the whole file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Sidecar {
    pub server: String,
    pub song: String,
    pub suffix: String,
    pub total: u64,
    #[serde(default)]
    pub validator: Option<String>,
    pub ranges: ByteRangeSet,
    #[serde(default)]
    pub last_used_ms: i64,
}

impl Sidecar {
    pub fn new(server: &str, song: &str, suffix: &str) -> Self {
        Self {
            server: server.to_string(),
            song: song.to_string(),
            suffix: suffix.to_string(),
            total: 0,
            validator: None,
            ranges: ByteRangeSet::new(),
            last_used_ms: 0,
        }
    }

    /// Whether every byte of the file is held.
    pub fn is_complete(&self) -> bool {
        self.total > 0 && self.ranges.is_complete(self.total)
    }

    /// The song's path as the library stores it.
    pub fn rel_path(&self) -> String {
        remote_path::encode(&self.server, &self.song)
    }
}

/// The cache and pinned folders, and the operations on the files in them.
#[derive(Clone, Debug)]
pub struct Store {
    cache_root: PathBuf,
    pinned_root: PathBuf,
}

impl Store {
    /// `cache_root` and `pinned_root` are the `remote` folders under the cache
    /// and data directories.
    pub fn new(cache_root: PathBuf, pinned_root: PathBuf) -> Self {
        Self {
            cache_root,
            pinned_root,
        }
    }

    fn root(&self, location: Location) -> &Path {
        match location {
            Location::Cache => &self.cache_root,
            Location::Pinned => &self.pinned_root,
        }
    }

    /// The folder holding one server's files in `location`.
    pub fn server_dir(&self, location: Location, server: &str) -> PathBuf {
        self.root(location).join(encode_segment(server))
    }

    /// The file a song's bytes are written to.
    pub fn file_path(&self, location: Location, server: &str, song: &str, suffix: &str) -> PathBuf {
        self.server_dir(location, server)
            .join(cache_file_name(song, suffix))
    }

    /// The sidecar that belongs to `file`.
    pub fn sidecar_path(file: &Path) -> PathBuf {
        let mut name = file.file_name().unwrap_or_default().to_os_string();
        name.push(SIDECAR_SUFFIX);
        file.with_file_name(name)
    }

    /// Reads a sidecar, `None` when it is missing or unreadable.
    pub fn read_sidecar(file: &Path) -> Option<Sidecar> {
        let text = std::fs::read_to_string(Self::sidecar_path(file)).ok()?;
        serde_json::from_str(&text).ok()
    }

    /// Writes a sidecar through a temporary file, so a crash never leaves half
    /// of one.
    pub fn write_sidecar(file: &Path, sidecar: &Sidecar) -> std::io::Result<()> {
        let path = Self::sidecar_path(file);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let staging = path.with_extension("json.tmp");
        let text = serde_json::to_string(sidecar)
            .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err.to_string()))?;
        std::fs::write(&staging, text)?;
        std::fs::rename(&staging, &path)
    }

    /// Finds the file and sidecar a song already has, pinned first.
    pub fn find(&self, server: &str, song: &str) -> Option<(Location, PathBuf, Sidecar)> {
        [Location::Pinned, Location::Cache]
            .into_iter()
            .find_map(|location| {
                let directory = self.server_dir(location, server);
                let entries = std::fs::read_dir(directory).ok()?;
                entries.flatten().find_map(|entry| {
                    let name = entry.file_name().to_string_lossy().to_string();
                    if name.ends_with(SIDECAR_SUFFIX) {
                        return None;
                    }
                    if song_from_cache_file_name(&name).as_deref() != Some(song) {
                        return None;
                    }
                    let path = entry.path();
                    Self::read_sidecar(&path).map(|sidecar| (location, path, sidecar))
                })
            })
    }

    /// Every sidecar in `location` with the file it describes.
    pub fn scan(&self, location: Location) -> Vec<(PathBuf, Sidecar)> {
        let mut found = Vec::new();
        let Ok(servers) = std::fs::read_dir(self.root(location)) else {
            return found;
        };
        for server in servers.flatten() {
            let Ok(files) = std::fs::read_dir(server.path()) else {
                continue;
            };
            for file in files.flatten() {
                let name = file.file_name().to_string_lossy().to_string();
                let Some(stem) = name.strip_suffix(SIDECAR_SUFFIX) else {
                    continue;
                };
                let path = file.path().with_file_name(stem);
                if let Some(sidecar) = Self::read_sidecar(&path) {
                    found.push((path, sidecar));
                }
            }
        }
        found
    }

    /// The cache's entries for `cache_policy`: the bytes actually held, and the
    /// last time each song was used.
    pub fn cache_entries(&self) -> Vec<Entry> {
        self.scan(Location::Cache)
            .into_iter()
            .map(|(_, sidecar)| Entry {
                key: sidecar.rel_path(),
                bytes: sidecar.ranges.covered_bytes(),
                last_used_ms: sidecar.last_used_ms,
                pinned: false,
            })
            .collect()
    }

    /// The songs to delete so the cache fits `cap_bytes`, never those in
    /// `protected`.
    pub fn eviction_victims(&self, cap_bytes: u64, protected: &HashSet<String>) -> Vec<String> {
        cache_policy::victims(&self.cache_entries(), cap_bytes, protected)
    }

    /// Deletes a song's file and sidecar from `location`.
    pub fn remove(&self, location: Location, server: &str, song: &str) {
        let Some((found, path, _)) = self.find(server, song) else {
            return;
        };
        if found != location {
            return;
        }
        let _ = std::fs::remove_file(Self::sidecar_path(&path));
        let _ = std::fs::remove_file(path);
    }

    /// Deletes everything held for a song, wherever it is.
    pub fn remove_everywhere(&self, server: &str, song: &str) {
        while let Some((_, path, _)) = self.find(server, song) {
            let _ = std::fs::remove_file(Self::sidecar_path(&path));
            let _ = std::fs::remove_file(&path);
            if path.exists() {
                break;
            }
        }
    }

    /// Deletes both folders of one server.
    pub fn remove_server(&self, server: &str) {
        for location in [Location::Cache, Location::Pinned] {
            let _ = std::fs::remove_dir_all(self.server_dir(location, server));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(name: &str) -> (Store, PathBuf) {
        let base = std::env::temp_dir().join(format!("flaccy-cache-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        (
            Store::new(base.join("cache/remote"), base.join("data/remote")),
            base,
        )
    }

    fn put(store: &Store, location: Location, song: &str, covered: u64, last_used_ms: i64) {
        let file = store.file_path(location, "s1", song, "flac");
        std::fs::create_dir_all(file.parent().unwrap()).unwrap();
        std::fs::write(&file, vec![0u8; covered as usize]).unwrap();
        let mut sidecar = Sidecar::new("s1", song, "flac");
        sidecar.total = 1000;
        sidecar.validator = Some("v1".to_string());
        sidecar.ranges.insert(0..covered);
        sidecar.last_used_ms = last_used_ms;
        Store::write_sidecar(&file, &sidecar).unwrap();
    }

    #[test]
    fn a_sidecar_round_trips_ranges_validator_and_total() {
        let (store, base) = store("roundtrip");
        let file = store.file_path(Location::Cache, "s1", "song/1", "flac");
        let mut sidecar = Sidecar::new("s1", "song/1", "flac");
        sidecar.total = 5000;
        sidecar.validator = Some("\"abc\"".to_string());
        sidecar.ranges.insert(0..100);
        sidecar.ranges.insert(200..300);
        Store::write_sidecar(&file, &sidecar).unwrap();
        let back = Store::read_sidecar(&file).unwrap();
        assert_eq!(back, sidecar);
        assert_eq!(back.ranges.ranges(), &[0..100, 200..300]);
        assert!(!back.is_complete());
        let json = std::fs::read_to_string(Store::sidecar_path(&file)).unwrap();
        assert!(json.contains("[[0,100],[200,300]]"));
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn a_full_range_marks_the_song_complete() {
        let mut sidecar = Sidecar::new("s1", "a", "flac");
        sidecar.total = 10;
        sidecar.ranges.insert(0..4);
        assert!(!sidecar.is_complete());
        sidecar.ranges.insert(4..10);
        assert!(sidecar.is_complete());
    }

    #[test]
    fn find_prefers_the_pinned_copy_and_scan_lists_each_location() {
        let (store, base) = store("find");
        put(&store, Location::Cache, "a", 400, 10);
        put(&store, Location::Pinned, "a", 1000, 20);
        put(&store, Location::Cache, "b", 100, 30);
        let (location, _, sidecar) = store.find("s1", "a").unwrap();
        assert_eq!((location, sidecar.ranges.covered_bytes()), (Location::Pinned, 1000));
        assert_eq!(store.scan(Location::Cache).len(), 2);
        assert_eq!(store.scan(Location::Pinned).len(), 1);
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn eviction_drops_the_least_recently_used_and_spares_protected_and_pinned() {
        let (store, base) = store("evict");
        put(&store, Location::Cache, "old", 500, 1);
        put(&store, Location::Cache, "mid", 500, 2);
        put(&store, Location::Cache, "playing", 500, 0);
        put(&store, Location::Pinned, "kept", 1000, 0);
        let protected: HashSet<String> = [remote_path::encode("s1", "playing")].into_iter().collect();
        let victims = store.eviction_victims(1000, &protected);
        assert_eq!(victims, vec![remote_path::encode("s1", "old")]);
        let all_gone = store.eviction_victims(0, &protected);
        assert_eq!(
            all_gone,
            vec![remote_path::encode("s1", "old"), remote_path::encode("s1", "mid")]
        );
        let _ = std::fs::remove_dir_all(base);
    }

    #[test]
    fn removing_a_song_deletes_the_file_and_the_sidecar_in_that_location_only() {
        let (store, base) = store("remove");
        put(&store, Location::Cache, "a", 100, 1);
        put(&store, Location::Pinned, "b", 100, 1);
        store.remove(Location::Pinned, "s1", "a");
        assert!(store.find("s1", "a").is_some());
        store.remove(Location::Cache, "s1", "a");
        assert!(store.find("s1", "a").is_none());
        store.remove_server("s1");
        assert!(store.scan(Location::Pinned).is_empty());
        let _ = std::fs::remove_dir_all(base);
    }
}
