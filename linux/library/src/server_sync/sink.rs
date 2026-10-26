use serde_json::Value;

/// Where scalars that belong to the GUI crate go: equalizer profiles, settings, the wantlist and the like.
///
/// The engine calls it after the transaction that learned the value has
/// committed, once per scalar whose visible value was recomputed. `value` is
/// `None` when the scalar was cleared. Lyrics offsets (`lyr/<songKey>`) are
/// applied by the library itself and never reach the sink. Implementations
/// must be idempotent: the same value can arrive again.
pub trait ScalarSink: Send + Sync {
    /// Applies `value` for `key`, or resets the setting when it is `None`.
    fn apply(&self, key: &str, value: Option<&Value>);
}
