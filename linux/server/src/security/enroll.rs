//! Enrollment codes: short-lived, single-use secrets that turn into a device.

use std::collections::VecDeque;
use std::fmt;
use std::sync::Arc;
use std::time::Duration;

use rusqlite::OptionalExtension;

use super::keys::{hash_secret, new_enrollment_code, normalize_enrollment_code};
use super::users::require_user;
use super::{Clock, Memory, SecurityError, Store, UserId};

/// Wrong codes within [`FAILURE_WINDOW`] that lock redemption.
pub const MAX_FAILURES: usize = 5;
/// The span in which wrong codes add up.
pub const FAILURE_WINDOW: Duration = Duration::from_secs(60);
/// How long redemption stays locked.
pub const LOCKOUT: Duration = Duration::from_secs(60);

/// Why a code was not redeemed.
#[derive(Debug)]
pub enum EnrollError {
    /// Wrong, used or expired; the three look the same on purpose.
    Invalid,
    /// Too many wrong codes recently; try again after `retry_after`.
    Locked { retry_after: Duration },
    /// The database failed.
    Storage(SecurityError),
}

impl fmt::Display for EnrollError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            EnrollError::Invalid => write!(
                formatter,
                "That enrollment code is wrong, already used or expired. Make a fresh one with `flaccy-server enroll --user <name>` and type it again."
            ),
            EnrollError::Locked { retry_after } => write!(
                formatter,
                "Too many wrong enrollment codes. Wait {} seconds, then try again with a code from `flaccy-server enroll --user <name>`.",
                retry_after.as_secs().max(1)
            ),
            EnrollError::Storage(source) => write!(formatter, "{source}"),
        }
    }
}

impl std::error::Error for EnrollError {}

impl From<SecurityError> for EnrollError {
    fn from(source: SecurityError) -> Self {
        EnrollError::Storage(source)
    }
}

/// Counts wrong codes across all callers, not per address, so guessing from many addresses gains nothing.
#[derive(Default)]
pub(crate) struct EnrollThrottle {
    failures: VecDeque<i64>,
    in_flight: usize,
    locked_until: Option<i64>,
}

impl EnrollThrottle {
    fn begin(&mut self, now: i64) -> Result<(), Duration> {
        if let Some(until) = self.locked_until {
            if now < until {
                return Err(Duration::from_millis((until - now) as u64));
            }
            self.locked_until = None;
        }
        let window = FAILURE_WINDOW.as_millis() as i64;
        while self.failures.front().is_some_and(|at| now - at >= window) {
            self.failures.pop_front();
        }
        if self.failures.len() + self.in_flight >= MAX_FAILURES {
            return Err(Duration::from_secs(1));
        }
        self.in_flight += 1;
        Ok(())
    }

    fn finish(&mut self, now: i64, outcome: Outcome) {
        self.in_flight = self.in_flight.saturating_sub(1);
        if outcome != Outcome::Failed {
            return;
        }
        self.failures.push_back(now);
        if self.failures.len() >= MAX_FAILURES {
            self.failures.clear();
            self.locked_until = Some(now + LOCKOUT.as_millis() as i64);
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Outcome {
    Failed,
    Succeeded,
    Neutral,
}

/// One redemption attempt in progress. Unless it is settled, dropping it, as a cancelled request does, counts as a wrong code.
struct Attempt {
    memory: Arc<Memory>,
    clock: Clock,
    outcome: Outcome,
}

impl Attempt {
    fn start(memory: &Arc<Memory>, clock: &Clock) -> Result<Self, Duration> {
        memory
            .enroll_throttle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .begin(clock())?;
        Ok(Self {
            memory: memory.clone(),
            clock: clock.clone(),
            outcome: Outcome::Failed,
        })
    }

    fn settle(&mut self, outcome: Outcome) {
        self.outcome = outcome;
    }
}

impl Drop for Attempt {
    fn drop(&mut self) {
        self.memory
            .enroll_throttle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .finish((self.clock)(), self.outcome);
    }
}

impl Store {
    /// Makes a code that enrolls one device for `user_id` within `ttl`. The code is returned once; only its hash is kept.
    pub async fn create_enrollment(&self, user_id: &UserId, ttl: Duration) -> Result<String, SecurityError> {
        let user_id = user_id.clone();
        let code = new_enrollment_code()?;
        let hash = hash_secret(&code);
        let ttl_millis = ttl.as_millis() as i64;
        self.write(move |transaction, stamp| {
            require_user(transaction, &user_id)?;
            transaction.execute(
                "INSERT INTO enrollments(code_hash, user_id, created_at, expires_at) VALUES (?1, ?2, ?3, ?4)",
                (hash.as_slice(), &user_id, stamp.at, stamp.at + ttl_millis),
            )?;
            stamp.record(transaction, "enroll.create", &format!("user={user_id} ttl_s={}", ttl.as_secs()))?;
            Ok(())
        })
        .await?;
        Ok(code)
    }

    /// Spends `code` and returns the user it enrolls. A code works once.
    ///
    /// Five wrong codes within a minute, from anyone, lock redemption for a minute, right codes included.
    pub async fn redeem(&self, code: &str) -> Result<UserId, EnrollError> {
        let mut attempt = Attempt::start(&self.memory, &self.clock).map_err(|retry_after| EnrollError::Locked { retry_after })?;
        let Some(canonical) = normalize_enrollment_code(code) else {
            return Err(EnrollError::Invalid);
        };
        let hash = hash_secret(&canonical);
        let redeemed = self
            .write(move |transaction, stamp| {
                let found = transaction
                    .query_row(
                        "SELECT user_id, expires_at, used_at FROM enrollments WHERE code_hash = ?1",
                        [hash.as_slice()],
                        |row| Ok((row.get::<_, UserId>(0)?, row.get::<_, i64>(1)?, row.get::<_, Option<i64>>(2)?)),
                    )
                    .optional()?;
                let Some((user_id, expires_at, None)) = found else {
                    return Ok(None);
                };
                if stamp.at >= expires_at {
                    return Ok(None);
                }
                let spent = transaction.execute(
                    "UPDATE enrollments SET used_at = ?1 WHERE code_hash = ?2 AND used_at IS NULL",
                    (stamp.at, hash.as_slice()),
                )?;
                if spent != 1 {
                    return Ok(None);
                }
                stamp.record(transaction, "enroll.redeem", &format!("user={user_id}"))?;
                Ok(Some(user_id))
            })
            .await;
        match redeemed {
            Ok(Some(user_id)) => {
                attempt.settle(Outcome::Succeeded);
                Ok(user_id)
            }
            Ok(None) => Err(EnrollError::Invalid),
            Err(error) => {
                attempt.settle(Outcome::Neutral);
                Err(error.into())
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn five_failures_lock_for_a_minute_and_the_lock_then_lifts() {
        let mut throttle = EnrollThrottle::default();
        for second in 0..5 {
            throttle.begin(second * 1000).unwrap();
            throttle.finish(second * 1000, Outcome::Failed);
        }
        assert_eq!(throttle.begin(5_000), Err(Duration::from_millis(59_000)));
        assert!(throttle.begin(64_000).is_ok());
    }

    #[test]
    fn failures_older_than_the_window_do_not_add_up() {
        let mut throttle = EnrollThrottle::default();
        for second in 0..4 {
            throttle.begin(second * 1000).unwrap();
            throttle.finish(second * 1000, Outcome::Failed);
        }
        throttle.begin(70_000).unwrap();
        throttle.finish(70_000, Outcome::Failed);
        assert!(throttle.begin(71_000).is_ok());
    }

    #[test]
    fn attempts_in_flight_count_so_a_burst_cannot_outguess_the_limit() {
        let mut throttle = EnrollThrottle::default();
        for _ in 0..MAX_FAILURES {
            throttle.begin(0).unwrap();
        }
        assert!(throttle.begin(0).is_err());
    }
}
