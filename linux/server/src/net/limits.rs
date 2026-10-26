//! How many connections the server holds, and for how long: a cap in all, a cap per source address, a deadline
//! for a request head to arrive and an idle timeout between requests, so a flood of stalled sockets cannot
//! keep a legitimate device out.

use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use flaccy_library::logger;
use tokio::sync::Notify;

const CATEGORY: &str = "server";
const REPORT_INTERVAL: Duration = Duration::from_secs(60);

/// The limits `serve` applies to connections.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    /// Connections held at once, whoever opened them.
    pub max_connections: usize,
    /// Connections held at once for one source address.
    pub max_per_source: usize,
    /// How long a connection may take to deliver a request's head, counted from when it opened or when the
    /// first byte of the request arrived.
    pub head_timeout: Duration,
    /// How long a connection may sit idle between requests.
    pub idle_timeout: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            max_connections: 512,
            max_per_source: 64,
            head_timeout: Duration::from_secs(10),
            idle_timeout: Duration::from_secs(75),
        }
    }
}

struct Activity {
    in_flight: usize,
    head_started: Option<Instant>,
    last_active: Instant,
    exempt: bool,
}

/// What one connection has been doing, for its deadlines.
pub(super) struct Liveness {
    limits: Limits,
    activity: Mutex<Activity>,
}

impl Liveness {
    pub(super) fn new(limits: Limits, now: Instant) -> Self {
        Self {
            limits,
            activity: Mutex::new(Activity {
                in_flight: 0,
                head_started: Some(now),
                last_active: now,
                exempt: false,
            }),
        }
    }

    fn activity(&self) -> std::sync::MutexGuard<'_, Activity> {
        self.activity.lock().unwrap_or_else(PoisonError::into_inner)
    }

    pub(super) fn bytes_read(&self) {
        let now = Instant::now();
        let mut activity = self.activity();
        activity.last_active = now;
        if activity.in_flight == 0 && activity.head_started.is_none() {
            activity.head_started = Some(now);
        }
    }

    pub(super) fn bytes_written(&self) {
        self.activity().last_active = Instant::now();
    }

    pub(super) fn request_started(&self) {
        let mut activity = self.activity();
        activity.in_flight += 1;
        activity.head_started = None;
    }

    pub(super) fn request_finished(&self) {
        let mut activity = self.activity();
        activity.in_flight = activity.in_flight.saturating_sub(1);
        activity.last_active = Instant::now();
    }

    pub(super) fn upgraded(&self) {
        self.activity().exempt = true;
    }

    fn is_evictable(&self) -> bool {
        let activity = self.activity();
        activity.in_flight == 0 && !activity.exempt
    }

    /// How long until the connection must be closed, `None` while a request runs or after an upgrade.
    pub(super) fn time_left(&self, now: Instant) -> Option<Duration> {
        let activity = self.activity();
        if activity.exempt || activity.in_flight > 0 {
            return None;
        }
        let deadline = match activity.head_started {
            Some(started) => started + self.limits.head_timeout,
            None => activity.last_active + self.limits.idle_timeout,
        };
        Some(deadline.saturating_duration_since(now))
    }
}

struct Entry {
    source: IpAddr,
    opened: Instant,
    evict: Arc<Notify>,
    liveness: Arc<Liveness>,
}

#[derive(Default)]
struct Registry {
    next_id: u64,
    live: HashMap<u64, Entry>,
    per_source: HashMap<IpAddr, usize>,
}

impl Registry {
    fn count_of(&self, source: IpAddr) -> usize {
        self.per_source.get(&source).copied().unwrap_or(0)
    }

    fn remove(&mut self, id: u64) -> bool {
        let Some(entry) = self.live.remove(&id) else {
            return false;
        };
        if let Some(count) = self.per_source.get_mut(&entry.source) {
            *count -= 1;
            if *count == 0 {
                self.per_source.remove(&entry.source);
            }
        }
        true
    }

    fn heaviest_source(&self) -> Option<(IpAddr, usize)> {
        self.per_source.iter().map(|(source, count)| (*source, *count)).max_by_key(|(_, count)| *count)
    }

    fn oldest_idle_of(&self, source: IpAddr) -> Option<u64> {
        self.live
            .iter()
            .filter(|(_, entry)| entry.source == source && entry.liveness.is_evictable())
            .min_by_key(|(_, entry)| entry.opened)
            .map(|(id, _)| *id)
    }

    fn insert(&mut self, source: IpAddr, evict: Arc<Notify>, liveness: Arc<Liveness>) -> u64 {
        self.next_id += 1;
        let id = self.next_id;
        *self.per_source.entry(source).or_insert(0) += 1;
        self.live.insert(id, Entry { source, opened: Instant::now(), evict, liveness });
        id
    }
}

struct Refusals {
    pending: u64,
    last_report: Option<Instant>,
}

/// Counts the connections held and decides who gets in.
pub struct ConnectionLimits {
    limits: Limits,
    registry: Mutex<Registry>,
    refusals: Mutex<Refusals>,
}

/// A held connection's place in the count; dropping it frees the place.
pub(super) struct Admission {
    owner: Arc<ConnectionLimits>,
    id: u64,
    pub(super) evicted: Arc<Notify>,
    pub(super) liveness: Arc<Liveness>,
}

impl Drop for Admission {
    fn drop(&mut self) {
        self.owner.registry.lock().unwrap_or_else(PoisonError::into_inner).remove(self.id);
    }
}

impl ConnectionLimits {
    /// Limits that nothing is held under yet.
    pub fn new(limits: Limits) -> Arc<Self> {
        Arc::new(Self {
            limits,
            registry: Mutex::new(Registry::default()),
            refusals: Mutex::new(Refusals { pending: 0, last_report: None }),
        })
    }

    /// Lets a connection from `source` in, or answers `None` when the server is full of it.
    ///
    /// A source already at its own cap is refused. When the server is full, a source that holds fewer
    /// connections than the heaviest one takes over that one's oldest connection that is not serving a request.
    pub(super) fn admit(self: &Arc<Self>, source: IpAddr) -> Option<Admission> {
        let liveness = Arc::new(Liveness::new(self.limits, Instant::now()));
        let evicted = Arc::new(Notify::new());
        let mut registry = self.registry.lock().unwrap_or_else(PoisonError::into_inner);
        let held = registry.count_of(source);
        let room = held < self.limits.max_per_source && (registry.live.len() < self.limits.max_connections || Self::make_room(&mut registry, held));
        if !room {
            drop(registry);
            self.note_refusal(source);
            return None;
        }
        let id = registry.insert(source, evicted.clone(), liveness.clone());
        Some(Admission { owner: self.clone(), id, evicted, liveness })
    }

    /// Lets in a connection that arrived over the Unix socket, which only the machine's own user can reach, so no cap applies.
    pub(super) fn admit_trusted(self: &Arc<Self>) -> Admission {
        Admission {
            owner: self.clone(),
            id: 0,
            evicted: Arc::new(Notify::new()),
            liveness: Arc::new(Liveness::new(self.limits, Instant::now())),
        }
    }

    fn make_room(registry: &mut Registry, held: usize) -> bool {
        let Some((heaviest, count)) = registry.heaviest_source() else {
            return false;
        };
        if count <= held + 1 {
            return false;
        }
        let Some(victim) = registry.oldest_idle_of(heaviest) else {
            return false;
        };
        if let Some(entry) = registry.live.get(&victim) {
            entry.evict.notify_one();
        }
        registry.remove(victim)
    }

    fn note_refusal(&self, source: IpAddr) {
        if let Some(message) = self.refusal_report(Instant::now(), source) {
            logger::warn(CATEGORY, &message);
        }
    }

    /// Counts one refusal; returns the line to log when a minute has passed since the last one.
    fn refusal_report(&self, now: Instant, source: IpAddr) -> Option<String> {
        let mut refusals = self.refusals.lock().unwrap_or_else(PoisonError::into_inner);
        refusals.pending += 1;
        if refusals.last_report.is_some_and(|last| now.duration_since(last) < REPORT_INTERVAL) {
            return None;
        }
        let count = std::mem::take(&mut refusals.pending);
        refusals.last_report = Some(now);
        Some(format!(
            "closed {count} connection(s) without reading them because the server holds its limit of {} connections ({} per address), latest from {source}",
            self.limits.max_connections, self.limits.max_per_source
        ))
    }

    /// Connections held right now.
    pub fn held(&self) -> usize {
        self.registry.lock().unwrap_or_else(PoisonError::into_inner).live.len()
    }
}

#[cfg(test)]
mod tests {
    use futures_util::FutureExt;

    use super::*;

    fn ip(last: u8) -> IpAddr {
        IpAddr::from([100, 64, 0, last])
    }

    fn small() -> Arc<ConnectionLimits> {
        ConnectionLimits::new(Limits { max_connections: 6, max_per_source: 4, ..Limits::default() })
    }

    #[test]
    fn a_source_stops_at_its_own_cap() {
        let limits = small();
        let held: Vec<_> = (0..4).map(|_| limits.admit(ip(1)).unwrap()).collect();
        assert!(limits.admit(ip(1)).is_none());
        assert!(limits.admit(ip(2)).is_some());
        drop(held);
        assert!(limits.admit(ip(1)).is_some());
    }

    #[test]
    fn a_full_server_makes_room_for_a_lighter_source_by_closing_the_heaviest_one_connection() {
        let limits = small();
        let heavy: Vec<_> = (0..4).map(|_| limits.admit(ip(1)).unwrap()).collect();
        let _other: Vec<_> = (0..2).map(|_| limits.admit(ip(2)).unwrap()).collect();
        assert_eq!(limits.held(), 6);
        let newcomer = limits.admit(ip(3)).unwrap();
        assert_eq!(limits.held(), 6);
        assert!(heavy.iter().any(|admission| admission.evicted.notified().now_or_never().is_some()));
        drop(newcomer);
    }

    #[test]
    fn a_full_server_refuses_a_source_that_is_not_lighter_than_the_rest() {
        let limits = ConnectionLimits::new(Limits { max_connections: 4, max_per_source: 4, ..Limits::default() });
        let _two: Vec<_> = (0..2).map(|_| limits.admit(ip(1)).unwrap()).collect();
        let _more: Vec<_> = (0..2).map(|_| limits.admit(ip(2)).unwrap()).collect();
        let newcomer = limits.admit(ip(3));
        assert!(newcomer.is_some());
        assert!(limits.admit(ip(2)).is_none());
    }

    #[test]
    fn a_connection_serving_a_request_is_never_the_one_closed() {
        let limits = ConnectionLimits::new(Limits { max_connections: 3, max_per_source: 3, ..Limits::default() });
        let busy: Vec<_> = (0..3).map(|_| limits.admit(ip(1)).unwrap()).collect();
        busy.iter().for_each(|admission| admission.liveness.request_started());
        assert!(limits.admit(ip(2)).is_none());
    }

    #[test]
    fn a_connection_gets_ten_seconds_for_its_head_then_seventy_five_idle() {
        let start = Instant::now();
        let liveness = Liveness::new(Limits::default(), start);
        assert_eq!(liveness.time_left(start + Duration::from_secs(4)), Some(Duration::from_secs(6)));
        liveness.request_started();
        assert_eq!(liveness.time_left(start + Duration::from_secs(400)), None);
        liveness.request_finished();
        let idle = liveness.time_left(Instant::now()).unwrap();
        assert!(idle > Duration::from_secs(70) && idle <= Duration::from_secs(75), "{idle:?}");
        liveness.upgraded();
        assert_eq!(liveness.time_left(Instant::now()), None);
    }

    #[test]
    fn refusals_are_reported_at_most_once_a_minute() {
        let limits = small();
        let start = Instant::now();
        assert!(limits.refusal_report(start, ip(1)).unwrap().contains("closed 1 connection"));
        assert!(limits.refusal_report(start + Duration::from_secs(30), ip(1)).is_none());
        let report = limits.refusal_report(start + Duration::from_secs(60), ip(9)).unwrap();
        assert!(report.contains("closed 2 connection") && report.contains("100.64.0.9"), "{report}");
    }
}
