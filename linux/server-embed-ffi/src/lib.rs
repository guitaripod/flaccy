#![forbid(unsafe_code)]
#![deny(missing_docs)]
//! UniFFI binding of `flaccy_server::embed` for the sandboxed Mac app.
//!
//! Every export takes and answers JSON text and fails with [`EmbedFfiError`], so Swift sees `throws` and no
//! failure reaches the caller as a panic. One server runs per process; starting and stopping are idempotent.

use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

use flaccy_server::embed::{EmbedConfig, EmbeddedServer, Handle};
use serde_json::{json, Value};

uniffi::setup_scaffolding!();

/// The failure of an embedded-server call: the sentence to show the person.
#[derive(Debug, uniffi::Error)]
pub enum EmbedFfiError {
    /// What failed, why, and what to do next.
    Message(String),
}

impl std::fmt::Display for EmbedFfiError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let Self::Message(message) = self;
        formatter.write_str(message)
    }
}

impl std::error::Error for EmbedFfiError {}

#[derive(Default)]
struct Slot {
    handle: Option<Arc<Handle>>,
    last_error: Option<String>,
}

static SERVER: Mutex<Slot> = Mutex::new(Slot { handle: None, last_error: None });

fn slot() -> MutexGuard<'static, Slot> {
    SERVER.lock().unwrap_or_else(PoisonError::into_inner)
}

fn failure(error: impl std::fmt::Display) -> EmbedFfiError {
    EmbedFfiError::Message(error.to_string())
}

fn current_handle() -> Option<Arc<Handle>> {
    slot().handle.clone()
}

fn stopped_status(last_error: Option<String>) -> String {
    let state = if last_error.is_some() { "error" } else { "stopped" };
    json!({
        "state": state, "addresses": [], "urls": [], "deviceCount": null, "songCount": null,
        "lastError": last_error, "version": flaccy_server::VERSION,
    })
    .to_string()
}

fn status_of(handle: Option<Arc<Handle>>, last_error: Option<String>) -> String {
    match handle {
        Some(handle) => handle.status_json(),
        None => stopped_status(last_error),
    }
}

fn replace_finished(slot: &mut Slot) {
    let finished = slot.handle.as_ref().is_some_and(|handle| !handle.is_active());
    if finished {
        slot.handle = None;
    }
}

/// Starts the server from `{"musicFolder", "dataDir", "logDir", "name", "port", "ffmpeg"}` and answers the status
/// JSON without waiting for the listener. Starting while a server runs or is starting answers its status.
#[uniffi::export]
pub fn embed_start(config_json: String) -> Result<String, EmbedFfiError> {
    let config: EmbedConfig = serde_json::from_str(&config_json).map_err(|error| {
        failure(format!("The server settings are not valid: {error}. This is a bug in the app; update Flaccy."))
    })?;
    let mut guard = slot();
    replace_finished(&mut guard);
    if let Some(handle) = guard.handle.clone() {
        drop(guard);
        return Ok(handle.status_json());
    }
    match EmbeddedServer::start(config) {
        Ok(handle) => {
            guard.last_error = None;
            let handle = Arc::new(handle);
            guard.handle = Some(Arc::clone(&handle));
            drop(guard);
            Ok(handle.status_json())
        }
        Err(error) => {
            guard.last_error = Some(error.to_string());
            Err(failure(error))
        }
    }
}

/// Stops the server, waiting up to ten seconds for open requests. Stopping a server that is not running does nothing.
#[uniffi::export]
pub fn embed_stop() -> Result<(), EmbedFfiError> {
    let handle = {
        let mut guard = slot();
        guard.last_error = None;
        guard.handle.take()
    };
    match handle {
        Some(handle) => handle.stop().map_err(failure),
        None => Ok(()),
    }
}

/// The status JSON: `state` (starting, running, stopped or error), `addresses`, `urls`, `deviceCount`,
/// `songCount`, `lastError` and `version`.
#[uniffi::export]
pub fn embed_status() -> Result<String, EmbedFfiError> {
    let (handle, last_error) = {
        let guard = slot();
        (guard.handle.clone(), guard.last_error.clone())
    };
    Ok(status_of(handle, last_error))
}

/// Makes a ten-minute enrollment for `user` (the owner when empty) and answers `{link, code, url, user, expiresAt}`.
#[uniffi::export]
pub fn embed_enroll(user: String) -> Result<String, EmbedFfiError> {
    let handle = current_handle().ok_or_else(|| failure(flaccy_server::embed::EmbedError::NotRunning))?;
    let enrollment = handle.create_enrollment(Some(user.as_str())).map_err(failure)?;
    let value: Value = serde_json::to_value(enrollment).map_err(failure)?;
    Ok(value.to_string())
}

/// The version of the embedded server.
#[uniffi::export]
pub fn embed_version() -> String {
    flaccy_server::VERSION.to_owned()
}
