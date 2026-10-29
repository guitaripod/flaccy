#![forbid(unsafe_code)]
#![deny(missing_docs)]
//! UniFFI binding of `flaccy_server_core::json_api` for the Apple clients.
//!
//! Every export takes one JSON document and answers one. A `{"error": "..."}`
//! answer from the core becomes [`ServerCoreFfiError`], so Swift sees `throws`
//! and no failure reaches the caller as a panic.

use flaccy_server_core::json_api;
use serde_json::Value;
use std::fmt;

uniffi::setup_scaffolding!();

/// The failure of a core function: the message the core reported.
#[derive(Debug, uniffi::Error)]
pub enum ServerCoreFfiError {
    /// The core answered `{"error": message}`.
    Message(String),
}

impl fmt::Display for ServerCoreFfiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let Self::Message(message) = self;
        formatter.write_str(message)
    }
}

impl std::error::Error for ServerCoreFfiError {}

fn reported_error(answer: &str) -> Option<String> {
    let value: Value = serde_json::from_str(answer).ok()?;
    value.get("error")?.as_str().map(str::to_owned)
}

fn checked(answer: String) -> Result<String, ServerCoreFfiError> {
    match reported_error(&answer) {
        Some(message) => Err(ServerCoreFfiError::Message(message)),
        None => Ok(answer),
    }
}

macro_rules! export_json_functions {
    ($($(#[$doc:meta])* $name:ident),+ $(,)?) => {
        $(
            $(#[$doc])*
            #[uniffi::export]
            pub fn $name(input: String) -> Result<String, ServerCoreFfiError> {
                checked(json_api::$name(&input))
            }
        )+
    };
}

export_json_functions!(
    /// Applies a playlist or entry mutation: `{doc, mutation, caller, stamp?}` to `{status, code, doc, changed}`.
    apply_playlist,
    /// Applies a scalar mutation: `{scalar, mutation, caller, stamp?}` to `{status, code, scalar, changed}`.
    apply_scalar,
    /// Folds pending mutations onto a base playlist: `{playlistId, base, caller, pending}` to `{doc}`.
    rebase_playlist,
    /// Folds pending mutations onto a base love: `{songKey, base, caller, pending}` to `{love}`.
    rebase_love,
    /// Folds pending mutations onto a base rating: `{songKey, base, caller, pending}` to `{rating}`.
    rebase_rating,
    /// Folds pending mutations onto a base scalar: `{key, base, caller, pending}` to `{scalar}`.
    rebase_scalar,
    /// Folds pending mutations onto a base session: `{device, base, caller, pending}` to `{session}`.
    rebase_session,
    /// A position key between two others: `{a, b}` to `{pos}`.
    between,
    /// The song key of two normalized keys: `{artistKey, titleKey}` to `{songKey}`.
    song_key,
    /// The song keys of many pairs of normalized keys: `{pairs}` to `{songKeys}`.
    song_keys,
    /// A playlist name as the first-connect merge compares it: `{name}` to `{name}`.
    normalize_playlist_name,
    /// The deterministic id of a playlist that existed before sync: `{name, occurrence}` to `{playlistId}`.
    playlist_id,
    /// The deterministic id of an entry that existed before sync: `{playlistId, songKey, occurrence}` to `{entryId}`.
    entry_id,
    /// A client's listen id: `{deviceId, instance, counter}` to `{eventId}`.
    event_id_rec,
    /// The ids of migrated listens: `{plays}` to `{eventIds}`.
    event_ids_mig,
    /// The chunks a `state.reseed` must be sent in: `{entities}` to `{chunks}`.
    chunk_reseed_entities,
    /// The ledger verdict for the events of one second: `{events}` to `{flags}`.
    suppressed_flags,
    /// The next client stamp: `{last, offsetMs, nowMs}` to `{stamp}`.
    next_stamp,
);

/// The version of this binding.
#[uniffi::export]
pub fn version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}
