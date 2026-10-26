//! The flat entity tables both the server model and a client's base keep.

use crate::apply::EntityRef;
use crate::model::{
    Entity, EntityKind, EntityValue, Entry, Love, Playlist, PlaylistDoc, Rating, Scalar, SessionDoc,
};
use std::collections::BTreeMap;

/// Every state entity, keyed by id, dead ones included.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Store {
    /// Playlists by id.
    pub playlists: BTreeMap<String, Playlist>,
    /// The entries.
    pub entries: BTreeMap<String, Entry>,
    /// Loves by song key.
    pub loves: BTreeMap<String, Love>,
    /// Ratings by song key.
    pub ratings: BTreeMap<String, Rating>,
    /// Scalars by key.
    pub scalars: BTreeMap<String, Scalar>,
    /// Sessions by device id.
    pub sessions: BTreeMap<String, SessionDoc>,
}

impl Store {
    /// The playlist with all its entries, if the playlist exists.
    pub fn doc(&self, playlist_id: &str) -> Option<PlaylistDoc> {
        let playlist = self.playlists.get(playlist_id)?.clone();
        let entries = self
            .entries
            .values()
            .filter(|entry| entry.playlist == playlist_id)
            .cloned()
            .collect();
        Some(PlaylistDoc { playlist, entries })
    }

    /// The playlist document holding an entry.
    pub fn doc_of_entry(&self, entry_id: &str) -> Option<PlaylistDoc> {
        self.doc(&self.entries.get(entry_id)?.playlist)
    }

    /// Writes back the entities of `doc` that an apply reported changed.
    pub fn write_doc(&mut self, doc: &PlaylistDoc, changed: &[EntityRef]) {
        for reference in changed {
            match reference.kind {
                EntityKind::Playlist => {
                    self.playlists
                        .insert(doc.playlist.id.clone(), doc.playlist.clone());
                }
                EntityKind::PlaylistEntry => {
                    if let Some(entry) = doc.entry(&reference.id) {
                        self.entries.insert(entry.id.clone(), entry.clone());
                    }
                }
                _ => {}
            }
        }
    }

    /// Stores one entity, replacing what was there.
    pub fn put(&mut self, value: EntityValue) {
        match value {
            EntityValue::Playlist(v) => {
                self.playlists.insert(v.id.clone(), v);
            }
            EntityValue::Entry(v) => {
                self.entries.insert(v.id.clone(), v);
            }
            EntityValue::Love(v) => {
                self.loves.insert(v.song_key.clone(), v);
            }
            EntityValue::Rating(v) => {
                self.ratings.insert(v.song_key.clone(), v);
            }
            EntityValue::Scalar(v) => {
                self.scalars.insert(v.key.clone(), v);
            }
            EntityValue::Session(v) => {
                self.sessions.insert(v.device.clone(), v);
            }
        }
    }

    /// One entity by kind and id.
    pub fn get(&self, kind: EntityKind, id: &str) -> Option<EntityValue> {
        match kind {
            EntityKind::Playlist => self.playlists.get(id).cloned().map(EntityValue::Playlist),
            EntityKind::PlaylistEntry => self.entries.get(id).cloned().map(EntityValue::Entry),
            EntityKind::Love => self.loves.get(id).cloned().map(EntityValue::Love),
            EntityKind::Rating => self.ratings.get(id).cloned().map(EntityValue::Rating),
            EntityKind::Scalar => self.scalars.get(id).cloned().map(EntityValue::Scalar),
            EntityKind::Session => self.sessions.get(id).cloned().map(EntityValue::Session),
            EntityKind::Listen => None,
        }
    }

    /// Every entity in wire form, ordered by kind and id.
    pub fn entities(&self) -> Vec<Entity> {
        let mut all = Vec::new();
        all.extend(self.playlists.values().cloned().map(EntityValue::Playlist));
        all.extend(self.entries.values().cloned().map(EntityValue::Entry));
        all.extend(self.loves.values().cloned().map(EntityValue::Love));
        all.extend(self.ratings.values().cloned().map(EntityValue::Rating));
        all.extend(self.scalars.values().cloned().map(EntityValue::Scalar));
        all.extend(self.sessions.values().cloned().map(EntityValue::Session));
        all.iter().map(EntityValue::to_entity).collect()
    }
}
