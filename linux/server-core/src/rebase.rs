//! The client's visible state: the base the last pull produced with every
//! pending mutation folded on top, by the same apply functions the server runs.

use crate::apply::{apply_playlist, reseed_into_doc, upsert, Caller, Mergeable};
use crate::model::{EntityValue, Love, PlaylistDoc, Rating, Scalar, SessionDoc};
use crate::mutation::{parse, session_entity, Op, PlaylistOp, Target};
use crate::stamp::Stamp;
use crate::wire::Mutation;
use serde::{Deserialize, Serialize};

/// A mutation the client has written but a pull has not yet confirmed.
///
/// `mutation.stamp` is the local stamp. A `failed` mutation was refused by the
/// server and is skipped.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PendingMutation {
    /// The mutation; its stamp is the local stamp.
    pub mutation: Mutation,
    /// True once the server refused the mutation.
    #[serde(default)]
    pub failed: bool,
}

fn live_ops(pending: &[PendingMutation]) -> impl Iterator<Item = (Op, Stamp)> + '_ {
    pending
        .iter()
        .filter(|p| !p.failed)
        .filter_map(|p| parse(&p.mutation).ok().map(|op| (op, p.mutation.stamp)))
}

fn concerns(op: &PlaylistOp, playlist_id: &str, doc: &Option<PlaylistDoc>) -> bool {
    match op.target() {
        Target::Playlist(id) => id == playlist_id,
        Target::Entry(id) => doc.as_ref().is_some_and(|doc| doc.entry(id).is_some()),
        _ => false,
    }
}

/// The playlist as the client shows it: `base` (absent before the first pull) plus the pending mutations that touch it.
pub fn fold_playlist(
    playlist_id: &str,
    base: Option<&PlaylistDoc>,
    caller: &Caller,
    pending: &[PendingMutation],
) -> Option<PlaylistDoc> {
    let mut doc = base.cloned();
    for (op, stamp) in live_ops(pending) {
        match &op {
            Op::Playlist(playlist_op) if concerns(playlist_op, playlist_id, &doc) => {
                apply_playlist(&mut doc, playlist_op, caller, stamp);
            }
            Op::Reseed(entities) => {
                reseed_into_doc(&mut doc, playlist_id, entities, caller);
            }
            _ => {}
        }
    }
    doc
}

fn fold_single<T: Mergeable>(
    base: Option<&T>,
    caller: &Caller,
    pending: &[PendingMutation],
    candidates: impl Fn(&Op, Stamp) -> Vec<T>,
) -> Option<T> {
    let mut slot = base.cloned();
    for (op, stamp) in live_ops(pending) {
        for candidate in candidates(&op, stamp) {
            upsert(&mut slot, candidate, caller);
        }
    }
    slot
}

/// The love for `song_key`: `base` plus pending `love.set` and reseeds.
pub fn fold_love(
    song_key: &str,
    base: Option<&Love>,
    caller: &Caller,
    pending: &[PendingMutation],
) -> Option<Love> {
    fold_single(base, caller, pending, |op, stamp| match op {
        Op::Love(args) if args.song_key == song_key => vec![args.entity(stamp)],
        Op::Reseed(entities) => entities
            .iter()
            .filter_map(|e| match e {
                EntityValue::Love(love) if love.song_key == song_key => Some(love.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    })
}

/// The rating for `song_key`: `base` plus pending `rating.set` and reseeds.
pub fn fold_rating(
    song_key: &str,
    base: Option<&Rating>,
    caller: &Caller,
    pending: &[PendingMutation],
) -> Option<Rating> {
    fold_single(base, caller, pending, |op, stamp| match op {
        Op::Rating(args) if args.song_key == song_key => vec![args.entity(stamp)],
        Op::Reseed(entities) => entities
            .iter()
            .filter_map(|e| match e {
                EntityValue::Rating(rating) if rating.song_key == song_key => Some(rating.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    })
}

/// The scalar under `key`: `base` plus pending `scalar.set`, `scalar.clear` and reseeds.
pub fn fold_scalar(
    key: &str,
    base: Option<&Scalar>,
    caller: &Caller,
    pending: &[PendingMutation],
) -> Option<Scalar> {
    fold_single(base, caller, pending, |op, stamp| match op {
        Op::Scalar(scalar_op) if scalar_op.key() == key => vec![scalar_op.entity(stamp)],
        Op::Reseed(entities) => entities
            .iter()
            .filter_map(|e| match e {
                EntityValue::Scalar(scalar) if scalar.key == key => Some(scalar.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    })
}

/// The session of `device`: `base` plus pending `session.save` (when `device` is the caller's) and reseeds.
pub fn fold_session(
    device: &str,
    base: Option<&SessionDoc>,
    caller: &Caller,
    pending: &[PendingMutation],
) -> Option<SessionDoc> {
    fold_single(base, caller, pending, |op, stamp| match op {
        Op::Session(session) if caller.device == device => {
            vec![session_entity(device, session, stamp)]
        }
        Op::Reseed(entities) => entities
            .iter()
            .filter_map(|e| match e {
                EntityValue::Session(doc) if doc.device == device => Some(doc.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    })
}
