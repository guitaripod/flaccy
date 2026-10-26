use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use flaccy_library::listen_history::{artist_listen_key, title_key};
use flaccy_server_core::apply::Caller;
use flaccy_server_core::ledger::{recompute_second, SecondEvent};
use flaccy_server_core::model::SongRef;
use flaccy_server_core::mutation::{parse, ListenInput, Op};
use flaccy_server_core::sim::server::{ServerError, ServerModel, Snapshot};
use flaccy_server_core::wire::{Hello, PushRequest, ServerInfo};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::io::Write;
use std::sync::{Arc, Mutex};

const NOW_FALLBACK: i64 = 1_790_000_000_000;

#[derive(Clone)]
pub struct StoredListen {
    pub seq: i64,
    pub event_id: String,
    pub ts: i64,
    pub song: SongRef,
    pub played_s: i64,
    pub recorded: bool,
    pub suppressed: bool,
    pub title_key: String,
    pub artist_key: String,
}

#[derive(Clone, Default)]
pub struct ListenStore {
    pub rows: BTreeMap<String, StoredListen>,
    pub seq: i64,
}

impl ListenStore {
    pub fn record(&mut self, inputs: &[ListenInput]) {
        let mut seconds = Vec::new();
        for input in inputs {
            if self.rows.contains_key(&input.event_id) {
                continue;
            }
            self.seq += 1;
            let row = StoredListen {
                seq: self.seq,
                event_id: input.event_id.clone(),
                ts: input.ts,
                song: input.song.clone(),
                played_s: input.played_s,
                recorded: input.recorded,
                suppressed: false,
                title_key: title_key(&input.song.title),
                artist_key: artist_listen_key(&input.song.artist),
            };
            self.rows.insert(row.event_id.clone(), row);
            seconds.push(input.ts);
        }
        seconds.sort_unstable();
        seconds.dedup();
        for second in seconds {
            self.recompute(second);
        }
    }

    pub fn insert_raw(&mut self, rows: Vec<StoredListen>) {
        for row in rows {
            self.seq = self.seq.max(row.seq);
            self.rows.insert(row.event_id.clone(), row);
        }
    }

    fn recompute(&mut self, second: i64) {
        let events: Vec<SecondEvent> = self
            .rows
            .values()
            .filter(|row| row.ts == second)
            .map(|row| SecondEvent {
                event_id: row.event_id.clone(),
                recorded: row.recorded,
                title_key: row.title_key.clone(),
                artist_key: row.artist_key.clone(),
                suppressed: row.suppressed,
            })
            .collect();
        for change in recompute_second(&events) {
            self.seq += 1;
            if let Some(row) = self.rows.get_mut(&change.event_id) {
                row.suppressed = change.suppressed;
                row.seq = self.seq;
            }
        }
    }

    fn page(&self, query: &HashMap<String, String>) -> Value {
        let limit: usize = query
            .get("limit")
            .and_then(|v| v.parse().ok())
            .unwrap_or(1000);
        let mut rows: Vec<&StoredListen> = self.rows.values().collect();
        let (selected, more) =
            if let Some(before) = query.get("before").and_then(|v| v.parse::<i64>().ok()) {
                rows.retain(|row| row.ts < before);
                rows.sort_by(|a, b| b.ts.cmp(&a.ts).then(b.seq.cmp(&a.seq)));
                cut(rows, limit)
            } else {
                let after = query
                    .get("after")
                    .and_then(|v| v.parse::<i64>().ok())
                    .unwrap_or(0);
                rows.retain(|row| row.seq > after);
                rows.sort_by_key(|row| row.seq);
                cut(rows, limit)
            };
        let items: Vec<Value> = selected
            .into_iter()
            .map(|row| {
                json!({ "seq": row.seq, "eventId": row.event_id, "ts": row.ts, "ref": row.song,
                        "playedS": row.played_s, "source": "flaccy", "recorded": row.recorded,
                        "device": null, "suppressed": row.suppressed })
            })
            .collect();
        json!({ "listens": items, "more": more, "head": self.seq })
    }
}

fn cut(mut rows: Vec<&StoredListen>, limit: usize) -> (Vec<&StoredListen>, bool) {
    let more = rows.len() > limit;
    rows.truncate(limit);
    (rows, more)
}

pub struct DoubleState {
    pub model: ServerModel,
    pub listens: ListenStore,
    tokens: HashMap<String, (String, String)>,
    codes: HashMap<String, String>,
    next_device: u32,
    next_code: u32,
    pub offline: bool,
    pub pushes: u32,
    pub pulls: u32,
}

type Shared = Arc<Mutex<DoubleState>>;

pub struct Double {
    pub url: String,
    state: Shared,
    shutdown: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

fn now_ms() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(NOW_FALLBACK)
}

fn error(status: StatusCode, code: &str, extra: Value) -> Response {
    let mut body = json!({ "error": { "code": code, "message": code } });
    if let (Some(target), Some(extra)) = (body["error"].as_object_mut(), extra.as_object()) {
        target.extend(extra.clone());
    }
    (status, Json(body)).into_response()
}

fn caller(state: &DoubleState, headers: &HeaderMap) -> Result<Caller, Box<Response>> {
    if state.offline {
        return Err(Box::new(error(
            StatusCode::SERVICE_UNAVAILABLE,
            "unavailable",
            json!({}),
        )));
    }
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    let (user, device) = state
        .tokens
        .get(token)
        .ok_or_else(|| Box::new(error(StatusCode::UNAUTHORIZED, "unauthorized", json!({}))))?;
    if let Some(seen) = headers
        .get("Flaccy-Incarnation")
        .and_then(|v| v.to_str().ok())
    {
        if seen != state.model.incarnation {
            return Err(Box::new(error(
                StatusCode::CONFLICT,
                "incarnation_changed",
                json!({ "incarnation": state.model.incarnation }),
            )));
        }
    }
    Ok(Caller::member(user, device))
}

async fn hello(State(shared): State<Shared>) -> Response {
    let state = shared.lock().unwrap();
    Json(Hello {
        protocol: vec![1],
        server: ServerInfo {
            name: "double".into(),
            version: "0".into(),
            schema: 1,
        },
        features: vec!["sync".into(), "live".into()],
        mode: "easy".into(),
        server_time_ms: now_ms(),
        incarnation: state.model.incarnation.clone(),
        caller: None,
    })
    .into_response()
}

async fn enroll(State(shared): State<Shared>, Json(body): Json<Value>) -> Response {
    let mut state = shared.lock().unwrap();
    let code = body["enroll"].as_str().unwrap_or_default();
    let Some(user) = state.codes.remove(code) else {
        return error(StatusCode::UNAUTHORIZED, "enroll_invalid", json!({}));
    };
    state.next_device += 1;
    let device = format!("device-{}", state.next_device);
    let token = format!("token-{}-{}", state.next_device, rand_suffix());
    state
        .tokens
        .insert(token.clone(), (user.clone(), device.clone()));
    let reply = json!({ "device": device, "token": token, "user": { "id": user, "name": user, "role": "member" },
                        "serverTimeMs": now_ms(), "incarnation": state.model.incarnation });
    (StatusCode::CREATED, Json(reply)).into_response()
}

async fn devices(State(shared): State<Shared>, headers: HeaderMap) -> Response {
    let state = shared.lock().unwrap();
    let token = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "))
        .unwrap_or_default();
    let Some((user, current)) = state.tokens.get(token) else {
        return error(StatusCode::UNAUTHORIZED, "unauthorized", json!({}));
    };
    let mut listed: Vec<Value> = state
        .tokens
        .values()
        .filter(|(owner, _)| owner == user)
        .map(|(_, device)| {
            json!({ "id": device, "name": format!("name of {device}"), "platform": "linux",
                    "lastSeenAt": now_ms(), "current": device == current })
        })
        .collect();
    listed.sort_by_key(|device| device["id"].as_str().unwrap_or_default().to_owned());
    Json(json!({ "devices": listed })).into_response()
}

fn rand_suffix() -> u64 {
    now_ms() as u64 ^ (std::process::id() as u64) << 20
}

async fn push(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Json(request): Json<PushRequest>,
) -> Response {
    let mut state = shared.lock().unwrap();
    let caller = match caller(&state, &headers) {
        Ok(caller) => caller,
        Err(response) => return *response,
    };
    state.pushes += 1;
    match state.model.push(&caller, &request, now_ms()) {
        Ok(response) => {
            for mutation in &request.mutations {
                if let Ok(Op::Listen(inputs)) = parse(mutation) {
                    state.listens.record(&inputs);
                }
            }
            Json(response).into_response()
        }
        Err(ServerError::InstanceConflict) => {
            error(StatusCode::CONFLICT, "instance_conflict", json!({}))
        }
        Err(ServerError::MutationGap { have }) => error(
            StatusCode::CONFLICT,
            "mutation_gap",
            json!({ "have": have }),
        ),
        Err(ServerError::CookieAhead) => error(StatusCode::CONFLICT, "cookie_ahead", json!({})),
        Err(ServerError::ClockBehind) => {
            error(StatusCode::SERVICE_UNAVAILABLE, "clock_behind", json!({}))
        }
    }
}

async fn pull(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let mut state = shared.lock().unwrap();
    let caller = match caller(&state, &headers) {
        Ok(caller) => caller,
        Err(response) => return *response,
    };
    state.pulls += 1;
    let since = query.get("since").and_then(|v| v.parse().ok()).unwrap_or(0);
    let limit = query
        .get("limit")
        .and_then(|v| v.parse().ok())
        .unwrap_or(1000);
    let instance = query.get("instance").cloned().unwrap_or_default();
    match state
        .model
        .pull(&caller.device, &instance, since, limit, now_ms())
    {
        Ok(response) => Json(response).into_response(),
        Err(_) => error(
            StatusCode::CONFLICT,
            "cookie_ahead",
            json!({ "incarnation": state.model.incarnation }),
        ),
    }
}

async fn listens(
    State(shared): State<Shared>,
    headers: HeaderMap,
    Query(query): Query<HashMap<String, String>>,
) -> Response {
    let state = shared.lock().unwrap();
    if let Err(response) = caller(&state, &headers) {
        return *response;
    }
    let body = serde_json::to_vec(&state.listens.page(&query)).unwrap_or_default();
    let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
    let _ = encoder.write_all(&body);
    let compressed = encoder.finish().unwrap_or_default();
    (
        [
            (header::CONTENT_TYPE, "application/json"),
            (header::CONTENT_ENCODING, "gzip"),
        ],
        compressed,
    )
        .into_response()
}

impl Double {
    pub fn start() -> Double {
        let state: Shared = Arc::new(Mutex::new(DoubleState {
            model: ServerModel::new("incarnation-1".into()),
            listens: ListenStore::default(),
            tokens: HashMap::new(),
            codes: HashMap::new(),
            next_device: 0,
            next_code: 0,
            offline: false,
            pushes: 0,
            pulls: 0,
        }));
        let router = Router::new()
            .route("/flaccy/v1/hello", get(hello))
            .route("/flaccy/v1/devices", post(enroll).get(devices))
            .route("/flaccy/v1/sync/push", post(push))
            .route("/flaccy/v1/sync/pull", get(pull))
            .route("/flaccy/v1/listens", get(listens))
            .with_state(state.clone());
        let (address_tx, address_rx) = std::sync::mpsc::channel();
        let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel::<()>();
        let thread = std::thread::spawn(move || {
            let runtime = tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .unwrap();
            runtime.block_on(async move {
                let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
                address_tx.send(listener.local_addr().unwrap()).unwrap();
                let _ = axum::serve(listener, router)
                    .with_graceful_shutdown(async {
                        let _ = shutdown_rx.await;
                    })
                    .await;
            });
        });
        let address = address_rx.recv().unwrap();
        Double {
            url: format!("http://{address}"),
            state,
            shutdown: Some(shutdown_tx),
            thread: Some(thread),
        }
    }

    pub fn link(&self, user: &str) -> String {
        let mut state = self.state.lock().unwrap();
        state.next_code += 1;
        let code = format!("CODE{}X{}", state.next_code, rand_suffix());
        state.codes.insert(code.clone(), user.to_owned());
        format!(
            "flaccy://server?url={}&enroll={code}&name=Double",
            flaccy_library::remote::encode_segment(&self.url)
        )
    }

    pub fn with<T>(&self, read: impl FnOnce(&mut DoubleState) -> T) -> T {
        read(&mut self.state.lock().unwrap())
    }

    pub fn set_offline(&self, offline: bool) {
        self.with(|state| state.offline = offline);
    }

    pub fn snapshot(&self) -> (Snapshot, ListenStore) {
        self.with(|state| (state.model.snapshot(), state.listens.clone()))
    }

    pub fn restore(&self, saved: (Snapshot, ListenStore), incarnation: &str) {
        self.with(|state| {
            state.model.restore(saved.0, incarnation.to_owned());
            state.listens = saved.1;
        });
    }
}

impl Drop for Double {
    fn drop(&mut self) {
        if let Some(shutdown) = self.shutdown.take() {
            let _ = shutdown.send(());
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
