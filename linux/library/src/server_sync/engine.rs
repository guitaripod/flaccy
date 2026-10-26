use super::base;
use super::covers;
use super::error::{Result, SyncError};
use super::import::{self, ImportReport};
use super::listens::{self, ListensPage, ListensRequest};
use super::materialize::{self, ScalarChange};
use super::merge::{self, MergeReport};
use super::meta;
use super::pending;
use super::reset;
use super::sink::ScalarSink;
use super::store::atomically;
use crate::db::Db;
use crate::listen_history::ListenKeyCache;
use flaccy_server_core::wire::{Change, PullResponse, PushRequest, PushResponse};
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::sync::Arc;

const PUSH_MAX_MUTATIONS: usize = 500;
const PUSH_MAX_BYTES: usize = 900_000;
const PULL_LIMIT: usize = 5_000;
const APPLY_CHUNK_ROWS: usize = 5_000;

/// What changed in the app tables, so the GUI can repaint only that.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Dirty {
    /// Sync ids of playlists whose rows or entries were recomputed.
    pub playlists: BTreeSet<String>,
    /// Song keys whose loved flag was recomputed.
    pub loves: BTreeSet<String>,
    /// Scalar keys recomputed, lyrics offsets included.
    pub scalars: BTreeSet<String>,
    /// Plays written or corrected in the history.
    pub listens: usize,
}

impl Dirty {
    /// True when no playlist, love or scalar needs recomputing.
    pub fn is_empty(&self) -> bool {
        self.playlists.is_empty() && self.loves.is_empty() && self.scalars.is_empty()
    }

    /// True when anything at all changed, plays included.
    pub fn changed(&self) -> bool {
        !self.is_empty() || self.listens > 0
    }

    pub(crate) fn add_key(&mut self, key: &str) {
        match key.split_once(':') {
            Some(("playlist", id)) => self.playlists.insert(id.to_owned()),
            Some(("love", id)) => self.loves.insert(id.to_owned()),
            Some(("scalar", id)) => self.scalars.insert(id.to_owned()),
            _ => false,
        };
    }

    pub(crate) fn merge(&mut self, other: Dirty) {
        self.playlists.extend(other.playlists);
        self.loves.extend(other.loves);
        self.scalars.extend(other.scalars);
        self.listens += other.listens;
    }
}

/// The pull the engine wants made next.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PullRequest {
    /// The cursor to pull after.
    pub since: i64,
    /// The page size.
    pub limit: usize,
    /// The instance to report in `instance=`.
    pub instance: String,
    /// The incarnation to send as `Flaccy-Incarnation`, once known.
    pub incarnation: Option<String>,
}

/// Why a push was refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PushFailure {
    /// `409 instance_conflict`.
    InstanceConflict,
    /// `409 mutation_gap`; `have` is the last id the server applied.
    MutationGap {
        /// The last mutation id the server applied for this instance.
        have: i64,
    },
    /// `503 clock_behind`: writes wait.
    ClockBehind,
}

/// What the driver does after a refused push.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushRecovery {
    /// Push again now.
    Resend,
    /// The base was dropped: pull from zero first.
    Reset,
    /// Nothing to do until the server accepts writes.
    Wait,
}

/// What a pull page did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PullOutcome {
    /// The page landed in the base and the app tables.
    Applied {
        /// True when another page follows.
        more: bool,
        /// What was recomputed.
        dirty: Dirty,
    },
    /// The page answered a request the engine has since moved past; ignored.
    Stale,
    /// The server's state was replaced; the base was dropped and the queue renumbered.
    Reset,
}

/// What enrolling returned, as the engine stores it.
#[derive(Clone, Debug)]
pub struct Enrollment {
    /// The server's base URL.
    pub server_url: String,
    /// This device's id on the server.
    pub device: String,
    /// The user id the device writes as.
    pub user: String,
    /// The server incarnation at enrollment.
    pub incarnation: String,
    /// The instance id this install writes under.
    pub instance: String,
    /// The server's clock at enrollment, in milliseconds.
    pub server_time_ms: i64,
}

/// The sans-IO sync state machine. It holds no connection: every method takes the [`Db`] it works on, and everything durable lives in that database.
pub struct Engine {
    sink: Option<Arc<dyn ScalarSink>>,
    keys: ListenKeyCache,
}

impl Default for Engine {
    fn default() -> Self {
        Self::new()
    }
}

impl Engine {
    /// An engine without a scalar sink; scalars other than lyrics offsets are stored but not applied.
    pub fn new() -> Self {
        Engine {
            sink: None,
            keys: ListenKeyCache::default(),
        }
    }

    /// An engine that hands settings, equalizer and wantlist scalars to `sink`.
    pub fn with_sink(sink: Arc<dyn ScalarSink>) -> Self {
        Engine {
            sink: Some(sink),
            keys: ListenKeyCache::default(),
        }
    }

    /// Starts syncing with a server: stores its identity, then queues the local playlists, loves and plays (see [`super::import`]), all in one transaction. Replaces any earlier server.
    pub fn attach(&self, db: &Db, enrollment: &Enrollment) -> Result<ImportReport> {
        let conn = db.connection();
        atomically(conn, || {
            wipe(conn)?;
            meta::set(conn, meta::SERVER_URL, &enrollment.server_url)?;
            meta::set(conn, meta::SERVER_ID, &server_id(&enrollment.server_url))?;
            meta::set(conn, meta::USER, &enrollment.user)?;
            meta::set(conn, meta::INSTANCE, &enrollment.instance)?;
            meta::set(conn, meta::INCARNATION, &enrollment.incarnation)?;
            meta::set_i64(conn, meta::CURSOR, 0)?;
            meta::set_i64(conn, meta::NEXT_ID, 1)?;
            meta::observe_server_time(conn, enrollment.server_time_ms, crate::db::now_ms())?;
            meta::set(conn, meta::DEVICE, &enrollment.device)?;
            let report = import::run(conn)?;
            if report.playlists > 0 || report.loves > 0 {
                merge::expect(conn)?;
            }
            Ok(report)
        })
    }

    /// After the first complete pull of a new connection: what the server already had of this computer's playlists and loves, taken once, before the first push. `None` when nothing merged.
    pub fn take_merge(&self, db: &Db) -> Result<Option<MergeReport>> {
        let conn = db.connection();
        atomically(conn, || merge::capture(conn))
    }

    /// Stops syncing: forgets the server, the base and the queue. Playlists, loves and plays stay as they are.
    pub fn detach(&self, db: &Db) -> Result<()> {
        let conn = db.connection();
        atomically(conn, || wipe(conn))
    }

    /// The next push: the oldest unacknowledged mutations that fit one request, or `None` when there are none.
    pub fn next_push(&self, db: &Db) -> Result<Option<PushRequest>> {
        let conn = db.connection();
        let Some(link) = meta::link(conn)? else {
            return Ok(None);
        };
        let mutations = atomically(conn, || {
            pending::next_batch(conn, PUSH_MAX_MUTATIONS, PUSH_MAX_BYTES)
        })?;
        Ok((!mutations.is_empty()).then_some(PushRequest {
            device: link.device,
            instance: link.instance,
            mutations,
        }))
    }

    /// A push succeeded: every answered mutation is acknowledged and refused ones drop out of the visible state. Nothing is retired; only a pull does that.
    pub fn on_push_response(
        &self,
        db: &Db,
        instance: &str,
        response: &PushResponse,
        local_now_ms: i64,
    ) -> Result<Dirty> {
        let conn = db.connection();
        let (dirty, changes) = atomically(conn, || {
            meta::observe_server_time(conn, response.server_time_ms, local_now_ms)?;
            let current = meta::link(conn)?.ok_or(SyncError::NotConfigured)?;
            if current.instance != instance {
                return Ok((Dirty::default(), Vec::new()));
            }
            let mut dirty = Dirty::default();
            for key in pending::mark_results(conn, &response.results)? {
                dirty.add_key(&key);
            }
            let changes = refresh(conn, &dirty)?;
            Ok((dirty, changes))
        })?;
        self.deliver(changes);
        Ok(dirty)
    }

    /// A push was refused.
    pub fn on_push_error(
        &self,
        db: &Db,
        instance: &str,
        failure: &PushFailure,
    ) -> Result<PushRecovery> {
        let conn = db.connection();
        let current = meta::link(conn)?.ok_or(SyncError::NotConfigured)?;
        if current.instance != instance {
            return Ok(PushRecovery::Resend);
        }
        match failure {
            PushFailure::ClockBehind => Ok(PushRecovery::Wait),
            PushFailure::InstanceConflict => {
                reset::after_instance_conflict(conn)?;
                Ok(PushRecovery::Resend)
            }
            PushFailure::MutationGap { have } => {
                let retired_ahead =
                    pending::lowest_id(conn)?.is_some_and(|lowest| lowest > have + 1);
                if retired_ahead {
                    reset::after_restore(conn, None)?;
                    return Ok(PushRecovery::Reset);
                }
                pending::unack_after(conn, *have)?;
                Ok(PushRecovery::Resend)
            }
        }
    }

    /// The pull to make next.
    pub fn pull_request(&self, db: &Db) -> Result<PullRequest> {
        let conn = db.connection();
        let link = meta::link(conn)?.ok_or(SyncError::NotConfigured)?;
        Ok(PullRequest {
            since: meta::cursor(conn)?,
            limit: PULL_LIMIT,
            instance: link.instance,
            incarnation: link.incarnation,
        })
    }

    /// A pull page arrived. A page for a request the engine has moved past is ignored, a new incarnation resets, otherwise the changes land in the base, the app tables follow, and a final page retires the mutations the server has applied.
    pub fn on_pull_page(
        &mut self,
        db: &Db,
        request: &PullRequest,
        response: &PullResponse,
        local_now_ms: i64,
    ) -> Result<PullOutcome> {
        let conn = db.connection();
        let link = meta::link(conn)?.ok_or(SyncError::NotConfigured)?;
        atomically(conn, || {
            meta::observe_server_time(conn, response.server_time_ms, local_now_ms)
        })?;
        if request.instance != link.instance || request.since != meta::cursor(conn)? {
            return Ok(PullOutcome::Stale);
        }
        if link
            .incarnation
            .as_deref()
            .is_some_and(|known| known != response.incarnation)
        {
            reset::after_restore(conn, Some(&response.incarnation))?;
            return Ok(PullOutcome::Reset);
        }
        let (dirty, changes) = apply_page(conn, response)?;
        self.deliver(changes);
        Ok(PullOutcome::Applied {
            more: response.more,
            dirty,
        })
    }

    /// A pull was refused because its cursor is ahead of the server's log.
    pub fn on_cookie_ahead(&self, db: &Db, request: &PullRequest) -> Result<PullOutcome> {
        let conn = db.connection();
        let link = meta::link(conn)?.ok_or(SyncError::NotConfigured)?;
        if request.instance != link.instance || request.since != meta::cursor(conn)? {
            return Ok(PullOutcome::Stale);
        }
        reset::after_restore(conn, None)?;
        Ok(PullOutcome::Reset)
    }

    /// Any call answered `409 incarnation_changed`: the state is another server's. Resets onto `incarnation`.
    pub fn on_incarnation_changed(&self, db: &Db, incarnation: &str) -> Result<()> {
        reset::after_restore(db.connection(), Some(incarnation))
    }

    /// A listens call was refused because its position is ahead of the server's log: the base is dropped like after a restore.
    pub fn on_listens_cookie_ahead(&self, db: &Db) -> Result<()> {
        reset::after_restore(db.connection(), None)
    }

    /// A push was answered `409 instance_conflict`: moves the queue to a new instance.
    pub fn on_instance_conflict(&self, db: &Db) -> Result<()> {
        reset::after_instance_conflict(db.connection())
    }

    /// The playlist covers named by reseeds that no push has carried yet.
    pub fn unsent_cover_hashes(&self, db: &Db) -> Result<Vec<String>> {
        covers::unsent_cover_hashes(db.connection())
    }

    /// The cover stored on this device whose SHA-256 is `hash`, if any, with its media type.
    pub fn local_cover(&self, db: &Db, hash: &str) -> Result<Option<(&'static str, Vec<u8>)>> {
        Ok(covers::local_blob(db.connection(), hash)?.map(|blob| (blob.mime, blob.bytes)))
    }

    /// Drops a cover this device cannot upload from the reseeds not yet sent.
    pub fn drop_cover(&self, db: &Db, hash: &str) -> Result<()> {
        covers::strip_cover(db.connection(), hash)
    }

    /// Reseeds the server refused that named covers, as `(mutation id, argument hash, blob hashes)`.
    pub fn refused_cover_reseeds(&self, db: &Db) -> Result<Vec<(i64, String, Vec<String>)>> {
        Ok(covers::refused_with_covers(db.connection())?
            .into_iter()
            .map(|refused| (refused.id, refused.args_hash, refused.hashes))
            .collect())
    }

    /// Queues a refused reseed again under a new mutation id.
    pub fn requeue_reseed(&self, db: &Db, id: i64) -> Result<()> {
        let conn = db.connection();
        atomically(conn, || covers::requeue(conn, id))
    }

    /// The `GET /listens` to make next: the history backfill newest first, then the tail.
    pub fn listens_request(&self, db: &Db) -> Result<ListensRequest> {
        listens::next_request(db.connection())
    }

    /// True once the history has been read back to its oldest play and only the tail remains.
    pub fn listens_backfilled(&self, db: &Db) -> Result<bool> {
        listens::backfill_done(db.connection())
    }

    /// A page of plays arrived: stores it, moves the paging state, and answers how many rows changed.
    pub fn on_listens_page(&mut self, db: &Db, page: &ListensPage) -> Result<usize> {
        let conn = db.connection();
        let keys = &mut self.keys;
        atomically(conn, || listens::apply_page(conn, page, keys))
    }

    /// How many mutations wait for the server, refused ones included until a pull retires them.
    pub fn pending_count(&self, db: &Db) -> Result<usize> {
        pending::count(db.connection())
    }

    /// How many mutations no push has acknowledged yet.
    pub fn unsent_count(&self, db: &Db) -> Result<usize> {
        pending::count_unacked(db.connection())
    }

    /// Unix milliseconds of the last complete pull, if any.
    pub fn last_synced_at(&self, db: &Db) -> Result<Option<i64>> {
        meta::get_i64(db.connection(), meta::LAST_SYNCED)
    }

    /// True once a server is configured on this database.
    pub fn is_attached(&self, db: &Db) -> bool {
        meta::enabled(db.connection())
    }

    /// The base URL of the configured server.
    pub fn server_url(&self, db: &Db) -> Result<Option<String>> {
        meta::get(db.connection(), meta::SERVER_URL)
    }

    fn deliver(&self, changes: Vec<ScalarChange>) {
        let Some(sink) = &self.sink else { return };
        for change in changes {
            sink.apply(&change.key, change.value.as_ref());
        }
    }
}

fn refresh(conn: &Connection, dirty: &Dirty) -> Result<Vec<ScalarChange>> {
    match materialize::caller(conn)? {
        Some(caller) => materialize::refresh(conn, dirty, &caller),
        None => Ok(Vec::new()),
    }
}

fn apply_page(conn: &Connection, response: &PullResponse) -> Result<(Dirty, Vec<ScalarChange>)> {
    let mut dirty = Dirty::default();
    let mut scalars = Vec::new();
    let empty: &[Change] = &[];
    let mut chunks: Vec<&[Change]> = response.changes.chunks(APPLY_CHUNK_ROWS).collect();
    if chunks.is_empty() {
        chunks.push(empty);
    }
    let last = chunks.len() - 1;
    for (index, chunk) in chunks.into_iter().enumerate() {
        let (chunk_dirty, changes) = atomically(conn, || {
            let mut chunk_dirty = Dirty::default();
            for change in chunk {
                if let Some(key) = base::put_change(conn, change)? {
                    chunk_dirty.add_key(&key);
                }
            }
            if index == last {
                finish_page(conn, response, &mut chunk_dirty)?;
            }
            let changes = refresh(conn, &chunk_dirty)?;
            Ok((chunk_dirty, changes))
        })?;
        dirty.merge(chunk_dirty);
        scalars.extend(changes);
    }
    Ok((dirty, scalars))
}

fn finish_page(conn: &Connection, response: &PullResponse, dirty: &mut Dirty) -> Result<()> {
    let cursor = match (response.more, response.changes.last()) {
        (true, Some(last)) => last.seq,
        _ => response.head,
    };
    meta::set_i64(conn, meta::CURSOR, cursor)?;
    meta::set(conn, meta::INCARNATION, &response.incarnation)?;
    if !response.more {
        for key in pending::retire(conn, response.last_mutation_id)? {
            dirty.add_key(&key);
        }
        meta::set_i64(conn, meta::LAST_SYNCED, crate::db::now_ms())?;
    }
    Ok(())
}

fn wipe(conn: &Connection) -> Result<()> {
    for table in ["sync_pending", "sync_base", "sync_ghosts", "sync_meta"] {
        conn.execute(&format!("DELETE FROM {table}"), [])?;
    }
    conn.execute("UPDATE playlists SET syncId = NULL", [])?;
    conn.execute("UPDATE playlistTracks SET syncId = NULL", [])?;
    Ok(())
}

fn server_id(url: &str) -> String {
    hex::encode(&Sha256::digest(url.as_bytes())[..8])
}
