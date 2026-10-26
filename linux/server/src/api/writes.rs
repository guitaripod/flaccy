//! Turning OpenSubsonic writes into sync mutations and applying them.

use flaccy_server_core::model::{Place, SongRef};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{ErrorCode, Mutation, MutationResult, MutationStatus};
use serde_json::{json, Value};

use super::identity::not_authorized;
use super::Call;
use crate::error::ApiError;
use crate::ids::{self, Entity};
use crate::songref::song_ref as library_song_ref;
use crate::sync::RestWriteError;

/// A mutation whose id and stamp the store assigns when it is applied.
pub(super) fn mutation(name: &str, args: Value) -> Mutation {
    Mutation {
        id: 0,
        name: name.to_owned(),
        stamp: Stamp(0),
        args,
    }
}

/// The reference for the song with API id `id`.
pub(super) fn song_ref(call: &Call<'_>, id: &str) -> Result<SongRef, ApiError> {
    let catalog = call.state.catalog();
    match ids::parse(id) {
        Some(Entity::Song(row_id)) => catalog.song(row_id).map(library_song_ref),
        _ => None,
    }
    .ok_or_else(|| ApiError::not_found("Song", id))
}

/// `love.set`
pub(super) fn love(song: &SongRef, loved: bool) -> Mutation {
    mutation("love.set", json!({ "songKey": song.song_key, "ref": song, "loved": loved }))
}

/// `rating.set`; no stars clears the rating.
pub(super) fn rating(song: &SongRef, stars: Option<i64>) -> Mutation {
    mutation("rating.set", json!({ "songKey": song.song_key, "ref": song, "rating": stars }))
}

/// `entry.insertMany` appending `entries`, each a new entry id with its song.
pub(super) fn append(playlist: &str, entries: &[(String, SongRef)]) -> Mutation {
    mutation(
        "entry.insertMany",
        json!({ "playlist": playlist, "entries": entry_values(entries), "place": Place::Last }),
    )
}

/// The `{id, ref}` objects of new entries.
pub(super) fn entry_values(entries: &[(String, SongRef)]) -> Vec<Value> {
    entries.iter().map(|(id, song)| json!({ "id": id, "ref": song })).collect()
}

fn write_failure(error: RestWriteError) -> ApiError {
    ApiError::generic(format!("Could not save the change: {error}"))
}

fn refusal(code: Option<ErrorCode>, call: &Call<'_>) -> ApiError {
    match code {
        Some(ErrorCode::UnknownPlaylist) | Some(ErrorCode::UnknownAnchor) => {
            ApiError::new(70, format!("{} named a playlist or entry the server does not have; refresh the client's playlists and try again", call.method))
        }
        Some(ErrorCode::Forbidden) => not_authorized("change this; playlists belong to their owner, and guests may not change anything"),
        Some(ErrorCode::TooLarge) => ApiError::generic(format!("{} is larger than the server accepts; send fewer songs at a time", call.method)),
        _ => ApiError::generic(format!("{} carried a value the server cannot store; check the ids and the rating", call.method)),
    }
}

fn check(call: &Call<'_>, results: &[MutationResult]) -> Result<(), ApiError> {
    for result in results {
        match result.status {
            MutationStatus::Applied | MutationStatus::Noop => {}
            MutationStatus::Invalid => return Err(refusal(result.code, call)),
            MutationStatus::Unsupported => return Err(refusal(None, call)),
        }
    }
    Ok(())
}

fn forget_view(call: &Call<'_>) {
    call.state.0.views.invalidate(call.principal.user.as_str());
}

/// Applies `mutations` as the call's API key, failing the call when any is refused.
pub(super) async fn apply(call: &Call<'_>, mutations: Vec<Mutation>) -> Result<(), ApiError> {
    let results = call.state.0.sync.apply_as(&call.principal, mutations).await.map_err(write_failure);
    forget_view(call);
    check(call, &results?)
}

/// Like [`apply`] for mutations that need the id of the first one, as a listen's event id does.
pub(super) async fn apply_numbered<F>(call: &Call<'_>, build: F) -> Result<(), ApiError>
where
    F: FnOnce(i64) -> Vec<Mutation> + Send + 'static,
{
    let results = call.state.0.sync.apply_numbered(&call.principal, build).await.map_err(write_failure);
    forget_view(call);
    check(call, &results?)
}
