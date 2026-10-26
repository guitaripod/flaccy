//! The client of the live channel (`docs/server/PROTOCOL.md` section 9): a blocking WebSocket on a thread of its own that tells the sync worker when another device changed something, so a change shows within a second instead of at the next poll. It reads pokes, ignores presence and commands for now, and never talks to the interface.

use crate::logger;
use std::io::ErrorKind;
use std::net::{TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tungstenite::client::IntoClientRequest;
use tungstenite::handshake::HandshakeError;
use tungstenite::http::HeaderValue;
use tungstenite::protocol::frame::coding::CloseCode;
use tungstenite::{Error, Message, WebSocket};

const LOG: &str = "server-sync";
const PATH: &str = "/flaccy/v1/live";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(8);
const READ_SLICE: Duration = Duration::from_secs(1);
const SILENCE_LIMIT: Duration = Duration::from_secs(90);
const STABLE_AFTER: Duration = Duration::from_secs(30);
const BACKOFF_BASE: Duration = Duration::from_secs(1);
const BACKOFF_CEILING: Duration = Duration::from_secs(60);
const UNSUPPORTED_WAIT: Duration = Duration::from_secs(300);
const NAP: Duration = Duration::from_millis(200);

/// What the channel tells the worker.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LiveEvent {
    /// The socket is open; pull once to catch up on what happened while it was down.
    Up,
    /// The socket closed; the poll takes over until it is back.
    Down,
    /// Another device changed something; the highest change sequence number is `head`.
    Poke {
        /// The server's head at the commit.
        head: i64,
    },
    /// The server no longer accepts this device's token.
    Revoked,
}

/// What a frame from the server says.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Frame {
    /// A hint to pull.
    Poke(i64),
    /// Another device of the same user changed what it plays.
    Presence,
    /// Another device asked this one to do something.
    Command,
    /// The server refused a frame this client sent.
    Failure(String),
    /// Anything else, which a newer server may send.
    Unknown,
}

/// Reads one text frame.
pub fn parse_frame(text: &str) -> Frame {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return Frame::Unknown;
    };
    match value["t"].as_str() {
        Some("poke") => Frame::Poke(value["head"].as_i64().unwrap_or(0)),
        Some("presence") => Frame::Presence,
        Some("command") => Frame::Command,
        Some("error") => Frame::Failure(value["code"].as_str().unwrap_or_default().to_owned()),
        _ => Frame::Unknown,
    }
}

/// The WebSocket address of the live channel of the server at `base`, an http or https base URL.
pub fn live_url(base: &str) -> Option<String> {
    let trimmed = base.trim_end_matches('/');
    let rest = trimmed
        .strip_prefix("https://")
        .map(|rest| ("wss", rest))
        .or_else(|| trimmed.strip_prefix("http://").map(|rest| ("ws", rest)))?;
    Some(format!("{}://{}{PATH}", rest.0, rest.1))
}

/// The wait before reconnect number `attempt` (from zero): doubling from a second to a minute, between half and all of it.
pub fn backoff(attempt: u32, jitter: f64) -> Duration {
    let doubled = BACKOFF_BASE.saturating_mul(1 << attempt.min(10));
    doubled
        .min(BACKOFF_CEILING)
        .mul_f64(0.5 + 0.5 * jitter.clamp(0.0, 1.0))
}

/// A running channel. Dropping it asks the thread to stop, which it does within a second.
pub struct Live {
    stop: Arc<AtomicBool>,
}

impl Live {
    /// Opens the channel to the server at `base` with `token` on a new thread and keeps it open, reporting to `notify` from that thread. `None` when the thread could not start.
    pub fn start(
        base: &str,
        token: &str,
        notify: impl Fn(LiveEvent) + Send + 'static,
    ) -> Option<Live> {
        let url = live_url(base)?;
        let token = token.to_owned();
        let stop = Arc::new(AtomicBool::new(false));
        let flag = Arc::clone(&stop);
        std::thread::Builder::new()
            .name("flaccy-server-live".into())
            .spawn(move || keep_open(&url, &token, &flag, &notify))
            .ok()?;
        Some(Live { stop })
    }
}

impl Drop for Live {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
    }
}

/// How one connection ended.
enum Ending {
    Stopped,
    Revoked,
    Unsupported,
    Lost { was_up_for: Option<Duration> },
}

fn keep_open(url: &str, token: &str, stop: &AtomicBool, notify: &dyn Fn(LiveEvent)) {
    let mut attempt = 0;
    while !stop.load(Ordering::Relaxed) {
        let wait = match connect_and_read(url, token, stop, notify) {
            Ending::Stopped => return,
            Ending::Revoked => {
                notify(LiveEvent::Revoked);
                return;
            }
            Ending::Unsupported => UNSUPPORTED_WAIT,
            Ending::Lost { was_up_for } => {
                attempt = next_attempt(attempt, was_up_for);
                backoff(attempt, rand::random::<f64>())
            }
        };
        nap(wait, stop);
    }
}

fn next_attempt(attempt: u32, was_up_for: Option<Duration>) -> u32 {
    match was_up_for {
        Some(up) if up >= STABLE_AFTER => 0,
        _ => attempt + 1,
    }
}

fn nap(total: Duration, stop: &AtomicBool) {
    let until = Instant::now() + total;
    while Instant::now() < until && !stop.load(Ordering::Relaxed) {
        std::thread::sleep(NAP);
    }
}

fn connect_and_read(
    url: &str,
    token: &str,
    stop: &AtomicBool,
    notify: &dyn Fn(LiveEvent),
) -> Ending {
    let (mut socket, timeouts) = match open(url, token) {
        Ok(opened) => opened,
        Err(ending) => return ending,
    };
    if let Err(error) = timeouts.set_read_timeout(Some(READ_SLICE)) {
        logger::warn(LOG, &format!("live channel: no read timeout: {error}"));
        return Ending::Lost { was_up_for: None };
    }
    logger::info(LOG, "live channel up");
    notify(LiveEvent::Up);
    let opened = Instant::now();
    let ending = read_frames(&mut socket, stop, notify);
    if !matches!(ending, Ending::Stopped | Ending::Revoked) {
        notify(LiveEvent::Down);
    }
    match ending {
        Ending::Lost { .. } => Ending::Lost {
            was_up_for: Some(opened.elapsed()),
        },
        other => other,
    }
}

type Socket = WebSocket<tungstenite::stream::MaybeTlsStream<TcpStream>>;

fn open(url: &str, token: &str) -> Result<(Socket, TcpStream), Ending> {
    let mut request = url.into_client_request().map_err(|error| {
        logger::warn(LOG, &format!("live channel address unusable: {error}"));
        Ending::Unsupported
    })?;
    let header = HeaderValue::from_str(&format!("Bearer {token}")).map_err(|_| Ending::Unsupported)?;
    request.headers_mut().insert("Authorization", header);
    let stream = tcp_stream(request.uri()).map_err(|error| {
        logger::info(LOG, &format!("live channel unreachable: {error}"));
        Ending::Lost { was_up_for: None }
    })?;
    let timeouts = stream.try_clone().map_err(|_| Ending::Lost { was_up_for: None })?;
    timeouts
        .set_read_timeout(Some(HANDSHAKE_TIMEOUT))
        .map_err(|_| Ending::Lost { was_up_for: None })?;
    match tungstenite::client_tls(request, stream) {
        Ok((socket, _)) => Ok((socket, timeouts)),
        Err(HandshakeError::Failure(error)) => Err(handshake_ending(&error)),
        Err(HandshakeError::Interrupted(_)) => Err(Ending::Lost { was_up_for: None }),
    }
}

fn tcp_stream(uri: &tungstenite::http::Uri) -> std::io::Result<TcpStream> {
    let host = uri
        .host()
        .ok_or_else(|| std::io::Error::new(ErrorKind::InvalidInput, "no host"))?;
    let port = uri
        .port_u16()
        .unwrap_or(if uri.scheme_str() == Some("wss") { 443 } else { 80 });
    let address = (host, port)
        .to_socket_addrs()?
        .next()
        .ok_or_else(|| std::io::Error::new(ErrorKind::NotFound, "name did not resolve"))?;
    let stream = TcpStream::connect_timeout(&address, CONNECT_TIMEOUT)?;
    stream.set_nodelay(true)?;
    Ok(stream)
}

fn handshake_ending(error: &Error) -> Ending {
    match error {
        Error::Http(response) if response.status().as_u16() == 401 => {
            logger::warn(LOG, "live channel refused the token (401)");
            Ending::Revoked
        }
        Error::Http(response) if matches!(response.status().as_u16(), 403 | 404 | 426) => {
            logger::info(LOG, &format!("live channel not offered ({})", response.status()));
            Ending::Unsupported
        }
        other => {
            logger::info(LOG, &format!("live channel not opened: {other}"));
            Ending::Lost { was_up_for: None }
        }
    }
}

fn read_frames(socket: &mut Socket, stop: &AtomicBool, notify: &dyn Fn(LiveEvent)) -> Ending {
    let mut last_heard = Instant::now();
    loop {
        if stop.load(Ordering::Relaxed) {
            let _ = socket.close(None);
            let _ = socket.flush();
            return Ending::Stopped;
        }
        match socket.read() {
            Ok(Message::Text(text)) => {
                last_heard = Instant::now();
                handle_frame(&text, notify);
            }
            Ok(Message::Close(frame)) => return closed_by_server(frame.map(|frame| frame.code)),
            Ok(_) => last_heard = Instant::now(),
            Err(Error::Io(error)) if is_idle(&error) => {
                if last_heard.elapsed() > SILENCE_LIMIT {
                    logger::info(LOG, "live channel silent; reconnecting");
                    return Ending::Lost { was_up_for: None };
                }
            }
            Err(Error::ConnectionClosed | Error::AlreadyClosed) => {
                return Ending::Lost { was_up_for: None };
            }
            Err(error) => {
                logger::info(LOG, &format!("live channel broke: {error}"));
                return Ending::Lost { was_up_for: None };
            }
        }
        let _ = socket.flush();
    }
}

fn is_idle(error: &std::io::Error) -> bool {
    matches!(error.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut)
}

fn closed_by_server(code: Option<CloseCode>) -> Ending {
    if code == Some(CloseCode::Policy) {
        logger::warn(LOG, "live channel closed by the server: token no longer valid");
        return Ending::Revoked;
    }
    logger::info(LOG, &format!("live channel closed by the server: {code:?}"));
    Ending::Lost { was_up_for: None }
}

fn handle_frame(text: &str, notify: &dyn Fn(LiveEvent)) {
    match parse_frame(text) {
        Frame::Poke(head) => notify(LiveEvent::Poke { head }),
        Frame::Presence => logger::debug(LOG, "live: presence frame ignored"),
        Frame::Command => logger::debug(LOG, "live: command frame ignored"),
        Frame::Failure(code) => logger::debug(LOG, &format!("live: server error frame {code}")),
        Frame::Unknown => logger::debug(LOG, "live: unknown frame ignored"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::sync::mpsc;

    #[test]
    fn frames_are_read_by_their_type() {
        assert_eq!(parse_frame(r#"{"t":"poke","head":42}"#), Frame::Poke(42));
        assert_eq!(parse_frame(r#"{"t":"presence","device":"x"}"#), Frame::Presence);
        assert_eq!(parse_frame(r#"{"t":"command","id":"1"}"#), Frame::Command);
        assert_eq!(
            parse_frame(r#"{"t":"error","code":"rate_limited"}"#),
            Frame::Failure("rate_limited".into())
        );
        assert_eq!(parse_frame(r#"{"t":"future"}"#), Frame::Unknown);
        assert_eq!(parse_frame("not json"), Frame::Unknown);
    }

    #[test]
    fn the_address_swaps_the_scheme_and_keeps_the_port() {
        assert_eq!(live_url("http://arch:4545/").as_deref(), Some("ws://arch:4545/flaccy/v1/live"));
        assert_eq!(
            live_url("https://arch.tail1.ts.net").as_deref(),
            Some("wss://arch.tail1.ts.net/flaccy/v1/live")
        );
        assert_eq!(live_url("ftp://arch"), None);
    }

    #[test]
    fn reconnects_double_up_to_a_minute_with_jitter() {
        assert_eq!(backoff(0, 1.0), Duration::from_secs(1));
        assert_eq!(backoff(0, 0.0), Duration::from_millis(500));
        assert_eq!(backoff(3, 1.0), Duration::from_secs(8));
        assert_eq!(backoff(20, 1.0), Duration::from_secs(60));
        assert!(backoff(20, 0.0) >= Duration::from_secs(30));
    }

    #[test]
    fn a_connection_that_held_resets_the_count_and_one_that_did_not_adds_to_it() {
        assert_eq!(next_attempt(4, Some(Duration::from_secs(120))), 0);
        assert_eq!(next_attempt(4, Some(Duration::from_secs(2))), 5);
        assert_eq!(next_attempt(0, None), 1);
    }

    fn serve_one(frames: Vec<&'static str>) -> (String, mpsc::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        let (headers, seen) = mpsc::channel();
        std::thread::spawn(move || {
            let Ok((stream, _)) = listener.accept() else { return };
            let callback = |request: &tungstenite::handshake::server::Request,
                            response: tungstenite::handshake::server::Response| {
                let auth = request
                    .headers()
                    .get("Authorization")
                    .and_then(|value| value.to_str().ok())
                    .unwrap_or_default()
                    .to_owned();
                let origin = request.headers().contains_key("Origin");
                let _ = headers.send(format!("{auth}|origin={origin}"));
                Ok(response)
            };
            let Ok(mut socket) = tungstenite::accept_hdr(stream, callback) else { return };
            for frame in frames {
                let _ = socket.send(Message::text(frame));
            }
            while socket.read().is_ok() {}
        });
        (format!("http://{address}"), seen)
    }

    fn collect(base: &str, token: &str, wanted: usize) -> Vec<LiveEvent> {
        let (events, inbox) = mpsc::channel();
        let live = Live::start(base, token, move |event| {
            let _ = events.send(event);
        })
        .expect("thread");
        let mut seen = Vec::new();
        while seen.len() < wanted {
            match inbox.recv_timeout(Duration::from_secs(5)) {
                Ok(event) => seen.push(event),
                Err(_) => break,
            }
        }
        drop(live);
        seen
    }

    #[test]
    fn the_token_goes_in_the_upgrade_and_pokes_come_out() {
        let (base, headers) = serve_one(
            vec![r#"{"t":"presence","state":"playing"}"#, r#"{"t":"poke","head":7}"#],
        );
        let seen = collect(&base, "tok-123", 2);
        assert_eq!(seen, vec![LiveEvent::Up, LiveEvent::Poke { head: 7 }]);
        assert_eq!(
            headers.recv_timeout(Duration::from_secs(1)).expect("headers"),
            "Bearer tok-123|origin=false"
        );
    }

    #[test]
    fn a_policy_close_means_the_token_is_revoked() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        std::thread::spawn(move || {
            let Ok((stream, _)) = listener.accept() else { return };
            let Ok(mut socket) = tungstenite::accept(stream) else { return };
            let frame = tungstenite::protocol::CloseFrame {
                code: CloseCode::Policy,
                reason: "revoked".into(),
            };
            let _ = socket.close(Some(frame));
            while socket.read().is_ok() {}
        });
        let seen = collect(&format!("http://{address}"), "gone", 2);
        assert_eq!(seen, vec![LiveEvent::Up, LiveEvent::Revoked]);
    }

    #[test]
    fn an_upgrade_answered_401_is_revoked_without_opening() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
        let address = listener.local_addr().expect("address");
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            let Ok((mut stream, _)) = listener.accept() else { return };
            let mut buffer = [0u8; 2048];
            let _ = stream.read(&mut buffer);
            let _ = stream.write_all(
                b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            );
        });
        let seen = collect(&format!("http://{address}"), "bad", 1);
        assert_eq!(seen, vec![LiveEvent::Revoked]);
    }
}
