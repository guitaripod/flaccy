//! String in, string out: every function takes one JSON document and answers
//! one JSON document, so a UniFFI binding is a thin wrapper. A failure is
//! `{"error": "<message>"}`.

use crate::apply::{self, Caller, Outcome};
use crate::ledger::{self, SecondEvent};
use crate::model::{Entity, Love, PlaylistDoc, Rating, Scalar, SessionDoc};
use crate::mutation::{chunk_reseed, parse, Op};
use crate::position;
use crate::rebase::{self, PendingMutation};
use crate::song;
use crate::stamp::{ClientClock, Stamp};
use crate::wire::Mutation;
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};

fn run<I: DeserializeOwned>(
    input: &str,
    handle: impl FnOnce(I) -> Result<Value, String>,
) -> String {
    let answer = serde_json::from_str::<I>(input)
        .map_err(|error| error.to_string())
        .and_then(handle);
    match answer {
        Ok(value) => value.to_string(),
        Err(message) => json!({ "error": message }).to_string(),
    }
}

fn to_value<T: serde::Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

fn outcome_json(outcome: &Outcome, entity_key: &str, entity: Value) -> Value {
    let (status, code) = outcome.status.wire();
    json!({
        "status": status,
        "code": code,
        entity_key: entity,
        "changed": outcome.changed,
    })
}

fn parse_op(mutation: &Mutation) -> Result<Op, String> {
    parse(mutation).map_err(|error| format!("{error:?}"))
}

#[derive(Deserialize)]
struct ApplyPlaylistInput {
    doc: Option<PlaylistDoc>,
    mutation: Mutation,
    caller: Caller,
    stamp: Option<Stamp>,
}

/// Applies a playlist or entry mutation. Input `{doc, mutation, caller, stamp?}`, output `{status, code, doc, changed}`.
pub fn apply_playlist(input: &str) -> String {
    run(input, |mut input: ApplyPlaylistInput| {
        let Op::Playlist(op) = parse_op(&input.mutation)? else {
            return Err("not a playlist mutation".to_owned());
        };
        let stamp = input.stamp.unwrap_or(input.mutation.stamp);
        let outcome = apply::apply_playlist(&mut input.doc, &op, &input.caller, stamp);
        Ok(outcome_json(&outcome, "doc", to_value(&input.doc)))
    })
}

#[derive(Deserialize)]
struct ApplyScalarInput {
    scalar: Option<Scalar>,
    mutation: Mutation,
    caller: Caller,
    stamp: Option<Stamp>,
}

/// Applies a scalar mutation. Input `{scalar, mutation, caller, stamp?}`, output `{status, code, scalar, changed}`.
pub fn apply_scalar(input: &str) -> String {
    run(input, |mut input: ApplyScalarInput| {
        let Op::Scalar(op) = parse_op(&input.mutation)? else {
            return Err("not a scalar mutation".to_owned());
        };
        let stamp = input.stamp.unwrap_or(input.mutation.stamp);
        let outcome = apply::apply_scalar(&mut input.scalar, &op, &input.caller, stamp);
        Ok(outcome_json(&outcome, "scalar", to_value(&input.scalar)))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RebaseInput {
    playlist_id: String,
    base: Option<PlaylistDoc>,
    caller: Caller,
    pending: Vec<PendingMutation>,
}

/// Folds pending mutations onto a base playlist. Input `{playlistId, base, caller, pending}`, output `{doc}`.
pub fn rebase_playlist(input: &str) -> String {
    run(input, |input: RebaseInput| {
        let doc = rebase::fold_playlist(
            &input.playlist_id,
            input.base.as_ref(),
            &input.caller,
            &input.pending,
        );
        Ok(json!({ "doc": doc }))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RebaseLoveInput {
    song_key: String,
    base: Option<Love>,
    caller: Caller,
    pending: Vec<PendingMutation>,
}

/// Folds pending mutations onto a base love. Input `{songKey, base, caller, pending}`, output `{love}`.
pub fn rebase_love(input: &str) -> String {
    run(input, |input: RebaseLoveInput| {
        let love = rebase::fold_love(
            &input.song_key,
            input.base.as_ref(),
            &input.caller,
            &input.pending,
        );
        Ok(json!({ "love": love }))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RebaseRatingInput {
    song_key: String,
    base: Option<Rating>,
    caller: Caller,
    pending: Vec<PendingMutation>,
}

/// Folds pending mutations onto a base rating. Input `{songKey, base, caller, pending}`, output `{rating}`.
pub fn rebase_rating(input: &str) -> String {
    run(input, |input: RebaseRatingInput| {
        let rating = rebase::fold_rating(
            &input.song_key,
            input.base.as_ref(),
            &input.caller,
            &input.pending,
        );
        Ok(json!({ "rating": rating }))
    })
}

#[derive(Deserialize)]
struct RebaseScalarInput {
    key: String,
    base: Option<Scalar>,
    caller: Caller,
    pending: Vec<PendingMutation>,
}

/// Folds pending mutations onto a base scalar. Input `{key, base, caller, pending}`, output `{scalar}`.
pub fn rebase_scalar(input: &str) -> String {
    run(input, |input: RebaseScalarInput| {
        let scalar = rebase::fold_scalar(
            &input.key,
            input.base.as_ref(),
            &input.caller,
            &input.pending,
        );
        Ok(json!({ "scalar": scalar }))
    })
}

#[derive(Deserialize)]
struct RebaseSessionInput {
    device: String,
    base: Option<SessionDoc>,
    caller: Caller,
    pending: Vec<PendingMutation>,
}

/// Folds pending mutations onto a base session. Input `{device, base, caller, pending}`, output `{session}`.
pub fn rebase_session(input: &str) -> String {
    run(input, |input: RebaseSessionInput| {
        let session = rebase::fold_session(
            &input.device,
            input.base.as_ref(),
            &input.caller,
            &input.pending,
        );
        Ok(json!({ "session": session }))
    })
}

#[derive(Deserialize)]
struct BetweenInput {
    a: Option<String>,
    b: Option<String>,
}

/// A position key between two others. Input `{a, b}` (either may be null), output `{pos}`.
pub fn between(input: &str) -> String {
    run(input, |input: BetweenInput| {
        let pos = position::between(input.a.as_deref(), input.b.as_deref());
        Ok(json!({ "pos": pos }))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SongKeyInput {
    artist_key: String,
    title_key: String,
}

/// The song key of two normalized keys. Input `{artistKey, titleKey}`, output `{songKey}`.
pub fn song_key(input: &str) -> String {
    run(input, |input: SongKeyInput| {
        let key = song::song_key(&input.artist_key, &input.title_key);
        Ok(json!({ "songKey": key }))
    })
}

#[derive(Deserialize)]
struct SuppressedInput {
    events: Vec<SecondEvent>,
}

/// The ledger verdict for the events of one second. Input `{events}`, output `{flags}` in input order.
pub fn suppressed_flags(input: &str) -> String {
    run(input, |input: SuppressedInput| {
        Ok(json!({ "flags": ledger::suppressed_flags(&input.events) }))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct NextStampInput {
    last: Stamp,
    offset_ms: i64,
    now_ms: i64,
}

/// The next client stamp. Input `{last, offsetMs, nowMs}`, output `{stamp}`.
pub fn next_stamp(input: &str) -> String {
    run(input, |input: NextStampInput| {
        let stamp = ClientClock::new(input.last, input.offset_ms).next(input.now_ms);
        Ok(json!({ "stamp": stamp }))
    })
}

#[derive(Deserialize)]
struct SongKeysInput {
    pairs: Vec<SongKeyInput>,
}

/// The song keys of many pairs of normalized keys. Input `{pairs: [{artistKey, titleKey}]}`, output `{songKeys}` in input order.
pub fn song_keys(input: &str) -> String {
    run(input, |input: SongKeysInput| {
        let keys: Vec<String> = input
            .pairs
            .iter()
            .map(|pair| song::song_key(&pair.artist_key, &pair.title_key))
            .collect();
        Ok(json!({ "songKeys": keys }))
    })
}

#[derive(Deserialize)]
struct NormalizePlaylistNameInput {
    name: String,
}

/// A playlist name as the first-connect merge compares it. Input `{name}`, output `{name}`.
pub fn normalize_playlist_name(input: &str) -> String {
    run(input, |input: NormalizePlaylistNameInput| {
        Ok(json!({ "name": song::normalize_playlist_name(&input.name) }))
    })
}

#[derive(Deserialize)]
struct PlaylistIdInput {
    name: String,
    occurrence: u32,
}

/// The deterministic id of a playlist that existed before sync. Input `{name, occurrence}`, output `{playlistId}`.
pub fn playlist_id(input: &str) -> String {
    run(input, |input: PlaylistIdInput| {
        Ok(json!({ "playlistId": song::playlist_id(&input.name, input.occurrence) }))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EntryIdInput {
    playlist_id: String,
    song_key: String,
    occurrence: u32,
}

/// The deterministic id of an entry that existed before sync. Input `{playlistId, songKey, occurrence}`, output `{entryId}`.
pub fn entry_id(input: &str) -> String {
    run(input, |input: EntryIdInput| {
        Ok(json!({ "entryId": song::entry_id(&input.playlist_id, &input.song_key, input.occurrence) }))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct EventIdRecInput {
    device_id: String,
    instance: String,
    counter: u64,
}

/// A client's listen id. Input `{deviceId, instance, counter}`, output `{eventId}`.
pub fn event_id_rec(input: &str) -> String {
    run(input, |input: EventIdRecInput| {
        Ok(json!({ "eventId": song::event_id_rec(&input.device_id, &input.instance, input.counter) }))
    })
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct MigratedPlay {
    ts: i64,
    title_key: String,
    artist_key: String,
}

#[derive(Deserialize)]
struct EventIdsMigInput {
    plays: Vec<MigratedPlay>,
}

/// The ids of migrated listens. Input `{plays: [{ts, titleKey, artistKey}]}`, output `{eventIds}` in input order.
pub fn event_ids_mig(input: &str) -> String {
    run(input, |input: EventIdsMigInput| {
        let ids: Vec<String> = input
            .plays
            .iter()
            .map(|play| song::event_id_mig(play.ts, &play.title_key, &play.artist_key))
            .collect();
        Ok(json!({ "eventIds": ids }))
    })
}

#[derive(Deserialize)]
struct ChunkReseedInput {
    entities: Vec<Entity>,
}

/// Splits the entities of a `state.reseed` into consecutive chunks the server accepts: at most 1,000 entities and 400 KB each, order kept. Input `{entities: [{kind, id, value}]}`, output `{chunks: [[{kind, id, value}]]}`.
pub fn chunk_reseed_entities(input: &str) -> String {
    run(input, |input: ChunkReseedInput| {
        Ok(json!({ "chunks": chunk_reseed(input.entities) }))
    })
}
