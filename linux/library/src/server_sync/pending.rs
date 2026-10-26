use super::error::Result;
use super::meta;
use flaccy_server_core::rebase::PendingMutation;
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{Mutation, MutationResult, MutationStatus};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};

pub(crate) const LISTEN_RECORD: &str = "listen.record";
pub(crate) const RESEED: &str = "state.reseed";
const LISTENS_PER_COALESCED_MUTATION: usize = 200;

pub(crate) fn playlist_key(id: &str) -> String {
    format!("playlist:{id}")
}

pub(crate) fn love_key(song_key: &str) -> String {
    format!("love:{song_key}")
}

pub(crate) fn scalar_key(key: &str) -> String {
    format!("scalar:{key}")
}

/// A mutation about to join the queue.
pub(crate) struct NewMutation {
    pub name: String,
    pub args: Value,
    pub touches: Vec<String>,
    pub stamp: Option<Stamp>,
}

impl NewMutation {
    pub(crate) fn new(name: &str, args: Value, touches: Vec<String>) -> Self {
        NewMutation {
            name: name.to_owned(),
            args,
            touches,
            stamp: None,
        }
    }

    pub(crate) fn stamped(mut self, stamp: Stamp) -> Self {
        self.stamp = Some(stamp);
        self
    }
}

/// Appends a mutation, taking its id and stamp inside the caller's transaction.
pub(crate) fn append(conn: &Connection, new: NewMutation) -> Result<i64> {
    let id = meta::take_mutation_id(conn)?;
    let stamp = match new.stamp {
        Some(stamp) => stamp,
        None => meta::next_stamp(conn, crate::db::now_ms())?,
    };
    insert_row(conn, id, &new.name, stamp, &new.args, &new.touches)?;
    Ok(id)
}

fn insert_row(
    conn: &Connection,
    id: i64,
    name: &str,
    stamp: Stamp,
    args: &Value,
    touches: &[String],
) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO sync_pending (mutation_id, name, stamp, args_json, touches_json)
         VALUES (?1, ?2, ?3, ?4, ?5)",
    )?
    .execute(params![
        id,
        name,
        stamp.0,
        serde_json::to_string(args)?,
        serde_json::to_string(touches)?
    ])?;
    Ok(())
}

/// Adds one listen, merging it into the newest queued `listen.record` that no push has carried yet.
pub(crate) fn append_listen(conn: &Connection, listen: Value) -> Result<()> {
    if let Some((id, mut listens)) = open_listen_batch(conn)? {
        listens.push(listen);
        conn.prepare_cached("UPDATE sync_pending SET args_json = ?1 WHERE mutation_id = ?2")?
            .execute(params![
                serde_json::to_string(&json!({ "listens": listens }))?,
                id
            ])?;
        return Ok(());
    }
    append(
        conn,
        NewMutation::new(LISTEN_RECORD, json!({ "listens": [listen] }), Vec::new()),
    )?;
    Ok(())
}

fn open_listen_batch(conn: &Connection) -> Result<Option<(i64, Vec<Value>)>> {
    let newest: Option<(i64, String, i64, i64, String)> = conn
        .prepare_cached(
            "SELECT mutation_id, name, sent, acked, args_json FROM sync_pending
             ORDER BY mutation_id DESC LIMIT 1",
        )?
        .query_row([], |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        })
        .ok();
    let Some((id, name, sent, acked, args)) = newest else {
        return Ok(None);
    };
    if name != LISTEN_RECORD || sent != 0 || acked != 0 {
        return Ok(None);
    }
    let parsed: Value = serde_json::from_str(&args)?;
    let listens = parsed["listens"].as_array().cloned().unwrap_or_default();
    Ok((listens.len() < LISTENS_PER_COALESCED_MUTATION).then_some((id, listens)))
}

/// The oldest unacknowledged mutations that fit one push, marked as sent.
pub(crate) fn next_batch(
    conn: &Connection,
    max_count: usize,
    max_bytes: usize,
) -> Result<Vec<Mutation>> {
    let mut stmt = conn.prepare_cached(
        "SELECT mutation_id, name, stamp, args_json FROM sync_pending
         WHERE acked = 0 ORDER BY mutation_id LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![max_count as i64], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, String>(3)?,
        ))
    })?;
    let mut batch = Vec::new();
    let mut bytes = 0;
    for row in rows {
        let (id, name, stamp, args) = row?;
        bytes += args.len();
        if !batch.is_empty() && bytes > max_bytes {
            break;
        }
        batch.push(Mutation {
            id,
            name,
            stamp: Stamp(stamp),
            args: serde_json::from_str(&args)?,
        });
    }
    let mut mark =
        conn.prepare_cached("UPDATE sync_pending SET sent = 1 WHERE mutation_id = ?1")?;
    for mutation in &batch {
        mark.execute(params![mutation.id])?;
    }
    Ok(batch)
}

/// Records push results: every answered mutation is acknowledged, refused ones fail. Answers the touches of the newly failed.
pub(crate) fn mark_results(conn: &Connection, results: &[MutationResult]) -> Result<Vec<String>> {
    let mut failed_touches = Vec::new();
    let mut touches_of = conn.prepare_cached(
        "SELECT touches_json FROM sync_pending WHERE mutation_id = ?1 AND failed = 0",
    )?;
    let mut mark = conn
        .prepare_cached("UPDATE sync_pending SET acked = 1, failed = ?1 WHERE mutation_id = ?2")?;
    for result in results {
        let refused = matches!(
            result.status,
            MutationStatus::Invalid | MutationStatus::Unsupported
        );
        if refused {
            let text: Option<String> = touches_of
                .query_row(params![result.id], |row| row.get(0))
                .ok();
            if let Some(text) = text {
                failed_touches.extend(serde_json::from_str::<Vec<String>>(&text)?);
            }
        }
        mark.execute(params![refused, result.id])?;
    }
    Ok(failed_touches)
}

/// Drops the acknowledged mutations a complete pull confirmed. Answers the touches of everything dropped.
pub(crate) fn retire(conn: &Connection, confirmed: i64) -> Result<Vec<String>> {
    let mut touches = Vec::new();
    let mut stmt = conn.prepare_cached(
        "SELECT touches_json FROM sync_pending WHERE acked = 1 AND mutation_id <= ?1",
    )?;
    let rows = stmt.query_map(params![confirmed], |row| row.get::<_, String>(0))?;
    for text in rows {
        touches.extend(serde_json::from_str::<Vec<String>>(&text?)?);
    }
    conn.prepare_cached("DELETE FROM sync_pending WHERE acked = 1 AND mutation_id <= ?1")?
        .execute(params![confirmed])?;
    Ok(touches)
}

pub(crate) fn count(conn: &Connection) -> Result<usize> {
    let total: i64 = conn.query_row("SELECT COUNT(*) FROM sync_pending", [], |row| row.get(0))?;
    Ok(total as usize)
}

pub(crate) fn count_unacked(conn: &Connection) -> Result<usize> {
    let total: i64 = conn.query_row(
        "SELECT COUNT(*) FROM sync_pending WHERE acked = 0",
        [],
        |row| row.get(0),
    )?;
    Ok(total as usize)
}

pub(crate) fn lowest_id(conn: &Connection) -> Result<Option<i64>> {
    Ok(
        conn.query_row("SELECT MIN(mutation_id) FROM sync_pending", [], |row| {
            row.get(0)
        })?,
    )
}

/// Forgets what the server said about every mutation after `have`, so the next push sends them again.
pub(crate) fn unack_after(conn: &Connection, have: i64) -> Result<()> {
    conn.execute(
        "UPDATE sync_pending SET acked = 0, failed = 0, sent = 0 WHERE mutation_id > ?1",
        params![have],
    )?;
    Ok(())
}

/// Gives every queued mutation a fresh id from 1 behind `leading`, forgetting what the server said about them.
pub(crate) fn renumber(conn: &Connection, leading: Vec<NewMutation>) -> Result<()> {
    let kept = all_rows(conn)?;
    conn.execute("DELETE FROM sync_pending", [])?;
    let mut next = 1;
    for lead in leading {
        let stamp = match lead.stamp {
            Some(stamp) => stamp,
            None => meta::next_stamp(conn, crate::db::now_ms())?,
        };
        insert_row(conn, next, &lead.name, stamp, &lead.args, &lead.touches)?;
        next += 1;
    }
    for row in kept {
        insert_row(
            conn,
            next,
            &row.mutation.name,
            row.mutation.stamp,
            &row.mutation.args,
            &row.touches,
        )?;
        next += 1;
    }
    meta::set_i64(conn, meta::NEXT_ID, next)
}

pub(crate) struct Row {
    pub mutation: Mutation,
    pub failed: bool,
    pub touches: Vec<String>,
}

pub(crate) fn all_rows(conn: &Connection) -> Result<Vec<Row>> {
    rows_matching(conn, "1 = 1")
}

fn rows_matching(conn: &Connection, condition: &str) -> Result<Vec<Row>> {
    let mut stmt = conn.prepare(&format!(
        "SELECT mutation_id, name, stamp, args_json, failed, touches_json
         FROM sync_pending WHERE {condition} ORDER BY mutation_id"
    ))?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, i64>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, i64>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, i64>(4)?,
            row.get::<_, String>(5)?,
        ))
    })?;
    let mut all = Vec::new();
    for row in rows {
        let (id, name, stamp, args, failed, touches) = row?;
        all.push(Row {
            mutation: Mutation {
                id,
                name,
                stamp: Stamp(stamp),
                args: serde_json::from_str(&args)?,
            },
            failed: failed != 0,
            touches: serde_json::from_str(&touches)?,
        });
    }
    Ok(all)
}

/// The key a reseeded entity is folded under.
pub(crate) fn reseed_entity_key(entity: &Value) -> Option<String> {
    let id = entity["id"].as_str()?;
    match entity["kind"].as_str()? {
        "playlist" => Some(playlist_key(id)),
        "playlist_entry" => Some(playlist_key(entity["value"]["playlist"].as_str()?)),
        "love" => Some(love_key(id)),
        "scalar" => Some(scalar_key(id)),
        other => Some(format!("{other}:{id}")),
    }
}

fn group_reseed(args: &Value) -> BTreeMap<String, Vec<Value>> {
    let mut groups: BTreeMap<String, Vec<Value>> = BTreeMap::new();
    for entity in args["entities"].as_array().into_iter().flatten() {
        if let Some(key) = reseed_entity_key(entity) {
            groups.entry(key).or_default().push(entity.clone());
        }
    }
    groups
}

/// The queue indexed by the entity each mutation touches, so folding one entity reads only its own mutations.
pub(crate) struct PendingIndex {
    by_key: HashMap<String, Vec<PendingMutation>>,
}

impl PendingIndex {
    pub(crate) fn load(conn: &Connection) -> Result<Self> {
        let mut by_key: HashMap<String, Vec<PendingMutation>> = HashMap::new();
        for row in rows_matching(conn, "name <> 'listen.record'")? {
            if row.mutation.name == RESEED {
                for (key, entities) in group_reseed(&row.mutation.args) {
                    let mut mutation = row.mutation.clone();
                    mutation.args = json!({ "entities": entities });
                    by_key.entry(key).or_default().push(PendingMutation {
                        mutation,
                        failed: row.failed,
                    });
                }
                continue;
            }
            for key in &row.touches {
                by_key
                    .entry(key.clone())
                    .or_default()
                    .push(PendingMutation {
                        mutation: row.mutation.clone(),
                        failed: row.failed,
                    });
            }
        }
        Ok(PendingIndex { by_key })
    }

    pub(crate) fn for_key(&self, key: &str) -> &[PendingMutation] {
        self.by_key.get(key).map(Vec::as_slice).unwrap_or(&[])
    }
}

/// The keys a reseed of `entities` touches, in the form `touches_json` stores.
pub(crate) fn reseed_touches(entities: &[Value]) -> Vec<String> {
    let mut keys: Vec<String> = entities.iter().filter_map(reseed_entity_key).collect();
    keys.sort();
    keys.dedup();
    keys
}
