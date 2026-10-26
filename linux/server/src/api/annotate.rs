//! What a listener records: plays, stars and ratings.

use flaccy_server_core::model::SongRef;
use flaccy_server_core::song::event_id_rec;
use flaccy_server_core::wire::Mutation;
use serde_json::json;

use super::now_playing::note_now_playing;
use super::writes::{self, mutation};
use super::{ok, Call, Fields};
use crate::error::ApiError;
use crate::ids::{self, Entity};

const MAX_RATING: i64 = 5;
const MILLIS_PER_SECOND: i64 = 1000;
const REST_INSTANCE: &str = "rest";

struct Play {
    ts: i64,
    song: SongRef,
}

fn play_mutation(device: &str, counter: i64, play: &Play) -> Mutation {
    let listen = json!({
        "eventId": event_id_rec(device, REST_INSTANCE, u64::try_from(counter).unwrap_or_default()),
        "ts": play.ts,
        "ref": play.song,
        "playedS": play.song.duration_ms / MILLIS_PER_SECOND,
        "recorded": true,
    });
    mutation("listen.record", json!({ "listens": [listen] }))
}

fn started_at(times: &[&str], index: usize, now: i64) -> i64 {
    times
        .get(index)
        .and_then(|text| text.trim().parse::<i64>().ok())
        .map(|millis| millis / MILLIS_PER_SECOND)
        .filter(|seconds| *seconds >= 0)
        .unwrap_or(now)
}

/// `scrobble`: with `submission` true (the default) each song becomes one listen of the key's user, started at the
/// matching `time` in milliseconds or now; with false it is only now playing, which is handed to the live channel and
/// not kept.
pub(super) async fn scrobble(call: &Call<'_>) -> Result<Fields, ApiError> {
    let song_ids = call.params.all("id");
    if song_ids.is_empty() {
        return Err(ApiError::missing_parameter(call.method, "id"));
    }
    let songs = song_ids
        .iter()
        .map(|id| writes::song_ref(call, id))
        .collect::<Result<Vec<_>, _>>()?;
    if call.params.flag("submission") == Some(false) {
        for song in &songs {
            note_now_playing(&call.principal, song);
        }
        return Ok(ok());
    }
    let times = call.params.all("time");
    let now = chrono::Utc::now().timestamp();
    let plays: Vec<Play> = songs
        .into_iter()
        .enumerate()
        .map(|(index, song)| Play {
            ts: started_at(&times, index, now),
            song,
        })
        .collect();
    let device = call.principal.device.as_ref().map(ToString::to_string).unwrap_or_default();
    writes::apply_numbered(call, move |first| {
        plays
            .iter()
            .enumerate()
            .map(|(offset, play)| play_mutation(&device, first + offset as i64, play))
            .collect()
    })
    .await?;
    Ok(ok())
}

/// `star` and `unstar`: songs are loved or not. Albums and artists are
/// accepted and not stored; a client shows an album as starred when every song
/// of it is.
pub(super) async fn star(call: &Call<'_>, loved: bool) -> Result<Fields, ApiError> {
    let mut songs = Vec::new();
    for id in call.params.all("id") {
        match ids::parse(id) {
            Some(Entity::Song(_)) => songs.push(writes::song_ref(call, id)?),
            Some(Entity::Album(_)) | Some(Entity::Artist(_)) => {}
            _ => return Err(ApiError::not_found("Item", id)),
        }
    }
    let has_collection = !call.params.all("albumId").is_empty() || !call.params.all("artistId").is_empty();
    if call.params.all("id").is_empty() && !has_collection {
        return Err(ApiError::missing_parameter(call.method, "id"));
    }
    writes::apply(call, songs.iter().map(|song| writes::love(song, loved)).collect()).await?;
    Ok(ok())
}

/// `setRating`: 1 to 5 stores a rating on a song, 0 removes it.
pub(super) async fn set_rating(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("id")?;
    let text = call.require("rating")?;
    let rating = text
        .trim()
        .parse::<i64>()
        .ok()
        .filter(|rating| (0..=MAX_RATING).contains(rating))
        .ok_or_else(|| ApiError::bad_parameter(call.method, "rating", text, "use a whole number from 1 to 5, or 0 to remove the rating"))?;
    let song = match ids::parse(id) {
        Some(Entity::Song(_)) => writes::song_ref(call, id)?,
        Some(Entity::Album(_)) | Some(Entity::Artist(_)) => return Ok(ok()),
        _ => return Err(ApiError::not_found("Item", id)),
    };
    writes::apply(call, vec![writes::rating(&song, (rating > 0).then_some(rating))]).await?;
    Ok(ok())
}
