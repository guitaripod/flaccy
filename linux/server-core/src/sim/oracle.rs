//! Ground truth for "no acknowledged write is lost": the winner of every
//! last-writer field, computed from the server's journal of applied writes.

use super::server::JournalEntry;
use super::store::Store;
use crate::mutation::{Op, PlaylistOp};
use crate::stamp::Stamp;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug)]
struct Winner {
    stamp: Stamp,
    value: Value,
    tied: bool,
}

/// Winners per field, and the entries whose removal is final.
#[derive(Debug, Default)]
pub struct Oracle {
    fields: BTreeMap<String, Winner>,
    removed: BTreeSet<String>,
    seen: usize,
}

impl Oracle {
    /// Folds in the journal entries written since the last call.
    pub fn absorb(&mut self, journal: &[JournalEntry]) {
        for entry in &journal[self.seen..] {
            self.note_op(entry);
        }
        self.seen = journal.len();
    }

    fn note(&mut self, field: String, stamp: Stamp, value: Value) {
        match self.fields.get_mut(&field) {
            Some(winner) if stamp == winner.stamp => winner.tied |= winner.value != value,
            Some(winner) if stamp < winner.stamp => {}
            _ => {
                self.fields.insert(
                    field,
                    Winner {
                        stamp,
                        value,
                        tied: false,
                    },
                );
            }
        }
    }

    fn note_op(&mut self, entry: &JournalEntry) {
        let stamp = entry.stored;
        match &entry.op {
            Op::Love(args) => {
                self.note(format!("love/{}", args.song_key), stamp, json!(args.loved))
            }
            Op::Rating(args) => self.note(
                format!("rating/{}", args.song_key),
                stamp,
                json!(args.rating),
            ),
            Op::Scalar(op) => {
                let written = op.entity(stamp);
                let value = json!([written.deleted, written.value]);
                self.note(format!("scalar/{}", op.key()), stamp, value);
            }
            Op::Playlist(PlaylistOp::Create(args)) => {
                self.note(format!("name/{}", args.id), stamp, json!(args.name))
            }
            Op::Playlist(PlaylistOp::Rename(args)) => {
                self.note(format!("name/{}", args.id), stamp, json!(args.name))
            }
            Op::Playlist(PlaylistOp::Remove(args)) => {
                self.removed.insert(args.id.clone());
            }
            _ => {}
        }
    }

    fn server_value(&self, field: &str, server: &Store) -> Option<Value> {
        let (kind, id) = field.split_once('/')?;
        match kind {
            "love" => server.loves.get(id).map(|v| json!(v.loved)),
            "rating" => server.ratings.get(id).map(|v| json!(v.rating)),
            "scalar" => server.scalars.get(id).map(|v| json!([v.deleted, v.value])),
            "name" => server.playlists.get(id).map(|v| json!(v.name)),
            _ => None,
        }
    }

    /// Fails when the server lost a winning write or brought a removed entry back; skipped when a restore and a wiped client together made the loss legitimate.
    pub fn check(&self, server: &Store, check_losses: bool) -> Result<(), String> {
        if !check_losses {
            return Ok(());
        }
        for id in &self.removed {
            if server.entries.get(id).is_some_and(|entry| entry.alive) {
                return Err(format!("removed entry {id} was resurrected"));
            }
        }
        for (field, winner) in self.fields.iter().filter(|(_, w)| !w.tied) {
            let actual = self.server_value(field, server);
            if actual.as_ref() != Some(&winner.value) {
                return Err(format!(
                    "acknowledged write lost on {field}: expected {}, server has {actual:?}",
                    winner.value
                ));
            }
        }
        Ok(())
    }
}
