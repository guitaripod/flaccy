use super::copy;
use flaccy_library::server_sync::{Blocker, SyncState, SyncStatus};

const MINUTE_MS: i64 = 60_000;
const HOUR_MS: i64 = 60 * MINUTE_MS;
const DAY_MS: i64 = 24 * HOUR_MS;

/// The one line under the server's name, from the table in `docs/server/UX.md` section 4.
pub fn status_line(name: &str, status: Option<&SyncStatus>, now_ms: i64) -> String {
    let Some(status) = status else {
        return copy::STATUS_NOT_SYNCED.to_owned();
    };
    match &status.state {
        SyncState::UpToDate => match status.last_synced_at {
            Some(at) => synced(now_ms - at),
            None => copy::STATUS_NOT_SYNCED.to_owned(),
        },
        SyncState::Syncing(changes) => copy::syncing(*changes),
        SyncState::Offline if status.pending > 0 => copy::offline_waiting(status.pending, name),
        SyncState::Offline => copy::unreachable_line(name),
        SyncState::NeedsAttention(text) => text.clone(),
        SyncState::Blocked(Blocker::ClockBehind) => copy::clock_line(name),
        SyncState::Blocked(Blocker::DiskFull) => copy::disk_full_line(name),
        SyncState::Blocked(Blocker::DeviceRevoked) => copy::revoked_line(name),
        SyncState::Blocked(Blocker::AppTooOld) => copy::UPDATE_FLACCY_LINE.to_owned(),
        SyncState::Blocked(Blocker::ServerTooOld) => copy::UPDATE_SERVER_LINE.to_owned(),
    }
}

/// "just now", "4 minutes ago", "2 hours ago", "3 days ago".
pub fn ago(elapsed_ms: i64) -> String {
    let (amount, unit) = elapsed_parts(elapsed_ms);
    match unit {
        None => "just now".to_owned(),
        Some(unit) => {
            let plural = if amount == 1 { "" } else { "s" };
            format!("{amount} {unit}{plural} ago")
        }
    }
}

fn synced(elapsed_ms: i64) -> String {
    match elapsed_parts(elapsed_ms) {
        (_, None) => copy::STATUS_JUST_NOW.to_owned(),
        (amount, Some(unit)) => copy::synced_ago(amount, unit),
    }
}

fn elapsed_parts(elapsed_ms: i64) -> (i64, Option<&'static str>) {
    let elapsed = elapsed_ms.max(0);
    if elapsed < MINUTE_MS {
        (0, None)
    } else if elapsed < HOUR_MS {
        (elapsed / MINUTE_MS, Some("minute"))
    } else if elapsed < DAY_MS {
        (elapsed / HOUR_MS, Some("hour"))
    } else {
        (elapsed / DAY_MS, Some("day"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn status(state: SyncState, pending: usize, last: Option<i64>) -> SyncStatus {
        SyncStatus {
            state,
            pending,
            last_synced_at: last,
        }
    }

    fn line(state: SyncState, pending: usize, last: Option<i64>) -> String {
        status_line("arch", Some(&status(state, pending, last)), 10 * HOUR_MS)
    }

    #[test]
    fn an_up_to_date_server_says_how_long_ago() {
        let now = 10 * HOUR_MS;
        assert_eq!(line(SyncState::UpToDate, 0, Some(now - 5_000)), "Synced just now");
        assert_eq!(
            line(SyncState::UpToDate, 0, Some(now - 4 * MINUTE_MS)),
            "Synced 4 minutes ago"
        );
        assert_eq!(
            line(SyncState::UpToDate, 0, Some(now - MINUTE_MS)),
            "Synced 1 minute ago"
        );
        assert_eq!(
            line(SyncState::UpToDate, 0, Some(now - 2 * HOUR_MS)),
            "Synced 2 hours ago"
        );
        assert_eq!(
            line(SyncState::UpToDate, 0, Some(now - 3 * DAY_MS)),
            "Synced 3 days ago"
        );
        assert_eq!(line(SyncState::UpToDate, 0, None), "Not synced yet");
    }

    #[test]
    fn working_counts_the_changes() {
        assert_eq!(line(SyncState::Syncing(12), 12, None), "Syncing 12 changes…");
        assert_eq!(line(SyncState::Syncing(1), 1, None), "Syncing 1 change…");
    }

    #[test]
    fn offline_with_changes_waiting_says_they_will_send() {
        assert_eq!(
            line(SyncState::Offline, 4, None),
            "Offline. 4 changes will send when arch is reachable."
        );
        assert_eq!(
            line(SyncState::Offline, 1, None),
            "Offline. 1 change will send when arch is reachable."
        );
    }

    #[test]
    fn offline_with_nothing_waiting_asks_about_tailscale() {
        assert_eq!(
            line(SyncState::Offline, 0, None),
            "Can't reach arch. Is Tailscale on?"
        );
    }

    #[test]
    fn blockers_name_the_server() {
        assert_eq!(
            line(SyncState::Blocked(Blocker::ClockBehind), 0, None),
            "The clock on arch is wrong. Sync is paused."
        );
        assert_eq!(
            line(SyncState::Blocked(Blocker::DiskFull), 0, None),
            "arch is out of disk space. Free some up and Flaccy retries by itself."
        );
        assert!(line(SyncState::Blocked(Blocker::DeviceRevoked), 0, None).starts_with("arch no longer"));
    }

    #[test]
    fn a_version_gap_says_which_side_to_update() {
        assert_eq!(
            line(SyncState::Blocked(Blocker::AppTooOld), 0, None),
            "Update Flaccy to keep syncing."
        );
        assert_eq!(
            line(SyncState::Blocked(Blocker::ServerTooOld), 0, None),
            "Update your Flaccy Server to keep syncing."
        );
    }

    #[test]
    fn text_the_engine_wrote_passes_through_and_no_status_is_not_synced() {
        assert_eq!(
            line(SyncState::NeedsAttention("Do this.".into()), 0, None),
            "Do this."
        );
        assert_eq!(status_line("arch", None, 0), "Not synced yet");
    }

    #[test]
    fn ago_reads_like_a_person() {
        assert_eq!(ago(10_000), "just now");
        assert_eq!(ago(90 * 1000), "1 minute ago");
        assert_eq!(ago(-5), "just now");
    }
}
