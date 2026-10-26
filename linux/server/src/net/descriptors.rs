//! The open-files limit: the server holds up to [`Limits::max_connections`] sockets besides its databases and
//! converters, so a low `ulimit -n` would turn a busy moment into failed accepts.

use flaccy_library::logger;

use super::limits::Limits;

const LIMITS_FILE: &str = "/proc/self/limits";
const HEADROOM: u64 = 512;

/// The soft open-files limit named in the text of `/proc/self/limits`; `None` for "unlimited" or an unreadable line.
fn soft_limit_from(text: &str) -> Option<u64> {
    let line = text.lines().find(|line| line.starts_with("Max open files"))?;
    line.split_whitespace().nth(3)?.parse().ok()
}

/// What to tell the person when `soft` descriptors cannot hold `limits` connections plus headroom.
fn shortfall_message(soft: u64, limits: &Limits) -> Option<String> {
    let needed = limits.max_connections as u64 + HEADROOM;
    (soft < needed).then(|| {
        format!(
            "the open-files limit is {soft}, below the {needed} the server may need for {} connections; raise it, for example with LimitNOFILE=65536 in the systemd unit or `ulimit -n 65536` before starting",
            limits.max_connections
        )
    })
}

/// Logs a warning when the process may not open as many files as `limits` allow connections.
pub fn warn_if_too_low(limits: &Limits) {
    let Some(soft) = std::fs::read_to_string(LIMITS_FILE).ok().and_then(|text| soft_limit_from(&text)) else {
        return;
    };
    if let Some(message) = shortfall_message(soft, limits) {
        logger::warn("server", &message);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = "Limit                     Soft Limit           Hard Limit           Units     \nMax open files            1024                 524288               files     \n";

    #[test]
    fn the_soft_limit_is_read_from_the_open_files_line() {
        assert_eq!(soft_limit_from(SAMPLE), Some(1024));
        assert_eq!(soft_limit_from("Max open files            unlimited            unlimited            files\n"), None);
        assert_eq!(soft_limit_from("nothing here"), None);
    }

    #[test]
    fn a_limit_below_the_connections_plus_headroom_is_reported_with_the_fix() {
        let message = shortfall_message(1000, &Limits::default());
        assert!(message.is_some_and(|text| text.contains("LimitNOFILE=65536")));
        assert!(shortfall_message(1024 + 1, &Limits { max_connections: 100, ..Limits::default() }).is_none());
        assert!(shortfall_message(65536, &Limits::default()).is_none());
    }
}
