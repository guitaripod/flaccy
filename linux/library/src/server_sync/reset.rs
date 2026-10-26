use super::base;
use super::error::{Result, SyncError};
use super::ids::new_uuid_v7;
use super::listens;
use super::meta;
use super::pending::{self, reseed_touches, NewMutation, RESEED};
use super::store::atomically;
use flaccy_server_core::model::Entity;
use flaccy_server_core::mutation::chunk_reseed;
use rusqlite::Connection;
use serde_json::json;

/// The server's state was replaced (a new incarnation, or a cookie ahead of its log). Builds a `state.reseed` of what the base holds and this person may write, drops the base, restarts at cursor 0 under a new instance, and renumbers the queue behind the reseed. Plays are queued again too: the server may have lost some.
pub(crate) fn after_restore(conn: &Connection, incarnation: Option<&str>) -> Result<()> {
    atomically(conn, || {
        let link = meta::link(conn)?.ok_or(SyncError::NotConfigured)?;
        let mut leading = reseed_mutations(base::reseed_entities(conn, &link.user)?)?;
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

fn reseed_mutations(entities: Vec<Entity>) -> Result<Vec<NewMutation>> {
    chunk_reseed(entities)
        .into_iter()
        .map(|chunk| {
            let values = serde_json::to_value(&chunk)?;
            let touches = reseed_touches(values.as_array().map(Vec::as_slice).unwrap_or_default());
            Ok(NewMutation::new(
                RESEED,
                json!({ "entities": values }),
                touches,
            ))
        })
        .collect()
}
