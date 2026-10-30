//! The network layer end to end: listeners, source handling and the browser guard.

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use axum::extract::{ConnectInfo, Extension};
use axum::routing::get;
use axum::Router;
use flaccy_server::net::{addresses, connections, guard_router, AllowedHosts, EasyListener, TrustedChannel};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

const IO_TIMEOUT: Duration = Duration::from_secs(5);

struct Reply {
    status: u16,
    body: String,
}

async fn who(ConnectInfo(peer): ConnectInfo<SocketAddr>) -> String {
    peer.ip().to_string()
}

async fn channel(trusted: Option<Extension<TrustedChannel>>) -> &'static str {
    if trusted.is_some() {
        "trusted"
    } else {
        "untrusted"
    }
}

fn app() -> Router {
    Router::new()
        .route("/", get(|| async { "ok" }))
        .route("/who", get(who))
        .route("/channel", get(channel))
}

fn request_text(path: &str, headers: &[(&str, &str)]) -> String {
    let mut text = format!("GET {path} HTTP/1.1\r\nConnection: close\r\n");
    for (name, value) in headers {
        text.push_str(&format!("{name}: {value}\r\n"));
    }
    text.push_str("\r\n");
    text
}

fn parse_reply(raw: &[u8]) -> Reply {
    let text = String::from_utf8_lossy(raw).into_owned();
    let status = text.split_whitespace().nth(1).and_then(|code| code.parse().ok()).unwrap_or(0);
    let body = text.split_once("\r\n\r\n").map(|(_, body)| body.to_string()).unwrap_or_default();
    Reply { status, body }
}

async fn exchange<S: AsyncReadExt + AsyncWriteExt + Unpin>(mut stream: S, request: String) -> Reply {
    stream.write_all(request.as_bytes()).await.unwrap();
    let mut raw = Vec::new();
    tokio::time::timeout(IO_TIMEOUT, stream.read_to_end(&mut raw)).await.unwrap().unwrap();
    parse_reply(&raw)
}

async fn get_tcp(address: SocketAddr, path: &str, headers: &[(&str, &str)]) -> Reply {
    let stream = TcpStream::connect(address).await.unwrap();
    exchange(stream, request_text(path, headers)).await
}

struct Running {
    address: SocketAddr,
    stop: oneshot::Sender<()>,
    task: JoinHandle<()>,
}

impl Running {
    async fn finish(self) {
        let _ = self.stop.send(());
        tokio::time::timeout(IO_TIMEOUT, self.task).await.unwrap().unwrap();
    }
}

async fn serve_guarded() -> (Running, flaccy_server::net::EasyHandle) {
    let listener = EasyListener::bind(0).await.unwrap();
    let handle = listener.handle();
    let hosts = AllowedHosts::new(&["music.example.org".to_string()], handle.tailnet());
    let service = connections(guard_router(app(), hosts));
    let (stop, stopped) = oneshot::channel::<()>();
    let loopback = loopback_address(&handle);
    let task = tokio::spawn(async move {
        let _ = axum::serve(listener, service).with_graceful_shutdown(async move { let _ = stopped.await; }).await;
    });
    (Running { address: loopback, stop, task }, handle)
}

fn loopback_address(handle: &flaccy_server::net::EasyHandle) -> SocketAddr {
    handle.bound().into_iter().find(|addr| addr.ip() == IpAddr::from([127, 0, 0, 1])).unwrap()
}

#[tokio::test]
async fn loopback_serves_a_good_host_end_to_end() {
    let (server, _) = serve_guarded().await;
    let host = server.address.to_string();
    let reply = get_tcp(server.address, "/", &[("Host", &host)]).await;
    assert_eq!((reply.status, reply.body.as_str()), (200, "ok"));
    server.finish().await;
}

#[tokio::test]
async fn handlers_see_the_tcp_peer_the_throttle_reads() {
    let (server, _) = serve_guarded().await;
    let reply = get_tcp(server.address, "/who", &[("Host", "localhost")]).await;
    assert_eq!(reply.status, 200);
    assert!(reply.body.contains("127.0.0.1"), "{}", reply.body);
    server.finish().await;
}

#[tokio::test]
async fn a_tcp_request_is_never_a_trusted_channel() {
    let (server, _) = serve_guarded().await;
    let reply = get_tcp(server.address, "/channel", &[("Host", "localhost")]).await;
    assert!(reply.body.contains("untrusted"), "{}", reply.body);
    server.finish().await;
}

#[tokio::test]
async fn the_guard_refuses_browsers_and_foreign_hosts_with_json() {
    let (server, _) = serve_guarded().await;
    let refused: [&[(&str, &str)]; 4] = [
        &[("Host", "localhost"), ("Origin", "https://evil.example")],
        &[("Host", "localhost"), ("Sec-Fetch-Site", "cross-site")],
        &[("Host", "evil.example")],
        &[],
    ];
    for headers in refused {
        let reply = get_tcp(server.address, "/", headers).await;
        assert_eq!(reply.status, 403, "{headers:?}");
        assert!(reply.body.contains("\"code\":\"browser_refused\""), "{}", reply.body);
        assert!(reply.body.contains("\"hint\""), "{}", reply.body);
    }
    server.finish().await;
}

#[tokio::test]
async fn a_preflight_is_refused_and_same_site_fetches_metadata_passes() {
    let (server, _) = serve_guarded().await;
    let preflight = "OPTIONS / HTTP/1.1\r\nConnection: close\r\nHost: localhost\r\nOrigin: https://evil.example\r\nAccess-Control-Request-Method: GET\r\n\r\n";
    let stream = TcpStream::connect(server.address).await.unwrap();
    let reply = exchange(stream, preflight.to_string()).await;
    assert_eq!(reply.status, 403);
    let same = get_tcp(server.address, "/", &[("Host", "localhost:4545"), ("Sec-Fetch-Site", "same-origin")]).await;
    assert_eq!(same.status, 200);
    let configured = get_tcp(server.address, "/", &[("Host", "music.example.org:4545")]).await;
    assert_eq!(configured.status, 200);
    let v6 = get_tcp(server.address, "/", &[("Host", "[::1]:4545")]).await;
    assert_eq!(v6.status, 200);
    server.finish().await;
}

#[tokio::test]
async fn a_stopped_server_releases_its_port() {
    let (server, handle) = serve_guarded().await;
    let address = server.address;
    server.finish().await;
    drop(handle);
    let outcome = tokio::time::timeout(IO_TIMEOUT, TcpStream::connect(address)).await.unwrap();
    assert!(outcome.is_err());
}

#[cfg(unix)]
mod unix_socket {
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener as StdUnixListener;
    use std::path::{Path, PathBuf};

    use flaccy_server::net::UnixListenerSecure;
    use tokio::net::UnixStream;

    use super::*;

    fn mode_of(path: &Path) -> u32 {
        std::fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    struct ShortDir(PathBuf);

    impl ShortDir {
        fn new(label: &str) -> Self {
            let path = PathBuf::from(format!("/tmp/fl-{label}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for ShortDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn socket_in(directory: &ShortDir) -> PathBuf {
        directory.path().join("run").join("s.sock")
    }

    #[tokio::test]
    async fn the_socket_is_private_and_so_is_the_directory_it_created() {
        let directory = ShortDir::new("priv");
        let path = socket_in(&directory);
        let listener = UnixListenerSecure::bind(&path).unwrap();
        assert_eq!(mode_of(&path), 0o600);
        assert_eq!(mode_of(path.parent().unwrap()), 0o700);
        drop(listener);
        assert!(!path.exists());
    }

    #[tokio::test]
    async fn a_stale_socket_file_is_replaced() {
        let directory = ShortDir::new("stale");
        let path = socket_in(&directory);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        drop(StdUnixListener::bind(&path).unwrap());
        assert!(path.exists());
        let listener = UnixListenerSecure::bind(&path).unwrap();
        assert_eq!(mode_of(&path), 0o600);
        drop(listener);
    }

    #[tokio::test]
    async fn a_live_socket_and_a_regular_file_are_refused() {
        let directory = ShortDir::new("refuse");
        let path = socket_in(&directory);
        let live = UnixListenerSecure::bind(&path).unwrap();
        let busy = UnixListenerSecure::bind(&path).err().unwrap();
        assert_eq!(busy.kind(), std::io::ErrorKind::AddrInUse);
        drop(live);
        std::fs::write(&path, b"keep me").unwrap();
        let foreign = UnixListenerSecure::bind(&path).err().unwrap();
        assert_eq!(foreign.kind(), std::io::ErrorKind::AlreadyExists);
        assert_eq!(std::fs::read(&path).unwrap(), b"keep me");
    }

    #[tokio::test]
    async fn a_path_too_long_for_a_socket_is_refused_with_the_fix_before_anything_is_created() {
        let directory = ShortDir::new("long");
        let path = directory.path().join("a".repeat(120)).join("s.sock");
        let refused = UnixListenerSecure::bind(&path).err().unwrap();
        assert_eq!(refused.kind(), std::io::ErrorKind::InvalidInput);
        let message = refused.to_string();
        assert!(message.contains("bytes long") && message.contains("choose a shorter path"), "{message}");
        assert!(!path.parent().unwrap().exists());
    }

    #[tokio::test]
    async fn requests_over_the_socket_carry_the_trusted_channel_marker() {
        let directory = ShortDir::new("serve");
        let path = socket_in(&directory);
        let listener = UnixListenerSecure::bind(&path).unwrap();
        let hosts = AllowedHosts::new(&[], Default::default());
        let service = connections(guard_router(app(), hosts));
        let server = tokio::spawn(async move { let _ = axum::serve(listener, service).await; });
        let stream = UnixStream::connect(&path).await.unwrap();
        let reply = exchange(stream, request_text("/channel", &[("Host", "localhost")])).await;
        assert!(reply.body.contains("trusted") && !reply.body.contains("untrusted"), "{}", reply.body);
        server.abort();
    }
}

#[tokio::test]
#[ignore = "needs a tailnet address on this machine"]
async fn real_tailnet_address() {
    let tailnet = addresses().unwrap_or_default();
    let Some(first) = tailnet.first().copied() else {
        println!("no tailnet address on this host; nothing to prove");
        return;
    };
    let (server, handle) = serve_guarded().await;
    let bound = handle.bound();
    println!("bound: {bound:?}");
    println!("urls: {:?}", handle.urls());
    for ip in &tailnet {
        let address = bound.iter().copied().find(|addr| addr.ip() == *ip).unwrap();
        let host = address.to_string();
        let reply = get_tcp(address, "/who", &[("Host", &host)]).await;
        println!("{address} -> {} {}", reply.status, reply.body.lines().last().unwrap_or(""));
        assert_eq!(reply.status, 200);
        assert!(reply.body.contains(&ip.to_string()), "peer should be the tailnet address itself: {}", reply.body);
        let wrong_host = get_tcp(address, "/", &[("Host", "evil.example")]).await;
        assert_eq!(wrong_host.status, 403);
    }
    assert!(handle.tailnet().contains(first));
    server.finish().await;
}
