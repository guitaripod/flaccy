//! Enrollment codes: short-lived, single-use secrets that turn into a device.

use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::net::{IpAddr, Ipv4Addr};
use std::sync::Arc;
use std::time::Duration;

use rusqlite::{OptionalExtension, Transaction};

use super::devices::NewDevice;
use super::keys::{hash_secret, new_enrollment_code, normalize_enrollment_code};
use super::users::require_user;
use super::{Clock, DeviceId, Memory, SecurityError, Stamp, Store, UserId};

/// Wrong codes within [`FAILURE_WINDOW`] from one source address that lock it out of redeeming.
pub const MAX_FAILURES: usize = 5;
/// Wrong codes within [`FAILURE_WINDOW`] from all addresses together that lock redeeming for everyone.
pub const GLOBAL_MAX_FAILURES: usize = 60;
const UNKNOWN_SOURCE: IpAddr = IpAddr::V4(Ipv4Addr::UNSPECIFIED);
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

/// Wrong codes from one source address, or from all of them, within a window.
#[derive(Default)]
struct Window {
    failures: VecDeque<i64>,
    in_flight: usize,
    locked_until: Option<i64>,
}

impl Window {
    fn forget_old(&mut self, now: i64) {
        let window = FAILURE_WINDOW.as_millis() as i64;
        while self.failures.front().is_some_and(|at| now - at >= window) {
            self.failures.pop_front();
        }
        if self.locked_until.is_some_and(|until| now >= until) {
            self.locked_until = None;
        }
    }

    fn check(&mut self, now: i64, limit: usize) -> Result<(), Duration> {
        self.forget_old(now);
        if let Some(until) = self.locked_until {
            return Err(Duration::from_millis((until - now) as u64));
        }
        if self.failures.len() + self.in_flight >= limit {
            return Err(Duration::from_secs(1));
        }
        Ok(())
    }

    fn finish(&mut self, now: i64, outcome: Outcome, limit: usize) {
        self.in_flight = self.in_flight.saturating_sub(1);
        if outcome != Outcome::Failed {
            return;
        }
        self.failures.push_back(now);
        if self.failures.len() >= limit {
            self.failures.clear();
            self.locked_until = Some(now + LOCKOUT.as_millis() as i64);
        }
    }

    fn is_idle(&mut self, now: i64) -> bool {
        self.forget_old(now);
        self.failures.is_empty() && self.in_flight == 0 && self.locked_until.is_none()
    }
}

/// Counts wrong codes per source address and across all of them, so one guesser cannot lock the others out and
/// guessing from many addresses at once still meets a ceiling.
#[derive(Default)]
pub(crate) struct EnrollThrottle {
    global: Window,
    sources: HashMap<IpAddr, Window>,
}

impl EnrollThrottle {
    fn begin(&mut self, source: IpAddr, now: i64) -> Result<(), Duration> {
        self.sources.retain(|_, window| !window.is_idle(now));
        self.global.check(now, GLOBAL_MAX_FAILURES)?;
        let window = self.sources.entry(source).or_default();
        window.check(now, MAX_FAILURES)?;
        window.in_flight += 1;
        self.global.in_flight += 1;
        Ok(())
    }

    fn finish(&mut self, source: IpAddr, now: i64, outcome: Outcome) {
        self.global.finish(now, outcome, GLOBAL_MAX_FAILURES);
        if let Some(window) = self.sources.get_mut(&source) {
            window.finish(now, outcome, MAX_FAILURES);
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
    source: IpAddr,
    outcome: Outcome,
}

impl Attempt {
    fn start(memory: &Arc<Memory>, clock: &Clock, source: IpAddr) -> Result<Self, Duration> {
        memory
            .enroll_throttle
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .begin(source, clock())?;
        Ok(Self {
            memory: memory.clone(),
            clock: clock.clone(),
            source,
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
            .finish(self.source, (self.clock)(), self.outcome);
    }
}

/// A device that just enrolled: its user, its id and its token, which is shown once.
#[derive(Debug)]
pub struct Enrolled {
    /// The user the code was made for.
    pub user: UserId,
    /// The new device.
    pub device: DeviceId,
    /// The device's token; only its hash is kept.
    pub token: String,
}

/// Marks the code spent and answers its user, or `None` when it is unknown, used or expired.
fn spend_code(transaction: &Transaction<'_>, stamp: &Stamp, hash: &[u8]) -> Result<Option<UserId>, SecurityError> {
    let found = transaction
        .query_row(
            "SELECT user_id, expires_at, used_at FROM enrollments WHERE code_hash = ?1",
            [hash],
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
        (stamp.at, hash),
    )?;
    if spent != 1 {
        return Ok(None);
    }
    stamp.record(transaction, "enroll.redeem", &format!("user={user_id}"))?;
    Ok(Some(user_id))
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

    /// Spends `code` for a caller whose address is unknown, as the command line and the tests are, and returns the user it enrolls.
    pub async fn redeem(&self, code: &str) -> Result<UserId, EnrollError> {
        self.redeem_from(UNKNOWN_SOURCE, code).await
    }

    /// Spends `code` for a caller at `source` and returns the user it enrolls. A code works once.
    ///
    /// Five wrong codes within a minute from one address lock that address out of redeeming for a minute, right
    /// codes included; sixty from all addresses together lock everyone out for a minute.
    pub async fn redeem_from(&self, source: IpAddr, code: &str) -> Result<UserId, EnrollError> {
        let mut attempt = Attempt::start(&self.memory, &self.clock, source).map_err(|retry_after| EnrollError::Locked { retry_after })?;
        let Some(canonical) = normalize_enrollment_code(code) else {
            return Err(EnrollError::Invalid);
        };
        let hash = hash_secret(&canonical);
        let redeemed = self.write(move |transaction, stamp| spend_code(transaction, stamp, hash.as_slice())).await;
        Self::settle_redemption(&mut attempt, redeemed)
    }

    /// Spends `code` and creates the device it enrolls in one transaction, so a failure after the code was found
    /// good, such as a full disk, leaves the code unspent for another try. The throttle counts `source` as in
    /// [`Store::redeem_from`].
    pub async fn enroll_device(&self, source: IpAddr, code: &str, name: &str, platform: &str) -> Result<Enrolled, EnrollError> {
        let mut attempt = Attempt::start(&self.memory, &self.clock, source).map_err(|retry_after| EnrollError::Locked { retry_after })?;
        let Some(canonical) = normalize_enrollment_code(code) else {
            return Err(EnrollError::Invalid);
        };
        let prepared = NewDevice::prepare(name, platform);
        let new_device = match prepared {
            Ok(new_device) => new_device,
            Err(error) => {
                attempt.settle(Outcome::Neutral);
                return Err(error.into());
            }
        };
        let hash = hash_secret(&canonical);
        let (id, token) = (new_device.id.clone(), new_device.token.clone());
        let enrolled = self
            .write(move |transaction, stamp| {
                let Some(user_id) = spend_code(transaction, stamp, hash.as_slice())? else {
                    return Ok(None);
                };
                new_device.insert(transaction, stamp, &user_id)?;
                Ok(Some(user_id))
            })
            .await;
        let user = Self::settle_redemption(&mut attempt, enrolled)?;
        Ok(Enrolled { user, device: id, token })
    }

    fn settle_redemption(attempt: &mut Attempt, redeemed: Result<Option<UserId>, SecurityError>) -> Result<UserId, EnrollError> {
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

    fn source(last: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(100, 64, 0, last))
    }

    fn fail(throttle: &mut EnrollThrottle, from: IpAddr, at: i64) {
        throttle.begin(from, at).unwrap();
        throttle.finish(from, at, Outcome::Failed);
    }

    #[test]
    fn five_failures_lock_a_source_for_a_minute_and_the_lock_then_lifts() {
        let mut throttle = EnrollThrottle::default();
        for second in 0..5 {
            fail(&mut throttle, source(1), second * 1000);
        }
        assert_eq!(throttle.begin(source(1), 5_000), Err(Duration::from_millis(59_000)));
        assert!(throttle.begin(source(1), 64_000).is_ok());
    }

    #[test]
    fn a_locked_source_does_not_lock_another() {
        let mut throttle = EnrollThrottle::default();
        for second in 0..5 {
            fail(&mut throttle, source(1), second * 1000);
        }
        assert!(throttle.begin(source(1), 5_000).is_err());
        assert!(throttle.begin(source(2), 5_000).is_ok());
    }

    #[test]
    fn failures_older_than_the_window_do_not_add_up() {
        let mut throttle = EnrollThrottle::default();
        for second in 0..4 {
            fail(&mut throttle, source(1), second * 1000);
        }
        fail(&mut throttle, source(1), 70_000);
        assert!(throttle.begin(source(1), 71_000).is_ok());
    }

    #[test]
    fn attempts_in_flight_count_so_a_burst_cannot_outguess_the_limit() {
        let mut throttle = EnrollThrottle::default();
        for _ in 0..MAX_FAILURES {
            throttle.begin(source(1), 0).unwrap();
        }
        assert!(throttle.begin(source(1), 0).is_err());
        assert!(throttle.begin(source(2), 0).is_ok());
    }

    #[test]
    fn sixty_failures_from_many_sources_lock_everyone_for_a_minute() {
        let mut throttle = EnrollThrottle::default();
        for guess in 0..GLOBAL_MAX_FAILURES {
            fail(&mut throttle, source((guess / 4) as u8), guess as i64);
        }
        assert!(throttle.begin(source(200), 100).is_err());
        assert!(throttle.begin(source(201), 61_000).is_ok());
    }

    #[test]
    fn idle_sources_are_forgotten() {
        let mut throttle = EnrollThrottle::default();
        for guess in 0..50 {
            fail(&mut throttle, source(guess), 0);
        }
        throttle.begin(source(100), 120_000).unwrap();
        assert_eq!(throttle.sources.len(), 1);
    }
}
