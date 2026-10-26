//! The server's connection loop: accepts connections, applies [`Limits`] and serves each with hyper.

use std::convert::Infallible;
use std::future::Future;
use std::io;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::serve::Listener;
use axum::Router;
use hyper::body::Incoming;
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper_util::rt::TokioIo;
use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};
use tokio::sync::watch;
use tokio::task::JoinSet;
use tower::ServiceExt;

use super::guard::{ConnectionAddr, Origin, Tagged};
use super::limits::{Admission, ConnectionLimits, Liveness};

const BUSY_RECHECK: Duration = Duration::from_secs(1);

/// A connection's I/O, reporting every byte moved so the connection's deadlines know it is alive.
struct Watched<T> {
    inner: T,
    liveness: Arc<Liveness>,
}

impl<T: AsyncRead + Unpin> AsyncRead for Watched<T> {
    fn poll_read(mut self: Pin<&mut Self>, context: &mut Context<'_>, buffer: &mut ReadBuf<'_>) -> Poll<io::Result<()>> {
        let before = buffer.filled().len();
        let polled = Pin::new(&mut self.inner).poll_read(context, buffer);
        if matches!(polled, Poll::Ready(Ok(()))) && buffer.filled().len() > before {
            self.liveness.bytes_read();
        }
        polled
    }
}

impl<T: AsyncWrite + Unpin> AsyncWrite for Watched<T> {
    fn poll_write(mut self: Pin<&mut Self>, context: &mut Context<'_>, bytes: &[u8]) -> Poll<io::Result<usize>> {
        let polled = Pin::new(&mut self.inner).poll_write(context, bytes);
        if matches!(polled, Poll::Ready(Ok(written)) if written > 0) {
            self.liveness.bytes_written();
        }
        polled
    }

    fn poll_flush(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(context)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(context)
    }
}

/// Counts a request as running on its connection until the answer is ready or the request is dropped.
struct RequestGuard(Arc<Liveness>);

impl RequestGuard {
    fn begin(liveness: &Arc<Liveness>) -> Self {
        liveness.request_started();
        Self(liveness.clone())
    }
}

impl Drop for RequestGuard {
    fn drop(&mut self) {
        self.0.request_finished();
    }
}

async fn answer(service: Tagged, liveness: Arc<Liveness>, request: Request<Incoming>) -> Result<axum::response::Response, Infallible> {
    let _running = RequestGuard::begin(&liveness);
    let response = service.oneshot(request.map(Body::new)).await?;
    if response.status() == StatusCode::SWITCHING_PROTOCOLS {
        liveness.upgraded();
    }
    Ok(response)
}

/// Resolves when the connection has outlived its deadline.
async fn expired(liveness: &Liveness) {
    loop {
        match liveness.time_left(Instant::now()) {
            Some(left) if left.is_zero() => return,
            Some(left) => tokio::time::sleep(left).await,
            None => tokio::time::sleep(BUSY_RECHECK).await,
        }
    }
}

async fn serve_connection<Io>(io: Io, service: Tagged, admission: Admission, mut draining: watch::Receiver<bool>)
where
    Io: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let liveness = admission.liveness.clone();
    let watched = TokioIo::new(Watched { inner: io, liveness: liveness.clone() });
    let handler = {
        let liveness = liveness.clone();
        service_fn(move |request| answer(service.clone(), liveness.clone(), request))
    };
    let connection = http1::Builder::new().serve_connection(watched, handler).with_upgrades();
    tokio::pin!(connection);
    let mut shutting_down = false;
    loop {
        tokio::select! {
            _ = connection.as_mut() => return,
            () = expired(&liveness) => return,
            () = admission.evicted.notified() => return,
            changed = draining.changed(), if !shutting_down => {
                if changed.is_ok() && *draining.borrow() {
                    shutting_down = true;
                    connection.as_mut().graceful_shutdown();
                }
            }
        }
    }
}

/// Accepts connections from `listener` and serves `app` to each until `draining` resolves, then lets requests in
/// flight finish. Connections beyond `limits` are closed unread, and one that is slow to send its request head or
/// idle too long is closed. Dropping the returned future closes every connection.
pub async fn serve<L>(listener: L, app: Router, limits: Arc<ConnectionLimits>, draining: impl Future<Output = ()>) -> io::Result<()>
where
    L: Listener,
    L::Io: AsyncRead + AsyncWrite + Unpin + Send + 'static,
    L::Addr: ConnectionAddr,
{
    let mut listener = listener;
    let mut connections = JoinSet::new();
    let (drain, draining_connections) = watch::channel(false);
    tokio::pin!(draining);
    loop {
        tokio::select! {
            () = &mut draining => break,
            (io, address) = listener.accept() => {
                let origin = address.origin();
                let Some(admission) = admit(&limits, origin) else {
                    continue;
                };
                let service = Tagged::new(app.clone(), origin);
                connections.spawn(serve_connection(io, service, admission, draining_connections.clone()));
            }
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    drain.send_replace(true);
    while connections.join_next().await.is_some() {}
    Ok(())
}

fn admit(limits: &Arc<ConnectionLimits>, origin: Origin) -> Option<Admission> {
    match origin {
        Origin::Tcp(peer) => limits.admit(peer.ip()),
        Origin::Socket => Some(limits.admit_trusted()),
    }
}
