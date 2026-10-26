use super::transport::ApiError;
use std::fmt;

/// Why a server cannot be used with this version of Flaccy.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Incompatibility {
    /// The server speaks an older protocol, or lacks sync.
    ServerTooOld,
    /// The server speaks only a newer protocol than this Flaccy knows.
    AppTooOld,
}

/// Everything sync can fail with.
#[derive(Debug)]
pub enum SyncError {
    /// The local database refused a statement.
    Db(rusqlite::Error),
    /// A stored or received document did not parse.
    Json(serde_json::Error),
    /// The server answered something the protocol does not allow.
    Protocol(String),
    /// A file could not be read or written.
    Io(std::io::Error),
    /// No server is configured on this database.
    NotConfigured,
    /// A call to the server failed in a way the person may need to act on.
    Api(ApiError),
    /// The server and this Flaccy cannot speak to each other.
    Incompatible(Incompatibility),
}

/// The result type of the sync module.
pub type Result<T> = std::result::Result<T, SyncError>;

impl fmt::Display for SyncError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SyncError::Db(error) => write!(formatter, "database: {error}"),
            SyncError::Json(error) => write!(formatter, "document: {error}"),
            SyncError::Protocol(message) => write!(formatter, "protocol: {message}"),
            SyncError::Io(error) => write!(formatter, "file: {error}"),
            SyncError::NotConfigured => write!(formatter, "no Flaccy Server is configured"),
            SyncError::Api(error) => write!(formatter, "{error}"),
            SyncError::Incompatible(Incompatibility::ServerTooOld) => write!(
                formatter,
                "This server is too old for sync. Update Flaccy Server to 1.0 or newer."
            ),
            SyncError::Incompatible(Incompatibility::AppTooOld) => write!(
                formatter,
                "This server needs a newer Flaccy. Update Flaccy and try again."
            ),
        }
    }
}

impl std::error::Error for SyncError {}

impl From<ApiError> for SyncError {
    fn from(error: ApiError) -> Self {
        SyncError::Api(error)
    }
}

impl From<rusqlite::Error> for SyncError {
    fn from(error: rusqlite::Error) -> Self {
        SyncError::Db(error)
    }
}

impl From<serde_json::Error> for SyncError {
    fn from(error: serde_json::Error) -> Self {
        SyncError::Json(error)
    }
}

impl From<std::io::Error> for SyncError {
    fn from(error: std::io::Error) -> Self {
        SyncError::Io(error)
    }
}

/// Maps a sync failure back onto the error type of the `Db` method that was recording.
pub(crate) fn db_error(error: SyncError) -> rusqlite::Error {
    match error {
        SyncError::Db(error) => error,
        other => rusqlite::Error::ToSqlConversionFailure(Box::new(other)),
    }
}
