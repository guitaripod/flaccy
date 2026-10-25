//! Playlists and the saved play queue.

use std::collections::HashMap;

use flaccy_shared::remote::subsonic_response::Playlist;
use serde_json::{json, Value};

use super::model::{iso, song_value};
use super::{ok, one, Call, Fields};
use crate::catalog::Catalog;
use crate::error::ApiError;
use crate::ids::{self, Entity};
use crate::store::QueueRecord;

fn database_failure(action: &str, error: rusqlite::Error) -> ApiError {
    ApiError::generic(format!(
        "Could not {action} in the library database: {error}. Check that the server's data folder is writable and the disk is not full, then try again"
    ))
}

fn playlist_row(id: &str) -> Result<i64, ApiError> {
    match ids::parse(id) {
        Some(Entity::Playlist(row_id)) => Ok(row_id),
        _ => Err(ApiError::not_found("Playlist", id)),
    }
}

fn song_paths(call: &Call<'_>, song_ids: &[&str]) -> Result<Vec<String>, ApiError> {
    let catalog = call.state.catalog();
    song_ids
        .iter()
        .map(|id| match ids::parse(id) {
            Some(Entity::Song(row_id)) => catalog
                .song(row_id)
                .map(|song| song.row.rel_path.clone())
                .ok_or_else(|| ApiError::not_found("Song", id)),
            _ => Err(ApiError::not_found("Song", id)),
        })
        .collect()
}

fn playlist_summary(
    catalog: &Catalog,
    call: &Call<'_>,
    row_id: i64,
    name: String,
    created_at: i64,
    paths: &[String],
) -> Playlist {
    let songs: Vec<_> = paths.iter().filter_map(|path| catalog.song_at_path(path)).collect();
    let duration: f64 = songs.iter().map(|song| song.row.duration).sum();
    let has_cover = call.state.db().has_playlist_cover(row_id);
    Playlist {
        id: Some(ids::playlist(row_id)),
        name: Some(name),
        song_count: Some(songs.len() as i64),
        duration: Some(duration.round() as i64),
        created: Some(iso(created_at)),
        changed: Some(iso(created_at)),
        cover_art: has_cover.then(|| ids::playlist(row_id)),
        owner: Some(call.username.clone()),
        public: Some(false),
    }
}

/// `getPlaylists`: every playlist with its song count and running time.
pub(super) fn list(call: &Call<'_>) -> Fields {
    let catalog = call.state.catalog();
    let (rows, tracks) = {
        let db = call.state.db();
        (db.fetch_playlists(), db.all_playlist_tracks())
    };
    let mut paths: HashMap<i64, Vec<String>> = HashMap::new();
    for (playlist_id, path) in tracks {
        paths.entry(playlist_id).or_default().push(path);
    }
    let listed: Vec<Value> = rows
        .into_iter()
        .map(|row| {
            let own = paths.remove(&row.id).unwrap_or_default();
            let summary = playlist_summary(&catalog, call, row.id, row.name, row.created_at, &own);
            serde_json::to_value(summary).unwrap_or_default()
        })
        .collect();
    one(
        "playlists",
        if listed.is_empty() {
            json!({})
        } else {
            json!({"playlist": listed})
        },
    )
}

fn playlist_value(call: &Call<'_>, row_id: i64) -> Result<Value, ApiError> {
    let catalog = call.state.catalog();
    let (row, tracks) = {
        let db = call.state.db();
        let row = db
            .fetch_playlists()
            .into_iter()
            .find(|row| row.id == row_id)
            .ok_or_else(|| ApiError::not_found("Playlist", &ids::playlist(row_id)))?;
        (row, db.playlist_tracks(row_id))
    };
    let paths: Vec<String> = tracks.into_iter().map(|track| track.rel_path).collect();
    let summary = playlist_summary(&catalog, call, row.id, row.name, row.created_at, &paths);
    let mut value = serde_json::to_value(summary).unwrap_or_default();
    let entries: Vec<Value> = paths
        .iter()
        .filter_map(|path| catalog.song_at_path(path))
        .map(|song| song_value(&catalog, song))
        .collect();
    if let Value::Object(object) = &mut value {
        if !entries.is_empty() {
            object.insert("entry".into(), Value::Array(entries));
        }
    }
    Ok(value)
}

/// `getPlaylist`: one playlist with its songs in order.
pub(super) fn get(call: &Call<'_>) -> Result<Fields, ApiError> {
    let row_id = playlist_row(call.require("id")?)?;
    Ok(one("playlist", playlist_value(call, row_id)?))
}

/// `createPlaylist`: a new playlist named `name` with the given `songId`s, or,
/// with `playlistId`, the songs of an existing one replaced.
pub(super) fn create(call: &Call<'_>) -> Result<Fields, ApiError> {
    let song_ids = call.params.all("songId");
    let paths = song_paths(call, &song_ids)?;
    let row_id = match call.params.get("playlistId").filter(|id| !id.is_empty()) {
        Some(id) => {
            let row_id = playlist_row(id)?;
            let db = call.state.db();
            if db.playlist_name(row_id).is_none() {
                return Err(ApiError::not_found("Playlist", id));
            }
            if let Some(name) = call.params.get("name").filter(|name| !name.trim().is_empty()) {
                db.rename_playlist(row_id, name)
                    .map_err(|error| database_failure("rename the playlist", error))?;
            }
            for track in db.playlist_tracks(row_id) {
                db.remove_playlist_track(track.row_id)
                    .map_err(|error| database_failure("clear the playlist", error))?;
            }
            db.add_tracks_to_playlist(row_id, &paths)
                .map_err(|error| database_failure("fill the playlist", error))?;
            row_id
        }
        None => {
            let name = call
                .params
                .get("name")
                .filter(|name| !name.trim().is_empty())
                .ok_or_else(|| ApiError::missing_parameter(call.method, "name"))?;
            let db = call.state.db();
            let row_id = db
                .create_playlist(name)
                .map_err(|error| database_failure("create the playlist", error))?;
            db.add_tracks_to_playlist(row_id, &paths)
                .map_err(|error| database_failure("fill the playlist", error))?;
            row_id
        }
    };
    Ok(one("playlist", playlist_value(call, row_id)?))
}

/// `updatePlaylist`: rename it, remove songs by index and add songs by id.
pub(super) fn update(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("playlistId")?;
    let row_id = playlist_row(id)?;
    let additions = song_paths(call, &call.params.all("songIdToAdd"))?;
    let removals: Vec<usize> = call
        .params
        .all("songIndexToRemove")
        .iter()
        .filter_map(|index| index.trim().parse::<usize>().ok())
        .collect();
    let db = call.state.db();
    if db.playlist_name(row_id).is_none() {
        return Err(ApiError::not_found("Playlist", id));
    }
    if let Some(name) = call.params.get("name").filter(|name| !name.trim().is_empty()) {
        db.rename_playlist(row_id, name)
            .map_err(|error| database_failure("rename the playlist", error))?;
    }
    let tracks = db.playlist_tracks(row_id);
    for index in removals {
        if let Some(track) = tracks.get(index) {
            db.remove_playlist_track(track.row_id)
                .map_err(|error| database_failure("remove a song from the playlist", error))?;
        }
    }
    if !additions.is_empty() {
        db.add_tracks_to_playlist(row_id, &additions)
            .map_err(|error| database_failure("add songs to the playlist", error))?;
    }
    Ok(ok())
}

/// `deletePlaylist`: removes the playlist and its song list.
pub(super) fn delete(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("id")?;
    let row_id = playlist_row(id)?;
    let db = call.state.db();
    if db.playlist_name(row_id).is_none() {
        return Err(ApiError::not_found("Playlist", id));
    }
    db.delete_playlist(row_id)
        .map_err(|error| database_failure("delete the playlist", error))?;
    Ok(ok())
}

/// `getPlayQueue`: the queue a client last saved, with its songs.
pub(super) fn play_queue(call: &Call<'_>) -> Fields {
    let Some(queue) = call.state.0.store.play_queue() else {
        return ok();
    };
    let catalog = call.state.catalog();
    let entries: Vec<Value> = queue
        .entries
        .iter()
        .filter_map(|id| match ids::parse(id) {
            Some(Entity::Song(row_id)) => catalog.song(row_id),
            _ => None,
        })
        .map(|song| song_value(&catalog, song))
        .collect();
    let mut value = json!({
        "position": queue.position,
        "username": call.username,
        "changed": queue.changed_at,
        "changedBy": queue.changed_by
    });
    if let (Some(current), Value::Object(object)) = (queue.current, &mut value) {
        object.insert("current".into(), json!(current));
    }
    if let Value::Object(object) = &mut value {
        if !entries.is_empty() {
            object.insert("entry".into(), Value::Array(entries));
        }
    }
    one("playQueue", value)
}

/// `savePlayQueue`: remembers the songs, which one plays and the position in
/// milliseconds; no `id` clears the queue.
pub(super) fn save_play_queue(call: &Call<'_>) -> Result<Fields, ApiError> {
    let entries: Vec<String> = call.params.all("id").iter().map(|id| id.to_string()).collect();
    for id in &entries {
        match ids::parse(id) {
            Some(Entity::Song(row_id)) if call.state.catalog().song(row_id).is_some() => {}
            _ => return Err(ApiError::not_found("Song", id)),
        }
    }
    let queue = QueueRecord {
        entries,
        current: call.params.get("current").filter(|id| !id.is_empty()).map(str::to_string),
        position: call.params.int("position").unwrap_or(0).max(0),
        changed_by: call.params.get("c").unwrap_or("").to_string(),
        changed_at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
    };
    call.state
        .0
        .store
        .save_play_queue(&queue)
        .map_err(ApiError::generic)?;
    Ok(ok())
}
