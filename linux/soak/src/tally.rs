use crate::sync_util::locked;
use std::collections::BTreeMap;
use std::sync::Mutex;

/// Named counters shared by every harness thread.
#[derive(Default)]
pub struct Tally(Mutex<BTreeMap<&'static str, u64>>);

impl Tally {
    /// Adds one to `key`.
    pub fn bump(&self, key: &'static str) {
        self.add(key, 1);
    }

    /// Adds `amount` to `key`.
    pub fn add(&self, key: &'static str, amount: u64) {
        *locked(&self.0).entry(key).or_insert(0) += amount;
    }

    /// The current value of `key`.
    pub fn get(&self, key: &'static str) -> u64 {
        locked(&self.0).get(key).copied().unwrap_or(0)
    }

    /// Every counter, sorted by name.
    pub fn snapshot(&self) -> Vec<(&'static str, u64)> {
        locked(&self.0).iter().map(|(key, value)| (*key, *value)).collect()
    }
}
