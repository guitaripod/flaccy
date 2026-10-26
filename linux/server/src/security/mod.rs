//! Who may use the server: users, enrolled devices, API keys, the audit trail
//! and the Last.fm sessions, all kept in `security.sqlite`.
//!
//! [`Store`] is a cheap handle over one [`DbThread`]. Every secret (device
//! token, enrollment code, API key) is shown once when it is made and only its
//! SHA-256 is stored. Every mutation writes its audit entry in the same
//! transaction.

use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use rusqlite::{Connection, OptionalExtension, Transaction, TransactionBehavior};

use crate::dbthread::{self, DbError, DbThread, Durability};

macro_rules! string_id {
    ($(#[$doc:meta])* $name:ident) => {
        $(#[$doc])*
        #[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub struct $name(pub String);

        impl $name {
            /// The id as text.
            pub fn as_str(&self) -> &str {
                &self.0
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl From<String> for $name {
            fn from(value: String) -> Self {
                Self(value)
            }
        }

        impl rusqlite::types::FromSql for $name {
            fn column_result(value: rusqlite::types::ValueRef<'_>) -> rusqlite::types::FromSqlResult<Self> {
                String::column_result(value).map(Self)
            }
        }

        impl rusqlite::types::ToSql for $name {
            fn to_sql(&self) -> rusqlite::Result<rusqlite::types::ToSqlOutput<'_>> {
                self.0.to_sql()
            }
        }
    };
}

pub mod audit;
pub mod devices;
pub mod enroll;
pub mod keys;
pub mod lastfm;
mod maintenance;
pub mod rest;
pub mod schema;
pub mod users;

pub use audit::VerifyError;
pub use devices::{Device, Principal};
pub use enroll::{EnrollError, Enrolled};
pub use keys::{ApiKey, LegacyImport};
pub use lastfm::LastfmSession;
pub use users::{Role, User};

string_id! {
    /// The id of a user.
    UserId
}
string_id! {
    /// The id of an enrolled device.
    DeviceId
}
string_id! {
    /// The id of an API key.
    KeyId
}

const MAX_NAME_CHARS: usize = 80;
const INCARNATION_KEY: &str = "incarnation";
const SERVER_ID_KEY: &str = "server_id";
const SCHEMA_KEY: &str = "schema";

/// Milliseconds since the Unix epoch, as tests and the server both supply it.
pub type Clock = Arc<dyn Fn() -> i64 + Send + Sync>;

/// The wall clock.
pub fn system_clock() -> Clock {
    Arc::new(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|elapsed| elapsed.as_millis() as i64)
            .unwrap_or(0)
    })
}

/// Why a security operation failed.
#[derive(Debug)]
pub enum SecurityError {
    /// The database failed or is gone.
    Storage(DbError),
    /// No user has that id.
    UnknownUser(UserId),
    /// No device has that id.
    UnknownDevice(DeviceId),
    /// No API key has that id.
    UnknownKey(KeyId),
    /// Another user, or another key of the same user, already has this name.
    NameTaken(String),
    /// The name is empty, too long or has control characters.
    InvalidName(&'static str),
    /// The change would leave the server without an admin.
    LastAdmin,
    /// No admin exists yet to own the imported keys.
    NoOwner,
    /// The operating system could not supply random bytes.
    Randomness(String),
}

impl fmt::Display for SecurityError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SecurityError::Storage(source) => write!(formatter, "{source}"),
            SecurityError::UnknownUser(id) => write!(
                formatter,
                "No user has the id {id}. List the users with `flaccy-server user list` and use one of those ids."
            ),
            SecurityError::UnknownDevice(id) => write!(
                formatter,
                "No device has the id {id}. List the devices with `flaccy-server device list` and use one of those ids."
            ),
            SecurityError::UnknownKey(id) => write!(formatter, "No API key has the id {id}. List the keys and use one of those ids."),
            SecurityError::NameTaken(name) => write!(
                formatter,
                "The name '{name}' is already taken. Pick another name, or revoke the one that has it first."
            ),
            SecurityError::InvalidName(reason) => write!(formatter, "That name does not work: it {reason}. Use 1 to 80 printable characters."),
            SecurityError::LastAdmin => write!(
                formatter,
                "That would leave the server without an admin. Make another user an admin first, then change this one."
            ),
            SecurityError::NoOwner => write!(
                formatter,
                "There is no admin to own the keys yet. Create the owner first with `flaccy-server user add <name> --role admin`, then import again."
            ),
            SecurityError::Randomness(message) => write!(
                formatter,
                "The operating system could not supply random bytes ({message}). Check that /dev/urandom is readable, then try again."
            ),
        }
    }
}

impl std::error::Error for SecurityError {}

impl From<DbError> for SecurityError {
    fn from(source: DbError) -> Self {
        SecurityError::Storage(source)
    }
}

impl From<rusqlite::Error> for SecurityError {
    fn from(source: rusqlite::Error) -> Self {
        SecurityError::Storage(DbError::Sqlite(source))
    }
}

/// When and by whom one mutation happens, handed to its closure on the database thread.
pub(crate) struct Stamp {
    pub at: i64,
    actor: Option<Arc<str>>,
}

impl Stamp {
    /// Appends the audit entry of this mutation to the chain in `connection`'s open transaction.
    pub fn record(&self, connection: &Connection, action: &str, detail: &str) -> rusqlite::Result<()> {
        audit::append(connection, self.at, self.actor.as_deref(), action, detail)
    }
}

/// State that lives only in memory: the enrollment throttle and the last-seen coalescing.
struct Memory {
    enroll_throttle: Mutex<enroll::EnrollThrottle>,
    last_seen: Mutex<HashMap<DeviceId, i64>>,
}

/// A handle on `security.sqlite`. Clones share one database thread.
#[derive(Clone)]
pub struct Store {
    db: DbThread,
    clock: Clock,
    memory: Arc<Memory>,
    actor: Option<Arc<str>>,
}

impl Store {
    /// Opens (creating and migrating when needed) the database at `path`.
    pub async fn open(path: &Path) -> Result<Self, SecurityError> {
        Self::open_with_clock(path, system_clock()).await
    }

    /// Like [`Store::open`] with a clock the caller controls, for tests.
    pub async fn open_with_clock(path: &Path, clock: Clock) -> Result<Self, SecurityError> {
        prepare_private_file(path).map_err(|error| {
            SecurityError::Storage(DbError::Snapshot {
                path: path.to_path_buf(),
                message: error.to_string(),
            })
        })?;
        let db = DbThread::open(path, Durability::Full).await?;
        let file = path.to_path_buf();
        let initialised = db
            .call(move |connection| Ok::<_, DbError>(initialise(connection, &file)))
            .await
            .map_err(SecurityError::from)
            .and_then(|inner| inner);
        if let Err(error) = initialised {
            let _ = db.close().await;
            return Err(error);
        }
        restrict_database_files(path);
        Ok(Self {
            db,
            clock,
            memory: Arc::new(Memory {
                enroll_throttle: Mutex::new(enroll::EnrollThrottle::default()),
                last_seen: Mutex::new(HashMap::new()),
            }),
            actor: None,
        })
    }

    /// A handle whose audit entries name `user` as the actor.
    pub fn acting_as(&self, user: &UserId) -> Self {
        Self {
            actor: Some(Arc::from(user.as_str())),
            ..self.clone()
        }
    }

    /// Finishes queued work and closes the database.
    pub async fn close(&self) -> Result<(), SecurityError> {
        Ok(self.db.close().await?)
    }

    /// The server's current incarnation id, a uuid made on first open.
    pub async fn incarnation(&self) -> Result<String, SecurityError> {
        self.meta(INCARNATION_KEY).await
    }

    /// Replaces the incarnation id, as after restoring from a backup, and returns the new one.
    pub async fn bump_incarnation(&self) -> Result<String, SecurityError> {
        self.write(|transaction, stamp| {
            let fresh = keys::random_uuid()?;
            transaction.execute("UPDATE server_meta SET value = ?1 WHERE key = ?2", (&fresh, INCARNATION_KEY))?;
            stamp.record(transaction, "server.incarnate", "")?;
            Ok(fresh)
        })
        .await
    }

    /// The id of this server, a uuid made on first open that never changes.
    pub async fn server_id(&self) -> Result<String, SecurityError> {
        self.meta(SERVER_ID_KEY).await
    }

    /// The schema version recorded in `server_meta`.
    pub async fn schema_version(&self) -> Result<u32, SecurityError> {
        Ok(self.meta(SCHEMA_KEY).await?.parse().unwrap_or(0))
    }

    async fn meta(&self, key: &'static str) -> Result<String, SecurityError> {
        self.read(move |connection| {
            Ok(connection
                .query_row("SELECT value FROM server_meta WHERE key = ?1", [key], |row| row.get(0))
                .optional()?
                .unwrap_or_default())
        })
        .await
    }

    pub(crate) fn now(&self) -> i64 {
        (self.clock)()
    }

    pub(crate) async fn read<T, F>(&self, work: F) -> Result<T, SecurityError>
    where
        F: FnOnce(&Connection) -> Result<T, SecurityError> + Send + 'static,
        T: Send + 'static,
    {
        self.db
            .call(move |connection| Ok::<_, DbError>(work(connection)))
            .await
            .map_err(SecurityError::from)
            .and_then(|inner| inner)
    }

    pub(crate) async fn write<T, F>(&self, work: F) -> Result<T, SecurityError>
    where
        F: FnOnce(&Transaction<'_>, &Stamp) -> Result<T, SecurityError> + Send + 'static,
        T: Send + 'static,
    {
        let stamp = Stamp {
            at: self.now(),
            actor: self.actor.clone(),
        };
        self.db
            .call(move |connection| {
                Ok::<_, DbError>((|| {
                    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
                    let value = work(&transaction, &stamp)?;
                    transaction.commit()?;
                    Ok(value)
                })())
            })
            .await
            .map_err(SecurityError::from)
            .and_then(|inner| inner)
    }
}

fn initialise(connection: &mut Connection, file: &Path) -> Result<(), SecurityError> {
    let version = dbthread::migrate(connection, file, schema::MIGRATIONS)?;
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    for key in [INCARNATION_KEY, SERVER_ID_KEY] {
        let exists = transaction
            .query_row("SELECT 1 FROM server_meta WHERE key = ?1", [key], |_| Ok(()))
            .optional()?
            .is_some();
        if !exists {
            transaction.execute("INSERT INTO server_meta(key, value) VALUES (?1, ?2)", (key, keys::random_uuid()?))?;
        }
    }
    transaction.execute(
        "INSERT INTO server_meta(key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        (SCHEMA_KEY, version.to_string()),
    )?;
    transaction.commit()?;
    Ok(())
}

/// Trims `name` and refuses an empty, overlong or control-character name.
pub(crate) fn clean_name(name: &str) -> Result<String, SecurityError> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(SecurityError::InvalidName("is empty"));
    }
    if trimmed.chars().count() > MAX_NAME_CHARS {
        return Err(SecurityError::InvalidName("is longer than 80 characters"));
    }
    if trimmed.chars().any(char::is_control) {
        return Err(SecurityError::InvalidName("has a control character"));
    }
    Ok(trimmed.to_string())
}

#[cfg(unix)]
pub(crate) fn prepare_private_file(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::OpenOptions::new().create(true).append(true).mode(0o600).open(path).map(drop)
}

#[cfg(not(unix))]
pub(crate) fn prepare_private_file(path: &Path) -> std::io::Result<()> {
    if let Some(parent) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent)?;
    }
    Ok(())
}

pub(crate) fn restrict_database_files(path: &Path) {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    for suffix in ["", "-wal", "-shm"] {
        let file = path.with_file_name(format!("{name}{suffix}"));
        if file.exists() {
            let _ = dbthread::restrict_to_owner(&file);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_current_version_is_the_newest_migration() {
        let newest = schema::MIGRATIONS.iter().map(|migration| migration.version).max();
        assert_eq!(newest, Some(schema::CURRENT_VERSION));
    }

    #[test]
    fn names_are_trimmed_and_bounded() {
        assert_eq!(clean_name("  iPhone ").unwrap(), "iPhone");
        assert!(clean_name("   ").is_err());
        assert!(clean_name("bad\nname").is_err());
        assert!(clean_name(&"x".repeat(81)).is_err());
        assert!(clean_name(&"x".repeat(80)).is_ok());
    }
}
