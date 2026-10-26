//! The relay's rows in `state.sqlite`: where each connected user stands and the write-ahead queue of plays to submit.

use rusqlite::{Connection, OptionalExtension};

use super::api::ScrobbleEntry;
use crate::security::UserId;
use crate::sync::{Store, SyncError};

const RETAIN_SUBMITTED_SECONDS: i64 = 30 * 86_400;
const ENQUEUE_CHUNK: i64 = 500;

/// A connected user's relay as stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayRecord {
    /// Unix seconds of the connection; plays before it are never submitted.
    pub connected_at: i64,
    /// Why the relay stopped for good until the person reconnects.
    pub paused_reason: Option<String>,
    /// Unix seconds it paused.
    pub paused_at: Option<i64>,
    /// Unix seconds of the last accepted batch.
    pub last_submit: Option<i64>,
    /// The last failure, shown in `lastfm status`.
    pub last_error: Option<String>,
    /// Plays submitted so far.
    pub submitted: i64,
    /// Plays Last.fm refused for good.
    pub rejected: i64,
}

/// A play waiting in the queue.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QueuedPlay {
    /// The listen's event id.
    pub event_id: String,
    /// What to submit.
    pub entry: ScrobbleEntry,
    /// How many times it has been tried.
    pub attempts: u32,
}

fn head_seq(connection: &Connection, user: &str) -> Result<i64, SyncError> {
    Ok(connection.query_row("SELECT COALESCE(MAX(seq), 0) FROM listens WHERE user_id = ?1", [user], |row| row.get(0))?)
}

/// Queues one chunk of new listens; answers how many it read and how many were new to the queue.
fn enqueue_chunk(connection: &Connection, user: &str) -> Result<(usize, usize), SyncError> {
    let after: i64 = connection.query_row("SELECT enqueued_seq FROM lastfm_relay WHERE user_id = ?1", [user], |row| row.get(0))?;
    let mut statement = connection.prepare_cached(
        "SELECT seq, event_id, ts, ref_json, played_s FROM listens
         WHERE user_id = ?1 AND source = 'opensubsonic' AND suppressed = 0 AND seq > ?2 ORDER BY seq LIMIT ?3",
    )?;
    let rows = statement
        .query_map((user, after, ENQUEUE_CHUNK), |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, i64>(2)?, row.get::<_, String>(3)?))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let mut last = after;
    let mut queued = 0;
    for (seq, event_id, ts, song_json) in &rows {
        last = last.max(*seq);
        let song: flaccy_server_core::model::SongRef = serde_json::from_str(song_json)
            .map_err(|error| SyncError::Corrupt(format!("a stored listen's song would not parse: {error}")))?;
        queued += connection.execute(
            "INSERT OR IGNORE INTO lastfm_queue(event_id, user_id, ts, title, artist, album, duration_s) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            (event_id, user, ts, &song.title, &song.artist, &song.album, song.duration_ms / 1000),
        )?;
    }
    if last > after {
        connection.execute("UPDATE lastfm_relay SET enqueued_seq = ?2 WHERE user_id = ?1", (user, last))?;
    }
    Ok((rows.len(), queued))
}

impl Store {
    /// Starts relaying for `user`: only plays recorded after this moment are submitted. Clears a pause.
    pub async fn lastfm_start_relay(&self, user: &UserId, now: i64) -> Result<(), SyncError> {
        let user = user.to_string();
        self.write(move |connection| {
            let head = head_seq(connection, &user)?;
            connection.execute(
                "INSERT INTO lastfm_relay(user_id, connected_seq, enqueued_seq, connected_at) VALUES (?1, ?2, ?2, ?3)
                 ON CONFLICT(user_id) DO UPDATE SET paused_reason = NULL, paused_at = NULL, last_error = NULL",
                (&user, head, now),
            )?;
            Ok::<_, SyncError>(())
        })
        .await
    }

    /// Stops relaying for `user` and forgets the queue; whether there was a relay.
    pub async fn lastfm_stop_relay(&self, user: &UserId) -> Result<bool, SyncError> {
        let user = user.to_string();
        self.write(move |connection| {
            connection.execute("DELETE FROM lastfm_queue WHERE user_id = ?1", [&user])?;
            Ok::<_, SyncError>(connection.execute("DELETE FROM lastfm_relay WHERE user_id = ?1", [&user])? == 1)
        })
        .await
    }

    /// Every user whose relay row exists.
    pub async fn lastfm_relay_users(&self) -> Result<Vec<UserId>, SyncError> {
        self.read(|connection| {
            let mut statement = connection.prepare_cached("SELECT user_id FROM lastfm_relay ORDER BY user_id")?;
            let users = statement.query_map([], |row| row.get::<_, String>(0).map(UserId))?.collect::<Result<Vec<_>, _>>()?;
            Ok::<_, SyncError>(users)
        })
        .await
    }

    /// The relay of `user`, `None` when none is connected.
    pub async fn lastfm_relay_record(&self, user: &UserId) -> Result<Option<RelayRecord>, SyncError> {
        let user = user.to_string();
        self.read(move |connection| {
            Ok::<_, SyncError>(
                connection
                    .prepare_cached(
                        "SELECT connected_at, paused_reason, paused_at, last_submit, last_error, submitted, rejected FROM lastfm_relay WHERE user_id = ?1",
                    )?
                    .query_row([&user], |row| {
                        Ok(RelayRecord {
                            connected_at: row.get(0)?,
                            paused_reason: row.get(1)?,
                            paused_at: row.get(2)?,
                            last_submit: row.get(3)?,
                            last_error: row.get(4)?,
                            submitted: row.get(5)?,
                            rejected: row.get(6)?,
                        })
                    })
                    .optional()?,
            )
        })
        .await
    }

    /// Stops the relay of `user` until a reconnect, saying why.
    pub async fn lastfm_pause_relay(&self, user: &UserId, reason: &str, now: i64) -> Result<(), SyncError> {
        let (user, reason) = (user.to_string(), reason.to_owned());
        self.write(move |connection| {
            connection.execute(
                "UPDATE lastfm_relay SET paused_reason = ?2, paused_at = ?3, last_error = ?2 WHERE user_id = ?1",
                (&user, &reason, now),
            )?;
            Ok::<_, SyncError>(())
        })
        .await
    }

    /// Moves new `opensubsonic` listens of `user` into the queue; answers how many were queued. Also prunes old submitted rows.
    pub async fn lastfm_enqueue_new(&self, user: &UserId, now: i64) -> Result<usize, SyncError> {
        let user = user.to_string();
        self.write(move |connection| {
            let transaction = connection.transaction()?;
            let mut queued = 0;
            loop {
                let (read, added) = enqueue_chunk(&transaction, &user)?;
                queued += added;
                if read < ENQUEUE_CHUNK as usize {
                    break;
                }
            }
            transaction.execute(
                "DELETE FROM lastfm_queue WHERE user_id = ?1 AND done_at IS NOT NULL AND done_at < ?2",
                (&user, now - RETAIN_SUBMITTED_SECONDS),
            )?;
            transaction.commit()?;
            Ok::<_, SyncError>(queued)
        })
        .await
    }

    /// Up to `limit` plays of `user` whose retry time has come, oldest first.
    pub async fn lastfm_due(&self, user: &UserId, now: i64, limit: usize) -> Result<Vec<QueuedPlay>, SyncError> {
        let user = user.to_string();
        self.read(move |connection| {
            let mut statement = connection.prepare_cached(
                "SELECT event_id, title, artist, album, ts, duration_s, attempts FROM lastfm_queue
                 WHERE user_id = ?1 AND done_at IS NULL AND next_attempt_at <= ?2 ORDER BY ts, event_id LIMIT ?3",
            )?;
            let plays = statement
                .query_map((&user, now, limit as i64), |row| {
                    Ok(QueuedPlay {
                        event_id: row.get(0)?,
                        entry: ScrobbleEntry {
                            title: row.get(1)?,
                            artist: row.get(2)?,
                            album: row.get(3)?,
                            timestamp: row.get(4)?,
                            duration_s: row.get(5)?,
                        },
                        attempts: row.get(6)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok::<_, SyncError>(plays)
        })
        .await
    }

    /// Marks `event_ids` as submitted.
    pub async fn lastfm_mark_done(&self, user: &UserId, event_ids: Vec<String>, now: i64) -> Result<(), SyncError> {
        let user = user.to_string();
        self.write(move |connection| {
            let transaction = connection.transaction()?;
            for event_id in &event_ids {
                transaction.execute("UPDATE lastfm_queue SET done_at = ?2, last_error = NULL WHERE event_id = ?1", (event_id, now))?;
            }
            transaction.execute(
                "UPDATE lastfm_relay SET submitted = submitted + ?2, last_submit = ?3, last_error = NULL WHERE user_id = ?1",
                (&user, event_ids.len() as i64, now),
            )?;
            transaction.commit()?;
            Ok::<_, SyncError>(())
        })
        .await
    }

    /// Schedules `event_ids` to be tried again at `retry_at`, counting the attempt.
    pub async fn lastfm_retry_later(&self, user: &UserId, event_ids: Vec<String>, retry_at: i64, error: &str) -> Result<(), SyncError> {
        let (user, error) = (user.to_string(), error.to_owned());
        self.write(move |connection| {
            let transaction = connection.transaction()?;
            for event_id in &event_ids {
                transaction.execute(
                    "UPDATE lastfm_queue SET attempts = attempts + 1, next_attempt_at = ?2, last_error = ?3 WHERE event_id = ?1",
                    (event_id, retry_at, &error),
                )?;
            }
            transaction.execute("UPDATE lastfm_relay SET last_error = ?2 WHERE user_id = ?1", (&user, &error))?;
            transaction.commit()?;
            Ok::<_, SyncError>(())
        })
        .await
    }

    /// Drops a play Last.fm refused for good, keeping a count and the reason.
    pub async fn lastfm_reject(&self, user: &UserId, event_id: &str, error: &str) -> Result<(), SyncError> {
        let (user, event_id, error) = (user.to_string(), event_id.to_owned(), error.to_owned());
        self.write(move |connection| {
            let transaction = connection.transaction()?;
            transaction.execute("DELETE FROM lastfm_queue WHERE event_id = ?1", [&event_id])?;
            transaction.execute("UPDATE lastfm_relay SET rejected = rejected + 1, last_error = ?2 WHERE user_id = ?1", (&user, &error))?;
            transaction.commit()?;
            Ok::<_, SyncError>(())
        })
        .await
    }

    /// How many plays of `user` wait to be submitted.
    pub async fn lastfm_queue_len(&self, user: &UserId) -> Result<i64, SyncError> {
        let user = user.to_string();
        self.read(move |connection| {
            Ok::<_, SyncError>(connection.query_row(
                "SELECT COUNT(*) FROM lastfm_queue WHERE user_id = ?1 AND done_at IS NULL",
                [&user],
                |row| row.get(0),
            )?)
        })
        .await
    }
}
