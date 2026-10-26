//! Last-writer merges: how a stamped write, or a whole entity carrying its own
//! stamps (`state.reseed`), lands on what is stored.

use super::playlist::can_edit_content;
use super::{Caller, EntityRef, Outcome};
use crate::model::{
    EntityKind, EntityValue, Entry, Love, Playlist, PlaylistDoc, Rating, Scalar, SessionDoc,
};
use crate::stamp::Stamp;
use crate::wire::ErrorCode;

/// Writes `value` into a field when `stamp` is not older than the field's stamp.
///
/// Ties go to the later write. True when the value or the stamp changed.
pub(super) fn assign<T: PartialEq>(
    slot: &mut T,
    slot_stamp: &mut Stamp,
    value: T,
    stamp: Stamp,
) -> bool {
    if stamp < *slot_stamp {
        return false;
    }
    let changed = *slot != value || *slot_stamp != stamp;
    *slot = value;
    *slot_stamp = stamp;
    changed
}

/// An entity that folds a newer version of itself in.
pub trait Mergeable: Clone {
    /// Folds `incoming` in field by field; true when anything changed.
    fn merge(&mut self, incoming: &Self) -> bool;

    /// The reference the server writes into `changes`.
    fn entity_ref(&self) -> EntityRef;
}

macro_rules! whole_entity {
    ($type:ty, $kind:expr, $id:ident) => {
        impl Mergeable for $type {
            fn merge(&mut self, incoming: &Self) -> bool {
                if incoming.stamp < self.stamp {
                    return false;
                }
                let changed = *self != *incoming;
                *self = incoming.clone();
                changed
            }

            fn entity_ref(&self) -> EntityRef {
                EntityRef::new($kind, &self.$id)
            }
        }
    };
}

whole_entity!(Love, EntityKind::Love, song_key);
whole_entity!(Rating, EntityKind::Rating, song_key);
whole_entity!(Scalar, EntityKind::Scalar, key);
whole_entity!(SessionDoc, EntityKind::Session, device);

impl Mergeable for Playlist {
    fn merge(&mut self, incoming: &Self) -> bool {
        let mut changed = false;
        let stamps = incoming.stamps;
        changed |= assign(
            &mut self.name,
            &mut self.stamps.name,
            incoming.name.clone(),
            stamps.name,
        );
        changed |= assign(
            &mut self.cover_blob,
            &mut self.stamps.cover,
            incoming.cover_blob.clone(),
            stamps.cover,
        );
        changed |= assign(
            &mut self.visibility,
            &mut self.stamps.visibility,
            incoming.visibility,
            stamps.visibility,
        );
        changed |= assign(
            &mut self.alive,
            &mut self.stamps.alive,
            incoming.alive,
            stamps.alive,
        );
        changed
    }

    fn entity_ref(&self) -> EntityRef {
        EntityRef::new(EntityKind::Playlist, &self.id)
    }
}

impl Mergeable for Entry {
    fn merge(&mut self, incoming: &Self) -> bool {
        let mut changed = false;
        changed |= assign(
            &mut self.song,
            &mut self.stamps.song,
            incoming.song.clone(),
            incoming.stamps.song,
        );
        changed |= assign(
            &mut self.pos,
            &mut self.stamps.pos,
            incoming.pos.clone(),
            incoming.stamps.pos,
        );
        let alive = self.alive && incoming.alive;
        let alive_stamp = self.stamps.alive.max(incoming.stamps.alive);
        changed |= alive != self.alive || alive_stamp != self.stamps.alive;
        self.alive = alive;
        self.stamps.alive = alive_stamp;
        changed
    }

    fn entity_ref(&self) -> EntityRef {
        EntityRef::new(EntityKind::PlaylistEntry, &self.id)
    }
}

/// Last-writer upsert of one whole entity into its slot.
pub fn upsert<T: Mergeable>(slot: &mut Option<T>, incoming: T, caller: &Caller) -> Outcome {
    if !caller.can_write() {
        return Outcome::invalid(ErrorCode::Forbidden);
    }
    let changed = match slot.as_mut() {
        Some(existing) => existing.merge(&incoming),
        None => {
            *slot = Some(incoming.clone());
            true
        }
    };
    if changed {
        Outcome::from_changed(vec![incoming.entity_ref()])
    } else {
        Outcome::noop()
    }
}

fn playlists_of<'a>(entities: &'a [EntityValue], id: &str) -> Vec<&'a Playlist> {
    entities
        .iter()
        .filter_map(|entity| match entity {
            EntityValue::Playlist(playlist) if playlist.id == id => Some(playlist),
            _ => None,
        })
        .collect()
}

fn entries_of<'a>(entities: &'a [EntityValue], playlist_id: &str) -> Vec<&'a Entry> {
    entities
        .iter()
        .filter_map(|entity| match entity {
            EntityValue::Entry(entry) if entry.playlist == playlist_id => Some(entry),
            _ => None,
        })
        .collect()
}

fn check_reseed(
    doc: Option<&PlaylistDoc>,
    playlists: &[&Playlist],
    entries: &[&Entry],
    caller: &Caller,
) -> Result<(), ErrorCode> {
    for playlist in playlists {
        let owner_matches = doc.is_none_or(|doc| doc.playlist.owner == playlist.owner);
        if playlist.owner != caller.user || !owner_matches {
            return Err(ErrorCode::Forbidden);
        }
    }
    if entries.is_empty() {
        return Ok(());
    }
    match doc {
        Some(doc) if !can_edit_content(&doc.playlist, caller) => Err(ErrorCode::Forbidden),
        None if playlists.is_empty() => Err(ErrorCode::UnknownPlaylist),
        _ => Ok(()),
    }
}

/// Merges the playlist and entries of a `state.reseed` that belong to `playlist_id` into its document.
///
/// Every check runs before the first write, so an invalid answer leaves `doc` as it was.
pub fn reseed_into_doc(
    doc: &mut Option<PlaylistDoc>,
    playlist_id: &str,
    entities: &[EntityValue],
    caller: &Caller,
) -> Outcome {
    if !caller.can_write() {
        return Outcome::invalid(ErrorCode::Forbidden);
    }
    let playlists = playlists_of(entities, playlist_id);
    let entries = entries_of(entities, playlist_id);
    if let Err(code) = check_reseed(doc.as_ref(), &playlists, &entries, caller) {
        return Outcome::invalid(code);
    }
    let mut changed = Vec::new();
    for playlist in playlists {
        changed.extend(reseed_playlist(doc, playlist));
    }
    if let Some(doc) = doc.as_mut() {
        for entry in entries {
            changed.extend(reseed_entry(doc, entry));
        }
    }
    Outcome::from_changed(changed)
}

fn reseed_playlist(doc: &mut Option<PlaylistDoc>, incoming: &Playlist) -> Option<EntityRef> {
    let changed = match doc.as_mut() {
        Some(doc) => doc.playlist.merge(incoming),
        None => {
            *doc = Some(PlaylistDoc::new(incoming.clone()));
            true
        }
    };
    changed.then(|| incoming.entity_ref())
}

fn reseed_entry(doc: &mut PlaylistDoc, incoming: &Entry) -> Option<EntityRef> {
    let changed = match doc.entries.iter_mut().find(|entry| entry.id == incoming.id) {
        Some(existing) => existing.merge(incoming),
        None => {
            doc.entries.push(incoming.clone());
            true
        }
    };
    changed.then(|| incoming.entity_ref())
}
