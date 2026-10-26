//! The synced entities of `docs/server/PROTOCOL.md` section 4.

use crate::position::is_valid as is_valid_pos;
use crate::scalar::validate_scalar;
use crate::song::is_song_key;
use crate::stamp::Stamp;
use crate::wire::ErrorCode;
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The most alive entries one playlist holds.
pub const MAX_ENTRIES: usize = 20_000;
/// The most entries one playlist keeps in all, dead ones included, since removed entries stay as tombstones.
pub const MAX_TOTAL_ENTRIES: usize = 40_000;

/// A song as a client names it; `song_key` is the identity.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SongRef {
    /// The song's identity key.
    pub song_key: String,
    /// The song title.
    pub title: String,
    /// The artist credit.
    pub artist: String,
    /// The album title.
    #[serde(default)]
    pub album: String,
    /// The duration in milliseconds.
    #[serde(default)]
    pub duration_ms: i64,
    /// An audio fingerprint, when known.
    pub fp: Option<String>,
    /// The MusicBrainz id, when known.
    pub mbid: Option<String>,
    /// The normalized album key, when known.
    pub album_key: Option<String>,
    /// The path relative to the library root, when known.
    pub rel_path: Option<String>,
}

/// Who may see a playlist.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Visibility {
    /// Visible to the owner only.
    Private,
    /// Visible to every user of the server.
    Household,
}

/// Where a listen came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// Recorded by a Flaccy player.
    Flaccy,
    /// Pulled from Last.fm.
    Lastfm,
    /// Reported by an OpenSubsonic client.
    Opensubsonic,
    /// Imported from an older history.
    Migrated,
}

/// Where an inserted or moved entry goes.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Place {
    /// Before every entry.
    First,
    /// After every entry.
    Last,
    /// Right after the anchor entry.
    After {
        /// The anchor entry's id.
        id: String,
    },
    /// Right before the anchor entry.
    Before {
        /// The anchor entry's id.
        id: String,
    },
}

/// The per-field stamps of a playlist.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistStamps {
    /// Stamp of `name`.
    pub name: Stamp,
    /// Stamp of the cover.
    pub cover: Stamp,
    /// Stamp of `visibility`.
    pub visibility: Stamp,
    /// Stamp of `alive`.
    pub alive: Stamp,
}

impl PlaylistStamps {
    /// Every field stamped at once, as at creation.
    pub fn all(stamp: Stamp) -> Self {
        PlaylistStamps {
            name: stamp,
            cover: stamp,
            visibility: stamp,
            alive: stamp,
        }
    }
}

/// A playlist without its entries.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Playlist {
    /// The playlist id.
    pub id: String,
    /// The id of the owning user.
    pub owner: String,
    /// The playlist name.
    pub name: String,
    /// The cover image's blob hash.
    pub cover_blob: Option<String>,
    /// Who may see it.
    pub visibility: Visibility,
    /// False once deleted.
    pub alive: bool,
    /// Unix seconds the playlist was created.
    pub created_at: i64,
    /// The per-field stamps.
    pub stamps: PlaylistStamps,
}

/// The per-field stamps of a playlist entry.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EntryStamps {
    /// Stamp of the song reference.
    #[serde(rename = "ref")]
    pub song: Stamp,
    /// Stamp of `pos`.
    pub pos: Stamp,
    /// Stamp of `alive`.
    pub alive: Stamp,
}

impl EntryStamps {
    /// Every field stamped at once, as at insertion.
    pub fn all(stamp: Stamp) -> Self {
        EntryStamps {
            song: stamp,
            pos: stamp,
            alive: stamp,
        }
    }
}

/// One song in a playlist, ordered by `(pos, id)`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Entry {
    /// The entry id.
    pub id: String,
    /// The id of the playlist holding the entry.
    pub playlist: String,
    /// The song.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// The position key ordering the entry.
    pub pos: String,
    /// False once deleted or removed.
    pub alive: bool,
    /// The per-field stamps.
    pub stamps: EntryStamps,
}

impl Entry {
    /// A new alive entry with every field stamped at `stamp`.
    pub fn new(id: &str, playlist: &str, song: SongRef, pos: String, stamp: Stamp) -> Self {
        Entry {
            id: id.to_owned(),
            playlist: playlist.to_owned(),
            song,
            pos,
            alive: true,
            stamps: EntryStamps::all(stamp),
        }
    }
}

/// A user's love of a song.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Love {
    /// The song's identity key.
    pub song_key: String,
    /// The song.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// Whether the song is loved.
    pub loved: bool,
    /// The stamp of the last write.
    pub stamp: Stamp,
}

/// A user's rating of a song, 1 to 5 or cleared.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Rating {
    /// The song's identity key.
    pub song_key: String,
    /// The song.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// One to five stars, or none.
    pub rating: Option<u8>,
    /// The stamp of the last write.
    pub stamp: Stamp,
}

/// A keyed preference or small document.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Scalar {
    /// The scalar key.
    pub key: String,
    /// The stored value.
    pub value: Value,
    /// True when the entity is dead.
    pub deleted: bool,
    /// The stamp of the last write.
    pub stamp: Stamp,
}

/// One device's saved player session.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SessionDoc {
    /// The device the session belongs to.
    pub device: String,
    /// The player session document.
    pub session: Value,
    /// The stamp of the last save.
    pub stamp: Stamp,
}

/// One play, kept forever; `suppressed` is the ledger's verdict.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Listen {
    /// The 24 hex character listen id.
    pub event_id: String,
    /// Unix seconds the play started.
    pub ts: i64,
    /// The song played.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// Seconds actually played.
    pub played_s: i64,
    /// Where the play came from.
    pub source: Source,
    /// True when the player recorded the play itself rather than importing it.
    pub recorded: bool,
    /// The device that recorded the play, if any.
    pub device: Option<String>,
    /// True when the ledger suppressed this play.
    pub suppressed: bool,
}

/// A playlist with all of its entries, dead ones included.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PlaylistDoc {
    /// The id of the playlist.
    pub playlist: Playlist,
    /// The entries.
    pub entries: Vec<Entry>,
}

impl PlaylistDoc {
    /// A playlist with no entries yet.
    pub fn new(playlist: Playlist) -> Self {
        PlaylistDoc {
            playlist,
            entries: Vec::new(),
        }
    }

    /// Every entry, dead included, in `(pos, id)` order.
    pub fn ordered(&self) -> Vec<&Entry> {
        let mut order: Vec<&Entry> = self.entries.iter().collect();
        order.sort_by(|a, b| a.pos.cmp(&b.pos).then_with(|| a.id.cmp(&b.id)));
        order
    }

    /// The alive entries in `(pos, id)` order: what a person sees.
    pub fn visible(&self) -> Vec<&Entry> {
        let mut order = self.ordered();
        order.retain(|entry| entry.alive);
        order
    }

    /// The entry with this id, alive or not.
    pub fn entry(&self, id: &str) -> Option<&Entry> {
        self.entries.iter().find(|entry| entry.id == id)
    }

    /// The entries either side of `place` in the full order, leaving `skip` out of it.
    ///
    /// One pass over the entries, nothing sorted or allocated: the cost of an insert grows with the playlist, not with its logarithm times its length.
    pub fn neighbours(
        &self,
        place: &Place,
        skip: Option<&str>,
    ) -> Result<(Option<&Entry>, Option<&Entry>), ErrorCode> {
        let candidates = || self.entries.iter().filter(|entry| Some(entry.id.as_str()) != skip);
        let anchor = |id: &str| {
            candidates()
                .find(|entry| entry.id == id)
                .ok_or(ErrorCode::UnknownAnchor)
        };
        match place {
            Place::First => Ok((None, candidates().min_by(|a, b| order_of(a).cmp(&order_of(b))))),
            Place::Last => Ok((candidates().max_by(|a, b| order_of(a).cmp(&order_of(b))), None)),
            Place::After { id } => {
                let before = anchor(id)?;
                let after = candidates()
                    .filter(|entry| order_of(entry) > order_of(before))
                    .min_by(|a, b| order_of(a).cmp(&order_of(b)));
                Ok((Some(before), after))
            }
            Place::Before { id } => {
                let after = anchor(id)?;
                let before = candidates()
                    .filter(|entry| order_of(entry) < order_of(after))
                    .max_by(|a, b| order_of(a).cmp(&order_of(b)));
                Ok((before, Some(after)))
            }
        }
    }
}

fn order_of(entry: &Entry) -> (&str, &str) {
    (entry.pos.as_str(), entry.id.as_str())
}

/// The kinds of synced entity.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityKind {
    /// A playlist.
    Playlist,
    /// A playlist entry.
    PlaylistEntry,
    /// A love.
    Love,
    /// A rating.
    Rating,
    /// A scalar.
    Scalar,
    /// A session.
    Session,
    /// A listen.
    Listen,
}

/// An entity as it travels: kind, id and its JSON value.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Entity {
    /// The kind of entity.
    pub kind: EntityKind,
    /// The entity's id.
    pub id: String,
    /// The entity's JSON value.
    pub value: Value,
}

/// A decoded, validated state entity (every kind except listens).
#[derive(Clone, Debug, PartialEq)]
pub enum EntityValue {
    /// A playlist.
    Playlist(Playlist),
    /// A playlist entry.
    Entry(Entry),
    /// A love.
    Love(Love),
    /// A rating.
    Rating(Rating),
    /// A scalar.
    Scalar(Scalar),
    /// A session.
    Session(SessionDoc),
}

fn parse<T: serde::de::DeserializeOwned>(value: &Value) -> Result<T, ErrorCode> {
    T::deserialize(value).map_err(|_| ErrorCode::BadArgs)
}

fn require(condition: bool, code: ErrorCode) -> Result<(), ErrorCode> {
    condition.then_some(()).ok_or(code)
}

impl Entity {
    /// Decodes and validates the value; listens are not state and are refused.
    pub fn decode(&self) -> Result<EntityValue, ErrorCode> {
        let decoded = match self.kind {
            EntityKind::Playlist => EntityValue::Playlist(parse(&self.value)?),
            EntityKind::PlaylistEntry => EntityValue::Entry(parse(&self.value)?),
            EntityKind::Love => EntityValue::Love(parse(&self.value)?),
            EntityKind::Rating => EntityValue::Rating(parse(&self.value)?),
            EntityKind::Scalar => EntityValue::Scalar(parse(&self.value)?),
            EntityKind::Session => EntityValue::Session(parse(&self.value)?),
            EntityKind::Listen => return Err(ErrorCode::BadArgs),
        };
        require(decoded.id() == self.id, ErrorCode::BadArgs)?;
        decoded.validate()?;
        Ok(decoded)
    }
}

impl EntityValue {
    /// The entity's kind.
    pub fn kind(&self) -> EntityKind {
        match self {
            EntityValue::Playlist(_) => EntityKind::Playlist,
            EntityValue::Entry(_) => EntityKind::PlaylistEntry,
            EntityValue::Love(_) => EntityKind::Love,
            EntityValue::Rating(_) => EntityKind::Rating,
            EntityValue::Scalar(_) => EntityKind::Scalar,
            EntityValue::Session(_) => EntityKind::Session,
        }
    }

    /// The entity's id: playlist or entry id, song key, scalar key or device id.
    pub fn id(&self) -> &str {
        match self {
            EntityValue::Playlist(p) => &p.id,
            EntityValue::Entry(e) => &e.id,
            EntityValue::Love(l) => &l.song_key,
            EntityValue::Rating(r) => &r.song_key,
            EntityValue::Scalar(s) => &s.key,
            EntityValue::Session(s) => &s.device,
        }
    }

    /// True when the entity is dead (`alive` false, unloved, unrated, deleted).
    pub fn is_dead(&self) -> bool {
        match self {
            EntityValue::Playlist(p) => !p.alive,
            EntityValue::Entry(e) => !e.alive,
            EntityValue::Love(l) => !l.loved,
            EntityValue::Rating(r) => r.rating.is_none(),
            EntityValue::Scalar(s) => s.deleted,
            EntityValue::Session(_) => false,
        }
    }

    /// The wire form of the entity.
    pub fn to_entity(&self) -> Entity {
        let value = match self {
            EntityValue::Playlist(p) => serde_json::to_value(p),
            EntityValue::Entry(e) => serde_json::to_value(e),
            EntityValue::Love(l) => serde_json::to_value(l),
            EntityValue::Rating(r) => serde_json::to_value(r),
            EntityValue::Scalar(s) => serde_json::to_value(s),
            EntityValue::Session(s) => serde_json::to_value(s),
        };
        Entity {
            kind: self.kind(),
            id: self.id().to_owned(),
            value: value.unwrap_or(Value::Null),
        }
    }

    /// Lowers every stamp the entity carries to `ceiling`, so a write cannot claim a time the server has not reached.
    pub fn clamp_stamps(&mut self, ceiling: Stamp) {
        match self {
            EntityValue::Playlist(p) => {
                let stamps = &mut p.stamps;
                for stamp in [&mut stamps.name, &mut stamps.cover, &mut stamps.visibility, &mut stamps.alive] {
                    *stamp = (*stamp).min(ceiling);
                }
            }
            EntityValue::Entry(e) => {
                let stamps = &mut e.stamps;
                for stamp in [&mut stamps.song, &mut stamps.pos, &mut stamps.alive] {
                    *stamp = (*stamp).min(ceiling);
                }
            }
            EntityValue::Love(l) => l.stamp = l.stamp.min(ceiling),
            EntityValue::Rating(r) => r.stamp = r.stamp.min(ceiling),
            EntityValue::Scalar(s) => s.stamp = s.stamp.min(ceiling),
            EntityValue::Session(s) => s.stamp = s.stamp.min(ceiling),
        }
    }

    fn validate(&self) -> Result<(), ErrorCode> {
        match self {
            EntityValue::Playlist(p) => require(!p.id.is_empty(), ErrorCode::BadArgs),
            EntityValue::Entry(e) => require(
                !e.id.is_empty() && !e.playlist.is_empty() && is_valid_pos(&e.pos),
                ErrorCode::BadArgs,
            ),
            EntityValue::Love(l) => require(is_song_key(&l.song_key), ErrorCode::BadKey),
            EntityValue::Rating(r) => {
                require(is_song_key(&r.song_key), ErrorCode::BadKey)?;
                require(
                    r.rating.is_none_or(|stars| (1..=5).contains(&stars)),
                    ErrorCode::BadArgs,
                )
            }
            EntityValue::Scalar(s) if s.deleted => crate::scalar::validate_scalar_key(&s.key),
            EntityValue::Scalar(s) => validate_scalar(&s.key, &s.value),
            EntityValue::Session(s) => require(
                !s.device.is_empty() && s.session.is_object(),
                ErrorCode::BadArgs,
            ),
        }
    }
}
