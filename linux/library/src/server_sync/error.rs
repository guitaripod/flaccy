use std::fmt;

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
        }
    }
}

impl std::error::Error for SyncError {}

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
