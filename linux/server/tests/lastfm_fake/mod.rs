#![allow(dead_code)]

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use axum::extract::{Form, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio::task::JoinHandle;

pub const API_KEY: &str = "0123456789abcdef0123456789abcdef";
pub const SESSION_KEY: &str = "feedfacefeedfacefeedfacefeedface";
pub const TOKEN: &str = "tokentokentoken1234";
pub const ACCOUNT: &str = "alice_fm";
const SIGNED_METHODS: [&str; 4] = ["auth.getToken", "auth.getSession", "track.scrobble", "track.updateNowPlaying"];

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Play {
    pub uts: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
}

pub fn plays(count: usize, newest_uts: i64, spacing: i64) -> Vec<Play> {
    (0..count)
        .map(|index| Play {
            uts: newest_uts - spacing * index as i64,
            title: format!("Song {index}"),
            artist: format!("Artist {}", index % 50),
            album: "Album".to_owned(),
        })
        .collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Read {
    pub page: u32,
    pub from: Option<i64>,
    pub to: Option<i64>,
}

#[derive(Clone, Copy, Debug)]
pub enum ScrobbleReply {
    ServerError,
    Duplicate,
    InvalidSession,
    Malformed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Scrobbled {
    pub artist: String,
    pub title: String,
    pub timestamp: i64,
}

#[derive(Default)]
pub struct Inner {
    pub plays: Mutex<Vec<Play>>,
    pub reads: Mutex<Vec<Read>>,
    pub hang_page: AtomicU32,
    pub hung: AtomicU32,
    pub release: Notify,
    pub fail_reads: AtomicU32,
    pub script: Mutex<VecDeque<ScrobbleReply>>,
    pub scrobble_calls: AtomicU32,
    pub scrobbled: Mutex<Vec<Vec<Scrobbled>>>,
    pub now_playing: Mutex<Vec<String>>,
    pub signed: Mutex<Vec<(String, String)>>,
}

pub struct Fake {
    pub inner: Arc<Inner>,
    pub base: String,
    task: JoinHandle<()>,
}

impl Fake {
    pub async fn start(plays: Vec<Play>) -> Self {
        let inner = Arc::new(Inner::default());
        *inner.plays.lock().unwrap() = plays;
        let app = Router::new()
            .route("/2.0/", get(read).post(write))
            .route("/sign", post(sign))
            .with_state(inner.clone());
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://{}", listener.local_addr().unwrap());
        let task = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });
        Self { inner, base, task }
    }

    pub fn api_url(&self) -> String {
        format!("{}/2.0/", self.base)
    }

    pub fn sign_url(&self) -> String {
        format!("{}/sign", self.base)
    }

    pub fn reads(&self) -> Vec<Read> {
        self.inner.reads.lock().unwrap().clone()
    }

    pub fn script(&self, replies: &[ScrobbleReply]) {
        self.inner.script.lock().unwrap().extend(replies.iter().copied());
    }

    pub fn batches(&self) -> Vec<Vec<Scrobbled>> {
        self.inner.scrobbled.lock().unwrap().clone()
    }

    pub fn add_play(&self, play: Play) {
        let mut plays = self.inner.plays.lock().unwrap();
        plays.push(play);
        plays.sort_by_key(|play| std::cmp::Reverse(play.uts));
    }
}

impl Drop for Fake {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn sign(State(inner): State<Arc<Inner>>, headers: HeaderMap, Json(body): Json<Value>) -> Response {
    let method = body["params"]["method"].as_str().unwrap_or_default().to_owned();
    let device = headers.get("x-device-id").and_then(|value| value.to_str().ok()).unwrap_or_default().to_owned();
    if device.is_empty() || !SIGNED_METHODS.contains(&method.as_str()) {
        return (StatusCode::BAD_REQUEST, Json(json!({ "error": "method not allowed" }))).into_response();
    }
    inner.signed.lock().unwrap().push((method.clone(), device));
    Json(json!({ "api_sig": format!("sig-{method}") })).into_response()
}

fn lastfm_error(code: i64, message: &str) -> Response {
    Json(json!({ "error": code, "message": message })).into_response()
}

fn track_json(play: &Play) -> Value {
    json!({ "name": play.title, "artist": { "#text": play.artist }, "album": { "#text": play.album }, "date": { "uts": play.uts.to_string() } })
}

async fn recent_tracks(inner: &Inner, query: &HashMap<String, String>) -> Response {
    let number = |name: &str| query.get(name).and_then(|value| value.parse::<i64>().ok());
    let page = number("page").unwrap_or(1) as u32;
    let limit = number("limit").unwrap_or(50) as usize;
    inner.reads.lock().unwrap().push(Read { page, from: number("from"), to: number("to") });
    if inner.hang_page.load(Ordering::SeqCst) == page {
        inner.hung.fetch_add(1, Ordering::SeqCst);
        inner.release.notified().await;
    }
    if inner.fail_reads.load(Ordering::SeqCst) > 0 {
        inner.fail_reads.fetch_sub(1, Ordering::SeqCst);
        return (StatusCode::INTERNAL_SERVER_ERROR, "boom").into_response();
    }
    let matching: Vec<Play> = inner
        .plays
        .lock()
        .unwrap()
        .iter()
        .filter(|play| number("from").is_none_or(|from| play.uts >= from) && number("to").is_none_or(|to| play.uts <= to))
        .cloned()
        .collect();
    let total_pages = matching.len().div_ceil(limit).max(1);
    let mut tracks: Vec<Value> = matching.iter().skip((page as usize - 1) * limit).take(limit).map(track_json).collect();
    if page == 1 {
        tracks.insert(0, json!({ "name": "Playing Now", "artist": { "#text": "Live" }, "@attr": { "nowplaying": "true" } }));
    }
    Json(json!({ "recenttracks": { "track": tracks, "@attr": { "page": page.to_string(), "totalPages": total_pages.to_string(), "total": matching.len().to_string() } } })).into_response()
}

async fn read(State(inner): State<Arc<Inner>>, Query(query): Query<HashMap<String, String>>) -> Response {
    let method = query.get("method").cloned().unwrap_or_default();
    let signed = query.get("api_sig").is_some_and(|signature| *signature == format!("sig-{method}"));
    match method.as_str() {
        "user.getRecentTracks" => recent_tracks(&inner, &query).await,
        "auth.getToken" if signed => Json(json!({ "token": TOKEN })).into_response(),
        "auth.getSession" if signed && query.get("token").map(String::as_str) == Some(TOKEN) => {
            Json(json!({ "session": { "name": ACCOUNT, "key": SESSION_KEY, "subscriber": 0 } })).into_response()
        }
        _ => lastfm_error(13, "Invalid method signature supplied"),
    }
}

fn scrobbled_from(form: &HashMap<String, String>) -> Vec<Scrobbled> {
    (0..)
        .map_while(|index| {
            let title = form.get(&format!("track[{index}]"))?;
            Some(Scrobbled {
                artist: form.get(&format!("artist[{index}]")).cloned().unwrap_or_default(),
                title: title.clone(),
                timestamp: form.get(&format!("timestamp[{index}]")).and_then(|value| value.parse().ok()).unwrap_or(0),
            })
        })
        .collect()
}

fn scrobble_entries(batch: &[Scrobbled], ignored_code: &str) -> Value {
    let entries: Vec<Value> = batch
        .iter()
        .map(|play| json!({ "track": { "#text": play.title }, "ignoredMessage": { "code": ignored_code, "#text": "" } }))
        .collect();
    if entries.len() == 1 {
        entries[0].clone()
    } else {
        Value::Array(entries)
    }
}

async fn write(State(inner): State<Arc<Inner>>, Form(form): Form<HashMap<String, String>>) -> Response {
    let method = form.get("method").cloned().unwrap_or_default();
    let signed = form.get("api_sig").is_some_and(|signature| *signature == format!("sig-{method}"));
    if !signed {
        return lastfm_error(13, "Invalid method signature supplied");
    }
    if method == "track.updateNowPlaying" {
        inner.now_playing.lock().unwrap().push(form.get("track").cloned().unwrap_or_default());
        return Json(json!({ "nowplaying": { "track": { "#text": "x" } } })).into_response();
    }
    inner.scrobble_calls.fetch_add(1, Ordering::SeqCst);
    let batch = scrobbled_from(&form);
    match inner.script.lock().unwrap().pop_front() {
        Some(ScrobbleReply::ServerError) => return (StatusCode::INTERNAL_SERVER_ERROR, "boom").into_response(),
        Some(ScrobbleReply::InvalidSession) => return lastfm_error(9, "Invalid session key - Please re-authenticate"),
        Some(ScrobbleReply::Malformed) => return lastfm_error(6, "Invalid parameters"),
        Some(ScrobbleReply::Duplicate) => {
            let body = json!({ "scrobbles": { "@attr": { "accepted": 0, "ignored": batch.len() }, "scrobble": scrobble_entries(&batch, "1") } });
            return Json(body).into_response();
        }
        None => {}
    }
    if form.get("sk").map(String::as_str) != Some(SESSION_KEY) {
        return lastfm_error(9, "Invalid session key - Please re-authenticate");
    }
    inner.scrobbled.lock().unwrap().push(batch.clone());
    Json(json!({ "scrobbles": { "@attr": { "accepted": batch.len(), "ignored": 0 }, "scrobble": scrobble_entries(&batch, "0") } })).into_response()
}
