//! What a user may see of an entity, and `GET /sync/entity`.

use flaccy_server_core::model::{EntityKind, EntityValue, Entry, Playlist, SongRef, Visibility};
use flaccy_server_core::wire::Change;
use rusqlite::{Connection, OptionalExtension};

use super::changes::kind_text;
use super::rows::{load_entry, load_playlist, load_user_entity};
use super::{Store, SyncError, HOUSEHOLD_SCOPE};
use crate::security::UserId;

const REDACTED_SONG_KEY: &str = "00000000000000000000000000000000";

/// An entity as a particular user sees it.
pub(super) enum Seen {
    /// The user may read the entity as stored.
    Visible(EntityValue),
    /// The entity was shared with the household and has since become private to someone else.
    Hidden(EntityValue),
}

impl Seen {
    /// The entity to send: as stored when visible, an emptied dead tombstone when hidden.
    pub fn into_sent(self) -> EntityValue {
        match self {
            Seen::Visible(value) => value,
            Seen::Hidden(value) => redact(value),
        }
    }
}

fn redact(value: EntityValue) -> EntityValue {
    match value {
        EntityValue::Playlist(playlist) => EntityValue::Playlist(Playlist {
            name: String::new(),
            cover_blob: None,
            visibility: Visibility::Private,
            alive: false,
            ..playlist
        }),
        EntityValue::Entry(entry) => EntityValue::Entry(Entry {
            song: SongRef {
                song_key: REDACTED_SONG_KEY.to_owned(),
                ..SongRef::default()
            },
            alive: false,
            ..entry
        }),
        other => other,
    }
}

fn may_read(playlist: &Playlist, user: &str) -> bool {
    playlist.owner == user || playlist.visibility == Visibility::Household
}

/// The entity `user` finds under `(kind, id)`, `None` when there is none.
pub(super) fn see(connection: &Connection, user: &str, kind: EntityKind, id: &str) -> Result<Option<Seen>, SyncError> {
    match kind {
        EntityKind::Playlist => Ok(load_playlist(connection, id)?.map(|playlist| {
            let readable = may_read(&playlist, user);
            judge(readable, EntityValue::Playlist(playlist))
        })),
        EntityKind::PlaylistEntry => {
            let Some(entry) = load_entry(connection, id)? else {
                return Ok(None);
            };
            let Some(playlist) = load_playlist(connection, &entry.playlist)? else {
                return Ok(None);
            };
            Ok(Some(judge(may_read(&playlist, user), EntityValue::Entry(entry))))
        }
        EntityKind::Listen => Ok(None),
        per_user => Ok(load_user_entity(connection, user, per_user, id)?.map(Seen::Visible)),
    }
}

fn judge(readable: bool, value: EntityValue) -> Seen {
    if readable {
        Seen::Visible(value)
    } else {
        Seen::Hidden(value)
    }
}

/// The wire change of an entity at `seq`.
pub(super) fn change_of(seq: i64, value: EntityValue) -> Change {
    let deleted = value.is_dead();
    let entity = value.to_entity();
    Change {
        seq,
        kind: entity.kind,
        id: entity.id,
        deleted,
        value: entity.value,
    }
}

fn latest_seq(connection: &Connection, user: &str, kind: EntityKind, id: &str) -> Result<i64, SyncError> {
    let seq: Option<i64> = connection
        .prepare_cached("SELECT MAX(seq) FROM changes WHERE scope IN (?1, ?2) AND kind = ?3 AND id = ?4")?
        .query_row((user, HOUSEHOLD_SCOPE, kind_text(kind), id), |row| row.get(0))
        .optional()?
        .flatten();
    Ok(seq.unwrap_or(0))
}

impl Store {
    /// One entity as `user` may see it, with the sequence number of its last change; `None` when it does not exist or is private to someone else.
    ///
    /// Listens are not state entities and are read with [`Store::listens_before`] and [`Store::listens_after`].
    pub async fn entity(&self, user: &UserId, kind: EntityKind, id: &str) -> Result<Option<Change>, SyncError> {
        let user = user.to_string();
        let id = id.to_owned();
        self.read(move |connection| {
            let Some(Seen::Visible(value)) = see(connection, &user, kind, &id)? else {
                return Ok(None);
            };
            let seq = latest_seq(connection, &user, kind, &id)?;
            Ok(Some(change_of(seq, value)))
        })
        .await
    }
}
