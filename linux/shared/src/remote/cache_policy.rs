//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/RemoteCachePolicy.swift`.
//!
//! Which cached remote files to delete once the cache is over its cap. Pinned
//! entries (downloads the person asked to keep) sit outside the cap entirely.
//! Among the rest the least recently used go first, ties broken by key, and
//! the items that are playing or preloaded are never picked.

use std::collections::HashSet;

pub const DEFAULT_CAP_BYTES: u64 = 2 * 1024 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    pub key: String,
    pub bytes: u64,
    /// Milliseconds since the Unix epoch.
    pub last_used_ms: i64,
    pub pinned: bool,
}

/// The keys to delete, in the order they should go, so the unpinned entries
/// that are left total no more than `cap_bytes`. Protected entries are skipped
/// even when that leaves the cache over its cap.
pub fn victims(entries: &[Entry], cap_bytes: u64, protected: &HashSet<String>) -> Vec<String> {
    let mut candidates: Vec<&Entry> = entries.iter().filter(|entry| !entry.pinned).collect();
    let mut total: u64 = candidates.iter().map(|entry| entry.bytes).sum();
    candidates.sort_by(|a, b| {
        a.last_used_ms
            .cmp(&b.last_used_ms)
            .then_with(|| a.key.cmp(&b.key))
    });
    let mut victims = Vec::new();
    for entry in candidates {
        if total <= cap_bytes {
            break;
        }
        if protected.contains(&entry.key) {
            continue;
        }
        total -= entry.bytes;
        victims.push(entry.key.clone());
    }
    victims
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(key: &str, bytes: u64, last_used_ms: i64, pinned: bool) -> Entry {
        Entry {
            key: key.to_string(),
            bytes,
            last_used_ms,
            pinned,
        }
    }

    fn none() -> HashSet<String> {
        HashSet::new()
    }

    fn protecting(keys: &[&str]) -> HashSet<String> {
        keys.iter().map(|key| key.to_string()).collect()
    }

    #[test]
    fn the_default_cap_is_two_gibibytes() {
        assert_eq!(DEFAULT_CAP_BYTES, 2_147_483_648);
    }

    #[test]
    fn nothing_is_evicted_under_the_cap() {
        let entries = [entry("a", 40, 1, false), entry("b", 60, 2, false)];
        assert!(victims(&entries, 100, &none()).is_empty());
    }

    #[test]
    fn over_the_cap_by_one_entry_evicts_the_oldest() {
        let entries = [entry("new", 60, 20, false), entry("old", 50, 10, false)];
        assert_eq!(victims(&entries, 100, &none()), vec!["old".to_string()]);
    }

    #[test]
    fn a_pinned_entry_never_triggers_eviction() {
        let entries = [entry("kept", 500, 1, true), entry("a", 60, 2, false)];
        assert!(victims(&entries, 100, &none()).is_empty());
    }

    #[test]
    fn a_protected_oldest_entry_is_skipped_and_the_next_goes() {
        let entries = [
            entry("playing", 50, 1, false),
            entry("second", 50, 2, false),
            entry("third", 50, 3, false),
        ];
        assert_eq!(
            victims(&entries, 100, &protecting(&["playing"])),
            vec!["second".to_string()]
        );
    }

    #[test]
    fn ties_in_last_use_go_by_key() {
        let entries = [entry("b", 60, 5, false), entry("a", 60, 5, false)];
        assert_eq!(victims(&entries, 100, &none()), vec!["a".to_string()]);
    }

    #[test]
    fn evicts_as_many_as_needed_in_order() {
        let entries = [
            entry("c", 40, 3, false),
            entry("a", 40, 1, false),
            entry("b", 40, 2, false),
        ];
        assert_eq!(
            victims(&entries, 50, &none()),
            vec!["a".to_string(), "b".to_string()]
        );
    }
}
