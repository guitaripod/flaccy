//! Parsing a wire [`Mutation`] into a typed [`Op`], with every argument check
//! that needs no stored state.

use crate::model::{
    Entity, EntityValue, Love, Place, Rating, Scalar, SessionDoc, SongRef, Visibility, MAX_ENTRIES,
};
use crate::scalar::{validate_scalar, validate_scalar_key};
use crate::song::{is_event_id, is_song_key};
use crate::stamp::Stamp;
use crate::wire::{ErrorCode, Mutation};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;

const MAX_ID_BYTES: usize = 128;
const MAX_SESSION_BYTES: usize = 64 * 1024;
const MAX_LISTENS_PER_MUTATION: usize = 500;
const BLOB_HASH_LEN: usize = 64;

/// Why a mutation did not parse.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ParseError {
    /// The operation name is unknown.
    Unsupported,
    /// The arguments were refused with this code.
    Invalid(ErrorCode),
}

impl From<ErrorCode> for ParseError {
    fn from(code: ErrorCode) -> Self {
        ParseError::Invalid(code)
    }
}

/// A new entry in `playlist.create` and `entry.insertMany`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NewEntry {
    /// The new entry's id.
    pub id: String,
    /// The song.
    #[serde(rename = "ref")]
    pub song: SongRef,
}

/// `playlist.create`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreateArgs {
    /// The new playlist's id.
    pub id: String,
    /// The display name.
    pub name: String,
    /// The entries.
    #[serde(default)]
    pub entries: Vec<NewEntry>,
}

/// `playlist.rename`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RenameArgs {
    /// The playlist to rename.
    pub id: String,
    /// The display name.
    pub name: String,
}

/// `playlist.setCover`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SetCoverArgs {
    /// The playlist to give a cover.
    pub id: String,
    /// The sha256 hash of the cover image blob.
    pub blob: String,
}

/// `playlist.clearCover`, `playlist.delete`, `playlist.restore` and `entry.remove`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdArgs {
    /// The playlist or entry the operation addresses.
    pub id: String,
}

/// `playlist.setVisibility`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct VisibilityArgs {
    /// The playlist to change.
    pub id: String,
    /// Who may see it.
    pub visibility: Visibility,
}

/// `entry.insert`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InsertArgs {
    /// The new entry's id.
    pub id: String,
    /// The playlist receiving the entry.
    pub playlist: String,
    /// The song.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// Where the entry goes.
    pub place: Place,
}

/// `entry.insertMany`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct InsertManyArgs {
    /// The playlist receiving the entries.
    pub playlist: String,
    /// The entries.
    pub entries: Vec<NewEntry>,
    /// Where the entry goes.
    pub place: Place,
}

/// `entry.move`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct MoveArgs {
    /// The entry to move.
    pub id: String,
    /// Where the entry goes.
    pub place: Place,
}

/// Every playlist and entry operation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PlaylistOp {
    /// `playlist.create`
    Create(CreateArgs),
    /// `playlist.rename`
    Rename(RenameArgs),
    /// `playlist.setCover`
    SetCover(SetCoverArgs),
    /// `playlist.clearCover`
    ClearCover(IdArgs),
    /// `playlist.delete`
    Delete(IdArgs),
    /// `playlist.restore`
    Restore(IdArgs),
    /// `playlist.setVisibility`
    SetVisibility(VisibilityArgs),
    /// `entry.insert`
    Insert(InsertArgs),
    /// `entry.insertMany`
    InsertMany(InsertManyArgs),
    /// `entry.move`
    Move(MoveArgs),
    /// `entry.remove`
    Remove(IdArgs),
}

/// `love.set`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LoveSet {
    /// The song's identity key.
    pub song_key: String,
    /// The song.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// Whether the song is loved.
    pub loved: bool,
}

impl LoveSet {
    /// The love this write produces at `stamp`.
    pub fn entity(&self, stamp: Stamp) -> Love {
        Love {
            song_key: self.song_key.clone(),
            song: self.song.clone(),
            loved: self.loved,
            stamp,
        }
    }
}

/// `rating.set`
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RatingSet {
    /// The song's identity key.
    pub song_key: String,
    /// The song.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// One to five stars, or none to clear.
    pub rating: Option<u8>,
}

impl RatingSet {
    /// The rating this write produces at `stamp`.
    pub fn entity(&self, stamp: Stamp) -> Rating {
        Rating {
            song_key: self.song_key.clone(),
            song: self.song.clone(),
            rating: self.rating,
            stamp,
        }
    }
}

/// `scalar.set` and `scalar.clear`
#[derive(Clone, Debug, PartialEq)]
pub enum ScalarOp {
    /// `scalar.set`
    Set {
        /// The scalar key.
        key: String,
        /// The value to store.
        value: Value,
    },
    /// `scalar.clear`
    Clear {
        /// The scalar key.
        key: String,
    },
}

impl ScalarOp {
    /// The key written.
    pub fn key(&self) -> &str {
        match self {
            ScalarOp::Set { key, .. } | ScalarOp::Clear { key } => key,
        }
    }

    /// The scalar this write produces at `stamp`.
    pub fn entity(&self, stamp: Stamp) -> Scalar {
        match self {
            ScalarOp::Set { key, value } => Scalar {
                key: key.clone(),
                value: value.clone(),
                deleted: false,
                stamp,
            },
            ScalarOp::Clear { key } => Scalar {
                key: key.clone(),
                value: Value::Null,
                deleted: true,
                stamp,
            },
        }
    }
}

/// One listen of `listen.record`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListenInput {
    /// The 24 hex character listen id.
    pub event_id: String,
    /// Unix seconds the play started.
    pub ts: i64,
    /// The song played.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// Seconds actually played.
    pub played_s: i64,
    /// True when the player recorded the play itself rather than importing it.
    pub recorded: bool,
}

/// A parsed mutation.
#[derive(Clone, Debug, PartialEq)]
pub enum Op {
    /// A playlist.
    Playlist(PlaylistOp),
    /// `love.set`
    Love(LoveSet),
    /// `rating.set`
    Rating(RatingSet),
    /// `scalar.set` and `scalar.clear`
    Scalar(ScalarOp),
    /// `session.save`
    Session(Value),
    /// `listen.record`
    Listen(Vec<ListenInput>),
    /// `device.rename`
    DeviceRename(String),
    /// `state.reseed`
    Reseed(Vec<EntityValue>),
}

/// What an operation reads and writes, so the caller can load it first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Target<'a> {
    /// A playlist, by id.
    Playlist(&'a str),
    /// An entry, by id.
    Entry(&'a str),
    /// A love, by song key.
    Love(&'a str),
    /// A rating, by song key.
    Rating(&'a str),
    /// A scalar, by key.
    Scalar(&'a str),
    /// The caller device's session.
    Session,
    /// The listens of `listen.record`.
    Listens,
    /// The caller's device record.
    Device,
    /// Entities across the store.
    Reseed,
}

impl PlaylistOp {
    /// The playlist, or for `entry.move` and `entry.remove` the entry, the operation addresses.
    pub fn target(&self) -> Target<'_> {
        match self {
            PlaylistOp::Create(a) => Target::Playlist(&a.id),
            PlaylistOp::Rename(a) => Target::Playlist(&a.id),
            PlaylistOp::SetCover(a) => Target::Playlist(&a.id),
            PlaylistOp::ClearCover(a) | PlaylistOp::Delete(a) | PlaylistOp::Restore(a) => {
                Target::Playlist(&a.id)
            }
            PlaylistOp::SetVisibility(a) => Target::Playlist(&a.id),
            PlaylistOp::Insert(a) => Target::Playlist(&a.playlist),
            PlaylistOp::InsertMany(a) => Target::Playlist(&a.playlist),
            PlaylistOp::Move(a) => Target::Entry(&a.id),
            PlaylistOp::Remove(a) => Target::Entry(&a.id),
        }
    }
}

impl Op {
    /// What the operation addresses.
    pub fn target(&self) -> Target<'_> {
        match self {
            Op::Playlist(op) => op.target(),
            Op::Love(a) => Target::Love(&a.song_key),
            Op::Rating(a) => Target::Rating(&a.song_key),
            Op::Scalar(op) => Target::Scalar(op.key()),
            Op::Session(_) => Target::Session,
            Op::Listen(_) => Target::Listens,
            Op::DeviceRename(_) => Target::Device,
            Op::Reseed(_) => Target::Reseed,
        }
    }
}

/// A session document as the caller's device writes it.
pub fn session_entity(device: &str, session: &Value, stamp: Stamp) -> SessionDoc {
    SessionDoc {
        device: device.to_owned(),
        session: session.clone(),
        stamp,
    }
}

fn decode<T: serde::de::DeserializeOwned>(args: &Value) -> Result<T, ParseError> {
    T::deserialize(args).map_err(|_| ParseError::Invalid(ErrorCode::BadArgs))
}

fn check(condition: bool, code: ErrorCode) -> Result<(), ParseError> {
    condition.then_some(()).ok_or(ParseError::Invalid(code))
}

fn valid_id(id: &str) -> Result<(), ParseError> {
    check(
        !id.is_empty() && id.len() <= MAX_ID_BYTES,
        ErrorCode::BadArgs,
    )
}

fn valid_new_entries(entries: &[NewEntry]) -> Result<(), ParseError> {
    check(entries.len() <= MAX_ENTRIES, ErrorCode::TooLarge)?;
    let mut seen = HashSet::new();
    for entry in entries {
        valid_id(&entry.id)?;
        check(seen.insert(entry.id.as_str()), ErrorCode::BadArgs)?;
    }
    Ok(())
}

fn valid_song_key(key: &str) -> Result<(), ParseError> {
    check(is_song_key(key), ErrorCode::BadKey)
}

fn playlist_op<T: serde::de::DeserializeOwned>(
    args: &Value,
    wrap: fn(T) -> PlaylistOp,
    validate: fn(&T) -> Result<(), ParseError>,
) -> Result<Op, ParseError> {
    let parsed: T = decode(args)?;
    validate(&parsed)?;
    Ok(Op::Playlist(wrap(parsed)))
}

fn valid_create(args: &CreateArgs) -> Result<(), ParseError> {
    valid_id(&args.id)?;
    valid_new_entries(&args.entries)
}

fn valid_cover(args: &SetCoverArgs) -> Result<(), ParseError> {
    valid_id(&args.id)?;
    let is_hash =
        args.blob.len() == BLOB_HASH_LEN && args.blob.bytes().all(|b| b.is_ascii_hexdigit());
    check(is_hash, ErrorCode::BadArgs)
}

fn valid_insert(args: &InsertArgs) -> Result<(), ParseError> {
    valid_id(&args.id)?;
    valid_id(&args.playlist)
}

fn valid_insert_many(args: &InsertManyArgs) -> Result<(), ParseError> {
    valid_id(&args.playlist)?;
    valid_new_entries(&args.entries)
}

fn parse_playlist(name: &str, args: &Value) -> Result<Op, ParseError> {
    match name {
        "playlist.create" => playlist_op(args, PlaylistOp::Create, valid_create),
        "playlist.rename" => playlist_op(args, PlaylistOp::Rename, |a| valid_id(&a.id)),
        "playlist.setCover" => playlist_op(args, PlaylistOp::SetCover, valid_cover),
        "playlist.clearCover" => playlist_op(args, PlaylistOp::ClearCover, |a| valid_id(&a.id)),
        "playlist.delete" => playlist_op(args, PlaylistOp::Delete, |a| valid_id(&a.id)),
        "playlist.restore" => playlist_op(args, PlaylistOp::Restore, |a| valid_id(&a.id)),
        "playlist.setVisibility" => {
            playlist_op(args, PlaylistOp::SetVisibility, |a| valid_id(&a.id))
        }
        "entry.insert" => playlist_op(args, PlaylistOp::Insert, valid_insert),
        "entry.insertMany" => playlist_op(args, PlaylistOp::InsertMany, valid_insert_many),
        "entry.move" => playlist_op(args, PlaylistOp::Move, |a| valid_id(&a.id)),
        "entry.remove" => playlist_op(args, PlaylistOp::Remove, |a| valid_id(&a.id)),
        _ => Err(ParseError::Unsupported),
    }
}

fn parse_love(args: &Value) -> Result<Op, ParseError> {
    let parsed: LoveSet = decode(args)?;
    valid_song_key(&parsed.song_key)?;
    check(parsed.song.song_key == parsed.song_key, ErrorCode::BadArgs)?;
    Ok(Op::Love(parsed))
}

fn parse_rating(args: &Value) -> Result<Op, ParseError> {
    let parsed: RatingSet = decode(args)?;
    valid_song_key(&parsed.song_key)?;
    check(parsed.song.song_key == parsed.song_key, ErrorCode::BadArgs)?;
    let in_range = parsed.rating.is_none_or(|stars| (1..=5).contains(&stars));
    check(in_range, ErrorCode::BadArgs)?;
    Ok(Op::Rating(parsed))
}

#[derive(Deserialize)]
struct KeyArgs {
    key: String,
}

#[derive(Deserialize)]
struct ScalarSetArgs {
    key: String,
    value: Value,
}

fn parse_scalar(name: &str, args: &Value) -> Result<Op, ParseError> {
    if name == "scalar.set" {
        let parsed: ScalarSetArgs = decode(args)?;
        validate_scalar(&parsed.key, &parsed.value)?;
        return Ok(Op::Scalar(ScalarOp::Set {
            key: parsed.key,
            value: parsed.value,
        }));
    }
    let parsed: KeyArgs = decode(args)?;
    validate_scalar_key(&parsed.key)?;
    Ok(Op::Scalar(ScalarOp::Clear { key: parsed.key }))
}

fn parse_session(args: &Value) -> Result<Op, ParseError> {
    #[derive(Deserialize)]
    struct SessionArgs {
        session: Value,
    }
    let parsed: SessionArgs = decode(args)?;
    check(parsed.session.is_object(), ErrorCode::BadArgs)?;
    check(
        parsed.session.to_string().len() <= MAX_SESSION_BYTES,
        ErrorCode::TooLarge,
    )?;
    Ok(Op::Session(parsed.session))
}

fn parse_listen(args: &Value) -> Result<Op, ParseError> {
    #[derive(Deserialize)]
    struct ListenArgs {
        listens: Vec<ListenInput>,
    }
    let parsed: ListenArgs = decode(args)?;
    check(
        parsed.listens.len() <= MAX_LISTENS_PER_MUTATION,
        ErrorCode::TooLarge,
    )?;
    for listen in &parsed.listens {
        check(
            is_event_id(&listen.event_id) && listen.ts >= 0 && listen.played_s >= 0,
            ErrorCode::BadArgs,
        )?;
    }
    Ok(Op::Listen(parsed.listens))
}

fn parse_device(args: &Value) -> Result<Op, ParseError> {
    #[derive(Deserialize)]
    struct DeviceArgs {
        name: String,
    }
    let parsed: DeviceArgs = decode(args)?;
    check(!parsed.name.is_empty(), ErrorCode::BadArgs)?;
    Ok(Op::DeviceRename(parsed.name))
}

fn parse_reseed(args: &Value) -> Result<Op, ParseError> {
    #[derive(Deserialize)]
    struct ReseedArgs {
        entities: Vec<Entity>,
    }
    let parsed: ReseedArgs = decode(args)?;
    let decoded: Result<Vec<EntityValue>, ErrorCode> =
        parsed.entities.iter().map(Entity::decode).collect();
    Ok(Op::Reseed(decoded?))
}

/// Parses a mutation: unknown names are [`ParseError::Unsupported`], bad arguments carry their code.
pub fn parse(mutation: &Mutation) -> Result<Op, ParseError> {
    let args = &mutation.args;
    match mutation.name.as_str() {
        "love.set" => parse_love(args),
        "rating.set" => parse_rating(args),
        "scalar.set" | "scalar.clear" => parse_scalar(&mutation.name, args),
        "session.save" => parse_session(args),
        "listen.record" => parse_listen(args),
        "device.rename" => parse_device(args),
        "state.reseed" => parse_reseed(args),
        other => parse_playlist(other, args),
    }
}
