//! Playlist documents: loading a playlist with its entries, writing back what
//! changed, and filing the changes under the scope that may see them.

use std::collections::HashSet;

use flaccy_server_core::apply::EntityRef;
use flaccy_server_core::model::{EntityKind, Playlist, PlaylistDoc, Visibility};
use flaccy_server_core::mutation::Target;
use rusqlite::Connection;

use super::changes;
use super::meta::Counters;
use super::rows::{entry_playlist, load_entries, load_entry, load_playlist, save_entry, save_playlist};
use super::{SyncError, HOUSEHOLD_SCOPE};

/// The playlist with all its entries, or `None` when there is no such playlist.
pub(super) fn load_doc(connection: &Connection, playlist_id: &str) -> Result<Option<PlaylistDoc>, SyncError> {
    let Some(playlist) = load_playlist(connection, playlist_id)? else {
        return Ok(None);
    };
    let entries = load_entries(connection, playlist_id)?;
    Ok(Some(PlaylistDoc { playlist, entries }))
}

/// The document an operation addresses: the playlist, or for an entry the playlist holding it.
pub(super) fn load_doc_for(connection: &Connection, target: Target<'_>) -> Result<Option<PlaylistDoc>, SyncError> {
    match target {
        Target::Playlist(id) => load_doc(connection, id),
        Target::Entry(id) => match load_entry(connection, id)? {
            Some(entry) => load_doc(connection, &entry.playlist),
            None => Ok(None),
        },
        _ => Ok(None),
    }
}

/// True when any of `entry_ids` already belongs to a playlist other than `playlist_id`.
pub(super) fn takes_foreign_entry<'a>(
    connection: &Connection,
    playlist_id: &str,
    entry_ids: impl IntoIterator<Item = &'a str>,
) -> Result<bool, SyncError> {
    for id in entry_ids {
        if entry_playlist(connection, id)?.is_some_and(|holder| holder != playlist_id) {
            return Ok(true);
        }
    }
    Ok(false)
}

/// The scope that sees a playlist and its entries: the owner, or the household.
pub(super) fn scope_of(playlist: &Playlist) -> &str {
    match playlist.visibility {
        Visibility::Household => HOUSEHOLD_SCOPE,
        Visibility::Private => &playlist.owner,
    }
}

/// Writes the rows of the entities an apply reported changed.
pub(super) fn write_rows(connection: &Connection, doc: &PlaylistDoc, changed: &[EntityRef]) -> Result<(), SyncError> {
    for reference in changed {
        match reference.kind {
            EntityKind::Playlist => save_playlist(connection, &doc.playlist)?,
            EntityKind::PlaylistEntry => {
                if let Some(entry) = doc.entry(&reference.id) {
                    save_entry(connection, entry)?;
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// Which way a playlist's visibility moved in one write.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Flip {
    None,
    ToHousehold,
    ToPrivate,
}

fn flip_of(before: Option<Visibility>, after: Visibility) -> Flip {
    match (before, after) {
        (Some(Visibility::Private), Visibility::Household) => Flip::ToHousehold,
        (Some(Visibility::Household), Visibility::Private) => Flip::ToPrivate,
        _ => Flip::None,
    }
}

/// Files the changed entities under the playlist's scope with new sequence numbers.
///
/// When the visibility flips, every other entity of the playlist is filed too,
/// so users who just gained access receive the whole playlist and, going back
/// to private, the household learns it is gone (the entries are then served as
/// redacted tombstones).
pub(super) fn record_changes(
    connection: &Connection,
    counters: &mut Counters,
    doc: &PlaylistDoc,
    before: Option<Visibility>,
    changed: &[EntityRef],
) -> Result<(), SyncError> {
    let flip = flip_of(before, doc.playlist.visibility);
    let scope = scope_of(&doc.playlist).to_owned();
    for reference in changed {
        let seq = counters.next_seq();
        file(connection, counters, &scope, flip, reference, seq)?;
    }
    if flip == Flip::None {
        return Ok(());
    }
    let known: HashSet<&str> = changed.iter().map(|reference| reference.id.as_str()).collect();
    let mut rest = Vec::new();
    if !known.contains(doc.playlist.id.as_str()) {
        rest.push(EntityRef::new(EntityKind::Playlist, &doc.playlist.id));
    }
    for entry in doc.entries.iter().filter(|entry| !known.contains(entry.id.as_str())) {
        rest.push(EntityRef::new(EntityKind::PlaylistEntry, &entry.id));
    }
    for reference in &rest {
        let seq = counters.next_seq();
        file(connection, counters, &scope, flip, reference, seq)?;
    }
    Ok(())
}

fn file(
    connection: &Connection,
    counters: &mut Counters,
    scope: &str,
    flip: Flip,
    reference: &EntityRef,
    seq: i64,
) -> Result<(), SyncError> {
    changes::record(connection, counters, scope, reference.kind, &reference.id, seq)?;
    if flip == Flip::ToPrivate {
        changes::record(connection, counters, HOUSEHOLD_SCOPE, reference.kind, &reference.id, seq)?;
    }
    Ok(())
}
