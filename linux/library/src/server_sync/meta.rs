use super::error::Result;
use flaccy_server_core::stamp::{ClientClock, Stamp};
use rusqlite::{params, Connection, OptionalExtension};

pub(crate) const DEVICE: &str = "device";
pub(crate) const USER: &str = "user";
pub(crate) const INSTANCE: &str = "instance";
pub(crate) const INCARNATION: &str = "incarnation";
pub(crate) const CURSOR: &str = "cursor";
pub(crate) const NEXT_ID: &str = "next_mutation_id";
pub(crate) const LAST_STAMP: &str = "last_stamp";
pub(crate) const OFFSET: &str = "server_offset_ms";
pub(crate) const EVENT_COUNTER: &str = "event_counter";
pub(crate) const SERVER_URL: &str = "server_url";
pub(crate) const SERVER_ID: &str = "server_id";
pub(crate) const IMPORTED: &str = "imported";
pub(crate) const LAST_SYNCED: &str = "last_synced_at";
pub(crate) const TRACKS_SIGNATURE: &str = "tracks_signature";
pub(crate) const LISTENS_PHASE: &str = "listens_phase";
pub(crate) const LISTENS_BEFORE: &str = "listens_before";
pub(crate) const LISTENS_AFTER: &str = "listens_after";
pub(crate) const LISTENS_TAIL_FROM: &str = "listens_tail_from";

pub(crate) fn get(conn: &Connection, key: &str) -> Result<Option<String>> {
    Ok(conn
        .prepare_cached("SELECT value FROM sync_meta WHERE key = ?1")?
        .query_row(params![key], |row| row.get(0))
        .optional()?)
}

pub(crate) fn set(conn: &Connection, key: &str, value: &str) -> Result<()> {
    conn.prepare_cached(
        "INSERT INTO sync_meta (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
    )?
    .execute(params![key, value])?;
    Ok(())
}

pub(crate) fn remove(conn: &Connection, key: &str) -> Result<()> {
    conn.prepare_cached("DELETE FROM sync_meta WHERE key = ?1")?
        .execute(params![key])?;
    Ok(())
}

pub(crate) fn get_i64(conn: &Connection, key: &str) -> Result<Option<i64>> {
    Ok(get(conn, key)?.and_then(|text| text.parse().ok()))
}

pub(crate) fn set_i64(conn: &Connection, key: &str, value: i64) -> Result<()> {
    set(conn, key, &value.to_string())
}

/// True once this database has enrolled with a server; the recorder's whole cost when it has not.
pub(crate) fn enabled(conn: &Connection) -> bool {
    matches!(get(conn, DEVICE), Ok(Some(_)))
}

/// What this database knows about the server it syncs with.
#[derive(Clone, Debug)]
pub(crate) struct Link {
    pub device: String,
    pub user: String,
    pub instance: String,
    pub incarnation: Option<String>,
}

pub(crate) fn link(conn: &Connection) -> Result<Option<Link>> {
    let Some(device) = get(conn, DEVICE)? else {
        return Ok(None);
    };
    Ok(Some(Link {
        device,
        user: get(conn, USER)?.unwrap_or_default(),
        instance: get(conn, INSTANCE)?.unwrap_or_default(),
        incarnation: get(conn, INCARNATION)?,
    }))
}

pub(crate) fn cursor(conn: &Connection) -> Result<i64> {
    Ok(get_i64(conn, CURSOR)?.unwrap_or(0))
}

/// Takes the next mutation id; call inside the transaction that stores the mutation.
pub(crate) fn take_mutation_id(conn: &Connection) -> Result<i64> {
    let id = get_i64(conn, NEXT_ID)?.unwrap_or(1);
    set_i64(conn, NEXT_ID, id + 1)?;
    Ok(id)
}

fn clock(conn: &Connection) -> Result<ClientClock> {
    let last = get_i64(conn, LAST_STAMP)?.unwrap_or(0);
    let offset = get_i64(conn, OFFSET)?.unwrap_or(0);
    Ok(ClientClock::new(Stamp(last), offset))
}

/// The next client stamp, persisted; call inside the transaction that stores what it stamps.
pub(crate) fn next_stamp(conn: &Connection, now_ms: i64) -> Result<Stamp> {
    let mut clock = clock(conn)?;
    let stamp = clock.next(now_ms);
    set_i64(conn, LAST_STAMP, clock.last().0)?;
    Ok(stamp)
}

/// Learns the server's clock offset from a response's `serverTimeMs`.
pub(crate) fn observe_server_time(
    conn: &Connection,
    server_time_ms: i64,
    local_now_ms: i64,
) -> Result<()> {
    let mut clock = clock(conn)?;
    clock.observe_server_time(server_time_ms, local_now_ms);
    set_i64(conn, OFFSET, clock.offset_ms())
}

/// The next listen counter for `event_id_rec`, never reused across instances.
pub(crate) fn take_event_counter(conn: &Connection) -> Result<u64> {
    let counter = get_i64(conn, EVENT_COUNTER)?.unwrap_or(0);
    set_i64(conn, EVENT_COUNTER, counter + 1)?;
    Ok(counter as u64)
}
