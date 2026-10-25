//! The loopback HTTP server GStreamer plays remote songs from.
//!
//! `GET` and `HEAD` `/<server>/<song>` answer from the cache file with `Range`
//! support, fetching whatever bytes are missing from the server first. The
//! player only ever sees plain `http://127.0.0.1:<port>/…` URLs, so gapless
//! playback, seeking and the equalizer work the way they do for local files.

use super::catalog::content_type;
use super::decode_segment;
use super::manager::{FetchError, Manager, FETCH_BLOCK};
use super::redact::redact;
use std::io::{BufRead, BufReader, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::sync::Arc;
use std::time::Duration;

const MAX_HEAD_BYTES: usize = 16 * 1024;
const SOCKET_TIMEOUT: Duration = Duration::from_secs(30);
const SEND_CHUNK: usize = 64 * 1024;

/// The running server.
pub struct Proxy {
    port: u16,
}

impl Proxy {
    /// Binds a random loopback port and serves it from a background thread.
    pub fn start(manager: Arc<Manager>) -> std::io::Result<Self> {
        let listener = TcpListener::bind("127.0.0.1:0")?;
        let port = listener.local_addr()?.port();
        std::thread::Builder::new()
            .name("flaccy-proxy".into())
            .spawn(move || {
                for stream in listener.incoming().flatten() {
                    let manager = Arc::clone(&manager);
                    let _ = std::thread::Builder::new()
                        .name("flaccy-proxy-conn".into())
                        .spawn(move || {
                            let _ = handle(&manager, stream);
                        });
                }
            })?;
        Ok(Self { port })
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    /// The URL that plays one song.
    pub fn url(&self, server: &str, song: &str) -> String {
        format!(
            "http://127.0.0.1:{}/{}/{}",
            self.port,
            super::encode_segment(server),
            super::encode_segment(song)
        )
    }
}

struct Request {
    head_only: bool,
    server: String,
    song: String,
    range: Option<ByteSpec>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ByteSpec {
    From(u64),
    Between(u64, u64),
    Last(u64),
}

enum Parsed {
    Ok(Request),
    Reject(u16, &'static str),
}

fn handle(manager: &Arc<Manager>, mut stream: TcpStream) -> std::io::Result<()> {
    stream.set_read_timeout(Some(SOCKET_TIMEOUT))?;
    stream.set_write_timeout(Some(SOCKET_TIMEOUT))?;
    let request = match read_request(&stream)? {
        Parsed::Ok(request) => request,
        Parsed::Reject(code, reason) => return respond_plain(&mut stream, code, reason),
    };
    let result = serve(manager, &mut stream, &request);
    let _ = stream.flush();
    let _ = stream.shutdown(Shutdown::Both);
    result
}

fn read_request(stream: &TcpStream) -> std::io::Result<Parsed> {
    let mut reader = BufReader::new(stream);
    let mut head = String::new();
    loop {
        let mut line = String::new();
        let read = reader.read_line(&mut line)?;
        if read == 0 || head.len() + line.len() > MAX_HEAD_BYTES {
            return Ok(Parsed::Reject(400, "Bad Request"));
        }
        let blank = line == "\r\n" || line == "\n";
        head.push_str(&line);
        if blank {
            break;
        }
    }
    Ok(parse_head(&head))
}

fn parse_head(head: &str) -> Parsed {
    let mut lines = head.lines();
    let Some(request_line) = lines.next() else {
        return Parsed::Reject(400, "Bad Request");
    };
    let mut parts = request_line.split_whitespace();
    let (Some(method), Some(target)) = (parts.next(), parts.next()) else {
        return Parsed::Reject(400, "Bad Request");
    };
    let head_only = match method {
        "GET" => false,
        "HEAD" => true,
        _ => return Parsed::Reject(405, "Method Not Allowed"),
    };
    let path = target.split(['?', '#']).next().unwrap_or_default();
    let mut segments = path.trim_start_matches('/').split('/');
    let (Some(server), Some(song), None) = (segments.next(), segments.next(), segments.next()) else {
        return Parsed::Reject(404, "Not Found");
    };
    let (Some(server), Some(song)) = (decode_segment(server), decode_segment(song)) else {
        return Parsed::Reject(404, "Not Found");
    };
    let range = lines.find_map(|line| {
        let (name, value) = line.split_once(':')?;
        name.trim().eq_ignore_ascii_case("range").then(|| parse_range(value.trim()))?
    });
    Parsed::Ok(Request {
        head_only,
        server,
        song,
        range,
    })
}

/// The first byte range of a `Range: bytes=…` header; `None` for anything
/// else, which is then answered with the whole file.
fn parse_range(value: &str) -> Option<ByteSpec> {
    let spec = value.strip_prefix("bytes=")?.split(',').next()?.trim();
    let (first, last) = spec.split_once('-')?;
    match (first.trim(), last.trim()) {
        ("", "") => None,
        ("", last) => Some(ByteSpec::Last(last.parse().ok()?)),
        (first, "") => Some(ByteSpec::From(first.parse().ok()?)),
        (first, last) => Some(ByteSpec::Between(first.parse().ok()?, last.parse().ok()?)),
    }
}

/// The half-open byte range a spec means in a file of `total` bytes, `None`
/// when no byte of the file is in it.
fn resolve(spec: ByteSpec, total: u64) -> Option<std::ops::Range<u64>> {
    let range = match spec {
        ByteSpec::From(first) => first..total,
        ByteSpec::Between(first, last) if last >= first => first..last.saturating_add(1).min(total),
        ByteSpec::Between(..) => return None,
        ByteSpec::Last(0) => return None,
        ByteSpec::Last(count) => total.saturating_sub(count)..total,
    };
    (range.start < range.end && range.start < total).then_some(range)
}

fn serve(manager: &Arc<Manager>, stream: &mut TcpStream, request: &Request) -> std::io::Result<()> {
    let entry = match manager.entry(&request.server, &request.song) {
        Ok(entry) => entry,
        Err(error) => return respond_failure(stream, &error),
    };
    let _reading = entry.reading();
    manager.touch(&entry);
    let mut attempts = 0;
    let (total, span) = loop {
        let total = match manager.ensure_total(&entry) {
            Ok(total) => total,
            Err(error) => return respond_failure(stream, &error),
        };
        let span = request.range.map(|spec| resolve(spec, total));
        let first_block = match &span {
            Some(Some(range)) => range.start..(range.start + FETCH_BLOCK).min(range.end),
            Some(None) => 0..0,
            None => 0..FETCH_BLOCK.min(total),
        };
        match manager.fill(&entry, first_block, FETCH_BLOCK) {
            Ok(()) => break (total, span),
            Err(FetchError::Changed) if attempts < 2 => attempts += 1,
            Err(error) => return respond_failure(stream, &error),
        }
    };
    let content_type = content_type(&entry.suffix());
    let (status_line, body_range, content_range) = match span {
        Some(None) => {
            return write_head(
                stream,
                "416 Range Not Satisfiable",
                &[
                    ("Content-Range", format!("bytes */{total}")),
                    ("Content-Length", "0".to_string()),
                ],
            )
        }
        Some(Some(range)) => (
            "206 Partial Content",
            range.clone(),
            Some(format!("bytes {}-{}/{total}", range.start, range.end - 1)),
        ),
        None => ("200 OK", 0..total, None),
    };
    let mut headers = vec![
        ("Content-Type", content_type.to_string()),
        ("Accept-Ranges", "bytes".to_string()),
        ("Content-Length", (body_range.end - body_range.start).to_string()),
    ];
    if let Some(content_range) = content_range {
        headers.push(("Content-Range", content_range));
    }
    write_head(stream, status_line, &headers)?;
    if request.head_only {
        return Ok(());
    }
    send_body(manager, stream, &entry, body_range)
}

fn send_body(
    manager: &Arc<Manager>,
    stream: &mut TcpStream,
    entry: &Arc<super::manager::Entry>,
    range: std::ops::Range<u64>,
) -> std::io::Result<()> {
    let mut position = range.start;
    let mut buffer = vec![0u8; SEND_CHUNK];
    while position < range.end {
        let block_end = (position + FETCH_BLOCK).min(range.end);
        if let Err(error) = manager.fill(entry, position..block_end, FETCH_BLOCK) {
            crate::logger::warn(
                "remote",
                &format!("stream of {} cut short: {}", entry.key(), redact(&error.to_string())),
            );
            return Err(std::io::Error::new(std::io::ErrorKind::Other, error.to_string()));
        }
        while position < block_end {
            let wanted = ((block_end - position) as usize).min(SEND_CHUNK);
            entry.read_at(&mut buffer[..wanted], position)?;
            stream.write_all(&buffer[..wanted])?;
            position += wanted as u64;
        }
    }
    Ok(())
}

fn respond_failure(stream: &mut TcpStream, error: &FetchError) -> std::io::Result<()> {
    let (code, reason) = match error {
        FetchError::UnknownSong | FetchError::UnknownServer => (404, "Not Found"),
        _ => (502, "Bad Gateway"),
    };
    crate::logger::warn("remote", &format!("proxy answered {code}: {}", redact(&error.to_string())));
    respond_plain(stream, code, reason)
}

fn respond_plain(stream: &mut TcpStream, code: u16, reason: &str) -> std::io::Result<()> {
    let body = format!("{reason}\n");
    write_head(
        stream,
        &format!("{code} {reason}"),
        &[
            ("Content-Type", "text/plain".to_string()),
            ("Content-Length", body.len().to_string()),
        ],
    )?;
    stream.write_all(body.as_bytes())
}

fn write_head(stream: &mut TcpStream, status: &str, headers: &[(&str, String)]) -> std::io::Result<()> {
    let mut head = format!("HTTP/1.1 {status}\r\n");
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("Connection: close\r\n\r\n");
    stream.write_all(head.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::cache::{Location, Store};
    use crate::remote::client::Client;
    use crate::remote::manager::{CacheEvent, Manager};
    use crate::remote::servers::Server;
    use crate::remote::testing::{http_request, song_bytes, FixtureServer};
    use crate::db::RemoteSongMeta;
    use std::collections::HashMap;
    use std::sync::Mutex;

    struct Rig {
        base: std::path::PathBuf,
        fixture: FixtureServer,
        manager: Arc<Manager>,
        proxy: Proxy,
        events: Arc<Mutex<Vec<CacheEvent>>>,
    }

    impl Drop for Rig {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.base);
        }
    }

    fn rig(name: &str, cap: u64) -> Rig {
        let base = std::env::temp_dir().join(format!("flaccy-proxy-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let fixture = FixtureServer::start();
        let server = Server {
            id: "s1".to_string(),
            ..Server::new("Fixture", &fixture.address(), "ana", "pw", false)
        };
        let client = Client::new(&server).unwrap();
        let sizes: Arc<Mutex<HashMap<String, u64>>> = Arc::new(Mutex::new(HashMap::new()));
        let meta_sizes = Arc::clone(&sizes);
        let meta: crate::remote::manager::MetaLookup = Arc::new(move |_, song| {
            Some(RemoteSongMeta {
                suffix: "flac".to_string(),
                size: meta_sizes.lock().unwrap().get(song).copied().unwrap_or(0),
                title: format!("Song {song}"),
            })
        });
        let clients: crate::remote::manager::ClientLookup =
            Arc::new(move |id| (id == "s1").then(|| client.clone()));
        let store = Store::new(base.join("cache/remote"), base.join("data/remote"));
        let manager = Manager::new(store, meta, clients, cap);
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = Arc::clone(&events);
        manager.set_listener(Arc::new(move |event| sink.lock().unwrap().push(event)));
        let proxy = Proxy::start(Arc::clone(&manager)).unwrap();
        Rig {
            base,
            fixture,
            manager,
            proxy,
            events,
        }
    }

    #[test]
    fn a_range_request_gets_a_206_with_the_right_bytes_and_headers() {
        let rig = rig("range", u64::MAX);
        let bytes = song_bytes(3_000_000, 1);
        rig.fixture.put("a", bytes.clone());
        let reply = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=100-199"));
        assert_eq!(reply.status, 206);
        assert_eq!(reply.header("content-range").as_deref(), Some("bytes 100-199/3000000"));
        assert_eq!(reply.header("content-length").as_deref(), Some("100"));
        assert_eq!(reply.header("accept-ranges").as_deref(), Some("bytes"));
        assert_eq!(reply.header("content-type").as_deref(), Some("audio/flac"));
        assert_eq!(reply.body, bytes[100..200]);
    }

    #[test]
    fn open_ended_and_suffix_ranges_are_resolved_against_the_length() {
        let rig = rig("open", u64::MAX);
        let bytes = song_bytes(2_500_000, 2);
        rig.fixture.put("a", bytes.clone());
        let from = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=2499900-"));
        assert_eq!(from.status, 206);
        assert_eq!(from.header("content-range").as_deref(), Some("bytes 2499900-2499999/2500000"));
        assert_eq!(from.body, bytes[2_499_900..]);
        let last = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=-50"));
        assert_eq!(last.header("content-range").as_deref(), Some("bytes 2499950-2499999/2500000"));
        assert_eq!(last.body, bytes[2_499_950..]);
    }

    #[test]
    fn head_answers_the_length_and_no_body() {
        let rig = rig("head", u64::MAX);
        rig.fixture.put("a", song_bytes(1_234_567, 3));
        let reply = http_request(rig.proxy.port(), "HEAD", "/s1/a", None);
        assert_eq!(reply.status, 200);
        assert_eq!(reply.header("content-length").as_deref(), Some("1234567"));
        assert_eq!(reply.header("accept-ranges").as_deref(), Some("bytes"));
        assert!(reply.body.is_empty());
    }

    #[test]
    fn a_request_without_a_range_streams_the_whole_file() {
        let rig = rig("whole", u64::MAX);
        let bytes = song_bytes(2_200_000, 4);
        rig.fixture.put("a", bytes.clone());
        let reply = http_request(rig.proxy.port(), "GET", "/s1/a", None);
        assert_eq!(reply.status, 200);
        assert_eq!(reply.body, bytes);
        let entry = rig.manager.entry("s1", "a").unwrap();
        assert!(entry.is_complete());
        assert!(rig.manager.is_complete("remote://s1/a"));
    }

    #[test]
    fn a_range_past_the_end_is_a_416_with_the_length() {
        let rig = rig("unsatisfiable", u64::MAX);
        rig.fixture.put("a", song_bytes(1000, 5));
        let reply = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=5000-6000"));
        assert_eq!(reply.status, 416);
        assert_eq!(reply.header("content-range").as_deref(), Some("bytes */1000"));
    }

    #[test]
    fn an_unknown_server_or_song_is_a_404_and_other_methods_are_refused() {
        let rig = rig("unknown", u64::MAX);
        assert_eq!(http_request(rig.proxy.port(), "GET", "/nope/a", None).status, 404);
        assert_eq!(http_request(rig.proxy.port(), "GET", "/s1", None).status, 404);
        assert_eq!(http_request(rig.proxy.port(), "POST", "/s1/a", None).status, 405);
    }

    #[test]
    fn cached_bytes_are_served_again_without_asking_the_server() {
        let rig = rig("cached", u64::MAX);
        let bytes = song_bytes(1_500_000, 6);
        rig.fixture.put("a", bytes.clone());
        let first = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=0-99"));
        assert_eq!(first.body, bytes[..100]);
        let requests_after_first = rig.fixture.stream_requests();
        let second = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=10-50"));
        assert_eq!(second.body, bytes[10..51]);
        assert_eq!(rig.fixture.stream_requests(), requests_after_first);
        let sidecar = Store::read_sidecar(&rig.manager.entry("s1", "a").unwrap().path()).unwrap();
        assert_eq!(sidecar.total, 1_500_000);
        assert!(sidecar.validator.is_some());
        assert!(!sidecar.ranges.ranges().is_empty());
    }

    #[test]
    fn the_validator_rides_along_as_if_range_on_later_fetches() {
        let rig = rig("ifrange", u64::MAX);
        rig.fixture.put("a", song_bytes(3_000_000, 7));
        http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=0-9"));
        http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=2500000-2500009"));
        let seen = rig.fixture.if_range_headers();
        assert_eq!(seen.len(), 1);
        assert!(!seen[0].is_empty());
    }

    #[test]
    fn a_full_answer_to_if_range_drops_the_cached_ranges_and_serves_the_new_bytes() {
        let rig = rig("changed", u64::MAX);
        let old = song_bytes(3_000_000, 8);
        rig.fixture.put("a", old.clone());
        let before = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=0-9"));
        assert_eq!(before.body, old[..10]);
        let new = song_bytes(3_100_000, 9);
        rig.fixture.put("a", new.clone());
        let after = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=2900000-2900009"));
        assert_eq!(after.status, 206);
        assert_eq!(after.header("content-range").as_deref(), Some("bytes 2900000-2900009/3100000"));
        assert_eq!(after.body, new[2_900_000..2_900_010]);
        let entry = rig.manager.entry("s1", "a").unwrap();
        assert_eq!(entry.total(), 3_100_000);
        assert!(entry.is_complete());
        let again = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=0-9"));
        assert_eq!(again.body, new[..10]);
        assert!(rig
            .events
            .lock()
            .unwrap()
            .contains(&CacheEvent::NewVersion { server: "s1".into(), song: "a".into() }));
    }

    #[test]
    fn an_unreachable_server_marks_itself_and_a_complete_song_still_plays() {
        let rig = rig("offline", u64::MAX);
        let bytes = song_bytes(1_100_000, 10);
        rig.fixture.put("a", bytes.clone());
        rig.fixture.put("b", song_bytes(1_100_000, 11));
        http_request(rig.proxy.port(), "GET", "/s1/a", None);
        rig.fixture.go_offline();
        let cached = http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=5-14"));
        assert_eq!(cached.status, 206);
        assert_eq!(cached.body, bytes[5..15]);
        let missing = http_request(rig.proxy.port(), "GET", "/s1/b", Some("bytes=0-9"));
        assert_eq!(missing.status, 502);
        assert!(!rig.manager.is_reachable("s1"));
    }

    #[test]
    fn pinning_moves_a_song_to_the_kept_folder_and_downloads_all_of_it() {
        let rig = rig("pin", 10);
        let bytes = song_bytes(2_600_000, 12);
        rig.fixture.put("a", bytes.clone());
        http_request(rig.proxy.port(), "GET", "/s1/a", Some("bytes=0-99"));
        rig.manager.pin(vec![("s1".to_string(), "a".to_string())]);
        crate::remote::testing::wait_until(|| rig.manager.is_downloaded("remote://s1/a"));
        let (location, path, sidecar) = rig.manager.store().find("s1", "a").unwrap();
        assert_eq!(location, Location::Pinned);
        assert!(sidecar.is_complete());
        assert_eq!(std::fs::read(path).unwrap(), bytes);
        rig.manager.enforce_cap_now();
        assert!(rig.manager.is_downloaded("remote://s1/a"));
        rig.manager.unpin(&[("s1".to_string(), "a".to_string())]);
        assert!(!rig.manager.is_pinned("remote://s1/a"));
        assert!(rig.manager.store().find("s1", "a").is_none());
    }

    #[test]
    fn eviction_removes_old_songs_but_not_the_playing_or_next_ones() {
        let rig = rig("evict", 1_500_000);
        for (id, seed) in [("a", 1u8), ("b", 2), ("c", 3)] {
            rig.fixture.put(id, song_bytes(1_000_000, seed));
            http_request(rig.proxy.port(), "GET", &format!("/s1/{id}"), None);
        }
        assert!(rig.manager.is_complete("remote://s1/a"));
        rig.manager.prefetch(Some(("s1".into(), "a".into())), Some(("s1".into(), "c".into())));
        crate::remote::testing::wait_until(|| !rig.manager.is_complete("remote://s1/b"));
        assert!(rig.manager.is_complete("remote://s1/a"));
        assert!(rig.manager.is_complete("remote://s1/c"));
    }

    #[test]
    fn the_range_parser_reads_the_three_forms() {
        assert_eq!(parse_range("bytes=1-5"), Some(ByteSpec::Between(1, 5)));
        assert_eq!(parse_range("bytes=7-"), Some(ByteSpec::From(7)));
        assert_eq!(parse_range("bytes=-9"), Some(ByteSpec::Last(9)));
        assert_eq!(parse_range("bytes=1-2,5-6"), Some(ByteSpec::Between(1, 2)));
        assert_eq!(parse_range("items=1-5"), None);
        assert_eq!(resolve(ByteSpec::Between(0, 999_999), 100), Some(0..100));
        assert_eq!(resolve(ByteSpec::Between(5, 2), 100), None);
        assert_eq!(resolve(ByteSpec::From(100), 100), None);
    }
}
