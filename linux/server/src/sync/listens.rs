//! Listens: recording plays, running the ledger of PROTOCOL.md section 8, and reading them back.

use std::collections::BTreeSet;

use flaccy_library::listen_history::{artist_listen_key, title_key};
use flaccy_server_core::apply::{Outcome, Status};
use flaccy_server_core::ledger::{recompute_second, SecondEvent};
use flaccy_server_core::model::{Listen, Source};
use flaccy_server_core::mutation::ListenInput;
use flaccy_server_core::wire::ErrorCode;
use rusqlite::types::Type;
use rusqlite::{Connection, Row};
use serde::Serialize;

use super::apply::Ctx;
use super::meta::Counters;
use super::{Store, SyncError};
use crate::security::UserId;

/// The most listens one page returns.
pub const MAX_LISTEN_PAGE: usize = 5000;

/// A listen with the sequence number of its last change.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct ListenRow {
    /// The sequence number at which the listen was added or its `suppressed` flag last changed.
    pub seq: i64,
    /// The listen itself.
    #[serde(flatten)]
    pub listen: Listen,
}

/// One page of listens.
#[derive(Clone, Debug, PartialEq)]
pub struct ListenPage {
    /// The listens of the page.
    pub listens: Vec<ListenRow>,
    /// True when another page follows.
    pub more: bool,
    /// The highest listen sequence number the user has.
    pub head: i64,
}

fn source_text(source: Source) -> &'static str {
    match source {
        Source::Flaccy => "flaccy",
        Source::Lastfm => "lastfm",
        Source::Opensubsonic => "opensubsonic",
        Source::Migrated => "migrated",
    }
}

#[derive(Debug)]
struct UnknownSource(String);

impl std::fmt::Display for UnknownSource {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "unknown listen source '{}'", self.0)
    }
}

impl std::error::Error for UnknownSource {}

fn source_column(row: &Row<'_>, column: usize) -> rusqlite::Result<Source> {
    let word: String = row.get(column)?;
    match word.as_str() {
        "flaccy" => Ok(Source::Flaccy),
        "lastfm" => Ok(Source::Lastfm),
        "opensubsonic" => Ok(Source::Opensubsonic),
        "migrated" => Ok(Source::Migrated),
        _ => Err(rusqlite::Error::FromSqlConversionFailure(column, Type::Text, Box::new(UnknownSource(word)))),
    }
}

const LISTEN_COLUMNS: &str = "seq, event_id, ts, ref_json, played_s, source, recorded, device_id, suppressed";

fn listen_from_row(row: &Row<'_>) -> rusqlite::Result<ListenRow> {
    let song_text: String = row.get(3)?;
    let song = serde_json::from_str(&song_text)
        .map_err(|error| rusqlite::Error::FromSqlConversionFailure(3, Type::Text, Box::new(error)))?;
    Ok(ListenRow {
        seq: row.get(0)?,
        listen: Listen {
            event_id: row.get(1)?,
            ts: row.get(2)?,
            song,
            played_s: row.get(4)?,
            source: source_column(row, 5)?,
            recorded: row.get(6)?,
            device: row.get(7)?,
            suppressed: row.get(8)?,
        },
    })
}

fn insert_listen(connection: &Connection, user: &str, device: &str, source: Source, input: &ListenInput) -> Result<bool, SyncError> {
    let song_text = serde_json::to_string(&input.song)
        .map_err(|error| SyncError::Corrupt(format!("a listen would not serialize: {error}")))?;
    let added = connection
        .prepare_cached(
            "INSERT OR IGNORE INTO listens(event_id, user_id, ts, song_key, title_key, artist_key, ref_json, played_s,
                 source, recorded, device_id, suppressed, seq) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 0, 0)",
        )?
        .execute((
            &input.event_id,
            user,
            input.ts,
            &input.song.song_key,
            title_key(&input.song.title),
            artist_listen_key(&input.song.artist),
            song_text,
            input.played_s,
            source_text(source),
            input.recorded,
            (!device.is_empty()).then_some(device),
        ))?;
    Ok(added == 1)
}

fn second_events(connection: &Connection, user: &str, ts: i64) -> Result<Vec<SecondEvent>, SyncError> {
    let mut statement = connection.prepare_cached(
        "SELECT event_id, recorded, title_key, artist_key, suppressed FROM listens WHERE user_id = ?1 AND ts = ?2",
    )?;
    let events = statement
        .query_map((user, ts), |row| {
            Ok(SecondEvent {
                event_id: row.get(0)?,
                recorded: row.get(1)?,
                title_key: row.get(2)?,
                artist_key: row.get(3)?,
                suppressed: row.get(4)?,
            })
        })?
        .collect::<Result<Vec<_>, _>>()?;
    Ok(events)
}

fn set_flag(connection: &Connection, event_id: &str, suppressed: bool) -> Result<(), SyncError> {
    connection
        .prepare_cached("UPDATE listens SET suppressed = ?1 WHERE event_id = ?2")?
        .execute((suppressed, event_id))?;
    Ok(())
}

fn stamp_seq(connection: &Connection, counters: &mut Counters, user: &str, event_id: &str) -> Result<(), SyncError> {
    let seq = counters.next_seq();
    connection
        .prepare_cached("UPDATE listens SET seq = ?1 WHERE event_id = ?2")?
        .execute((seq, event_id))?;
    counters.note_head(user, seq);
    Ok(())
}

/// `listen.record`: inserts each listen once, recomputes every second it touched and gives each new or flipped listen a sequence number.
pub(super) fn record(connection: &Connection, inputs: &[ListenInput], ctx: &mut Ctx<'_>) -> Result<Outcome, SyncError> {
    record_as(connection, inputs, Source::Flaccy, ctx)
}

/// Like [`record`] with the `source` the listens are stored under; a caller without a device stores none.
pub(super) fn record_as(connection: &Connection, inputs: &[ListenInput], source: Source, ctx: &mut Ctx<'_>) -> Result<Outcome, SyncError> {
    if !ctx.caller.can_write() {
        return Ok(Outcome::invalid(ErrorCode::Forbidden));
    }
    let mut stamped: BTreeSet<String> = BTreeSet::new();
    let mut seconds: BTreeSet<i64> = BTreeSet::new();
    for input in inputs {
        if insert_listen(connection, &ctx.caller.user, &ctx.caller.device, source, input)? {
            stamped.insert(input.event_id.clone());
            seconds.insert(input.ts);
        }
    }
    if stamped.is_empty() {
        return Ok(Outcome::noop());
    }
    for ts in seconds {
        let events = second_events(connection, &ctx.caller.user, ts)?;
        for flip in recompute_second(&events) {
            set_flag(connection, &flip.event_id, flip.suppressed)?;
            stamped.insert(flip.event_id);
        }
    }
    for event_id in &stamped {
        stamp_seq(connection, ctx.counters, &ctx.caller.user, event_id)?;
    }
    Ok(Outcome {
        status: Status::Applied,
        changed: Vec::new(),
    })
}

fn page_head(connection: &Connection, user: &str) -> Result<i64, SyncError> {
    Ok(connection
        .prepare_cached("SELECT COALESCE(MAX(seq), 0) FROM listens WHERE user_id = ?1")?
        .query_row([user], |row| row.get(0))?)
}

fn into_page(connection: &Connection, user: &str, mut listens: Vec<ListenRow>, limit: usize) -> Result<ListenPage, SyncError> {
    let more = listens.len() > limit;
    listens.truncate(limit);
    Ok(ListenPage {
        listens,
        more,
        head: page_head(connection, user)?,
    })
}

fn clamp_page(limit: usize) -> usize {
    limit.clamp(1, MAX_LISTEN_PAGE)
}

impl Store {
    /// The user's listens that started before `before` (Unix seconds), newest first.
    pub async fn listens_before(&self, user: &UserId, before: i64, limit: usize) -> Result<ListenPage, SyncError> {
        let user = user.to_string();
        let limit = clamp_page(limit);
        self.read(move |connection| {
            let mut statement = connection.prepare_cached(&format!(
                "SELECT {LISTEN_COLUMNS} FROM listens WHERE user_id = ?1 AND ts < ?2 ORDER BY ts DESC, event_id DESC LIMIT ?3"
            ))?;
            let rows = statement
                .query_map((&user, before, limit as i64 + 1), listen_from_row)?
                .collect::<Result<Vec<_>, _>>()?;
            drop(statement);
            into_page(connection, &user, rows, limit)
        })
        .await
    }

    /// The user's listens whose sequence number is greater than `after`, ascending.
    pub async fn listens_after(&self, user: &UserId, after: i64, limit: usize) -> Result<ListenPage, SyncError> {
        let user = user.to_string();
        let limit = clamp_page(limit);
        self.read(move |connection| {
            let mut statement = connection.prepare_cached(&format!(
                "SELECT {LISTEN_COLUMNS} FROM listens WHERE user_id = ?1 AND seq > ?2 ORDER BY seq LIMIT ?3"
            ))?;
            let rows = statement
                .query_map((&user, after, limit as i64 + 1), listen_from_row)?
                .collect::<Result<Vec<_>, _>>()?;
            drop(statement);
            into_page(connection, &user, rows, limit)
        })
        .await
    }

    /// One of the user's listens by event id.
    pub async fn listen(&self, user: &UserId, event_id: &str) -> Result<Option<ListenRow>, SyncError> {
        use rusqlite::OptionalExtension;
        let user = user.to_string();
        let event_id = event_id.to_owned();
        self.read(move |connection| {
            Ok(connection
                .prepare_cached(&format!("SELECT {LISTEN_COLUMNS} FROM listens WHERE user_id = ?1 AND event_id = ?2"))?
                .query_row((&user, &event_id), listen_from_row)
                .optional()?)
        })
        .await
    }
}
