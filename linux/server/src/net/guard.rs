//! The browser guard and the per-connection plumbing around the router.

use std::convert::Infallible;
use std::future::{ready, Ready};
use std::net::SocketAddr;
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

use super::hosts::AllowedHosts;

const REFUSED_CODE: &str = "browser_refused";
const MAX_ECHOED_HOST: usize = 80;

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
            Self::Host(_) => "Connect with this machine's name, its Tailscale or local address, or add the name you use to `hosts` in the configuration file and restart the server.",
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

impl Tagged {
    pub(super) fn new(router: Router, origin: Origin) -> Self {
        Self { router, origin }
    }
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

    #[test]
    fn the_echoed_host_is_short_and_printable() {
        let long = format!("{}\n", "a".repeat(500));
        assert_eq!(echoable(&long).len(), MAX_ECHOED_HOST);
    }
}
