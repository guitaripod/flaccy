use crate::faults::{Fault, Faults};
use crate::metrics::{Latency, Route};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{sleep, timeout};

const CLIENT_READ_LIMIT: Duration = Duration::from_secs(30);
const CONNECT_LIMIT: Duration = Duration::from_secs(3);
const UPSTREAM_LIMIT: Duration = Duration::from_secs(90);
const MAX_HEAD_BYTES: usize = 64 * 1024;

struct Context {
    upstream: SocketAddr,
    faults: Arc<Faults>,
    latency: Arc<Latency>,
}

struct Request {
    route: Route,
    bytes: Vec<u8>,
}

/// Starts the fault-injecting proxy on an ephemeral loopback port and answers where it listens.
pub async fn start(
    upstream: SocketAddr,
    faults: Arc<Faults>,
    latency: Arc<Latency>,
) -> Result<SocketAddr, String> {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .map_err(|error| format!("proxy cannot listen: {error}"))?;
    let address = listener
        .local_addr()
        .map_err(|error| format!("proxy has no address: {error}"))?;
    let context = Arc::new(Context { upstream, faults, latency });
    tokio::spawn(accept_loop(listener, context));
    Ok(address)
}

async fn accept_loop(listener: TcpListener, context: Arc<Context>) {
    loop {
        let Ok((stream, _)) = listener.accept().await else {
            continue;
        };
        tokio::spawn(serve_connection(stream, context.clone()));
    }
}

async fn serve_connection(mut client: TcpStream, context: Arc<Context>) {
    if context.faults.refusing() {
        context.faults.note_refused();
        reset(client);
        return;
    }
    let Some(request) = read_request(&mut client).await else {
        return;
    };
    let fault = context.faults.roll();
    let started = Instant::now();
    match fault {
        Some(Fault::DropRequest) => reset(client),
        Some(Fault::DropResponse) => {
            let _ = forward(context.upstream, &request.bytes).await;
            reset(client);
        }
        Some(Fault::Truncate) => {
            if let Some(answer) = forward(context.upstream, &request.bytes).await {
                let cut = context.faults.cut_at(answer.len());
                deliver(client, &answer[..cut]).await;
            }
        }
        Some(Fault::Duplicate) => {
            let (first, _) = tokio::join!(
                forward(context.upstream, &request.bytes),
                forward(context.upstream, &request.bytes)
            );
            relay(client, first).await;
        }
        Some(Fault::Delay) => {
            sleep(Duration::from_millis(context.faults.pick_ms(80, 1800))).await;
            relay(client, forward(context.upstream, &request.bytes).await).await;
        }
        Some(Fault::Pause) => {
            sleep(Duration::from_millis(context.faults.pick_ms(2000, 6000))).await;
            relay(client, forward(context.upstream, &request.bytes).await).await;
        }
        None => {
            let answer = forward(context.upstream, &request.bytes).await;
            let delivered = answer.is_some();
            relay(client, answer).await;
            if delivered {
                context.latency.record(request.route, started.elapsed());
            }
        }
    }
}

async fn relay(client: TcpStream, answer: Option<Vec<u8>>) {
    match answer {
        Some(bytes) => deliver(client, &bytes).await,
        None => reset(client),
    }
}

async fn deliver(mut client: TcpStream, bytes: &[u8]) {
    let _ = client.write_all(bytes).await;
    let _ = client.shutdown().await;
}

#[allow(deprecated)]
fn reset(client: TcpStream) {
    let _ = client.set_linger(Some(Duration::ZERO));
    drop(client);
}

async fn forward(upstream: SocketAddr, request: &[u8]) -> Option<Vec<u8>> {
    let mut stream = timeout(CONNECT_LIMIT, TcpStream::connect(upstream)).await.ok()?.ok()?;
    stream.write_all(request).await.ok()?;
    let mut answer = Vec::new();
    timeout(UPSTREAM_LIMIT, stream.read_to_end(&mut answer)).await.ok()?.ok()?;
    if answer.is_empty() {
        return None;
    }
    Some(answer)
}

async fn read_request(client: &mut TcpStream) -> Option<Request> {
    let mut buffer = Vec::with_capacity(4096);
    let head_end = loop {
        if let Some(position) = find(&buffer, b"\r\n\r\n") {
            break position + 4;
        }
        if buffer.len() > MAX_HEAD_BYTES || !read_more(client, &mut buffer).await {
            return None;
        }
    };
    let head = String::from_utf8_lossy(&buffer[..head_end]).into_owned();
    let length = content_length(&head);
    while buffer.len() < head_end + length {
        if !read_more(client, &mut buffer).await {
            return None;
        }
    }
    Some(Request {
        route: route_of(&head),
        bytes: rewrite(&head, &buffer[head_end..head_end + length]),
    })
}

async fn read_more(client: &mut TcpStream, buffer: &mut Vec<u8>) -> bool {
    let mut chunk = [0u8; 16 * 1024];
    match timeout(CLIENT_READ_LIMIT, client.read(&mut chunk)).await {
        Ok(Ok(count)) if count > 0 => {
            buffer.extend_from_slice(&chunk[..count]);
            true
        }
        _ => false,
    }
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

fn content_length(head: &str) -> usize {
    head.lines()
        .filter_map(|line| line.split_once(':'))
        .find(|(name, _)| name.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, value)| value.trim().parse().ok())
        .unwrap_or(0)
}

fn route_of(head: &str) -> Route {
    let line = head.lines().next().unwrap_or_default();
    if line.contains("/sync/push") {
        Route::Push
    } else if line.contains("/sync/pull") {
        Route::Pull
    } else {
        Route::Other
    }
}

fn rewrite(head: &str, body: &[u8]) -> Vec<u8> {
    let mut out = String::new();
    for line in head.split("\r\n").filter(|line| !line.is_empty()) {
        let lowered = line.to_ascii_lowercase();
        if lowered.starts_with("connection:") || lowered.starts_with("proxy-connection:") {
            continue;
        }
        out.push_str(line);
        out.push_str("\r\n");
    }
    out.push_str("Connection: close\r\n\r\n");
    let mut bytes = out.into_bytes();
    bytes.extend_from_slice(body);
    bytes
}
