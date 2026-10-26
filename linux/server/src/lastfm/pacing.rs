//! How fast the server talks to Last.fm, and how long it waits after a failure.

use std::time::{Duration, Instant};

use tokio::sync::Mutex;

const REQUEST_GAP: Duration = Duration::from_secs(1);
const PAGE_RETRY_BASE: Duration = Duration::from_secs(2);
const PAGE_RETRY_CAP: Duration = Duration::from_secs(60);
const PAGE_ATTEMPTS: u32 = 5;
const SUPERVISOR_TICK: Duration = Duration::from_secs(30);
const RELAY_TICK: Duration = Duration::from_secs(5);
const RELAY_RETRY_FLOOR_SECONDS: i64 = 1;
const RELAY_RETRY_CEILING_SECONDS: i64 = 3_600;

/// The waits the workers use; tests shrink them to nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pacing {
    /// The least time between two requests to Last.fm.
    pub request_gap: Duration,
    /// The wait after the first failed attempt at a page; it doubles each time.
    pub retry_base: Duration,
    /// The longest wait between two attempts at a page.
    pub retry_cap: Duration,
    /// Attempts at one page before the sync stops and tries again later.
    pub attempts: u32,
    /// How often the history supervisor looks for work.
    pub tick: Duration,
    /// How often the relay looks for new plays and due retries.
    pub relay_tick: Duration,
}

impl Pacing {
    /// One request a second, doubling waits from 2 s to a minute, five attempts, a history look every 30 s and a relay look every 5 s.
    pub fn polite() -> Self {
        Self {
            request_gap: REQUEST_GAP,
            retry_base: PAGE_RETRY_BASE,
            retry_cap: PAGE_RETRY_CAP,
            attempts: PAGE_ATTEMPTS,
            tick: SUPERVISOR_TICK,
            relay_tick: RELAY_TICK,
        }
    }

    /// No waiting beyond a millisecond, for tests that fake Last.fm.
    pub fn instant() -> Self {
        Self {
            request_gap: Duration::ZERO,
            retry_base: Duration::from_millis(1),
            retry_cap: Duration::from_millis(4),
            attempts: PAGE_ATTEMPTS,
            tick: Duration::from_millis(20),
            relay_tick: Duration::from_millis(20),
        }
    }

    /// The wait after `attempt` failed attempts (1 for the first): `retry_base` doubled each time, capped.
    pub fn retry_wait(&self, attempt: u32) -> Duration {
        let doublings = attempt.saturating_sub(1).min(16);
        self.retry_base.saturating_mul(1u32 << doublings).min(self.retry_cap)
    }
}

/// Spaces calls out so Last.fm sees at most one a `request_gap`.
pub struct Pacer {
    gap: Duration,
    last: Mutex<Option<Instant>>,
}

impl Pacer {
    /// A pacer holding `gap` between calls.
    pub fn new(gap: Duration) -> Self {
        Self { gap, last: Mutex::new(None) }
    }

    /// Waits until the next call is allowed, then claims the slot.
    pub async fn wait(&self) {
        let mut last = self.last.lock().await;
        if let Some(previous) = *last {
            let ready = previous + self.gap;
            if let Some(remaining) = ready.checked_duration_since(Instant::now()) {
                tokio::time::sleep(remaining).await;
            }
        }
        *last = Some(Instant::now());
    }
}

/// Seconds the relay waits before trying a play again after `attempts` failures: 1 s, 2 s, 4 s ... up to an hour.
pub fn relay_retry_seconds(attempts: u32) -> i64 {
    let doublings = attempts.saturating_sub(1).min(20);
    (RELAY_RETRY_FLOOR_SECONDS << doublings).min(RELAY_RETRY_CEILING_SECONDS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn page_retries_double_up_to_the_cap() {
        let pacing = Pacing::polite();
        let waits: Vec<u64> = (1..=7).map(|attempt| pacing.retry_wait(attempt).as_secs()).collect();
        assert_eq!(waits, vec![2, 4, 8, 16, 32, 60, 60]);
    }

    #[test]
    fn the_relay_backs_off_from_a_second_to_an_hour() {
        let waits: Vec<i64> = [1, 2, 3, 4, 11, 12, 13, 40].into_iter().map(relay_retry_seconds).collect();
        assert_eq!(waits, vec![1, 2, 4, 8, 1_024, 2_048, 3_600, 3_600]);
    }

    #[tokio::test]
    async fn the_pacer_holds_calls_a_gap_apart() {
        let pacer = Pacer::new(Duration::from_millis(40));
        let started = Instant::now();
        pacer.wait().await;
        pacer.wait().await;
        pacer.wait().await;
        assert!(started.elapsed() >= Duration::from_millis(80));
    }
}
