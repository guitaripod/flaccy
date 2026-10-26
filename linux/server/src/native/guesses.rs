//! Failed bearer tokens per peer address: ten within ten minutes lock that address for ten minutes.
//!
//! Only the peer address and counts are kept, never a token.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use flaccy_library::logger;

use crate::throttle::{FAILURE_WINDOW, LOCKOUT, MAX_FAILURES};

#[derive(Clone, Copy)]
struct Streak {
    started: Instant,
    failures: u32,
    locked_until: Option<Instant>,
}

impl Streak {
    fn is_live(&self, now: Instant) -> bool {
        now.duration_since(self.started) < FAILURE_WINDOW || self.remaining_lock(now).is_some()
    }

    fn remaining_lock(&self, now: Instant) -> Option<Duration> {
        self.locked_until.and_then(|until| until.checked_duration_since(now)).filter(|left| !left.is_zero())
    }
}

/// Counts bearer tokens that matched no device, per peer address.
#[derive(Default)]
pub struct BearerThrottle {
    streaks: Mutex<HashMap<IpAddr, Streak>>,
}

impl BearerThrottle {
    fn streaks(&self, now: Instant) -> MutexGuard<'_, HashMap<IpAddr, Streak>> {
        let mut streaks = self.streaks.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        streaks.retain(|_, streak| streak.is_live(now));
        streaks
    }

    /// How long `address` stays locked out, `None` when it may try.
    pub fn locked_for(&self, address: IpAddr, now: Instant) -> Option<Duration> {
        self.streaks(now).get(&address).and_then(|streak| streak.remaining_lock(now))
    }

    /// Counts a token that matched nothing; the tenth in a window locks the address.
    pub fn record_failure(&self, address: IpAddr, now: Instant) {
        let mut streaks = self.streaks(now);
        let streak = streaks.entry(address).or_insert(Streak {
            started: now,
            failures: 0,
            locked_until: None,
        });
        if now.duration_since(streak.started) >= FAILURE_WINDOW {
            *streak = Streak {
                started: now,
                failures: 0,
                locked_until: None,
            };
        }
        streak.failures += 1;
        if streak.failures >= MAX_FAILURES && streak.locked_until.is_none() {
            streak.locked_until = Some(now + LOCKOUT);
            logger::warn(
                "native",
                &format!("refusing device tokens from {address} for ten minutes after {MAX_FAILURES} unknown tokens"),
            );
        }
    }

    /// Forgets the failures of an address whose token worked.
    pub fn record_success(&self, address: IpAddr, now: Instant) {
        self.streaks(now).remove(&address);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn address() -> IpAddr {
        "100.64.0.7".parse().unwrap()
    }

    #[test]
    fn ten_failures_lock_the_address_and_the_lock_lifts() {
        let throttle = BearerThrottle::default();
        let start = Instant::now();
        for _ in 0..MAX_FAILURES {
            assert!(throttle.locked_for(address(), start).is_none());
            throttle.record_failure(address(), start);
        }
        assert!(throttle.locked_for(address(), start).is_some());
        assert!(throttle.locked_for("100.64.0.8".parse().unwrap(), start).is_none());
        assert!(throttle.locked_for(address(), start + LOCKOUT + Duration::from_secs(1)).is_none());
    }

    #[test]
    fn a_working_token_clears_the_count() {
        let throttle = BearerThrottle::default();
        let start = Instant::now();
        for _ in 0..MAX_FAILURES - 1 {
            throttle.record_failure(address(), start);
        }
        throttle.record_success(address(), start);
        throttle.record_failure(address(), start);
        assert!(throttle.locked_for(address(), start).is_none());
    }
}
