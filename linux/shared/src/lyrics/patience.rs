use super::status::LyricsFailure;

/// Seconds to wait after the first, second, third and fourth failure in a row
/// before asking again, saying nothing meanwhile. About 76 seconds in all,
/// which is longer than most lrclib hiccups last.
pub const QUIET_DELAYS: [f64; 4] = [3.0, 8.0, 20.0, 45.0];

/// Seconds between the later attempts, after the failure has been shown: the
/// lyrics appear on their own once lrclib is back.
pub const SLOW_DELAY: f64 = 60.0;

/// What a lookup that lrclib could not answer does next. Mirrored in Swift as
/// `LyricsPatience`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Retry {
    /// Ask again after this many seconds, with nothing on screen to say so.
    Quietly(f64),
    /// Put the failure in front of the listener, then ask again after this many
    /// seconds. Happens once per lookup.
    Show(f64),
    /// Asking again cannot help: say why and stop.
    GiveUp,
}

/// What to do after the `failures`-th failure in a row (1 for the first).
/// `cooldown_left` is how long the shared lrclib gate is still holding requests
/// back, which no retry may undercut.
pub fn next_retry(failure: LyricsFailure, failures: usize, cooldown_left: f64) -> Retry {
    if matches!(failure, LyricsFailure::Rejected(_)) {
        return Retry::GiveUp;
    }
    let hold = cooldown_left.max(0.0);
    let failures = failures.max(1);
    if failures <= QUIET_DELAYS.len() {
        Retry::Quietly(QUIET_DELAYS[failures - 1].max(hold))
    } else if failures == QUIET_DELAYS.len() + 1 {
        Retry::Show(SLOW_DELAY.max(hold))
    } else {
        Retry::Quietly(SLOW_DELAY.max(hold))
    }
}

/// Whether the next question to lrclib is worth asking after this answer.
/// lrclib gives up on a question it cannot answer from memory within about half
/// a second with a 503 and keeps working on it, so a 503 says nothing about the
/// plainer questions that follow it: the same song asked without its album, or
/// searched for, is often answered straight away. Anything else (no connection,
/// a timeout, a refusal, a 500 or 502) says the server is not answering at all.
pub fn tries_next_question(failure: LyricsFailure) -> bool {
    matches!(failure, LyricsFailure::Server(503))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_busy_answer_lets_the_next_question_be_asked() {
        assert!(tries_next_question(LyricsFailure::Server(503)));
        assert!(!tries_next_question(LyricsFailure::Server(500)));
        assert!(!tries_next_question(LyricsFailure::Server(502)));
        assert!(!tries_next_question(LyricsFailure::TimedOut));
        assert!(!tries_next_question(LyricsFailure::Unreachable));
        assert!(!tries_next_question(LyricsFailure::Busy));
        assert!(!tries_next_question(LyricsFailure::Rejected(403)));
    }

    #[test]
    fn the_first_four_failures_wait_longer_each_time_and_say_nothing() {
        let failure = LyricsFailure::Server(503);
        let waits: Vec<Retry> = (1..=4).map(|n| next_retry(failure, n, 0.0)).collect();
        assert_eq!(
            waits,
            [
                Retry::Quietly(3.0),
                Retry::Quietly(8.0),
                Retry::Quietly(20.0),
                Retry::Quietly(45.0),
            ]
        );
    }

    #[test]
    fn the_fifth_failure_is_shown_once_and_the_later_ones_stay_quiet() {
        let failure = LyricsFailure::TimedOut;
        assert_eq!(next_retry(failure, 5, 0.0), Retry::Show(60.0));
        assert_eq!(next_retry(failure, 6, 0.0), Retry::Quietly(60.0));
        assert_eq!(next_retry(failure, 40, 0.0), Retry::Quietly(60.0));
    }

    #[test]
    fn a_cooldown_the_server_asked_for_is_never_undercut() {
        assert_eq!(
            next_retry(LyricsFailure::Busy, 1, 120.0),
            Retry::Quietly(120.0)
        );
        assert_eq!(next_retry(LyricsFailure::Busy, 1, 1.0), Retry::Quietly(3.0));
        assert_eq!(next_retry(LyricsFailure::Busy, 5, 300.0), Retry::Show(300.0));
    }

    #[test]
    fn a_refusal_is_shown_at_once_and_not_retried() {
        assert_eq!(
            next_retry(LyricsFailure::Rejected(403), 1, 0.0),
            Retry::GiveUp
        );
    }

    #[test]
    fn a_connection_that_cannot_open_is_retried_like_a_server_error() {
        assert_eq!(
            next_retry(LyricsFailure::Unreachable, 2, 0.0),
            Retry::Quietly(8.0)
        );
    }
}
