//! What a listener records: plays, stars and ratings.

use super::{ok, Call, Fields};
use crate::error::ApiError;
use crate::ids::{self, Entity};

const MAX_RATING: i64 = 5;

fn database_failure(action: &str, error: rusqlite::Error) -> ApiError {
    ApiError::generic(format!(
        "Could not {action} in the library database: {error}. Check that the server's data folder is writable and the disk is not full, then try again"
    ))
}

fn song_row(call: &Call<'_>, id: &str) -> Result<i64, ApiError> {
    match ids::parse(id) {
        Some(Entity::Song(row_id)) if call.state.catalog().song(row_id).is_some() => Ok(row_id),
        _ => Err(ApiError::not_found("Song", id)),
    }
}

/// `scrobble`: with `submission` true (the default) each song gets one more
/// play and a new last-played time; with false it is only now playing, which
/// the server does not keep.
pub(super) fn scrobble(call: &Call<'_>) -> Result<Fields, ApiError> {
    let song_ids = call.params.all("id");
    if song_ids.is_empty() {
        return Err(ApiError::missing_parameter(call.method, "id"));
    }
    let rows = song_ids
        .iter()
        .map(|id| song_row(call, id))
        .collect::<Result<Vec<_>, _>>()?;
    if call.params.flag("submission") == Some(false) {
        return Ok(ok());
    }
    let now = chrono::Utc::now().timestamp();
    let mut catalog = call.state.catalog_mut();
    for row_id in rows {
        let Some(rel_path) = catalog.song(row_id).map(|song| song.row.rel_path.clone()) else {
            continue;
        };
        call.state
            .db()
            .increment_play_count(&rel_path)
            .map_err(|error| database_failure("count the play", error))?;
        catalog.record_play(row_id, now);
    }
    Ok(ok())
}

/// `star` and `unstar`: songs are loved or not. Albums and artists are
/// accepted and not stored; a client shows an album as starred when every song
/// of it is.
pub(super) fn star(call: &Call<'_>, loved: bool) -> Result<Fields, ApiError> {
    let mut rows = Vec::new();
    for id in call.params.all("id") {
        match ids::parse(id) {
            Some(Entity::Song(_)) => rows.push(song_row(call, id)?),
            Some(Entity::Album(_)) | Some(Entity::Artist(_)) => {}
            _ => return Err(ApiError::not_found("Item", id)),
        }
    }
    let has_collection = !call.params.all("albumId").is_empty() || !call.params.all("artistId").is_empty();
    if call.params.all("id").is_empty() && !has_collection {
        return Err(ApiError::missing_parameter(call.method, "id"));
    }
    let mut catalog = call.state.catalog_mut();
    for row_id in rows {
        let Some(rel_path) = catalog.song(row_id).map(|song| song.row.rel_path.clone()) else {
            continue;
        };
        call.state
            .db()
            .set_loved(&rel_path, loved, None)
            .map_err(|error| database_failure("save the star", error))?;
        catalog.set_loved(row_id, loved);
    }
    Ok(ok())
}

/// `setRating`: 1 to 5 stores a rating on a song, 0 removes it.
pub(super) fn set_rating(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("id")?;
    let text = call.require("rating")?;
    let rating = text
        .trim()
        .parse::<i64>()
        .ok()
        .filter(|rating| (0..=MAX_RATING).contains(rating))
        .ok_or_else(|| ApiError::bad_parameter(call.method, "rating", text, "use a whole number from 1 to 5, or 0 to remove the rating"))?;
    let row_id = match ids::parse(id) {
        Some(Entity::Song(_)) => song_row(call, id)?,
        Some(Entity::Album(_)) | Some(Entity::Artist(_)) => return Ok(ok()),
        _ => return Err(ApiError::not_found("Item", id)),
    };
    let mut catalog = call.state.catalog_mut();
    let Some(rel_path) = catalog.song(row_id).map(|song| song.row.rel_path.clone()) else {
        return Err(ApiError::not_found("Song", id));
    };
    let stored = (rating > 0).then_some(rating);
    call.state
        .0
        .store
        .set_rating(&rel_path, stored)
        .map_err(|error| database_failure("save the rating", error))?;
    catalog.set_rating(row_id, stored);
    Ok(ok())
}
