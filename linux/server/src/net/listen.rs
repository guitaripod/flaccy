//! Easy mode's listener: every tailnet address plus loopback, with a source
//! filter applied before a single byte is read.

use std::collections::{HashMap, HashSet};
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::{Arc, Mutex, PoisonError, RwLock};
use std::time::{Duration, Instant};

use axum::serve::Listener;
use flaccy_library::logger;
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use super::tailnet::{self, source_allowed, TailnetAddresses};

const CATEGORY: &str = "server";
const RECONCILE_INTERVAL: Duration = Duration::from_secs(5);
const REFUSAL_REPORT_INTERVAL: Duration = Duration::from_secs(60);
const ACCEPT_BACKLOG: usize = 64;
const ACCEPT_ERROR_PAUSE: Duration = Duration::from_secs(1);
const LOOPBACKS: [IpAddr; 2] = [IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST)];

type SourceFilter = fn(IpAddr) -> bool;

/// Pauses after an `accept` failure that is not just one connection going away
/// (running out of file descriptors, for example), so the loop does not spin.
pub(super) async fn pause_after_accept_error(error: &io::Error) {
    if is_single_connection_error(error) {
        return;
    }
    logger::error(CATEGORY, &format!("accept failed: {error}; retrying in a second"));
    tokio::time::sleep(ACCEPT_ERROR_PAUSE).await;
}

fn is_single_connection_error(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::ConnectionRefused | io::ErrorKind::ConnectionAborted | io::ErrorKind::ConnectionReset
    )
}

/// Where the listener is bound right now, readable from anywhere.
#[derive(Clone, Debug)]
pub struct EasyHandle {
    bound: Arc<RwLock<Vec<SocketAddr>>>,
    tailnet: TailnetAddresses,
}

impl EasyHandle {
    fn new() -> Self {
        Self {
            bound: Arc::new(RwLock::new(Vec::new())),
            tailnet: TailnetAddresses::default(),
        }
    }

    /// Every address with its port the server accepts connections on, sorted.
    pub fn bound(&self) -> Vec<SocketAddr> {
        self.bound.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// The address local tools should use: 127.0.0.1 when bound, otherwise the first one.
    pub fn primary(&self) -> Option<SocketAddr> {
        let bound = self.bound();
        bound.iter().copied().find(|addr| addr.ip() == LOOPBACKS[0]).or_else(|| bound.first().copied())
    }

    /// The tailnet addresses among [`bound`](Self::bound), shared with the Host check.
    pub fn tailnet(&self) -> TailnetAddresses {
        self.tailnet.clone()
    }

    /// The `http://` URLs a client can use: tailnet addresses, or loopback when
    /// Tailscale is not up.
    pub fn urls(&self) -> Vec<String> {
        let bound = self.bound();
        let reachable: Vec<SocketAddr> = bound.iter().copied().filter(|addr| tailnet::is_tailnet(addr.ip())).collect();
        let chosen = if reachable.is_empty() { bound } else { reachable };
        chosen.iter().map(|addr| format!("http://{addr}")).collect()
    }

    fn publish(&self, mut bound: Vec<SocketAddr>) {
        bound.sort();
        self.tailnet.replace(tailnet::tailnet_only(bound.iter().map(SocketAddr::ip)));
        *self.bound.write().unwrap_or_else(PoisonError::into_inner) = bound;
    }
}

/// Counts refused connections and decides when the log hears about them.
struct RefusalLog {
    state: Mutex<RefusalState>,
}

struct RefusalState {
    pending: u64,
    last_report: Option<Instant>,
}

impl RefusalLog {
    fn new() -> Self {
        Self {
            state: Mutex::new(RefusalState { pending: 0, last_report: None }),
        }
    }

    fn note(&self, peer: IpAddr) {
        if let Some(message) = self.note_at(Instant::now(), peer) {
            logger::warn(CATEGORY, &message);
        }
    }

    /// Counts one refusal; returns the line to log when a minute has passed since the last one.
    fn note_at(&self, now: Instant, peer: IpAddr) -> Option<String> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.pending += 1;
        let due = state.last_report.is_none_or(|last| now.duration_since(last) >= REFUSAL_REPORT_INTERVAL);
        if !due {
            return None;
        }
        let count = std::mem::take(&mut state.pending);
        state.last_report = Some(now);
        Some(format!(
            "closed {count} connection(s) from outside the tailnet without reading them, latest from {peer}; only Tailscale and loopback addresses may connect, so reach this server over Tailscale"
        ))
    }
}

/// Which addresses to bind and which to let go.
#[derive(Debug, PartialEq, Eq)]
struct Plan {
    add: Vec<IpAddr>,
    drop: Vec<IpAddr>,
}

fn plan(bound: &HashSet<IpAddr>, wanted: &[IpAddr]) -> Plan {
    let add = wanted.iter().copied().filter(|ip| !bound.contains(ip)).collect();
    let mut drop: Vec<IpAddr> = bound.iter().copied().filter(|ip| !wanted.contains(ip)).collect();
    drop.sort();
    Plan { add, drop }
}

/// One bound address; its accept task stops when this is dropped.
struct Bound {
    task: JoinHandle<()>,
}

impl Drop for Bound {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn accept_loop(
    listener: TcpListener,
    admitted: mpsc::Sender<(TcpStream, SocketAddr)>,
    refusals: Arc<RefusalLog>,
    filter: SourceFilter,
) {
    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                if !filter(peer.ip()) {
                    refusals.note(peer.ip());
                    continue;
                }
                let _ = stream.set_nodelay(true);
                if admitted.send((stream, peer)).await.is_err() {
                    return;
                }
            }
            Err(error) => pause_after_accept_error(&error).await,
        }
    }
}

/// Keeps the set of bound addresses equal to loopback plus the tailnet addresses.
struct Manager {
    port: u16,
    bound: HashMap<IpAddr, Bound>,
    unbindable: HashSet<IpAddr>,
    tailnet_up: Option<bool>,
    lookup_failed: bool,
    admitted: mpsc::Sender<(TcpStream, SocketAddr)>,
    refusals: Arc<RefusalLog>,
    handle: EasyHandle,
    filter: SourceFilter,
}

impl Manager {
    async fn reconcile(&mut self, tailnet: io::Result<Vec<IpAddr>>) -> Option<io::Error> {
        let tailnet = match tailnet {
            Ok(found) => found,
            Err(error) => {
                self.report_lookup_failure(&error);
                return None;
            }
        };
        self.lookup_failed = false;
        self.report_tailnet_state(!tailnet.is_empty());
        let wanted: Vec<IpAddr> = LOOPBACKS.iter().copied().chain(tailnet).collect();
        let current: HashSet<IpAddr> = self.bound.keys().copied().collect();
        let Plan { add, drop } = plan(&current, &wanted);
        for ip in drop {
            self.bound.remove(&ip);
            logger::info(CATEGORY, &format!("{ip} is gone; stopped listening on it"));
        }
        self.unbindable.retain(|ip| wanted.contains(ip));
        let mut first_failure = None;
        for ip in add {
            if let Err(error) = self.bind_one(ip).await {
                first_failure.get_or_insert(error);
            }
        }
        self.handle.publish(self.bound.keys().map(|ip| SocketAddr::new(*ip, self.port)).collect());
        first_failure
    }

    async fn bind_one(&mut self, ip: IpAddr) -> io::Result<()> {
        let listener = match TcpListener::bind(SocketAddr::new(ip, self.port)).await {
            Ok(listener) => listener,
            Err(error) => {
                self.note_bind_failure(ip, &error);
                return Err(io::Error::new(error.kind(), format!("could not listen on {}: {error}", SocketAddr::new(ip, self.port))));
            }
        };
        self.unbindable.remove(&ip);
        let address = listener.local_addr()?;
        self.port = address.port();
        let task = tokio::spawn(accept_loop(listener, self.admitted.clone(), self.refusals.clone(), self.filter));
        self.bound.insert(ip, Bound { task });
        logger::info(CATEGORY, &format!("listening on http://{address}"));
        Ok(())
    }

    fn note_bind_failure(&mut self, ip: IpAddr, error: &io::Error) {
        if self.unbindable.insert(ip) {
            logger::warn(CATEGORY, &format!("could not listen on {ip}: {error}; trying again every few seconds"));
        }
    }

    fn report_tailnet_state(&mut self, up: bool) {
        if self.tailnet_up == Some(up) {
            return;
        }
        self.tailnet_up = Some(up);
        if up {
            logger::info(CATEGORY, "Tailscale is up; listening on its addresses and on loopback");
        } else {
            logger::warn(CATEGORY, "Tailscale is not up; listening on loopback only");
        }
    }

    fn report_lookup_failure(&mut self, error: &io::Error) {
        if !self.lookup_failed {
            logger::warn(CATEGORY, &format!("could not list network interfaces: {error}; keeping the current addresses"));
        }
        self.lookup_failed = true;
    }
}

async fn keep_current(mut manager: Manager) {
    let mut ticks = tokio::time::interval_at(tokio::time::Instant::now() + RECONCILE_INTERVAL, RECONCILE_INTERVAL);
    ticks.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        ticks.tick().await;
        let found = tokio::task::spawn_blocking(tailnet::addresses)
            .await
            .unwrap_or_else(|error| Err(io::Error::other(error)));
        manager.reconcile(found).await;
    }
}

/// A listener for easy mode: one logical listener over every tailnet address
/// and loopback, re-evaluated every five seconds. Connections from any other
/// source are closed unread. Dropping it stops all of its tasks.
pub struct EasyListener {
    incoming: mpsc::Receiver<(TcpStream, SocketAddr)>,
    handle: EasyHandle,
    keeper: JoinHandle<()>,
}

impl EasyListener {
    /// Binds `port` on 127.0.0.1, [::1] when the host has IPv6 loopback, and
    /// every tailnet address; port 0 picks one free port shared by all of them.
    /// Must run inside a Tokio runtime. Fails when 127.0.0.1 cannot be bound.
    pub async fn bind(port: u16) -> io::Result<Self> {
        Self::bind_filtered(port, source_allowed).await
    }

    async fn bind_filtered(port: u16, filter: SourceFilter) -> io::Result<Self> {
        let (admitted, incoming) = mpsc::channel(ACCEPT_BACKLOG);
        let handle = EasyHandle::new();
        let mut manager = Manager {
            port,
            bound: HashMap::new(),
            unbindable: HashSet::new(),
            tailnet_up: None,
            lookup_failed: false,
            admitted,
            refusals: Arc::new(RefusalLog::new()),
            handle: handle.clone(),
            filter,
        };
        let found = tokio::task::spawn_blocking(tailnet::addresses)
            .await
            .unwrap_or_else(|error| Err(io::Error::other(error)));
        let failure = manager.reconcile(found).await;
        if !manager.bound.contains_key(&LOOPBACKS[0]) {
            return Err(failure.unwrap_or_else(|| io::Error::other("127.0.0.1 was not bound")));
        }
        let keeper = tokio::spawn(keep_current(manager));
        Ok(Self { incoming, handle, keeper })
    }

    /// A handle that reports the bound addresses and feeds the Host check.
    pub fn handle(&self) -> EasyHandle {
        self.handle.clone()
    }
}

impl Drop for EasyListener {
    fn drop(&mut self) {
        self.keeper.abort();
    }
}

impl Listener for EasyListener {
    type Io = TcpStream;
    type Addr = SocketAddr;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        match self.incoming.recv().await {
            Some(connection) => connection,
            None => std::future::pending().await,
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        self.handle
            .primary()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotConnected, "the listener is bound to no address"))
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn the_plan_binds_new_addresses_and_drops_vanished_ones() {
        let bound: HashSet<IpAddr> = [ip("127.0.0.1"), ip("100.64.0.1")].into_iter().collect();
        let wanted = [ip("127.0.0.1"), ip("::1"), ip("100.64.0.2")];
        let result = plan(&bound, &wanted);
        assert_eq!(result.add, vec![ip("::1"), ip("100.64.0.2")]);
        assert_eq!(result.drop, vec![ip("100.64.0.1")]);
    }

    #[test]
    fn an_unchanged_set_plans_nothing() {
        let bound: HashSet<IpAddr> = [ip("127.0.0.1")].into_iter().collect();
        assert_eq!(plan(&bound, &[ip("127.0.0.1")]), Plan { add: vec![], drop: vec![] });
    }

    #[test]
    fn refusals_are_reported_at_most_once_a_minute() {
        let log = RefusalLog::new();
        let start = Instant::now();
        let peer = ip("203.0.113.9");
        assert!(log.note_at(start, peer).unwrap().contains("closed 1 connection"));
        assert!(log.note_at(start + Duration::from_secs(10), peer).is_none());
        assert!(log.note_at(start + Duration::from_secs(59), peer).is_none());
        let report = log.note_at(start + Duration::from_secs(60), peer).unwrap();
        assert!(report.contains("closed 3 connection"));
        assert!(report.contains("203.0.113.9"));
    }

    #[tokio::test]
    async fn bind_zero_shares_one_port_and_reports_it() {
        let listener = EasyListener::bind(0).await.unwrap();
        let bound = listener.handle().bound();
        let loopback = bound.iter().find(|addr| addr.ip() == ip("127.0.0.1")).unwrap();
        assert_ne!(loopback.port(), 0);
        assert!(bound.iter().all(|addr| addr.port() == loopback.port()));
        assert_eq!(listener.local_addr().unwrap().port(), loopback.port());
        assert!(listener.handle().urls().iter().all(|url| url.starts_with("http://")));
    }

    #[tokio::test]
    async fn a_second_bind_on_a_taken_port_fails_with_the_address() {
        let first = EasyListener::bind(0).await.unwrap();
        let port = first.local_addr().unwrap().port();
        let error = EasyListener::bind(port).await.err().unwrap();
        assert!(error.to_string().contains("127.0.0.1"), "{error}");
    }

    #[tokio::test]
    async fn a_refused_source_is_closed_without_an_answer() {
        let mut listener = EasyListener::bind_filtered(0, |_| false).await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut client = TcpStream::connect(address).await.unwrap();
        let _ = client.write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n").await;
        let mut received = Vec::new();
        let _ = tokio::time::timeout(Duration::from_secs(2), client.read_to_end(&mut received)).await.unwrap();
        assert!(received.is_empty());
        let admitted = tokio::time::timeout(Duration::from_millis(200), listener.accept()).await;
        assert!(admitted.is_err());
    }

    #[tokio::test]
    async fn an_allowed_source_is_handed_to_the_server() {
        let mut listener = EasyListener::bind(0).await.unwrap();
        let address = listener.local_addr().unwrap();
        let _client = TcpStream::connect(address).await.unwrap();
        let (_stream, peer) = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await.unwrap();
        assert!(peer.ip().is_loopback());
    }
}
