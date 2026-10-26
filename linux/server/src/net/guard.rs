//! The browser guard and the per-connection plumbing around the router.

use std::convert::Infallible;
use std::future::{ready, Ready};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::task::{Context, Poll};

use axum::body::Body;
use axum::extract::{ConnectInfo, Request, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::middleware::{from_fn_with_state, Next};
use axum::response::{IntoResponse, Response};
use axum::serve::{IncomingStream, Listener};
use axum::{Json, Router};
use serde_json::json;
use tower::Service;

use super::tailnet::TailnetAddresses;

const REFUSED_CODE: &str = "browser_refused";
const LOCALHOST_NAME: &str = "localhost";
const MAX_ECHOED_HOST: usize = 80;

/// A host name or address as it appears in a `Host` header, port removed.
#[derive(Clone, Debug, PartialEq, Eq)]
enum HostName {
    Ip(IpAddr),
    Name(String),
}

impl HostName {
    /// Reads `name`, `name:port`, `1.2.3.4[:port]` or `[v6][:port]`; `None` when malformed.
    fn parse(raw: &str) -> Option<Self> {
        let text = raw.trim().to_ascii_lowercase();
        let host = match text.strip_prefix('[') {
            Some(rest) => {
                let (inner, after) = rest.split_once(']')?;
                valid_port_suffix(after)?;
                return inner.parse::<Ipv6Addr>().ok().map(|ip| Self::Ip(IpAddr::V6(ip)));
            }
            None => strip_port(&text)?,
        };
        if host.is_empty() {
            return None;
        }
        Some(match host.parse::<Ipv4Addr>() {
            Ok(ip) => Self::Ip(IpAddr::V4(ip)),
            Err(_) => Self::Name(host.trim_end_matches('.').to_string()),
        })
    }
}

fn valid_port_suffix(after: &str) -> Option<()> {
    match after.strip_prefix(':') {
        None if after.is_empty() => Some(()),
        Some(port) if is_port(port) => Some(()),
        _ => None,
    }
}

fn strip_port(text: &str) -> Option<&str> {
    match text.split_once(':') {
        None => Some(text),
        Some((host, port)) if is_port(port) => Some(host),
        Some(_) => None,
    }
}

fn is_port(text: &str) -> bool {
    !text.is_empty() && text.len() <= 5 && text.bytes().all(|byte| byte.is_ascii_digit())
}

/// The `Host` values the server answers to: the configured names, the current
/// tailnet addresses, `localhost`, `127.0.0.1` and `[::1]`, each with or
/// without a port. The tailnet part is re-read on every request.
#[derive(Clone, Debug)]
pub struct AllowedHosts {
    configured: Arc<[HostName]>,
    tailnet: TailnetAddresses,
}

impl AllowedHosts {
    /// `configured` are the `hosts` of the configuration file; entries that are
    /// not valid host names are skipped. `tailnet` is usually
    /// [`EasyHandle::tailnet`](super::EasyHandle::tailnet).
    pub fn new(configured: &[String], tailnet: TailnetAddresses) -> Self {
        let parsed: Vec<HostName> = configured.iter().filter_map(|entry| HostName::parse(entry)).collect();
        Self { configured: parsed.into(), tailnet }
    }

    /// Whether a raw `Host` header value is allowed.
    pub fn allows(&self, host_header: &str) -> bool {
        let Some(host) = HostName::parse(host_header) else {
            return false;
        };
        if self.configured.contains(&host) {
            return true;
        }
        match host {
            HostName::Name(name) => name == LOCALHOST_NAME,
            HostName::Ip(ip) => ip == IpAddr::V4(Ipv4Addr::LOCALHOST) || ip == IpAddr::V6(Ipv6Addr::LOCALHOST) || self.tailnet.contains(ip),
        }
    }
}

enum Refusal {
    Origin,
    CrossSite,
    Host(String),
}

impl Refusal {
    fn message(&self) -> String {
        match self {
            Self::Origin => "This request carries an Origin header, which only a web page sends, and Flaccy Server never answers web pages.".to_string(),
            Self::CrossSite => "This request was made by a page on another site (Sec-Fetch-Site is cross-site), and Flaccy Server never answers those.".to_string(),
            Self::Host(host) => format!("The Host '{host}' is not one this server answers to, which is how DNS-rebinding attacks are stopped."),
        }
    }

    fn hint(&self) -> &'static str {
        match self {
            Self::Origin | Self::CrossSite => "Use a Flaccy app or another native client instead of a browser.",
            Self::Host(_) => "Connect with this machine's Tailscale address, localhost, or a name listed under `hosts` in the configuration file, then restart the server.",
        }
    }

    fn into_response(self) -> Response {
        let body = json!({"error": {"code": REFUSED_CODE, "message": self.message(), "hint": self.hint()}});
        (StatusCode::FORBIDDEN, Json(body)).into_response()
    }
}

fn find_refusal(hosts: &AllowedHosts, request: &Request) -> Option<Refusal> {
    let headers = request.headers();
    if headers.contains_key(header::ORIGIN) {
        return Some(Refusal::Origin);
    }
    if header_text(headers, "sec-fetch-site").is_some_and(|value| value.eq_ignore_ascii_case("cross-site")) {
        return Some(Refusal::CrossSite);
    }
    let host = host_of(request);
    if host.as_deref().is_some_and(|host| hosts.allows(host)) {
        return None;
    }
    Some(Refusal::Host(echoable(host.as_deref().unwrap_or("(none)"))))
}

fn header_text<'a>(headers: &'a HeaderMap, name: &str) -> Option<&'a str> {
    headers.get(name)?.to_str().ok()
}

fn host_of(request: &Request) -> Option<String> {
    let header = header_text(request.headers(), "host");
    header.or_else(|| request.uri().authority().map(|authority| authority.as_str())).map(str::to_string)
}

fn echoable(host: &str) -> String {
    host.chars().filter(|c| !c.is_control()).take(MAX_ECHOED_HOST).collect()
}

/// Middleware that answers 403 `browser_refused` to any request with an
/// `Origin` header, a cross-site `Sec-Fetch-Site`, or a `Host` outside the
/// allowed set. CORS is never enabled, so a preflight is refused by the Origin rule.
pub async fn browser_guard(State(hosts): State<AllowedHosts>, request: Request, next: Next) -> Response {
    match find_refusal(&hosts, &request) {
        Some(refusal) => refusal.into_response(),
        None => next.run(request).await,
    }
}

/// `router` with [`browser_guard`] in front of every route.
pub fn guard_router(router: Router, hosts: AllowedHosts) -> Router {
    router.layer(from_fn_with_state(hosts, browser_guard))
}

/// Marker in the request extensions of every request that arrived over the
/// Unix socket; absent for TCP. Handlers trust identity headers only with it.
#[derive(Clone, Copy, Debug)]
pub struct TrustedChannel;

/// How a connection reached the server.
#[derive(Clone, Copy, Debug)]
pub enum Origin {
    /// Over TCP from this peer.
    Tcp(SocketAddr),
    /// Over the Unix socket.
    Socket,
}

impl Origin {
    fn attach(self, request: &mut Request<Body>) {
        match self {
            Self::Tcp(peer) => {
                request.extensions_mut().insert(ConnectInfo(peer));
            }
            Self::Socket => {
                request.extensions_mut().insert(TrustedChannel);
            }
        }
    }
}

/// A listener's address type, so [`connections`] can tell handlers where a request came from.
pub trait ConnectionAddr: Clone + Send + Sync + 'static {
    /// How the connection arrived.
    fn origin(&self) -> Origin;
}

impl ConnectionAddr for SocketAddr {
    fn origin(&self) -> Origin {
        Origin::Tcp(*self)
    }
}

/// Serves a [`Router`] to every accepted connection with its origin attached:
/// `ConnectInfo<SocketAddr>` for TCP (what `throttle::client_address` reads) or
/// [`TrustedChannel`] for the Unix socket.
#[derive(Clone)]
pub struct Connections {
    router: Router,
}

/// Wraps `router` for `axum::serve(listener, connections(router))`.
pub fn connections(router: Router) -> Connections {
    Connections { router }
}

/// The router bound to one connection's origin.
#[derive(Clone)]
pub struct Tagged {
    router: Router,
    origin: Origin,
}

impl<'a, L> Service<IncomingStream<'a, L>> for Connections
where
    L: Listener,
    L::Addr: ConnectionAddr,
{
    type Response = Tagged;
    type Error = Infallible;
    type Future = Ready<Result<Tagged, Infallible>>;

    fn poll_ready(&mut self, _: &mut Context<'_>) -> Poll<Result<(), Infallible>> {
        Poll::Ready(Ok(()))
    }

    fn call(&mut self, stream: IncomingStream<'a, L>) -> Self::Future {
        ready(Ok(Tagged {
            router: self.router.clone(),
            origin: stream.remote_addr().origin(),
        }))
    }
}

impl Service<Request<Body>> for Tagged {
    type Response = Response;
    type Error = Infallible;
    type Future = <Router as Service<Request<Body>>>::Future;

    fn poll_ready(&mut self, context: &mut Context<'_>) -> Poll<Result<(), Infallible>> {
        <Router as Service<Request<Body>>>::poll_ready(&mut self.router, context)
    }

    fn call(&mut self, mut request: Request<Body>) -> Self::Future {
        self.origin.attach(&mut request);
        self.router.call(request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hosts(configured: &[&str], tailnet: &[&str]) -> AllowedHosts {
        let shared = TailnetAddresses::default();
        shared.replace(tailnet.iter().map(|ip| ip.parse().unwrap()).collect());
        let configured: Vec<String> = configured.iter().map(|name| name.to_string()).collect();
        AllowedHosts::new(&configured, shared)
    }

    #[test]
    fn ports_are_stripped_from_names_and_addresses() {
        let allowed = hosts(&["arch.tail1234.ts.net"], &["100.91.211.44"]);
        for good in ["localhost", "localhost:4545", "127.0.0.1:80", "arch.tail1234.ts.net:4545", "ARCH.tail1234.ts.net", "100.91.211.44:4545"] {
            assert!(allowed.allows(good), "{good}");
        }
    }

    #[test]
    fn ipv6_literals_are_read_with_their_brackets() {
        let allowed = hosts(&[], &["fd7a:115c:a1e0::6b01:d32d"]);
        assert!(allowed.allows("[::1]"));
        assert!(allowed.allows("[::1]:4545"));
        assert!(allowed.allows("[fd7a:115c:a1e0::6b01:d32d]:4545"));
        assert!(!allowed.allows("::1"));
        assert!(!allowed.allows("[::2]:4545"));
        assert!(!allowed.allows("[::1]x"));
    }

    #[test]
    fn unknown_malformed_and_empty_hosts_are_refused() {
        let allowed = hosts(&["music.example.org"], &[]);
        for bad in ["evil.example", "127.0.0.2", "100.91.211.44", "localhost:notaport", "localhost:", "", ":80", "a:1:2"] {
            assert!(!allowed.allows(bad), "{bad}");
        }
    }

    #[test]
    fn tailnet_addresses_are_read_per_call() {
        let shared = TailnetAddresses::default();
        let allowed = AllowedHosts::new(&[], shared.clone());
        assert!(!allowed.allows("100.64.0.9"));
        shared.replace(vec!["100.64.0.9".parse().unwrap()]);
        assert!(allowed.allows("100.64.0.9:4545"));
        shared.replace(Vec::new());
        assert!(!allowed.allows("100.64.0.9"));
    }

    #[test]
    fn a_configured_address_with_a_port_matches_without_it() {
        let allowed = hosts(&["192.168.1.5:4545", "[fd00::5]"], &[]);
        assert!(allowed.allows("192.168.1.5"));
        assert!(allowed.allows("[fd00::5]:80"));
    }

    #[test]
    fn the_echoed_host_is_short_and_printable() {
        let long = format!("{}\n", "a".repeat(500));
        assert_eq!(echoable(&long).len(), MAX_ECHOED_HOST);
    }
}
