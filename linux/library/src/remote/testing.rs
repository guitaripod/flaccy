//! A small OpenSubsonic server for the tests, speaking just enough HTTP: the
//! login methods, the catalog methods, covers, scrobbles and an untranscoded
//! stream with `Range`, `If-Range` and `Last-Modified`. It answers on a random
//! loopback port and can be told to change a song, refuse logins or go dark.

use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

struct Song {
    bytes: Vec<u8>,
    modified: String,
}

#[derive(Default)]
struct State {
    songs: Mutex<HashMap<String, Song>>,
    children: Mutex<Vec<Value>>,
    stream_requests: AtomicUsize,
    cover_requests: AtomicUsize,
    versions: AtomicUsize,
    if_range: Mutex<Vec<String>>,
    scrobbles: Mutex<Vec<(String, bool)>>,
    stars: Mutex<Vec<(String, bool)>>,
    offline: AtomicBool,
    reject: AtomicBool,
    plain: AtomicBool,
    empty_search: AtomicBool,
}

/// The running fixture.
pub struct FixtureServer {
    port: u16,
    state: Arc<State>,
}

impl FixtureServer {
    pub fn start() -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").expect("fixture binds");
        let port = listener.local_addr().unwrap().port();
        let state = Arc::new(State::default());
        let shared = Arc::clone(&state);
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let state = Arc::clone(&shared);
                std::thread::spawn(move || {
                    let _ = answer(&state, stream);
                });
            }
        });
        Self { port, state }
    }

    pub fn address(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    /// Stores a song's audio. Every call gives it a new `Last-Modified`, so a
    /// second call for the same id is a new version.
    pub fn put(&self, id: &str, bytes: Vec<u8>) {
        let version = self.state.versions.fetch_add(1, Ordering::SeqCst);
        let modified = format!("Mon, 01 Jan 2024 00:{:02}:{:02} GMT", (version / 60) % 60, version % 60);
        self.state
            .songs
            .lock()
            .unwrap()
            .insert(id.to_string(), Song { bytes, modified });
    }

    /// Adds a song to the catalog the list methods return.
    pub fn add_child(&self, child: Value) {
        self.state.children.lock().unwrap().push(child);
    }

    pub fn clear_catalog(&self) {
        self.state.children.lock().unwrap().clear();
    }

    pub fn stream_requests(&self) -> usize {
        self.state.stream_requests.load(Ordering::SeqCst)
    }

    pub fn cover_requests(&self) -> usize {
        self.state.cover_requests.load(Ordering::SeqCst)
    }

    pub fn if_range_headers(&self) -> Vec<String> {
        self.state.if_range.lock().unwrap().clone()
    }

    pub fn scrobbles(&self) -> Vec<(String, bool)> {
        self.state.scrobbles.lock().unwrap().clone()
    }

    pub fn stars(&self) -> Vec<(String, bool)> {
        self.state.stars.lock().unwrap().clone()
    }

    pub fn go_offline(&self) {
        self.state.offline.store(true, Ordering::SeqCst);
    }

    pub fn reject_logins(&self) {
        self.state.reject.store(true, Ordering::SeqCst);
    }

    pub fn answer_plain_subsonic(&self) {
        self.state.plain.store(true, Ordering::SeqCst);
    }

    pub fn empty_search_results(&self) {
        self.state.empty_search.store(true, Ordering::SeqCst);
    }
}

/// A catalog entry in the shape a Navidrome `Child` has.
pub fn child_json(id: &str, title: &str, album: &str, track: i64, size: usize) -> Value {
    json!({
        "id": id,
        "title": title,
        "album": album,
        "albumId": format!("al-{album}"),
        "artist": "Fixture Band",
        "track": track,
        "duration": 30,
        "size": size,
        "suffix": "flac",
        "coverArt": format!("al-{album}"),
        "bitDepth": 16,
        "samplingRate": 44100,
        "channelCount": 2,
        "created": "2026-10-25T12:00:00Z"
    })
}

/// Deterministic audio-looking bytes.
pub fn song_bytes(length: usize, seed: u8) -> Vec<u8> {
    (0..length)
        .map(|index| (index.wrapping_mul(31) ^ (index >> 8) ^ usize::from(seed) * 7) as u8)
        .collect()
}

/// Polls `condition` for up to fifteen seconds.
pub fn wait_until(condition: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if condition() {
            return;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(condition(), "timed out waiting for the condition");
}

/// An HTTP answer read whole.
pub struct Reply {
    pub status: u16,
    headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn header(&self, name: &str) -> Option<String> {
        self.headers
            .iter()
            .find(|(key, _)| key.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.clone())
    }
}

/// Sends one request to the proxy on `port` and reads the answer to its end.
pub fn http_request(port: u16, method: &str, path: &str, range: Option<&str>) -> Reply {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    let mut request = format!("{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n");
    if let Some(range) = range {
        request.push_str(&format!("Range: {range}\r\n"));
    }
    request.push_str("\r\n");
    stream.write_all(request.as_bytes()).unwrap();
    let mut raw = Vec::new();
    let _ = stream.read_to_end(&mut raw);
    let split = raw
        .windows(4)
        .position(|window| window == b"\r\n\r\n")
        .expect("a complete head");
    let head = String::from_utf8_lossy(&raw[..split]).to_string();
    let mut lines = head.lines();
    let status = lines
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|code| code.parse().ok())
        .unwrap();
    let headers = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(name, value)| (name.trim().to_string(), value.trim().to_string()))
        .collect();
    Reply {
        status,
        headers,
        body: raw[split + 4..].to_vec(),
    }
}

fn answer(state: &Arc<State>, stream: TcpStream) -> std::io::Result<()> {
    if state.offline.load(Ordering::SeqCst) {
        return Ok(());
    }
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut request_line = String::new();
    reader.read_line(&mut request_line)?;
    let mut headers: HashMap<String, String> = HashMap::new();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line)?;
        if line.trim().is_empty() {
            break;
        }
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_lowercase(), value.trim().to_string());
        }
    }
    let mut parts = request_line.split_whitespace();
    let method = parts.next().unwrap_or_default().to_string();
    let target = parts.next().unwrap_or_default().to_string();
    let (path, query) = target.split_once('?').unwrap_or((&target, ""));
    let params = parse_query(query);
    let mut out = stream;
    if path.starts_with("/not-subsonic") {
        return reply(&mut out, 200, "text/html", b"<html>hello</html>", &[]);
    }
    let method_name = path.rsplit('/').next().unwrap_or_default();
    match method_name {
        "stream" => stream_song(state, &mut out, &method, &params, &headers),
        "getCoverArt" => {
            state.cover_requests.fetch_add(1, Ordering::SeqCst);
            reply(&mut out, 200, "image/png", TINY_PNG, &[])
        }
        other => {
            let body = json_answer(state, other, &params);
            reply(&mut out, 200, "application/json", body.to_string().as_bytes(), &[])
        }
    }
}

fn json_answer(state: &Arc<State>, method: &str, params: &HashMap<String, String>) -> Value {
    let ok = |extra: Value| {
        let mut base = json!({"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.64.2 (10114574)","openSubsonic":true});
        if let (Some(base), Some(extra)) = (base.as_object_mut(), extra.as_object()) {
            for (key, value) in extra {
                base.insert(key.clone(), value.clone());
            }
        }
        json!({ "subsonic-response": base })
    };
    if state.reject.load(Ordering::SeqCst) {
        return json!({"subsonic-response": {"status":"failed","version":"1.16.1","error":{"code":40,"message":"Wrong username or password"}}});
    }
    if state.plain.load(Ordering::SeqCst) {
        return json!({"subsonic-response": {"status":"ok","version":"1.16.1"}});
    }
    let number = |name: &str, default: usize| {
        params
            .get(name)
            .and_then(|value| value.parse::<usize>().ok())
            .unwrap_or(default)
    };
    let children = state.children.lock().unwrap().clone();
    match method {
        "ping" => ok(json!({})),
        "getOpenSubsonicExtensions" => {
            ok(json!({"openSubsonicExtensions":[{"name":"songLyrics","versions":[1]},{"name":"apiKeyAuthentication","versions":[1]}]}))
        }
        "search3" => {
            if state.empty_search.load(Ordering::SeqCst) {
                return ok(json!({"searchResult3":{}}));
            }
            let offset = number("songOffset", 0);
            let count = number("songCount", 20);
            let page: Vec<Value> = children.into_iter().skip(offset).take(count).collect();
            ok(json!({"searchResult3":{"song":page}}))
        }
        "getAlbumList2" => {
            let offset = number("offset", 0);
            let size = number("size", 10);
            let mut albums: Vec<String> = Vec::new();
            for child in &children {
                let id = child["albumId"].as_str().unwrap_or_default().to_string();
                if !albums.contains(&id) {
                    albums.push(id);
                }
            }
            albums.sort();
            let page: Vec<Value> = albums
                .into_iter()
                .skip(offset)
                .take(size)
                .map(|id| json!({"id": id, "name": id}))
                .collect();
            ok(json!({"albumList2":{"album":page}}))
        }
        "getAlbum" => {
            let id = params.get("id").cloned().unwrap_or_default();
            let songs: Vec<Value> = children
                .into_iter()
                .filter(|child| child["albumId"].as_str() == Some(id.as_str()))
                .collect();
            ok(json!({"album":{"id": id, "name": id, "song": songs}}))
        }
        "scrobble" => {
            state.scrobbles.lock().unwrap().push((
                params.get("id").cloned().unwrap_or_default(),
                params.get("submission").map(String::as_str) == Some("true"),
            ));
            ok(json!({}))
        }
        "star" | "unstar" => {
            state
                .stars
                .lock()
                .unwrap()
                .push((params.get("id").cloned().unwrap_or_default(), method == "star"));
            ok(json!({}))
        }
        _ => ok(json!({})),
    }
}

fn stream_song(
    state: &Arc<State>,
    out: &mut TcpStream,
    method: &str,
    params: &HashMap<String, String>,
    headers: &HashMap<String, String>,
) -> std::io::Result<()> {
    state.stream_requests.fetch_add(1, Ordering::SeqCst);
    let id = params.get("id").cloned().unwrap_or_default();
    let (bytes, modified) = match state.songs.lock().unwrap().get(&id) {
        Some(song) => (song.bytes.clone(), song.modified.clone()),
        None => return reply(out, 404, "text/plain", b"missing", &[]),
    };
    let total = bytes.len() as u64;
    let if_range = headers.get("if-range").cloned();
    if let Some(value) = &if_range {
        state.if_range.lock().unwrap().push(value.clone());
    }
    let unchanged = if_range.as_deref().map_or(true, |value| value == modified);
    let range = headers
        .get("range")
        .and_then(|value| value.strip_prefix("bytes="))
        .and_then(|spec| spec.split_once('-'))
        .and_then(|(first, last)| Some((first.parse::<u64>().ok()?, last.parse::<u64>().ok()?)));
    let validators = [("Last-Modified", modified), ("Accept-Ranges", "bytes".to_string())];
    match range {
        Some((first, last)) if unchanged => {
            if first >= total {
                return reply(out, 416, "text/plain", b"", &[("Content-Range", format!("bytes */{total}"))]);
            }
            let last = last.min(total - 1);
            let mut extra = vec![("Content-Range", format!("bytes {first}-{last}/{total}"))];
            extra.extend(validators);
            let body = if method == "HEAD" { &[][..] } else { &bytes[first as usize..=last as usize] };
            reply_with_length(out, 206, "audio/flac", body, last + 1 - first, &extra)
        }
        _ => {
            let body = if method == "HEAD" { &[][..] } else { &bytes[..] };
            reply_with_length(out, 200, "audio/flac", body, total, &validators)
        }
    }
}

fn reply(out: &mut TcpStream, status: u16, content_type: &str, body: &[u8], extra: &[(&str, String)]) -> std::io::Result<()> {
    reply_with_length(out, status, content_type, body, body.len() as u64, extra)
}

fn reply_with_length(
    out: &mut TcpStream,
    status: u16,
    content_type: &str,
    body: &[u8],
    length: u64,
    extra: &[(&str, String)],
) -> std::io::Result<()> {
    let mut head = format!(
        "HTTP/1.1 {status} X\r\nContent-Type: {content_type}\r\nContent-Length: {length}\r\nConnection: close\r\n"
    );
    for (name, value) in extra {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");
    out.write_all(head.as_bytes())?;
    out.write_all(body)
}

fn parse_query(query: &str) -> HashMap<String, String> {
    query
        .split('&')
        .filter_map(|pair| pair.split_once('='))
        .filter_map(|(name, value)| Some((crate::remote::decode_segment(name)?, crate::remote::decode_segment(value)?)))
        .collect()
}

const TINY_PNG: &[u8] = &[
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
    0x89, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0,
    0x1f, 0x00, 0x05, 0x00, 0x01, 0xff, 0x89, 0x99, 0x3d, 0x1d, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45,
    0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
];
