//! `state.reseed`: a whole mutation that merges full entities, all or nothing.

use std::collections::BTreeSet;

use flaccy_server_core::apply::{clamp_reseed, reseed_into_doc, upsert, Caller, EntityRef, Outcome, Status};
use flaccy_server_core::model::{EntityValue, Love, Rating, Scalar, SessionDoc, Visibility};
use flaccy_server_core::wire::ErrorCode;
use rusqlite::Connection;

use super::apply::Ctx;
use super::blobs::user_owns_blob;
use super::doc::{load_doc, record_changes, takes_foreign_entry, write_rows};
use super::rows::UserRow;
use super::singles::record_user_changes;
use super::SyncError;

const SAVEPOINT: &str = "reseed";

/// A playlist document merged during a reseed, waiting to have its changes filed.
struct MergedDoc {
    doc: flaccy_server_core::model::PlaylistDoc,
    before: Option<Visibility>,
    changed: Vec<EntityRef>,
}

/// What a reseed merged: the documents, then the single entities.
struct Merged {
    docs: Vec<MergedDoc>,
    singles: Vec<EntityRef>,
}

fn playlist_ids(entities: &[EntityValue]) -> BTreeSet<&str> {
    entities
        .iter()
        .filter_map(|entity| match entity {
            EntityValue::Playlist(playlist) => Some(playlist.id.as_str()),
            EntityValue::Entry(entry) => Some(entry.playlist.as_str()),
            _ => None,
        })
        .collect()
}

fn has_foreign_entry(connection: &Connection, entities: &[EntityValue]) -> Result<bool, SyncError> {
    for entity in entities {
        if let EntityValue::Entry(entry) = entity {
            if takes_foreign_entry(connection, &entry.playlist, [entry.id.as_str()])? {
                return Ok(true);
            }
        }
    }
    Ok(false)
}

/// True when a playlist of the reseed names a cover blob the user did not upload or the server no longer holds.
fn has_foreign_cover(connection: &Connection, entities: &[EntityValue], user: &str) -> Result<bool, SyncError> {
    for entity in entities {
        if let EntityValue::Playlist(playlist) = entity {
            if let Some(blob) = &playlist.cover_blob {
                if !user_owns_blob(connection, user, blob)? {
                    return Ok(true);
                }
            }
        }
    }
    Ok(false)
}

/// Merges the entities, rolling every row back when any of them is invalid; files the changes once all are valid.
///
/// Their stamps are first lowered to the server clock, as a push's stamp is.
pub(super) fn apply(connection: &Connection, entities: &[EntityValue], ctx: &mut Ctx<'_>) -> Result<Outcome, SyncError> {
    let entities = clamp_reseed(entities, ctx.counters.clock.last());
    let entities = entities.as_slice();
    if has_foreign_entry(connection, entities)? || has_foreign_cover(connection, entities, &ctx.caller.user)? {
        return Ok(Outcome::invalid(ErrorCode::BadArgs));
    }
    connection.execute_batch(&format!("SAVEPOINT {SAVEPOINT}"))?;
    let merged = merge_all(connection, entities, ctx.caller);
    match merged {
        Ok(Ok(merged)) => {
            let outcome = file_changes(connection, ctx, merged);
            connection.execute_batch(&format!("RELEASE {SAVEPOINT}"))?;
            outcome
        }
        Ok(Err(refusal)) => {
            roll_back(connection)?;
            Ok(refusal)
        }
        Err(error) => {
            let _ = roll_back(connection);
            Err(error)
        }
    }
}

fn roll_back(connection: &Connection) -> Result<(), SyncError> {
    connection.execute_batch(&format!("ROLLBACK TO {SAVEPOINT}; RELEASE {SAVEPOINT}"))?;
    Ok(())
}

fn merge_all(
    connection: &Connection,
    entities: &[EntityValue],
    caller: &Caller,
) -> Result<Result<Merged, Outcome>, SyncError> {
    let mut merged = Merged {
        docs: Vec::new(),
        singles: Vec::new(),
    };
    for id in playlist_ids(entities) {
        let mut doc = load_doc(connection, id)?;
        let before = doc.as_ref().map(|doc| doc.playlist.visibility);
        let outcome = reseed_into_doc(&mut doc, id, entities, caller);
        if let Status::Invalid(_) = outcome.status {
            return Ok(Err(outcome));
        }
        if let Some(doc) = doc {
            write_rows(connection, &doc, &outcome.changed)?;
            merged.docs.push(MergedDoc {
                doc,
                before,
                changed: outcome.changed,
            });
        }
    }
    for entity in entities {
        if let Some(outcome) = merge_single(connection, entity, caller)? {
            if let Status::Invalid(_) = outcome.status {
                return Ok(Err(outcome));
            }
            merged.singles.extend(outcome.changed);
        }
    }
    Ok(Ok(merged))
}

fn merge_single(connection: &Connection, entity: &EntityValue, caller: &Caller) -> Result<Option<Outcome>, SyncError> {
    Ok(match entity {
        EntityValue::Love(value) => Some(upsert_row::<Love>(connection, caller, value)?),
        EntityValue::Rating(value) => Some(upsert_row::<Rating>(connection, caller, value)?),
        EntityValue::Scalar(value) => Some(upsert_row::<Scalar>(connection, caller, value)?),
        EntityValue::Session(value) => Some(upsert_row::<SessionDoc>(connection, caller, value)?),
        EntityValue::Playlist(_) | EntityValue::Entry(_) => None,
    })
}

fn upsert_row<T: UserRow>(connection: &Connection, caller: &Caller, incoming: &T) -> Result<Outcome, SyncError> {
    let mut slot = T::load(connection, &caller.user, incoming.key())?;
    let outcome = upsert(&mut slot, incoming.clone(), caller);
    if outcome.status == Status::Applied {
        if let Some(value) = &slot {
            value.save(connection, &caller.user)?;
        }
    }
    Ok(outcome)
}

fn file_changes(connection: &Connection, ctx: &mut Ctx<'_>, merged: Merged) -> Result<Outcome, SyncError> {
    let mut changed = Vec::new();
    for item in &merged.docs {
        record_changes(connection, ctx.counters, &item.doc, item.before, &item.changed)?;
        changed.extend(item.changed.iter().cloned());
    }
    let singles = Outcome::from_changed(merged.singles);
    record_user_changes(connection, ctx.counters, &ctx.caller.user, &singles)?;
    changed.extend(singles.changed);
    Ok(Outcome::from_changed(changed))
}
