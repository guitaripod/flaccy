//! Playlists: the user's own and the household's, kept in the sync state.

use std::collections::HashMap;

use flaccy_server_core::model::{Entry, PlaylistDoc, SongRef, Visibility};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::Mutation;
use flaccy_shared::remote::subsonic_response::Playlist;
use serde_json::{json, Value};

use super::model::{iso, iso_ms, song_value};
use super::writes::{self, mutation};
use super::{ok, one, Call, Fields};
use crate::catalog::{Catalog, Song};
use crate::error::ApiError;
use crate::ids::{self, Entity};

fn storage_failure(action: &str, error: impl std::fmt::Display) -> ApiError {
    ApiError::generic(format!(
        "Could not {action}: {error} Check that the server's data folder is readable and the disk is not full, then try again"
    ))
}

fn sync_id(id: &str) -> Result<String, ApiError> {
    match ids::parse(id) {
        Some(Entity::Playlist(sync_id)) => Ok(sync_id),
        _ => Err(ApiError::not_found("Playlist", id)),
    }
}

async fn visible_playlist(call: &Call<'_>, id: &str) -> Result<PlaylistDoc, ApiError> {
    let sync_id = sync_id(id)?;
    call.state
        .0
        .sync
        .playlist_for(&call.principal.user, &sync_id)
        .await
        .map_err(|error| storage_failure("read the playlist", error))?
        .ok_or_else(|| ApiError::not_found("Playlist", id))
}

async fn owner_names(call: &Call<'_>) -> Result<HashMap<String, String>, ApiError> {
    let users = call
        .state
        .0
        .security
        .list_users()
        .await
        .map_err(|error| storage_failure("look up the playlists' owners", error))?;
    Ok(users.into_iter().map(|user| (user.id.to_string(), user.name)).collect())
}

fn listed<'a>(catalog: &'a Catalog, doc: &'a PlaylistDoc) -> Vec<(&'a Entry, &'a Song)> {
    doc.visible()
        .into_iter()
        .filter_map(|entry| catalog.resolve(&entry.song).map(|song| (entry, song)))
        .collect()
}

fn changed_ms(doc: &PlaylistDoc) -> i64 {
    let stamps = &doc.playlist.stamps;
    let own = [stamps.name, stamps.cover, stamps.visibility, stamps.alive];
    let entries = doc.entries.iter().flat_map(|entry| [entry.stamps.song, entry.stamps.pos, entry.stamps.alive]);
    own.into_iter().chain(entries).map(Stamp::wall_ms).max().unwrap_or_default()
}

fn summary(catalog: &Catalog, doc: &PlaylistDoc, owners: &HashMap<String, String>) -> Playlist {
    let songs = listed(catalog, doc);
    let duration: f64 = songs.iter().map(|(_, song)| song.row.duration).sum();
    let playlist = &doc.playlist;
    Playlist {
        id: Some(ids::playlist(&playlist.id)),
        name: Some(playlist.name.clone()),
        song_count: Some(songs.len() as i64),
        duration: Some(duration.round() as i64),
        created: Some(iso(playlist.created_at)),
        changed: Some(iso_ms(changed_ms(doc))),
        cover_art: playlist.cover_blob.as_ref().map(|_| ids::playlist(&playlist.id)),
        owner: Some(owners.get(&playlist.owner).cloned().unwrap_or_default()),
        public: Some(playlist.visibility == Visibility::Household),
    }
}

fn playlist_value(call: &Call<'_>, doc: &PlaylistDoc, owners: &HashMap<String, String>) -> Value {
    let catalog = call.state.catalog();
    let mut value = serde_json::to_value(summary(&catalog, doc, owners)).unwrap_or_default();
    let entries: Vec<Value> = listed(&catalog, doc)
        .into_iter()
        .map(|(_, song)| song_value(&catalog, &call.view, song))
        .collect();
    if let (Value::Object(object), false) = (&mut value, entries.is_empty()) {
        object.insert("entry".into(), Value::Array(entries));
    }
    value
}

/// `getPlaylists`: every playlist the user may see with its song count and running time.
pub(super) async fn list(call: &Call<'_>) -> Result<Fields, ApiError> {
    let docs = call
        .state
        .0
        .sync
        .playlists_for(&call.principal.user)
        .await
        .map_err(|error| storage_failure("read the playlists", error))?;
    let owners = owner_names(call).await?;
    let catalog = call.state.catalog();
    let summaries: Vec<Value> = docs
        .iter()
        .map(|doc| serde_json::to_value(summary(&catalog, doc, &owners)).unwrap_or_default())
        .collect();
    Ok(one(
        "playlists",
        if summaries.is_empty() {
            json!({})
        } else {
            json!({"playlist": summaries})
        },
    ))
}

/// `getPlaylist`: one playlist with its songs in order.
pub(super) async fn get(call: &Call<'_>) -> Result<Fields, ApiError> {
    let doc = visible_playlist(call, call.require("id")?).await?;
    let owners = owner_names(call).await?;
    Ok(one("playlist", playlist_value(call, &doc, &owners)))
}

fn new_ids(call: &Call<'_>, count: usize) -> Result<Vec<String>, ApiError> {
    let now_ms = call.state.0.sync.now_ms();
    (0..count)
        .map(|_| ids::uuid_v7(now_ms).map_err(|error| storage_failure("make an id", error)))
        .collect()
}

fn new_entries(call: &Call<'_>, song_ids: &[&str]) -> Result<Vec<(String, SongRef)>, ApiError> {
    let songs = song_ids
        .iter()
        .map(|id| writes::song_ref(call, id))
        .collect::<Result<Vec<_>, _>>()?;
    Ok(new_ids(call, songs.len())?.into_iter().zip(songs).collect())
}

fn visibility_change(call: &Call<'_>, id: &str) -> Option<Mutation> {
    let public = call.params.flag("public")?;
    let visibility = if public { Visibility::Household } else { Visibility::Private };
    Some(mutation("playlist.setVisibility", json!({ "id": id, "visibility": visibility })))
}

fn rename_change(call: &Call<'_>, id: &str) -> Option<Mutation> {
    let name = call.params.get("name").filter(|name| !name.trim().is_empty())?;
    Some(mutation("playlist.rename", json!({ "id": id, "name": name })))
}

fn removals(call: &Call<'_>, doc: &PlaylistDoc) -> Vec<Mutation> {
    let mut indexes: Vec<usize> = call
        .params
        .all("songIndexToRemove")
        .iter()
        .filter_map(|index| index.trim().parse::<usize>().ok())
        .collect();
    indexes.sort_unstable_by(|a, b| b.cmp(a));
    indexes.dedup();
    let catalog = call.state.catalog();
    let shown = listed(&catalog, doc);
    indexes
        .into_iter()
        .filter_map(|index| shown.get(index))
        .map(|(entry, _)| mutation("entry.remove", json!({ "id": entry.id })))
        .collect()
}

/// `createPlaylist`: a new playlist named `name` with the given `songId`s, or,
/// with `playlistId`, the songs of an existing one replaced.
pub(super) async fn create(call: &Call<'_>) -> Result<Fields, ApiError> {
    let entries = new_entries(call, &call.params.all("songId"))?;
    let mut mutations = Vec::new();
    let id = match call.params.get("playlistId").filter(|id| !id.is_empty()) {
        Some(existing) => {
            let doc = visible_playlist(call, existing).await?;
            mutations.extend(rename_change(call, &doc.playlist.id));
            mutations.extend(doc.visible().iter().map(|entry| mutation("entry.remove", json!({ "id": entry.id }))));
            if !entries.is_empty() {
                mutations.push(writes::append(&doc.playlist.id, &entries));
            }
            doc.playlist.id
        }
        None => {
            let name = call
                .params
                .get("name")
                .filter(|name| !name.trim().is_empty())
                .ok_or_else(|| ApiError::missing_parameter(call.method, "name"))?;
            let id = new_ids(call, 1)?.remove(0);
            mutations.push(mutation(
                "playlist.create",
                json!({ "id": id, "name": name, "entries": writes::entry_values(&entries) }),
            ));
            id
        }
    };
    mutations.extend(visibility_change(call, &id));
    writes::apply(call, mutations).await?;
    get_by_sync_id(call, &id).await
}

async fn get_by_sync_id(call: &Call<'_>, id: &str) -> Result<Fields, ApiError> {
    let doc = visible_playlist(call, &ids::playlist(id)).await?;
    let owners = owner_names(call).await?;
    Ok(one("playlist", playlist_value(call, &doc, &owners)))
}

/// `updatePlaylist`: rename it, change who sees it, remove songs by their position in what the client was shown and
/// add songs by id at the end.
pub(super) async fn update(call: &Call<'_>) -> Result<Fields, ApiError> {
    let doc = visible_playlist(call, call.require("playlistId")?).await?;
    let id = doc.playlist.id.clone();
    let additions = new_entries(call, &call.params.all("songIdToAdd"))?;
    let mut mutations = Vec::new();
    mutations.extend(rename_change(call, &id));
    mutations.extend(visibility_change(call, &id));
    mutations.extend(removals(call, &doc));
    if !additions.is_empty() {
        mutations.push(writes::append(&id, &additions));
    }
    writes::apply(call, mutations).await?;
    Ok(ok())
}

/// `deletePlaylist`: removes the playlist and its song list.
pub(super) async fn delete(call: &Call<'_>) -> Result<Fields, ApiError> {
    let doc = visible_playlist(call, call.require("id")?).await?;
    writes::apply(call, vec![mutation("playlist.delete", json!({ "id": doc.playlist.id }))]).await?;
    Ok(ok())
}
