//! Applying one parsed mutation to the tables: load what it addresses, run the
//! pure core, write back only what changed and file the changes.

use flaccy_server_core::apply::{
    apply_love, apply_playlist, apply_rating, apply_scalar, apply_session, Caller, Outcome, Status,
};
use flaccy_server_core::model::{Love, Rating, Scalar, SessionDoc};
use flaccy_server_core::mutation::{Op, PlaylistOp};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::ErrorCode;
use rusqlite::Connection;

use super::doc::{load_doc_for, record_changes, takes_foreign_entry, write_rows};
use super::meta::Counters;
use super::singles::apply_single;
use super::{listens, reseed, SyncError};
use crate::security;

/// What a mutation needs besides the connection: who writes, at which stamp, and the counters.
pub(super) struct Ctx<'a> {
    pub caller: &'a Caller,
    pub stamp: Stamp,
    pub counters: &'a mut Counters,
}

/// Applies `op`; the transaction around it is the caller's.
pub(super) fn apply_op(connection: &Connection, op: &Op, ctx: &mut Ctx<'_>) -> Result<Outcome, SyncError> {
    let caller = ctx.caller;
    let stamp = ctx.stamp;
    match op {
        Op::Playlist(playlist_op) => apply_playlist_op(connection, playlist_op, ctx),
        Op::Love(args) => apply_single::<Love>(connection, ctx.counters, &caller.user, &args.song_key, |slot| {
            apply_love(slot, args, caller, stamp)
        }),
        Op::Rating(args) => apply_single::<Rating>(connection, ctx.counters, &caller.user, &args.song_key, |slot| {
            apply_rating(slot, args, caller, stamp)
        }),
        Op::Scalar(scalar_op) => {
            apply_single::<Scalar>(connection, ctx.counters, &caller.user, scalar_op.key(), |slot| {
                apply_scalar(slot, scalar_op, caller, stamp)
            })
        }
        Op::Session(session) => {
            apply_single::<SessionDoc>(connection, ctx.counters, &caller.user, &caller.device, |slot| {
                apply_session(slot, session, caller, stamp)
            })
        }
        Op::Listen(inputs) => listens::record(connection, inputs, ctx),
        Op::DeviceRename(name) => Ok(rename_device(name, ctx)),
        Op::Reseed(entities) => reseed::apply(connection, entities, ctx),
    }
}

fn rename_device(name: &str, ctx: &mut Ctx<'_>) -> Outcome {
    if !ctx.caller.can_write() {
        return Outcome::invalid(ErrorCode::Forbidden);
    }
    match security::clean_name(name) {
        Ok(clean) => {
            ctx.counters.note_rename(&ctx.caller.device, &clean);
            Outcome {
                status: Status::Applied,
                changed: Vec::new(),
            }
        }
        Err(_) => Outcome::invalid(ErrorCode::BadArgs),
    }
}

/// The playlist an operation inserts entries into and the ids it would add.
fn new_entry_ids(op: &PlaylistOp) -> Option<(&str, Vec<&str>)> {
    match op {
        PlaylistOp::Create(args) => Some((&args.id, args.entries.iter().map(|entry| entry.id.as_str()).collect())),
        PlaylistOp::Insert(args) => Some((&args.playlist, vec![args.id.as_str()])),
        PlaylistOp::InsertMany(args) => {
            Some((&args.playlist, args.entries.iter().map(|entry| entry.id.as_str()).collect()))
        }
        _ => None,
    }
}

fn apply_playlist_op(connection: &Connection, op: &PlaylistOp, ctx: &mut Ctx<'_>) -> Result<Outcome, SyncError> {
    if let Some((playlist, ids)) = new_entry_ids(op) {
        if takes_foreign_entry(connection, playlist, ids)? {
            return Ok(Outcome::invalid(ErrorCode::BadArgs));
        }
    }
    let mut doc = load_doc_for(connection, op.target())?;
    let before = doc.as_ref().map(|doc| doc.playlist.visibility);
    let outcome = apply_playlist(&mut doc, op, ctx.caller, ctx.stamp);
    if outcome.status != Status::Applied {
        return Ok(outcome);
    }
    if let Some(doc) = &doc {
        write_rows(connection, doc, &outcome.changed)?;
        record_changes(connection, ctx.counters, doc, before, &outcome.changed)?;
    }
    Ok(outcome)
}
