//! Connection limits over real sockets: a flood of stalled connections neither starves a device nor outlives its deadline.

use std::net::SocketAddr;
#[cfg(not(target_os = "linux"))]
use std::net::{Ipv4Addr, Ipv6Addr};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::routing::get;
use axum::Router;
use flaccy_server::net::descriptors::raise_soft_limit;
use flaccy_server::net::{serve, ConnectionLimits, Limits};
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpSocket, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

const PARTIAL_HEAD: &[u8] = b"GET /flaccy/v1/hello HTTP/1.1\r\nHost: arch\r\n";
const FULL_REQUEST: &[u8] = b"GET /flaccy/v1/hello HTTP/1.1\r\nHost: arch\r\n\r\n";

struct Running {
    address: SocketAddr,
    limits: Arc<ConnectionLimits>,
    stop: Option<oneshot::Sender<()>>,
    task: JoinHandle<()>,
}

impl Running {
    async fn stop(mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        let _ = tokio::time::timeout(Duration::from_secs(5), self.task).await;
    }
}

async fn echo(socket: WebSocket) {
    let (mut sender, mut receiver) = socket.split();
    while let Some(Ok(Message::Text(text))) = receiver.next().await {
        if sender.send(Message::Text(text)).await.is_err() {
            return;
        }
    }
}

async fn slow() -> &'static str {
    tokio::time::sleep(Duration::from_millis(900)).await;
    "slow"
}

async fn start(limits: Limits) -> Running {
    start_on("127.0.0.1:0", limits).await
}

async fn start_on(bind: &str, limits: Limits) -> Running {
    raise_soft_limit();
    let app = Router::new()
        .route("/flaccy/v1/hello", get(|| async { "hello" }))
        .route("/slow", get(slow))
        .route("/ws", get(|upgrade: WebSocketUpgrade| async move { upgrade.on_upgrade(echo) }));
    let listener = TcpListener::bind(bind).await.unwrap();
    let address = listener.local_addr().unwrap();
    let held = ConnectionLimits::new(limits);
    let (stop, stopped) = oneshot::channel::<()>();
    let task = tokio::spawn({
        let held = held.clone();
        async move {
            let _ = serve(listener, app, held, async move {
                let _ = stopped.await;
            })
            .await;
        }
    });
    Running { address, limits: held, stop: Some(stop), task }
}

/// The loopback address the many connections of the per-source test come from. Only Linux has 127.0.0.2; elsewhere
/// they share 127.0.0.1 with the hello request, so the test lets them go before asking.
const HOLDING_SOURCE: u8 = if cfg!(target_os = "linux") { 2 } else { 1 };

async fn connect_from(source: u8, to: SocketAddr, first_bytes: &[u8]) -> TcpStream {
    let socket = TcpSocket::new_v4().unwrap();
    socket.bind(format!("127.0.0.{source}:0").parse().unwrap()).unwrap();
    let mut stream = socket.connect(to).await.unwrap();
    stream.write_all(first_bytes).await.unwrap();
    stream
}

async fn is_closed_by_server(stream: &mut TcpStream, within: Duration) -> bool {
    let mut byte = [0u8; 1];
    matches!(tokio::time::timeout(within, stream.read(&mut byte)).await, Ok(Ok(0)) | Ok(Err(_)))
}

async fn hello_status(address: SocketAddr) -> Option<String> {
    let mut stream = TcpStream::connect(address).await.ok()?;
    stream.write_all(b"GET /flaccy/v1/hello HTTP/1.1\r\nHost: arch\r\nConnection: close\r\n\r\n").await.ok()?;
    let mut raw = Vec::new();
    tokio::time::timeout(Duration::from_secs(3), stream.read_to_end(&mut raw)).await.ok()?.ok()?;
    String::from_utf8_lossy(&raw).lines().next().map(str::to_owned)
}

async fn read_hello_response(stream: &mut TcpStream) -> String {
    let mut seen = Vec::new();
    let mut chunk = [0u8; 512];
    while !seen.ends_with(b"hello") {
        let read = tokio::time::timeout(Duration::from_secs(3), stream.read(&mut chunk)).await.unwrap().unwrap();
        assert!(read > 0, "the connection closed before the answer");
        seen.extend_from_slice(&chunk[..read]);
    }
    String::from_utf8_lossy(&seen).into_owned()
}

#[tokio::test(flavor = "multi_thread")]
#[cfg(target_os = "linux")]
async fn seven_hundred_stalled_sockets_leave_hello_answering() {
    let running = start(Limits::default()).await;
    let mut stalled = Vec::new();
    for count in 0..700u32 {
        let source = 2 + (count % 12) as u8;
        stalled.push(connect_from(source, running.address, PARTIAL_HEAD).await);
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(running.limits.held() <= 512, "{} connections held", running.limits.held());
    let started = Instant::now();
    let status = hello_status(running.address).await;
    assert_eq!(status.as_deref(), Some("HTTP/1.1 200 OK"));
    assert!(started.elapsed() < Duration::from_secs(2));
    running.stop().await;
}

/// Off Linux the loopback has no 127.0.0.2 to 127.0.0.13, so one source floods and another, over IPv6, asks: the
/// server listens on both families, and the flooding source's cap is lifted so the whole house fills.
#[cfg(not(target_os = "linux"))]
#[tokio::test(flavor = "multi_thread")]
async fn seven_hundred_stalled_sockets_from_one_source_leave_another_source_answering() {
    let running = start_on("[::]:0", Limits { max_per_source: 1_000, ..Limits::default() }).await;
    let port = running.address.port();
    let flood = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stalled = Vec::new();
    for _ in 0..700u32 {
        stalled.push(connect_from(1, flood, PARTIAL_HEAD).await);
    }
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(running.limits.held() <= 512, "{} connections held", running.limits.held());
    let started = Instant::now();
    let status = hello_status(SocketAddr::from((Ipv6Addr::LOCALHOST, port))).await;
    assert_eq!(status.as_deref(), Some("HTTP/1.1 200 OK"));
    assert!(started.elapsed() < Duration::from_secs(2));
    running.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn one_source_holds_at_most_sixty_four_connections() {
    let running = start(Limits::default()).await;
    let mut streams = Vec::new();
    for _ in 0..100 {
        streams.push(connect_from(HOLDING_SOURCE, running.address, PARTIAL_HEAD).await);
    }
    let mut refused = 0;
    for stream in &mut streams {
        if is_closed_by_server(stream, Duration::from_millis(100)).await {
            refused += 1;
        }
    }
    assert_eq!(refused, 36);
    if HOLDING_SOURCE == 1 {
        streams.clear();
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    assert_eq!(hello_status(running.address).await.as_deref(), Some("HTTP/1.1 200 OK"));
    running.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_stalled_head_is_closed_at_its_deadline_and_a_kept_alive_connection_later() {
    let limits = Limits { head_timeout: Duration::from_millis(300), idle_timeout: Duration::from_millis(1_200), ..Limits::default() };
    let running = start(limits).await;

    let mut stalled = connect_from(1, running.address, PARTIAL_HEAD).await;
    let started = Instant::now();
    assert!(is_closed_by_server(&mut stalled, Duration::from_secs(2)).await);
    let waited = started.elapsed();
    assert!(waited >= Duration::from_millis(250) && waited < Duration::from_millis(1_100), "{waited:?}");

    let mut kept = connect_from(1, running.address, FULL_REQUEST).await;
    assert!(read_hello_response(&mut kept).await.starts_with("HTTP/1.1 200 OK"));
    tokio::time::sleep(Duration::from_millis(600)).await;
    kept.write_all(FULL_REQUEST).await.unwrap();
    assert!(read_hello_response(&mut kept).await.starts_with("HTTP/1.1 200 OK"));
    let idle_since = Instant::now();
    assert!(is_closed_by_server(&mut kept, Duration::from_secs(3)).await);
    assert!(idle_since.elapsed() >= Duration::from_millis(1_000), "{:?}", idle_since.elapsed());
    running.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_request_still_running_and_an_upgraded_socket_outlive_the_deadlines() {
    let limits = Limits { head_timeout: Duration::from_millis(300), idle_timeout: Duration::from_millis(300), ..Limits::default() };
    let running = start(limits).await;

    let mut slow = connect_from(1, running.address, b"GET /slow HTTP/1.1\r\nHost: arch\r\nConnection: close\r\n\r\n").await;
    let mut raw = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), slow.read_to_end(&mut raw)).await.unwrap().unwrap();
    assert!(String::from_utf8_lossy(&raw).ends_with("slow"));

    let (mut socket, _) = tokio_tungstenite::connect_async(format!("ws://{}/ws", running.address)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(900)).await;
    socket.send(tokio_tungstenite::tungstenite::Message::text("still here")).await.unwrap();
    let echoed = tokio::time::timeout(Duration::from_secs(2), socket.next()).await.unwrap().unwrap().unwrap();
    assert_eq!(echoed.into_text().unwrap().as_str(), "still here");
    running.stop().await;
}
