//! One SQLite connection owned by one thread, and the helpers around it.
//!
//! A [`DbThread`] runs every closure it is given on a dedicated `std` thread in
//! the order it was queued, so a file has exactly one writer and async code
//! never blocks a runtime worker on SQLite. A [`ReadPool`] holds a few
//! read-only connections for queries that must not wait behind the writer.
//! [`migrate`] moves a file forward through numbered migrations and refuses to
//! touch a file written by a newer program.

use std::any::Any;
use std::fmt;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread::JoinHandle;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use rusqlite::backup::Backup;
use rusqlite::{Connection, OpenFlags, Transaction};
use tokio::sync::oneshot;

const BUSY_TIMEOUT: Duration = Duration::from_millis(5000);
const BACKUP_PAGES_PER_STEP: i32 = 256;

/// How hard a file's writes are flushed to disk.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Durability {
    /// `synchronous = FULL`: a committed write survives power loss.
    Full,
    /// `synchronous = NORMAL`: a power loss may lose the last commits but never corrupts the file.
    Normal,
}

impl Durability {
    /// Whether commits must reach the disk itself, not just the drive's cache. macOS `fsync` stops at the cache and
    /// only `F_FULLFSYNC` goes further, which SQLite uses when `fullfsync` is on; Linux's `fsync` already flushes.
    fn flushes_drive_cache(self) -> bool {
        cfg!(target_os = "macos") && self == Durability::Full
    }

    fn synchronous(self) -> &'static str {
        match self {
            Durability::Full => "FULL",
            Durability::Normal => "NORMAL",
        }
    }
}

/// Why a database call failed.
#[derive(Debug)]
pub enum DbError {
    /// The file could not be opened.
    Open { path: PathBuf, source: rusqlite::Error },
    /// SQLite refused a statement.
    Sqlite(rusqlite::Error),
    /// The database thread has stopped, so nothing can run any more.
    Closed,
    /// The closure panicked; the thread and its connection are still alive.
    Panicked(String),
    /// The file was written by a newer program than this one.
    SchemaTooNew { file: PathBuf, found: u32, supported: u32 },
    /// The pre-migration copy could not be written.
    Snapshot { path: PathBuf, message: String },
}

impl fmt::Display for DbError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            DbError::Open { path, source } => write!(
                formatter,
                "Could not open the database {}: {source}. Check that the folder exists and your user may write to it, or set `data_dir` in config.toml to a folder you own.",
                path.display()
            ),
            DbError::Sqlite(source) => write!(formatter, "The database refused a statement: {source}."),
            DbError::Closed => write!(
                formatter,
                "The database thread has stopped, so the request could not run. Restart flaccy-server and check its log for the reason."
            ),
            DbError::Panicked(message) => write!(
                formatter,
                "A database task failed unexpectedly ({message}). The database is unchanged by that task; report this as a bug in flaccy-server."
            ),
            DbError::SchemaTooNew { file, found, supported } => write!(
                formatter,
                "{} is at schema version {found} but this flaccy-server only understands versions up to {supported}. A newer flaccy-server wrote it; install that version again, or restore an older copy of the file from a `.premigrate-<version>.bak` backup beside it.",
                file.display()
            ),
            DbError::Snapshot { path, message } => write!(
                formatter,
                "Could not copy the database to {} before upgrading it: {message}. Free disk space or fix the folder permissions, then start flaccy-server again; nothing was changed.",
                path.display()
            ),
        }
    }
}

impl std::error::Error for DbError {}

impl From<rusqlite::Error> for DbError {
    fn from(source: rusqlite::Error) -> Self {
        DbError::Sqlite(source)
    }
}

type Job = Box<dyn FnOnce(&mut Connection) + Send>;

enum Message {
    Job(Job),
    Close(oneshot::Sender<Result<(), DbError>>),
}

/// A connection living on its own thread. Clones share the same thread.
#[derive(Clone)]
pub struct DbThread {
    sender: mpsc::Sender<Message>,
    worker: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl DbThread {
    /// Opens `path` (creating it when missing) on a new thread with the pragmas `durability` asks for.
    pub async fn open(path: &Path, durability: Durability) -> Result<Self, DbError> {
        let (sender, receiver) = mpsc::channel::<Message>();
        let (ready_sender, ready) = oneshot::channel();
        let file = path.to_path_buf();
        let name = format!(
            "flaccy-db-{}",
            path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default()
        );
        let worker = std::thread::Builder::new()
            .name(name)
            .spawn(move || match open_connection(&file, durability) {
                Ok(connection) => {
                    let _ = ready_sender.send(Ok(()));
                    serve(connection, receiver);
                }
                Err(error) => {
                    let _ = ready_sender.send(Err(error));
                }
            })
            .map_err(|_| DbError::Closed)?;
        ready.await.map_err(|_| DbError::Closed)??;
        Ok(Self {
            sender,
            worker: Arc::new(Mutex::new(Some(worker))),
        })
    }

    /// Runs `work` on the database thread after everything queued before it.
    ///
    /// A panic inside `work` comes back as [`DbError::Panicked`] and the thread
    /// carries on. Dropping the returned future does not cancel `work`.
    pub async fn call<T, E, F>(&self, work: F) -> Result<T, DbError>
    where
        F: FnOnce(&mut Connection) -> Result<T, E> + Send + 'static,
        T: Send + 'static,
        E: Into<DbError>,
    {
        let (reply, receive) = oneshot::channel();
        let job: Job = Box::new(move |connection| {
            let outcome = match catch_unwind(AssertUnwindSafe(|| work(connection))) {
                Ok(result) => result.map_err(Into::into),
                Err(payload) => Err(DbError::Panicked(describe_panic(payload))),
            };
            let _ = reply.send(outcome);
        });
        self.sender.send(Message::Job(job)).map_err(|_| DbError::Closed)?;
        receive.await.map_err(|_| DbError::Closed)?
    }

    /// Finishes everything queued, closes the connection and joins the thread.
    /// Closing twice is harmless.
    pub async fn close(&self) -> Result<(), DbError> {
        let (reply, receive) = oneshot::channel();
        let outcome = match self.sender.send(Message::Close(reply)) {
            Ok(()) => receive.await.unwrap_or(Ok(())),
            Err(_) => Ok(()),
        };
        let worker = self.worker.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
        if let Some(worker) = worker {
            let _ = tokio::task::spawn_blocking(move || worker.join()).await;
        }
        outcome
    }
}

fn serve(mut connection: Connection, receiver: mpsc::Receiver<Message>) {
    while let Ok(message) = receiver.recv() {
        match message {
            Message::Job(job) => job(&mut connection),
            Message::Close(reply) => {
                let result = connection.close().map_err(|(_, source)| DbError::Sqlite(source));
                let _ = reply.send(result);
                return;
            }
        }
    }
}

fn open_connection(path: &Path, durability: Durability) -> Result<Connection, DbError> {
    let open_error = |source| DbError::Open { path: path.to_path_buf(), source };
    let connection = Connection::open(path).map_err(open_error)?;
    connection.busy_timeout(BUSY_TIMEOUT).map_err(open_error)?;
    connection
        .pragma_update_and_check(None, "journal_mode", "WAL", |row| row.get::<_, String>(0))
        .map_err(open_error)?;
    connection
        .pragma_update(None, "synchronous", durability.synchronous())
        .map_err(open_error)?;
    if durability.flushes_drive_cache() {
        connection.pragma_update(None, "fullfsync", "ON").map_err(open_error)?;
        connection.pragma_update(None, "checkpoint_fullfsync", "ON").map_err(open_error)?;
    }
    connection.pragma_update(None, "foreign_keys", "ON").map_err(open_error)?;
    Ok(connection)
}

fn describe_panic(payload: Box<dyn Any + Send>) -> String {
    if let Some(message) = payload.downcast_ref::<&str>() {
        (*message).to_string()
    } else if let Some(message) = payload.downcast_ref::<String>() {
        message.clone()
    } else {
        "no message".to_string()
    }
}

/// Read-only connections to one file, used round-robin, for queries that must not queue behind the writer.
#[derive(Clone)]
pub struct ReadPool {
    connections: Arc<Vec<Mutex<Option<Connection>>>>,
    next: Arc<AtomicUsize>,
}

impl ReadPool {
    /// Connections a pool opens unless told otherwise.
    pub const DEFAULT_SIZE: usize = 4;

    /// Opens `size` read-only connections to `path`, which must already exist.
    pub async fn open(path: &Path, size: usize) -> Result<Self, DbError> {
        let file = path.to_path_buf();
        let connections = tokio::task::spawn_blocking(move || {
            (0..size.max(1)).map(|_| open_reader(&file).map(|connection| Mutex::new(Some(connection)))).collect::<Result<Vec<_>, _>>()
        })
        .await
        .map_err(|error| DbError::Panicked(error.to_string()))??;
        Ok(Self {
            connections: Arc::new(connections),
            next: Arc::new(AtomicUsize::new(0)),
        })
    }

    /// Runs `work` on the next connection in turn, on a blocking thread.
    pub async fn call<T, E, F>(&self, work: F) -> Result<T, DbError>
    where
        F: FnOnce(&Connection) -> Result<T, E> + Send + 'static,
        T: Send + 'static,
        E: Into<DbError> + Send + 'static,
    {
        let pool = self.clone();
        tokio::task::spawn_blocking(move || {
            let slot = pool.next.fetch_add(1, Ordering::Relaxed) % pool.connections.len();
            let guard = pool.connections[slot].lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            let Some(connection) = guard.as_ref() else {
                return Err(DbError::Closed);
            };
            match catch_unwind(AssertUnwindSafe(|| work(connection))) {
                Ok(result) => result.map_err(Into::into),
                Err(payload) => Err(DbError::Panicked(describe_panic(payload))),
            }
        })
        .await
        .map_err(|error| DbError::Panicked(error.to_string()))?
    }
}

impl ReadPool {
    /// Waits for reads in progress, then closes every connection; later calls fail with [`DbError::Closed`].
    /// Closing the readers lets the writer's own close delete the write-ahead log.
    pub async fn close(&self) {
        let pool = self.clone();
        let _ = tokio::task::spawn_blocking(move || {
            for slot in pool.connections.iter() {
                let connection = slot.lock().unwrap_or_else(|poisoned| poisoned.into_inner()).take();
                drop(connection);
            }
        })
        .await;
    }
}

fn open_reader(path: &Path) -> Result<Connection, DbError> {
    let open_error = |source| DbError::Open { path: path.to_path_buf(), source };
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)
        .map_err(open_error)?;
    connection.busy_timeout(BUSY_TIMEOUT).map_err(open_error)?;
    connection.pragma_update(None, "query_only", "ON").map_err(open_error)?;
    Ok(connection)
}

/// One forward step of a file's schema.
pub struct Migration {
    /// The version the file has once this step has run. Versions start at 1.
    pub version: u32,
    /// Changes the schema; it runs inside a transaction that also records the version.
    pub apply: fn(&Transaction<'_>) -> rusqlite::Result<()>,
}

/// Brings `connection`, the open handle of `file`, up to the newest of `migrations`; returns the version it ends at.
///
/// An empty file is just migrated. A file with data is copied to
/// `<name>.premigrate-<version>.bak` first, and a file whose version is newer
/// than every migration is refused untouched.
pub fn migrate(connection: &mut Connection, file: &Path, migrations: &[Migration]) -> Result<u32, DbError> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS schema_migrations(version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL)",
    )?;
    let current = schema_version(connection)?;
    let latest = migrations.iter().map(|migration| migration.version).max().unwrap_or(0);
    if current > latest {
        return Err(DbError::SchemaTooNew {
            file: file.to_path_buf(),
            found: current,
            supported: latest,
        });
    }
    let mut pending: Vec<&Migration> = migrations.iter().filter(|migration| migration.version > current).collect();
    pending.sort_by_key(|migration| migration.version);
    if pending.is_empty() {
        return Ok(current);
    }
    if current > 0 {
        snapshot_before_migrate(connection, file, current)?;
    }
    for migration in pending {
        let step = connection.transaction()?;
        (migration.apply)(&step)?;
        step.execute(
            "INSERT INTO schema_migrations(version, applied_at) VALUES (?1, ?2)",
            (migration.version, unix_millis()),
        )?;
        step.commit()?;
    }
    Ok(latest)
}

/// The highest version recorded in `schema_migrations`, 0 for a file nothing has migrated yet.
pub fn schema_version(connection: &Connection) -> Result<u32, DbError> {
    connection
        .query_row("SELECT COALESCE(MAX(version), 0) FROM schema_migrations", [], |row| row.get(0))
        .map_err(DbError::from)
}

/// Copies the database behind `connection` to `<name>.premigrate-<version>.bak` beside `file`, with SQLite's
/// online backup so the copy is consistent while the file is in use. Returns the copy's path.
pub fn snapshot_before_migrate(connection: &Connection, file: &Path, version: u32) -> Result<PathBuf, DbError> {
    let name = file.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let copy = file.with_file_name(format!("{name}.premigrate-{version}.bak"));
    let failed = |message: String| DbError::Snapshot { path: copy.clone(), message };
    if copy.exists() {
        std::fs::remove_file(&copy).map_err(|error| failed(error.to_string()))?;
    }
    let mut target = Connection::open(&copy).map_err(|error| failed(error.to_string()))?;
    {
        let backup = Backup::new(connection, &mut target).map_err(|error| failed(error.to_string()))?;
        backup
            .run_to_completion(BACKUP_PAGES_PER_STEP, Duration::ZERO, None)
            .map_err(|error| failed(error.to_string()))?;
    }
    drop(target);
    restrict_to_owner(&copy).map_err(|error| failed(error.to_string()))?;
    Ok(copy)
}

/// Sets `path` to mode 0600 on Unix and does nothing elsewhere.
pub fn restrict_to_owner(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

fn unix_millis() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::AtomicU32;

    static NEXT_DIR: AtomicU32 = AtomicU32::new(0);

    struct TempDir(PathBuf);

    impl TempDir {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "flaccy-dbthread-{}-{}",
                std::process::id(),
                NEXT_DIR.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn file(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn pragma(connection: &Connection, name: &str) -> String {
        connection
            .query_row(&format!("PRAGMA {name}"), [], |row| row.get::<_, rusqlite::types::Value>(0))
            .map(|value| match value {
                rusqlite::types::Value::Text(text) => text,
                rusqlite::types::Value::Integer(number) => number.to_string(),
                other => format!("{other:?}"),
            })
            .unwrap()
    }

    #[tokio::test]
    async fn opening_applies_the_pragmas_of_each_durability() {
        let dir = TempDir::new();
        let full = DbThread::open(&dir.file("full.sqlite"), Durability::Full).await.unwrap();
        let settings = full
            .call(|connection| {
                Ok::<_, DbError>((
                    pragma(connection, "journal_mode"),
                    pragma(connection, "synchronous"),
                    pragma(connection, "foreign_keys"),
                    pragma(connection, "busy_timeout"),
                ))
            })
            .await
            .unwrap();
        assert_eq!(settings, ("wal".into(), "2".into(), "1".into(), "5000".into()));
        let flushes = full.call(|connection| Ok::<_, DbError>((pragma(connection, "fullfsync"), pragma(connection, "checkpoint_fullfsync")))).await.unwrap();
        let expected = if cfg!(target_os = "macos") { "1" } else { "0" };
        assert_eq!(flushes, (expected.to_string(), expected.to_string()));
        let normal = DbThread::open(&dir.file("normal.sqlite"), Durability::Normal).await.unwrap();
        let synchronous = normal.call(|connection| Ok::<_, DbError>(pragma(connection, "synchronous"))).await.unwrap();
        assert_eq!(synchronous, "1");
        let normal_flushes = normal.call(|connection| Ok::<_, DbError>(pragma(connection, "fullfsync"))).await.unwrap();
        assert_eq!(normal_flushes, "0");
        full.close().await.unwrap();
        normal.close().await.unwrap();
    }

    #[tokio::test]
    async fn a_panicking_closure_is_reported_and_the_thread_survives() {
        let dir = TempDir::new();
        let db = DbThread::open(&dir.file("panic.sqlite"), Durability::Normal).await.unwrap();
        let failed = db.call(|_| -> Result<(), DbError> { panic!("boom") }).await;
        assert!(matches!(failed, Err(DbError::Panicked(ref message)) if message == "boom"));
        let answer = db.call(|connection| connection.query_row("SELECT 41 + 1", [], |row| row.get::<_, i64>(0))).await;
        assert_eq!(answer.unwrap(), 42);
        db.close().await.unwrap();
    }

    #[tokio::test]
    async fn calls_run_in_the_order_they_were_queued() {
        let dir = TempDir::new();
        let db = DbThread::open(&dir.file("order.sqlite"), Durability::Normal).await.unwrap();
        db.call(|connection| connection.execute_batch("CREATE TABLE seen(n INTEGER)")).await.unwrap();
        let mut pending = Vec::new();
        for number in 0..200i64 {
            let handle = db.clone();
            pending.push(tokio::spawn(async move {
                handle.call(move |connection| connection.execute("INSERT INTO seen(n) VALUES (?1)", [number])).await
            }));
            tokio::task::yield_now().await;
        }
        for task in pending {
            task.await.unwrap().unwrap();
        }
        let rows = db
            .call(|connection| {
                let mut statement = connection.prepare("SELECT n FROM seen ORDER BY rowid")?;
                let rows = statement.query_map([], |row| row.get::<_, i64>(0))?.collect::<Result<Vec<_>, _>>();
                rows
            })
            .await
            .unwrap();
        assert_eq!(rows, (0..200).collect::<Vec<_>>());
        db.close().await.unwrap();
    }

    #[tokio::test]
    async fn ten_thousand_sequential_writes_all_land() {
        let dir = TempDir::new();
        let db = DbThread::open(&dir.file("bulk.sqlite"), Durability::Normal).await.unwrap();
        db.call(|connection| connection.execute_batch("CREATE TABLE bulk(n INTEGER PRIMARY KEY)")).await.unwrap();
        for number in 0..10_000i64 {
            db.call(move |connection| connection.execute("INSERT INTO bulk(n) VALUES (?1)", [number])).await.unwrap();
        }
        let (count, sum) = db
            .call(|connection| connection.query_row("SELECT COUNT(*), SUM(n) FROM bulk", [], |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?))))
            .await
            .unwrap();
        assert_eq!((count, sum), (10_000, 49_995_000));
        db.close().await.unwrap();
    }

    #[tokio::test]
    async fn close_finishes_queued_work_and_later_calls_fail() {
        let dir = TempDir::new();
        let db = DbThread::open(&dir.file("close.sqlite"), Durability::Normal).await.unwrap();
        db.call(|connection| connection.execute_batch("CREATE TABLE t(n INTEGER)")).await.unwrap();
        db.close().await.unwrap();
        db.close().await.unwrap();
        let after = db.call(|_| Ok::<_, DbError>(())).await;
        assert!(matches!(after, Err(DbError::Closed)));
    }

    #[tokio::test]
    async fn the_read_pool_reads_what_the_writer_wrote_and_cannot_write() {
        let dir = TempDir::new();
        let path = dir.file("pool.sqlite");
        let db = DbThread::open(&path, Durability::Normal).await.unwrap();
        db.call(|connection| connection.execute_batch("CREATE TABLE t(n INTEGER); INSERT INTO t VALUES (7)")).await.unwrap();
        let pool = ReadPool::open(&path, ReadPool::DEFAULT_SIZE).await.unwrap();
        for _ in 0..9 {
            let value = pool.call(|connection| connection.query_row("SELECT n FROM t", [], |row| row.get::<_, i64>(0))).await.unwrap();
            assert_eq!(value, 7);
        }
        let write = pool.call(|connection| connection.execute("INSERT INTO t VALUES (8)", [])).await;
        assert!(matches!(write, Err(DbError::Sqlite(_))));
        let panicked = pool.call(|_| -> Result<(), DbError> { panic!("reader") }).await;
        assert!(matches!(panicked, Err(DbError::Panicked(_))));
        db.close().await.unwrap();
    }

    fn create_first(step: &Transaction<'_>) -> rusqlite::Result<()> {
        step.execute_batch("CREATE TABLE first(n INTEGER); INSERT INTO first VALUES (1)")
    }

    fn create_second(step: &Transaction<'_>) -> rusqlite::Result<()> {
        step.execute_batch("CREATE TABLE second(n INTEGER)")
    }

    #[test]
    fn a_migration_from_version_one_snapshots_first() {
        let dir = TempDir::new();
        let path = dir.file("data.sqlite");
        let mut connection = Connection::open(&path).unwrap();
        let first = [Migration { version: 1, apply: create_first }];
        assert_eq!(migrate(&mut connection, &path, &first).unwrap(), 1);
        assert!(!dir.file("data.sqlite.premigrate-0.bak").exists());
        let both = [Migration { version: 1, apply: create_first }, Migration { version: 2, apply: create_second }];
        assert_eq!(migrate(&mut connection, &path, &both).unwrap(), 2);
        let copy = Connection::open(dir.file("data.sqlite.premigrate-1.bak")).unwrap();
        assert_eq!(schema_version(&copy).unwrap(), 1);
        assert_eq!(copy.query_row("SELECT n FROM first", [], |row| row.get::<_, i64>(0)).unwrap(), 1);
        assert!(copy.prepare("SELECT n FROM second").is_err());
        assert_eq!(schema_version(&connection).unwrap(), 2);
        assert_eq!(migrate(&mut connection, &path, &both).unwrap(), 2);
    }

    #[test]
    fn a_newer_file_is_refused_with_its_name_and_versions() {
        let dir = TempDir::new();
        let path = dir.file("future.sqlite");
        let mut connection = Connection::open(&path).unwrap();
        let first = [Migration { version: 1, apply: create_first }];
        migrate(&mut connection, &path, &first).unwrap();
        connection.execute("INSERT INTO schema_migrations(version, applied_at) VALUES (99, 0)", []).unwrap();
        let refused = migrate(&mut connection, &path, &first).unwrap_err().to_string();
        assert!(refused.contains("future.sqlite") && refused.contains("99") && refused.contains("up to 1"), "{refused}");
        assert!(refused.contains("restore"), "{refused}");
    }

    #[test]
    fn a_failing_step_rolls_back_and_leaves_the_version_alone() {
        fn broken(step: &Transaction<'_>) -> rusqlite::Result<()> {
            step.execute_batch("CREATE TABLE half(n INTEGER); SELECT nope FROM nowhere")
        }
        let dir = TempDir::new();
        let path = dir.file("broken.sqlite");
        let mut connection = Connection::open(&path).unwrap();
        let steps = [Migration { version: 1, apply: create_first }, Migration { version: 2, apply: broken }];
        assert!(migrate(&mut connection, &path, &steps).is_err());
        assert_eq!(schema_version(&connection).unwrap(), 1);
        assert!(connection.prepare("SELECT n FROM half").is_err());
    }
}
