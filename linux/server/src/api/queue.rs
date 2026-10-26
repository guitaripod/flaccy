//! The saved play queue, kept as the key's device session in the sync state.

use std::collections::HashMap;

use serde_json::{json, Value};

use super::model::{iso_ms, song_value};
use super::writes::{self, mutation};
use super::{ok, one, Call, Fields};
use crate::catalog::Song;
use crate::error::ApiError;
use crate::queue_session::{queue_of, session_value, QueueItem};

fn storage_failure(action: &str, error: impl std::fmt::Display) -> ApiError {
    ApiError::generic(format!(
        "Could not {action}: {error} Check that the server's data folder is readable and the disk is not full, then try again"
    ))
}

/// `savePlayQueue`: remembers the songs, which one plays and the position in
/// milliseconds as this key's session; no `id` clears the queue. A queue too long for a session is cut at its end.
pub(super) async fn save(call: &Call<'_>) -> Result<Fields, ApiError> {
    let songs = call
        .params
        .all("id")
        .iter()
        .map(|id| writes::song_ref(call, id))
        .collect::<Result<Vec<_>, _>>()?;
    let current = call
        .params
        .get("current")
        .filter(|id| !id.is_empty())
        .map(|id| writes::song_ref(call, id))
        .transpose()?
        .map(|song| song.song_key);
    let queue: Vec<QueueItem> = songs.iter().map(QueueItem::of).collect();
    let position = call.params.int("position").unwrap_or(0);
    let session = session_value(&queue, current, position, call.params.get("c").unwrap_or(""));
    writes::apply(call, vec![mutation("session.save", json!({ "session": session }))]).await?;
    Ok(ok())
}

fn changed_by(session: &flaccy_server_core::model::SessionDoc, devices: &HashMap<String, String>) -> String {
    session
        .session
        .get("changedBy")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty())
        .map(str::to_owned)
        .or_else(|| devices.get(&session.device).cloned())
        .unwrap_or_default()
}

/// `getPlayQueue`: the queue saved most recently by any of the user's devices, with its songs.
pub(super) async fn get(call: &Call<'_>) -> Result<Fields, ApiError> {
    let user = &call.principal.user;
    let sessions = call
        .state
        .0
        .sync
        .sessions_of(user)
        .await
        .map_err(|error| storage_failure("read the saved queue", error))?;
    let Some((session, queue)) = sessions.iter().find_map(|session| queue_of(session).map(|queue| (session, queue))) else {
        return Ok(ok());
    };
    let devices = call
        .state
        .0
        .security
        .list_devices(Some(user))
        .await
        .map_err(|error| storage_failure("look up the device that saved the queue", error))?;
    let names: HashMap<String, String> = devices.into_iter().map(|device| (device.id.to_string(), device.name)).collect();
    let catalog = call.state.catalog();
    let songs: Vec<&Song> = queue.iter().filter_map(|item| catalog.resolve(&item.reference())).collect();
    if songs.is_empty() {
        return Ok(ok());
    }
    let current = session
        .session
        .get("current")
        .and_then(Value::as_str)
        .and_then(|key| songs.iter().find(|song| song.song_key == key))
        .map(|song| song.id());
    let mut value = json!({
        "position": session.session.get("positionMs").and_then(Value::as_i64).unwrap_or(0),
        "username": call.username,
        "changed": iso_ms(session.stamp.wall_ms()),
        "changedBy": changed_by(session, &names),
        "entry": songs.iter().map(|song| song_value(&catalog, &call.view, song)).collect::<Vec<_>>(),
    });
    if let (Some(current), Value::Object(object)) = (current, &mut value) {
        object.insert("current".into(), json!(current));
    }
    Ok(one("playQueue", value))
}
