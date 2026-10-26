//! The sync state store: `state.sqlite` behind a cheap-to-clone [`Store`].
//!
//! It implements `docs/server/PROTOCOL.md` sections 6 and 10.2 over SQLite with
//! the same pure code (`flaccy-server-core`) the in-memory reference server
//! runs, so the two answer identically. Writes go through the single
//! [`DbThread`](crate::dbthread::DbThread) writer; reads use a
//! [`ReadPool`](crate::dbthread::ReadPool). Every commit that changes a scope
//! is announced on [`Store::subscribe`].

mod apply;
mod blobs;
mod changes;
mod doc;
mod entity;
mod listens;
pub mod migrate_legacy;
mod maintenance;
mod meta;
mod pull;
mod push;
mod reseed;
mod rest;
mod rest_read;
mod rows;
mod schema;
mod server_writes;
mod singles;
mod stats;

use std::fmt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

use rusqlite::Connection;
use tokio::sync::broadcast;

use crate::dbthread::{self, DbError, DbThread, Durability, ReadPool};
use crate::security::{self, Clock};

pub use blobs::{Blob, BlobError, BlobStored, MAX_BLOB_BYTES};
pub use listens::{ListenPage, ListenRow, MAX_LISTEN_PAGE};
pub use maintenance::{Tidied, KEEP_DAYS, KEEP_PER_DEVICE};
pub use pull::{PullError, DEFAULT_PULL_LIMIT, MAX_PULL_LIMIT};
pub use push::{PushError, MAX_BATCH};
pub use rest::RestWriteError;
pub use rest_read::{PlayStat, UserState};
pub use schema::CURRENT_VERSION;
pub use server_writes::ServerListen;
pub use stats::SyncStats;

/// The scope of household playlists and their entries in the `changes` table.
pub const HOUSEHOLD_SCOPE: &str = "household";

const POKE_BACKLOG: usize = 256;
const STATEMENT_CACHE: usize = 128;

/// Receives `(device id, new name)` after a `device.rename` mutation commits.
pub type DeviceRenamer = Arc<dyn Fn(&str, &str) + Send + Sync>;

/// A commit changed `scope`; its highest change sequence number is now `head`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Poke {
    /// The user id, or [`HOUSEHOLD_SCOPE`].
    pub scope: String,
    /// The highest sequence number the commit assigned in the scope.
    pub head: i64,
}

/// Why a store operation failed.
#[derive(Debug)]
pub enum SyncError {
    /// The database failed or is gone.
    Storage(DbError),
    /// A stored value could not be read back.
    Corrupt(String),
}

impl fmt::Display for SyncError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SyncError::Storage(source) => write!(formatter, "{source}"),
            SyncError::Corrupt(what) => write!(
                formatter,
                "state.sqlite holds a value this build cannot read ({what}). Restore the file from a backup or from the .premigrate copy beside it, and report this as a bug in flaccy-server."
            ),
        }
    }
}

impl std::error::Error for SyncError {}

impl From<DbError> for SyncError {
    fn from(source: DbError) -> Self {
        SyncError::Storage(source)
    }
}

impl From<rusqlite::Error> for SyncError {
    fn from(source: rusqlite::Error) -> Self {
        SyncError::Storage(DbError::Sqlite(source))
    }
}

struct Inner {
    db: DbThread,
    readers: ReadPool,
    clock: Clock,
    incarnation: RwLock<String>,
    pokes: broadcast::Sender<Poke>,
    renamer: RwLock<Option<DeviceRenamer>>,
    path: PathBuf,
}

/// A handle on `state.sqlite`. Clones share one writer thread and one read pool.
#[derive(Clone)]
pub struct Store {
    inner: Arc<Inner>,
}

impl Store {
    /// Opens (creating and migrating when needed) `path` with `synchronous = FULL`.
    pub async fn open(path: &Path, incarnation: String) -> Result<Self, SyncError> {
        Self::open_with(path, incarnation, security::system_clock(), Durability::Full).await
    }

    /// Like [`Store::open`] with a clock the caller controls, for tests.
    pub async fn open_with_clock(path: &Path, incarnation: String, clock: Clock) -> Result<Self, SyncError> {
        Self::open_with(path, incarnation, clock, Durability::Full).await
    }

    /// Like [`Store::open_with_clock`] with a chosen durability, for tests that trade fsyncs for speed.
    pub async fn open_with(
        path: &Path,
        incarnation: String,
        clock: Clock,
        durability: Durability,
    ) -> Result<Self, SyncError> {
        security::prepare_private_file(path).map_err(|error| {
            SyncError::Storage(DbError::Snapshot {
                path: path.to_path_buf(),
                message: error.to_string(),
            })
        })?;
        let db = DbThread::open(path, durability).await?;
        let file = path.to_path_buf();
        let initialised = db.call(move |connection| Ok::<_, DbError>(initialise(connection, &file))).await;
        if let Err(error) = initialised.map_err(SyncError::from).and_then(|inner| inner) {
            let _ = db.close().await;
            return Err(error);
        }
        let readers = ReadPool::open(path, ReadPool::DEFAULT_SIZE).await?;
        security::restrict_database_files(path);
        let (pokes, _) = broadcast::channel(POKE_BACKLOG);
        Ok(Self {
            inner: Arc::new(Inner {
                db,
                readers,
                clock,
                incarnation: RwLock::new(incarnation),
                pokes,
                renamer: RwLock::new(None),
                path: path.to_path_buf(),
            }),
        })
    }

    /// Finishes queued work, empties the write-ahead log, closes the readers and then the writer, which leaves no `-wal` file behind.
    pub async fn close(&self) -> Result<(), SyncError> {
        let emptied = self.inner.db.call(|connection| connection.execute_batch("PRAGMA wal_checkpoint(TRUNCATE)")).await;
        self.inner.readers.close().await;
        let closed = self.inner.db.close().await;
        match emptied {
            Ok(()) | Err(DbError::Closed) => Ok(closed?),
            Err(error) => Err(error.into()),
        }
    }

    /// The server incarnation this store answers pulls with.
    pub fn incarnation(&self) -> String {
        self.inner.incarnation.read().unwrap_or_else(|poisoned| poisoned.into_inner()).clone()
    }

    /// Replaces the incarnation, as after restoring from a backup.
    pub fn set_incarnation(&self, incarnation: String) {
        *self.inner.incarnation.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = incarnation;
    }

    /// Sets the function that names a device after a `device.rename` mutation.
    pub fn set_device_renamer(&self, renamer: DeviceRenamer) {
        *self.inner.renamer.write().unwrap_or_else(|poisoned| poisoned.into_inner()) = Some(renamer);
    }

    /// A receiver of [`Poke`]s, one per scope per commit that changed it.
    pub fn subscribe(&self) -> broadcast::Receiver<Poke> {
        self.inner.pokes.subscribe()
    }

    /// The current time in Unix milliseconds, from the store's clock.
    pub fn now_ms(&self) -> i64 {
        (self.inner.clock)()
    }

    pub(crate) fn file(&self) -> &Path {
        &self.inner.path
    }

    pub(crate) async fn write<T, E, F>(&self, work: F) -> Result<T, E>
    where
        F: FnOnce(&mut Connection) -> Result<T, E> + Send + 'static,
        T: Send + 'static,
        E: From<SyncError> + Send + 'static,
    {
        match self.inner.db.call(move |connection| Ok::<_, DbError>(work(connection))).await {
            Ok(inner) => inner,
            Err(error) => Err(E::from(SyncError::from(error))),
        }
    }

    pub(crate) async fn read<T, E, F>(&self, work: F) -> Result<T, E>
    where
        F: FnOnce(&Connection) -> Result<T, E> + Send + 'static,
        T: Send + 'static,
        E: From<SyncError> + Send + 'static,
    {
        match self.inner.readers.call(move |connection| Ok::<_, DbError>(work(connection))).await {
            Ok(inner) => inner,
            Err(error) => Err(E::from(SyncError::from(error))),
        }
    }
}

fn initialise(connection: &mut Connection, file: &Path) -> Result<(), SyncError> {
    connection.set_prepared_statement_cache_capacity(STATEMENT_CACHE);
    let version = dbthread::migrate(connection, file, schema::MIGRATIONS)?;
    meta::seed(connection, version)
}
