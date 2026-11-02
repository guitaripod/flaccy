//! Pacing for the servers preparation talks to: a minimum gap between
//! requests, a cooldown a server's `Retry-After` can start, and a breaker that
//! rests a whole lane after repeated trouble. The clock is a parameter so the
//! rules are testable.

use flaccy_shared::precache::{retry_delay_seconds, Failure};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Spaces the requests of one server, whoever sends them, and honours the
/// cooldown it asked for. lrclib bans clients that ignore `Retry-After`, and
/// it bans by address, so the lyrics panel and the background lane share one
/// gate.
pub struct Gate {
    gap: Duration,
    state: Mutex<GateState>,
}

#[derive(Default)]
struct GateState {
    next_slot: Option<Instant>,
    cooldown_until: Option<Instant>,
}

/// How much longer than asked a cooldown lasts, at most, so clients that were
/// throttled together do not return together.
const COOLDOWN_JITTER: f64 = 0.3;

impl Gate {
    pub const fn new(gap: Duration) -> Self {
        Self {
            gap,
            state: Mutex::new(GateState {
                next_slot: None,
                cooldown_until: None,
            }),
        }
    }

    /// Claims the next request slot and says how long to wait for it. `Err`
    /// holds the cooldown still left when that is longer than `patience`: the
    /// caller should not send at all.
    pub fn claim_at(&self, now: Instant, patience: Duration) -> Result<Duration, Duration> {
        let Ok(mut state) = self.state.lock() else {
            return Ok(Duration::ZERO);
        };
        let cooling = state
            .cooldown_until
            .map(|until| until.saturating_duration_since(now))
            .unwrap_or_default();
        if cooling > patience {
            return Err(cooling);
        }
        let slot = state
            .next_slot
            .map_or(now, |next| next.max(now))
            .max(now + cooling);
        state.next_slot = Some(slot + self.gap);
        Ok(slot.saturating_duration_since(now))
    }

    /// Waits for a slot, or gives up with the cooldown left.
    pub fn wait_turn(&self, patience: Duration) -> Result<(), Duration> {
        let wait = self.claim_at(Instant::now(), patience)?;
        if !wait.is_zero() {
            std::thread::sleep(wait);
        }
        Ok(())
    }

    /// The server said to slow down: nothing is sent for `retry_after`, plus
    /// up to 30 % so a crowd of clients spreads out.
    pub fn throttled_at(&self, now: Instant, retry_after: Duration, jitter: f64) {
        let until = now + retry_after.mul_f64(1.0 + COOLDOWN_JITTER * jitter.clamp(0.0, 1.0));
        if let Ok(mut state) = self.state.lock() {
            if state.cooldown_until.is_none_or(|current| current < until) {
                state.cooldown_until = Some(until);
            }
        }
    }

    pub fn throttled(&self, retry_after: Duration) {
        self.throttled_at(Instant::now(), retry_after, rand::random::<f64>());
    }

    pub fn cooldown_left_at(&self, now: Instant) -> Duration {
        self.state
            .lock()
            .ok()
            .and_then(|state| state.cooldown_until)
            .map(|until| until.saturating_duration_since(now))
            .unwrap_or_default()
    }

    pub fn cooldown_left(&self) -> Duration {
        self.cooldown_left_at(Instant::now())
    }
}

/// lrclib asks identified clients to stay under about 90 requests a minute
/// and library scans to leave 200 to 500 ms between requests.
pub static LRCLIB: Gate = Gate::new(Duration::from_millis(450));

/// YouTube answers a searching, resolving client that keeps a human pace and
/// turns away one that does not. This is the gap between the background
/// lane's yt-dlp runs; the jitter is added by the lane.
pub static YOUTUBE: Gate = Gate::new(Duration::from_secs(6));

/// Rests a lane after consecutive failures, for longer each time.
#[derive(Default)]
pub struct Breaker {
    consecutive: u32,
    resting_until: Option<Instant>,
    last: Option<Failure>,
}

/// Failures in a row before the lane rests.
const TRIP_AFTER: u32 = 3;

/// A server that answers "busy" is alive and merely slow on the questions it
/// was asked, so it takes a longer run of them, with no song done in between,
/// before the whole lane rests: a few songs lrclib has to think about must not
/// hold up the ones behind them.
const BUSY_TRIP_AFTER: u32 = 8;

impl Breaker {
    pub fn succeeded(&mut self) {
        self.consecutive = 0;
        self.resting_until = None;
        self.last = None;
    }

    /// Counts a failure. A refusal (`Throttled`, `Blocked`) rests the lane at
    /// once, since the server has said it does not want more; a hiccup needs
    /// `TRIP_AFTER` in a row and a busy answer `BUSY_TRIP_AFTER`, after which
    /// the rests lengthen from the shortest.
    pub fn failed_at(&mut self, now: Instant, failure: Failure, jitter: f64) {
        self.consecutive += 1;
        self.last = Some(failure);
        let refused = matches!(failure, Failure::Throttled | Failure::Blocked);
        let busy = failure == Failure::Busy;
        let threshold = if busy { BUSY_TRIP_AFTER } else { TRIP_AFTER };
        if refused || self.consecutive >= threshold {
            let attempts = if busy {
                self.consecutive - BUSY_TRIP_AFTER + 1
            } else {
                self.consecutive
            };
            let rest = retry_delay_seconds(failure, attempts, jitter);
            self.resting_until = Some(now + Duration::from_secs(rest.max(1) as u64));
        }
    }

    pub fn failed(&mut self, failure: Failure) {
        self.failed_at(Instant::now(), failure, rand::random::<f64>());
    }

    pub fn rest_left_at(&self, now: Instant) -> Duration {
        self.resting_until
            .map(|until| until.saturating_duration_since(now))
            .unwrap_or_default()
    }

    pub fn rest_left(&self) -> Duration {
        self.rest_left_at(Instant::now())
    }

    pub fn last(&self) -> Option<Failure> {
        self.last
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GAP: Duration = Duration::from_millis(400);

    #[test]
    fn requests_leave_a_gap_whoever_sends_them() {
        let gate = Gate::new(GAP);
        let now = Instant::now();
        let patience = Duration::from_secs(3);
        assert_eq!(gate.claim_at(now, patience), Ok(Duration::ZERO));
        assert_eq!(gate.claim_at(now, patience), Ok(GAP));
        assert_eq!(gate.claim_at(now, patience), Ok(GAP * 2));
        let later = now + Duration::from_secs(10);
        assert_eq!(gate.claim_at(later, patience), Ok(Duration::ZERO));
    }

    #[test]
    fn a_cooldown_holds_every_request_until_it_ends() {
        let gate = Gate::new(GAP);
        let now = Instant::now();
        gate.throttled_at(now, Duration::from_secs(2), 0.0);
        assert_eq!(
            gate.claim_at(now, Duration::from_secs(3)),
            Ok(Duration::from_secs(2))
        );
        assert_eq!(gate.cooldown_left_at(now), Duration::from_secs(2));
        assert_eq!(gate.cooldown_left_at(now + Duration::from_secs(5)), Duration::ZERO);
    }

    #[test]
    fn a_caller_with_little_patience_is_told_not_to_send() {
        let gate = Gate::new(GAP);
        let now = Instant::now();
        gate.throttled_at(now, Duration::from_secs(60), 0.0);
        assert_eq!(
            gate.claim_at(now, Duration::from_secs(3)),
            Err(Duration::from_secs(60))
        );
        assert_eq!(
            gate.claim_at(now, Duration::from_secs(120)),
            Ok(Duration::from_secs(60))
        );
    }

    #[test]
    fn jitter_stretches_a_cooldown_by_up_to_thirty_percent_and_never_shortens_one() {
        let gate = Gate::new(GAP);
        let now = Instant::now();
        gate.throttled_at(now, Duration::from_secs(10), 1.0);
        assert_eq!(gate.cooldown_left_at(now), Duration::from_secs(13));
        gate.throttled_at(now, Duration::from_secs(1), 0.0);
        assert_eq!(gate.cooldown_left_at(now), Duration::from_secs(13));
    }

    #[test]
    fn a_refusal_rests_the_lane_at_once_and_a_hiccup_needs_three() {
        let now = Instant::now();
        let mut refused = Breaker::default();
        refused.failed_at(now, Failure::Throttled, 0.0);
        assert_eq!(refused.rest_left_at(now), Duration::from_secs(300));

        let mut hiccups = Breaker::default();
        hiccups.failed_at(now, Failure::Transient, 0.0);
        hiccups.failed_at(now, Failure::Transient, 0.0);
        assert_eq!(hiccups.rest_left_at(now), Duration::ZERO);
        hiccups.failed_at(now, Failure::Transient, 0.0);
        assert_eq!(hiccups.rest_left_at(now), Duration::from_secs(120));
    }

    #[test]
    fn a_busy_answer_needs_eight_in_a_row_and_then_rests_briefly() {
        let now = Instant::now();
        let mut busy = Breaker::default();
        for _ in 0..7 {
            busy.failed_at(now, Failure::Busy, 0.0);
        }
        assert_eq!(busy.rest_left_at(now), Duration::ZERO);
        busy.failed_at(now, Failure::Busy, 0.0);
        assert_eq!(busy.rest_left_at(now), Duration::from_secs(30));
        busy.failed_at(now, Failure::Busy, 0.0);
        assert_eq!(busy.rest_left_at(now), Duration::from_secs(60));
        busy.succeeded();
        assert_eq!(busy.rest_left_at(now), Duration::ZERO);
    }

    #[test]
    fn rests_lengthen_and_a_success_ends_them() {
        let now = Instant::now();
        let mut breaker = Breaker::default();
        breaker.failed_at(now, Failure::Throttled, 0.0);
        breaker.failed_at(now, Failure::Throttled, 0.0);
        assert_eq!(breaker.rest_left_at(now), Duration::from_secs(600));
        assert_eq!(breaker.last(), Some(Failure::Throttled));
        breaker.succeeded();
        assert_eq!(breaker.rest_left_at(now), Duration::ZERO);
        assert_eq!(breaker.last(), None);
    }
}
