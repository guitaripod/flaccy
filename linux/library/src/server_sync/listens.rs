use super::error::Result;
use super::meta;
use super::pending::{self, NewMutation, LISTEN_RECORD};
use super::recorder::listen_json;
use super::songref::ref_for_play;
use crate::db::{string_from_unix, unix_from_string};
use crate::listen_history::ListenKeyCache;
use flaccy_server_core::model::SongRef;
use flaccy_server_core::song::event_id_rec;
use rusqlite::{params, Connection};
use serde::Deserialize;
use serde_json::json;

const PAGE_LIMIT: usize = 5_000;
const FAR_FUTURE: i64 = 4_102_444_800;
const PHASE_TAIL: &str = "tail";
const LISTENS_PER_IMPORT_MUTATION: usize = 500;

/// One listen as `GET /listens` returns it.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ListenItem {
    /// The change sequence number of the listen's last write.
    pub seq: i64,
    /// The 24 hex character listen id.
    pub event_id: String,
    /// Unix seconds the play started.
    pub ts: i64,
    /// The song played.
    #[serde(rename = "ref")]
    pub song: SongRef,
    /// Seconds actually played.
    pub played_s: i64,
    /// True when the server's ledger hid the play.
    #[serde(default)]
    pub suppressed: bool,
}

/// One page of `GET /listens`.
#[derive(Clone, Debug, Deserialize)]
pub struct ListensPage {
    /// The listens, newest first for `before`, ascending by `seq` for `after`.
    pub listens: Vec<ListenItem>,
    /// True when another page follows.
    #[serde(default)]
    pub more: bool,
    /// The highest listen `seq` at the snapshot.
    #[serde(default)]
    pub head: i64,
}

/// The next `GET /listens` the engine wants: exactly one of `before` and `after` is set.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ListensRequest {
    /// Page backwards from this Unix time (the history backfill).
    pub before: Option<i64>,
    /// Page forwards from this `seq` (the live tail).
    pub after: Option<i64>,
    /// The page size.
    pub limit: usize,
}

pub(crate) fn next_request(conn: &Connection) -> Result<ListensRequest> {
    if meta::get(conn, meta::LISTENS_PHASE)?.as_deref() == Some(PHASE_TAIL) {
        return Ok(ListensRequest {
            before: None,
            after: Some(meta::get_i64(conn, meta::LISTENS_AFTER)?.unwrap_or(0)),
            limit: PAGE_LIMIT,
        });
    }
    Ok(ListensRequest {
        before: Some(meta::get_i64(conn, meta::LISTENS_BEFORE)?.unwrap_or(FAR_FUTURE)),
        after: None,
        limit: PAGE_LIMIT,
    })
}

/// Stores a page and moves the paging state in the caller's transaction. Answers how many rows were written.
pub(crate) fn apply_page(
    conn: &Connection,
    page: &ListensPage,
    keys: &mut ListenKeyCache,
) -> Result<usize> {
    let written = upsert_all(conn, &page.listens, keys)?;
    if meta::get(conn, meta::LISTENS_PHASE)?.as_deref() == Some(PHASE_TAIL) {
        if let Some(last) = page.listens.last() {
            meta::set_i64(conn, meta::LISTENS_AFTER, last.seq)?;
        }
        return Ok(written);
    }
    if meta::get(conn, meta::LISTENS_TAIL_FROM)?.is_none() {
        meta::set_i64(conn, meta::LISTENS_TAIL_FROM, page.head)?;
    }
    let requested = meta::get_i64(conn, meta::LISTENS_BEFORE)?.unwrap_or(FAR_FUTURE);
    match page.listens.iter().map(|item| item.ts).min() {
        Some(oldest) if page.more => {
            let candidate = oldest + 1;
            let next = if candidate >= requested {
                oldest
            } else {
                candidate
            };
            meta::set_i64(conn, meta::LISTENS_BEFORE, next)?;
        }
        _ => {
            let tail_from = meta::get_i64(conn, meta::LISTENS_TAIL_FROM)?.unwrap_or(0);
            meta::set_i64(conn, meta::LISTENS_AFTER, tail_from)?;
            meta::set(conn, meta::LISTENS_PHASE, PHASE_TAIL)?;
        }
    }
    Ok(written)
}

/// Forgets the paging position after a server restore, so listens are read again and applied idempotently.
pub(crate) fn rewind(conn: &Connection) -> Result<()> {
    if meta::get(conn, meta::LISTENS_PHASE)?.as_deref() == Some(PHASE_TAIL) {
        return meta::set_i64(conn, meta::LISTENS_AFTER, 0);
    }
    meta::remove(conn, meta::LISTENS_BEFORE)?;
    meta::remove(conn, meta::LISTENS_TAIL_FROM)
}

/// True once the history has been read back to its oldest listen.
pub(crate) fn backfill_done(conn: &Connection) -> Result<bool> {
    Ok(meta::get(conn, meta::LISTENS_PHASE)?.as_deref() == Some(PHASE_TAIL))
}

fn upsert_all(
    conn: &Connection,
    listens: &[ListenItem],
    keys: &mut ListenKeyCache,
) -> Result<usize> {
    let mut stmt = conn.prepare_cached(
        "INSERT INTO scrobbles
         (trackTitle, artist, albumTitle, timestamp, duration, submitted,
          titleKey, artistKey, albumKey, eventId, suppressed)
         VALUES (?1, ?2, ?3, ?4, ?5, 1, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(eventId) WHERE eventId IS NOT NULL DO UPDATE SET suppressed = excluded.suppressed
         WHERE scrobbles.suppressed <> excluded.suppressed",
    )?;
    let mut written = 0;
    for item in listens {
        let song = &item.song;
        let derived = keys.keys(&song.title, &song.artist, &song.album);
        written += stmt.execute(params![
            song.title,
            song.artist,
            song.album,
            string_from_unix(item.ts),
            item.played_s,
            derived.title,
            derived.artist,
            derived.album,
            item.event_id,
            item.suppressed
        ])?;
    }
    Ok(written)
}

/// Queues every stored play that has an event id as `listen.record`, 500 to a mutation, for a server that lost them.
pub(crate) fn requeue_all(conn: &Connection) -> Result<Vec<NewMutation>> {
    let mut stmt = conn.prepare(
        "SELECT eventId, timestamp, trackTitle, artist, albumTitle, duration
         FROM scrobbles WHERE eventId IS NOT NULL ORDER BY id",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok((
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
            row.get::<_, String>(4)?,
            row.get::<_, i64>(5)?,
        ))
    })?;
    let mut mutations = Vec::new();
    let mut batch = Vec::new();
    for row in rows {
        let (event_id, timestamp, title, artist, album, played_s) = row?;
        let song = ref_for_play(&title, &artist, &album);
        batch.push(listen_json(
            &event_id,
            unix_from_string(&timestamp),
            &song,
            played_s,
            played_s > 0,
        ));
        if batch.len() == LISTENS_PER_IMPORT_MUTATION {
            mutations.push(listen_mutation(std::mem::take(&mut batch)));
        }
    }
    if !batch.is_empty() {
        mutations.push(listen_mutation(batch));
    }
    Ok(mutations)
}

/// A stale copy reached an instance whose ids the server has already spent on other plays. Gives each recorded play that no push was answered for a new id under `instance`, in its `scrobbles` row and in the queued `listen.record`, so it is neither taken for a repeat of the server's play nor shadows it when that play is read back.
pub(crate) fn rederive_unacknowledged(
    conn: &Connection,
    device: &str,
    instance: &str,
) -> Result<()> {
    let queued: Vec<(i64, String)> = {
        let mut stmt = conn.prepare(
            "SELECT mutation_id, args_json FROM sync_pending WHERE name = ?1 AND acked = 0",
        )?;
        let rows = stmt.query_map(params![LISTEN_RECORD], |row| Ok((row.get(0)?, row.get(1)?)))?;
        rows.collect::<std::result::Result<_, _>>()?
    };
    for (mutation_id, args) in queued {
        let mut parsed: serde_json::Value = serde_json::from_str(&args)?;
        let Some(listens) = parsed["listens"].as_array_mut() else {
            continue;
        };
        for listen in listens.iter_mut().filter(|listen| listen["recorded"] == true) {
            let Some(old) = listen["eventId"].as_str().map(str::to_owned) else {
                continue;
            };
            let new = event_id_rec(device, instance, meta::take_event_counter(conn)?);
            conn.execute(
                "UPDATE scrobbles SET eventId = ?1 WHERE eventId = ?2",
                params![new, old],
            )?;
            listen["eventId"] = json!(new);
        }
        conn.execute(
            "UPDATE sync_pending SET args_json = ?1 WHERE mutation_id = ?2",
            params![serde_json::to_string(&parsed)?, mutation_id],
        )?;
    }
    Ok(())
}

fn listen_mutation(listens: Vec<serde_json::Value>) -> NewMutation {
    NewMutation::new(LISTEN_RECORD, json!({ "listens": listens }), Vec::new())
}

/// Appends mutations built by `requeue_all` to the queue.
pub(crate) fn append_all(conn: &Connection, mutations: Vec<NewMutation>) -> Result<()> {
    for mutation in mutations {
        pending::append(conn, mutation)?;
    }
    Ok(())
}
