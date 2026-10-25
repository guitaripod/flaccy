//! Failed-login backoff per client address. Ten failed logins from one address
//! within ten minutes lock that address out for ten minutes: while locked, its
//! attempts are refused without looking at the credentials, so a guessing
//! client gets nothing from the account, and other addresses are unaffected.

use std::collections::HashMap;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, Instant};

use axum::extract::ConnectInfo;
use axum::http::request::Parts;
use flaccy_library::logger;

use crate::error::ApiError;

/// Failed logins from one address that lock it out.
pub const MAX_FAILURES: u32 = 10;
/// The span in which failures count. A streak restarts once this has passed since its first failure.
pub const FAILURE_WINDOW: Duration = Duration::from_secs(10 * 60);
/// How long an address stays locked, counted from the failure that locked it.
pub const LOCKOUT: Duration = Duration::from_secs(10 * 60);
const UNKNOWN_ADDRESS: IpAddr = IpAddr::V4(Ipv4Addr::UNSPECIFIED);

/// The failures one address has made in the current window, and its lockout if it has one.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Streak {
    started: Instant,
    failures: u32,
    locked_until: Option<Instant>,
}

impl Streak {
    fn fresh(now: Instant) -> Self {
        Self {
            started: now,
            failures: 0,
            locked_until: None,
        }
    }

    /// Whether the streak still changes an answer: its window is open or its lockout has not ended.
    fn is_live(&self, now: Instant) -> bool {
        now.duration_since(self.started) < FAILURE_WINDOW || self.is_locked(now)
    }

    fn is_locked(&self, now: Instant) -> bool {
        self.locked_until.is_some_and(|until| now < until)
    }
}

/// Failed-login counters for every client address that has recently failed.
#[derive(Default)]
pub struct LoginThrottle {
    streaks: Mutex<HashMap<IpAddr, Streak>>,
}

impl LoginThrottle {
    /// Runs `check` for a login from `address` unless that address is locked out.
    ///
    /// A locked address gets the lockout error and `check` is not called. A
    /// failed login (code 40 or 44) is counted against the address; the tenth
    /// one still answers with its own error and the next attempt is refused. A
    /// success clears only that address's count.
    pub fn attempt<T>(
        &self,
        address: IpAddr,
        now: Instant,
        check: impl FnOnce() -> Result<T, ApiError>,
    ) -> Result<T, ApiError> {
        if self.is_locked(address, now) {
            return Err(lockout_error(address));
        }
        let result = check();
        match &result {
            Ok(_) => {
                self.streaks(now).remove(&address);
            }
            Err(error) if is_login_failure(error) => self.record_failure(address, now),
            Err(_) => {}
        }
        result
    }

    fn streaks(&self, now: Instant) -> MutexGuard<'_, HashMap<IpAddr, Streak>> {
        let mut streaks = self.streaks.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        streaks.retain(|_, streak| streak.is_live(now));
        streaks
    }

    fn is_locked(&self, address: IpAddr, now: Instant) -> bool {
        self.streaks(now)
            .get(&address)
            .is_some_and(|streak| streak.is_locked(now))
    }

    fn record_failure(&self, address: IpAddr, now: Instant) {
        let mut streaks = self.streaks(now);
        let streak = streaks.entry(address).or_insert_with(|| Streak::fresh(now));
        if now.duration_since(streak.started) >= FAILURE_WINDOW {
            *streak = Streak::fresh(now);
        }
        streak.failures += 1;
        if streak.failures >= MAX_FAILURES && streak.locked_until.is_none() {
            streak.locked_until = Some(now + LOCKOUT);
            logger::warn(
                "server",
                &format!("refusing logins from {address} for ten minutes after {MAX_FAILURES} failed logins"),
            );
        }
    }
}

/// The address a login is counted against: the TCP peer, or with `behind_proxy`
/// the first address in `X-Forwarded-For`, falling back to the peer when that
/// header is missing or not an address.
pub fn client_address(parts: &Parts, behind_proxy: bool) -> IpAddr {
    let peer = parts
        .extensions
        .get::<ConnectInfo<SocketAddr>>()
        .map(|info| info.0.ip())
        .unwrap_or(UNKNOWN_ADDRESS);
    if behind_proxy {
        forwarded_client(parts).unwrap_or(peer)
    } else {
        peer
    }
}

fn forwarded_client(parts: &Parts) -> Option<IpAddr> {
    parts
        .headers
        .get("x-forwarded-for")?
        .to_str()
        .ok()?
        .split(',')
        .next()?
        .trim()
        .parse()
        .ok()
}

fn is_login_failure(error: &ApiError) -> bool {
    matches!(error.code, 40 | 44)
}

fn lockout_error(address: IpAddr) -> ApiError {
    ApiError::new(
        40,
        format!(
            "Too many failed logins from {address}. Wait 10 minutes, then check the username and password or API key saved in your app."
        ),
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::http::Request;

    fn address(last: u8) -> IpAddr {
        IpAddr::V4(Ipv4Addr::new(203, 0, 113, last))
    }

    fn refuse() -> Result<(), ApiError> {
        Err(ApiError::new(40, "wrong"))
    }

    fn assert_locked<T: std::fmt::Debug>(result: Result<T, ApiError>) {
        let error = result.unwrap_err();
        assert_eq!(error.code, 40);
        assert!(error.message.starts_with("Too many failed logins"), "{error}");
    }

    fn fail_times(throttle: &LoginThrottle, from: IpAddr, now: Instant, times: u32) {
        for _ in 0..times {
            assert_eq!(throttle.attempt(from, now, refuse).unwrap_err().code, 40);
        }
    }

    fn parts(peer: Option<&str>, forwarded: Option<&str>) -> Parts {
        let mut builder = Request::builder();
        if let Some(value) = forwarded {
            builder = builder.header("x-forwarded-for", value);
        }
        let (mut parts, _) = builder.body(()).unwrap().into_parts();
        if let Some(peer) = peer {
            parts.extensions.insert(ConnectInfo(peer.parse::<SocketAddr>().unwrap()));
        }
        parts
    }

    #[test]
    fn ten_failures_lock_the_address_and_the_eleventh_with_the_right_password_is_refused() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        fail_times(&throttle, address(1), start, MAX_FAILURES);
        let mut checked = false;
        let refused = throttle
            .attempt(address(1), start + Duration::from_secs(9 * 60 + 59), || {
                checked = true;
                Ok(())
            })
            .unwrap_err();
        assert!(!checked);
        assert_eq!(refused.code, 40);
        assert_eq!(
            refused.message,
            "Too many failed logins from 203.0.113.1. Wait 10 minutes, then check the username and password or API key saved in your app."
        );
    }

    #[test]
    fn an_attempt_after_the_lockout_is_checked_again() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        fail_times(&throttle, address(1), start, MAX_FAILURES);
        let after = start + LOCKOUT + Duration::from_secs(1);
        assert_eq!(throttle.attempt(address(1), after, || Ok("in")), Ok("in"));
    }

    #[test]
    fn nine_failures_do_not_lock() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        fail_times(&throttle, address(1), start, MAX_FAILURES - 1);
        assert_eq!(throttle.attempt(address(1), start, || Ok(7)), Ok(7));
    }

    #[test]
    fn failures_spread_past_the_window_do_not_add_up() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        fail_times(&throttle, address(1), start, MAX_FAILURES - 1);
        let later = start + FAILURE_WINDOW;
        fail_times(&throttle, address(1), later, MAX_FAILURES - 1);
        assert_eq!(throttle.attempt(address(1), later, || Ok(())), Ok(()));
    }

    #[test]
    fn a_lockout_on_one_address_leaves_another_address_alone() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        fail_times(&throttle, address(1), start, MAX_FAILURES);
        assert_locked(throttle.attempt(address(1), start, || Ok(())));
        assert_eq!(throttle.attempt(address(2), start, || Ok(())), Ok(()));
    }

    #[test]
    fn a_success_on_another_address_does_not_reset_a_count() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        fail_times(&throttle, address(1), start, MAX_FAILURES - 1);
        assert_eq!(throttle.attempt(address(2), start, || Ok(())), Ok(()));
        fail_times(&throttle, address(1), start, 1);
        assert_locked(throttle.attempt(address(1), start, || Ok(())));
    }

    #[test]
    fn a_success_clears_only_its_own_address() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        fail_times(&throttle, address(1), start, MAX_FAILURES - 1);
        assert_eq!(throttle.attempt(address(1), start, || Ok(())), Ok(()));
        fail_times(&throttle, address(1), start, MAX_FAILURES - 1);
        assert_eq!(throttle.attempt(address(1), start, || Ok(())), Ok(()));
    }

    #[test]
    fn a_wrong_key_counts_and_a_malformed_request_does_not() {
        let throttle = LoginThrottle::default();
        let start = Instant::now();
        for _ in 0..MAX_FAILURES {
            let _ = throttle.attempt(address(1), start, || Err::<(), _>(ApiError::new(44, "unknown key")));
        }
        assert_locked(throttle.attempt(address(1), start, || Ok(())));
        let other = address(2);
        for _ in 0..MAX_FAILURES * 2 {
            let _ = throttle.attempt(other, start, || Err::<(), _>(ApiError::new(10, "no login")));
        }
        assert_eq!(throttle.attempt(other, start, || Ok(())), Ok(()));
    }

    #[test]
    fn the_peer_is_the_address_unless_a_proxy_is_declared() {
        let spoofed = parts(Some("127.0.0.1:4000"), Some("198.51.100.7"));
        assert_eq!(client_address(&spoofed, false), address_of("127.0.0.1"));
        assert_eq!(client_address(&spoofed, true), address_of("198.51.100.7"));
    }

    #[test]
    fn a_proxy_chain_is_read_from_its_first_address() {
        let chained = parts(Some("127.0.0.1:4000"), Some("198.51.100.7, 10.0.0.2"));
        assert_eq!(client_address(&chained, true), address_of("198.51.100.7"));
        let ipv6 = parts(Some("127.0.0.1:4000"), Some("2001:db8::9"));
        assert_eq!(client_address(&ipv6, true), address_of("2001:db8::9"));
    }

    #[test]
    fn a_missing_or_unreadable_forwarded_header_falls_back_to_the_peer() {
        let none = parts(Some("127.0.0.1:4000"), None);
        assert_eq!(client_address(&none, true), address_of("127.0.0.1"));
        let garbage = parts(Some("127.0.0.1:4000"), Some("not-an-address, 1.2.3.4"));
        assert_eq!(client_address(&garbage, true), address_of("127.0.0.1"));
    }

    #[test]
    fn a_request_without_a_peer_is_counted_as_one_unknown_address() {
        assert_eq!(client_address(&parts(None, None), false), UNKNOWN_ADDRESS);
        assert_eq!(client_address(&parts(None, Some("198.51.100.7")), true), address_of("198.51.100.7"));
    }

    fn address_of(text: &str) -> IpAddr {
        text.parse().unwrap()
    }
}
