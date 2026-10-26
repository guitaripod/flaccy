use super::base;
use super::error::{Result, SyncError};
use super::ids::new_uuid_v7;
use super::listens;
use super::meta;
use super::pending::{self, reseed_touches, NewMutation, RESEED};
use super::store::atomically;
use rusqlite::Connection;
use serde_json::{json, Value};

const RESEED_ENTITIES: usize = 1_000;
const RESEED_BYTES: usize = 400_000;

/// The server's state was replaced (a new incarnation, or a cookie ahead of its log). Builds a `state.reseed` of what the base holds and this person may write, drops the base, restarts at cursor 0 under a new instance, and renumbers the queue behind the reseed. Plays are queued again too: the server may have lost some.
pub(crate) fn after_restore(conn: &Connection, incarnation: Option<&str>) -> Result<()> {
    atomically(conn, || {
        let link = meta::link(conn)?.ok_or(SyncError::NotConfigured)?;
        let mut leading = reseed_mutations(base::reseed_entities(conn, &link.user)?);
        leading.extend(listens::requeue_all(conn)?);
        base::clear(conn)?;
        conn.execute("DELETE FROM sync_ghosts", [])?;
        meta::set(conn, meta::INSTANCE, &new_uuid_v7())?;
        match incarnation {
            Some(incarnation) => meta::set(conn, meta::INCARNATION, incarnation)?,
            None => meta::remove(conn, meta::INCARNATION)?,
        }
        meta::set_i64(conn, meta::CURSOR, 0)?;
        listens::rewind(conn)?;
        pending::renumber(conn, leading)
    })
}

/// The server met this instance's ids with different arguments (a restored phone backup, a copied database). Moves the queue to a new instance.
pub(crate) fn after_instance_conflict(conn: &Connection) -> Result<()> {
    atomically(conn, || {
        meta::set(conn, meta::INSTANCE, &new_uuid_v7())?;
        pending::renumber(conn, Vec::new())
    })
}

fn reseed_mutations(entities: Vec<Value>) -> Vec<NewMutation> {
    let mut mutations = Vec::new();
    let mut batch: Vec<Value> = Vec::new();
    let mut bytes = 0;
    for entity in entities {
        bytes += entity.to_string().len();
        batch.push(entity);
        if batch.len() >= RESEED_ENTITIES || bytes >= RESEED_BYTES {
            mutations.push(reseed_mutation(std::mem::take(&mut batch)));
            bytes = 0;
        }
    }
    if !batch.is_empty() {
        mutations.push(reseed_mutation(batch));
    }
    mutations
}

fn reseed_mutation(entities: Vec<Value>) -> NewMutation {
    let touches = reseed_touches(&entities);
    NewMutation::new(RESEED, json!({ "entities": entities }), touches)
}
