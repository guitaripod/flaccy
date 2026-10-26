//! The `changes` table: which entity changed at which sequence number, per scope.

use flaccy_server_core::model::EntityKind;
use rusqlite::Connection;

use super::meta::Counters;
use super::SyncError;

/// The text a kind is stored and sent as.
pub(super) fn kind_text(kind: EntityKind) -> &'static str {
    match kind {
        EntityKind::Playlist => "playlist",
        EntityKind::PlaylistEntry => "playlist_entry",
        EntityKind::Love => "love",
        EntityKind::Rating => "rating",
        EntityKind::Scalar => "scalar",
        EntityKind::Session => "session",
        EntityKind::Listen => "listen",
    }
}

/// The kind a stored word names.
pub(super) fn parse_kind(text: &str) -> Option<EntityKind> {
    Some(match text {
        "playlist" => EntityKind::Playlist,
        "playlist_entry" => EntityKind::PlaylistEntry,
        "love" => EntityKind::Love,
        "rating" => EntityKind::Rating,
        "scalar" => EntityKind::Scalar,
        "session" => EntityKind::Session,
        "listen" => EntityKind::Listen,
        _ => return None,
    })
}

/// Records that an entity changed at `seq` in `scope`, replacing its older record there.
pub(super) fn record(
    connection: &Connection,
    counters: &mut Counters,
    scope: &str,
    kind: EntityKind,
    id: &str,
    seq: i64,
) -> Result<(), SyncError> {
    connection
        .prepare_cached(
            "INSERT INTO changes(seq, scope, kind, id) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(scope, kind, id) DO UPDATE SET seq = excluded.seq",
        )?
        .execute((seq, scope, kind_text(kind), id))?;
    counters.note_head(scope, seq);
    Ok(())
}
