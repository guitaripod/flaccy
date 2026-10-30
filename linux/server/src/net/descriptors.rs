//! The open-files limit: the server holds up to [`Limits::max_connections`] sockets besides its databases and
//! converters, so a low `ulimit -n` would turn a busy moment into failed accepts. macOS starts every process,
//! launchd agents included, at 256, so the server raises its own soft limit instead of asking the person to.

use flaccy_library::logger;

use super::limits::Limits;

const HEADROOM: u64 = 512;
const WANTED_SOFT_LIMIT: u64 = 10_240;

/// The soft limit to ask for: `wanted` held under the hard limit, and never below the one in force.
fn raised_target(soft: u64, hard: u64, wanted: u64) -> u64 {
    wanted.min(hard).max(soft)
}

/// What to tell the person when `soft` descriptors cannot hold `limits` connections plus headroom.
fn shortfall_message(soft: u64, limits: &Limits) -> Option<String> {
    let needed = limits.max_connections as u64 + HEADROOM;
    (soft < needed).then(|| {
        format!(
            "the open-files limit is {soft}, below the {needed} the server may need for {} connections, and the system will not let the server raise it; raise the hard limit, for example with LimitNOFILE=65536 in the systemd unit, `sudo launchctl limit maxfiles 65536 unlimited` on a Mac, or `ulimit -n 65536` before starting",
            limits.max_connections
        )
    })
}

/// Raises the soft open-files limit towards what a full house of connections needs and answers the limit in
/// force afterwards; `None` where the system has no such limit to read.
#[cfg(unix)]
#[allow(clippy::unnecessary_cast)]
pub fn raise_soft_limit() -> Option<u64> {
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    if unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) } != 0 {
        return None;
    }
    let soft = limit.rlim_cur as u64;
    let target = raised_target(soft, limit.rlim_max as u64, WANTED_SOFT_LIMIT);
    if target == soft {
        return Some(soft);
    }
    let raised = libc::rlimit { rlim_cur: target as libc::rlim_t, rlim_max: limit.rlim_max };
    if unsafe { libc::setrlimit(libc::RLIMIT_NOFILE, &raised) } == 0 {
        Some(target)
    } else {
        Some(soft)
    }
}

/// Raises the soft open-files limit; this system has none to raise.
#[cfg(not(unix))]
pub fn raise_soft_limit() -> Option<u64> {
    None
}

/// Raises the open-files limit, then logs a warning when it still cannot hold `limits` connections.
pub fn prepare(limits: &Limits) {
    let Some(soft) = raise_soft_limit() else {
        return;
    };
    if let Some(message) = shortfall_message(soft, limits) {
        logger::warn("server", &message);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_target_stays_under_the_hard_limit_and_never_lowers_the_soft_one() {
        assert_eq!(raised_target(256, u64::MAX, 10_240), 10_240);
        assert_eq!(raised_target(256, 4_096, 10_240), 4_096);
        assert_eq!(raised_target(65_536, 524_288, 10_240), 65_536);
        assert_eq!(raised_target(1_024, 1_024, 10_240), 1_024);
    }

    #[test]
    fn a_limit_below_the_connections_plus_headroom_is_reported_with_the_fix() {
        let message = shortfall_message(1000, &Limits::default());
        assert!(message.as_deref().is_some_and(|text| text.contains("LimitNOFILE=65536") && text.contains("launchctl limit maxfiles")));
        assert!(shortfall_message(1024 + 1, &Limits { max_connections: 100, ..Limits::default() }).is_none());
        assert!(shortfall_message(65536, &Limits::default()).is_none());
    }

    #[cfg(unix)]
    #[test]
    #[allow(clippy::unnecessary_cast)]
    fn the_process_ends_up_with_room_for_every_connection_when_the_hard_limit_allows_it() {
        let soft = raise_soft_limit().unwrap();
        let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        unsafe { libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit) };
        assert_eq!(soft, limit.rlim_cur as u64);
        assert!(soft >= (limit.rlim_max as u64).min(WANTED_SOFT_LIMIT));
    }
}
