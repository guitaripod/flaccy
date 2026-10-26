use super::error::{Incompatibility, SyncError};
use super::transport::ApiError;

/// Where a sync stands, for the status line.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncState {
    /// Everything local reached the server and everything on the server is here.
    UpToDate,
    /// This many local changes are waiting to be sent.
    Syncing(usize),
    /// The server cannot be reached; local changes wait and Flaccy retries by itself.
    Offline,
    /// Something only the person can fix; the text says what, why and what to do.
    NeedsAttention(String),
    /// Sync is paused for a reason the status line names.
    Blocked(Blocker),
}

/// Why sync is paused until something outside Flaccy changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Blocker {
    /// The server's clock is behind, so it refuses writes (`503 clock_behind`).
    ClockBehind,
    /// The server no longer accepts this device's token.
    DeviceRevoked,
    /// The server has no disk space left (`507`).
    DiskFull,
    /// The server speaks only a newer protocol than this Flaccy knows.
    AppTooOld,
    /// The server speaks only an older protocol, or lacks sync.
    ServerTooOld,
}

/// What a server says about itself in `GET /hello`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ServerIdentity {
    /// The name the server gave itself.
    pub name: String,
    /// Its version.
    pub version: String,
}

/// The state, the queue length and the last complete pull.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SyncStatus {
    /// Where the sync stands.
    pub state: SyncState,
    /// Mutations still queued, refused ones included until a pull retires them.
    pub pending: usize,
    /// Unix milliseconds of the last complete pull.
    pub last_synced_at: Option<i64>,
}

/// The state a failed call leaves the status line in.
pub(crate) fn api_state(error: &ApiError) -> SyncState {
    match error {
        ApiError::ClockBehind => SyncState::Blocked(Blocker::ClockBehind),
        ApiError::Unauthorized => SyncState::Blocked(Blocker::DeviceRevoked),
        ApiError::InsufficientStorage => SyncState::Blocked(Blocker::DiskFull),
        ApiError::Offline(_) | ApiError::Server(_) | ApiError::RateLimited(_) => SyncState::Offline,
        other => SyncState::NeedsAttention(other.to_string()),
    }
}

/// The state a failure other than a refused call leaves the status line in.
pub(crate) fn sync_state(error: &SyncError) -> SyncState {
    match error {
        SyncError::Incompatible(Incompatibility::AppTooOld) => {
            SyncState::Blocked(Blocker::AppTooOld)
        }
        SyncError::Incompatible(Incompatibility::ServerTooOld) => {
            SyncState::Blocked(Blocker::ServerTooOld)
        }
        other => SyncState::NeedsAttention(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refusals_that_wait_on_the_person_or_the_server_are_blockers_not_outages() {
        assert_eq!(
            api_state(&ApiError::ClockBehind),
            SyncState::Blocked(Blocker::ClockBehind)
        );
        assert_eq!(
            api_state(&ApiError::Unauthorized),
            SyncState::Blocked(Blocker::DeviceRevoked)
        );
        assert_eq!(
            api_state(&ApiError::InsufficientStorage),
            SyncState::Blocked(Blocker::DiskFull)
        );
        assert_eq!(api_state(&ApiError::Server(502)), SyncState::Offline);
        assert_eq!(
            api_state(&ApiError::Offline("x".into())),
            SyncState::Offline
        );
    }

    #[test]
    fn a_version_gap_pauses_sync_for_the_person() {
        assert_eq!(
            sync_state(&SyncError::Incompatible(Incompatibility::AppTooOld)),
            SyncState::Blocked(Blocker::AppTooOld)
        );
        assert_eq!(
            sync_state(&SyncError::Incompatible(Incompatibility::ServerTooOld)),
            SyncState::Blocked(Blocker::ServerTooOld)
        );
    }
}
