#![allow(dead_code)]

use std::net::SocketAddr;
use std::time::Duration;

use flaccy_server::config::{Config, Mode};
use flaccy_server::native;
use flaccy_server::net::{serve, AllowedHosts, ConnectionLimits, Limits, TailnetAddresses};
use flaccy_server::security::{DeviceId, Role, UserId};
use flaccy_server::state::AppState;
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio::task::JoinHandle;

use super::TempDir;

const IO_TIMEOUT: Duration = Duration::from_secs(20);

pub struct Reply {
    pub status: u16,
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or_else(|error| panic!("not JSON ({error}): {}", String::from_utf8_lossy(&self.body)))
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(key, _)| key.eq_ignore_ascii_case(name)).map(|(_, value)| value.as_str())
    }

    pub fn code(&self) -> String {
        self.json()["error"]["code"].as_str().unwrap_or("").to_owned()
    }
}

fn decode_chunked(mut raw: &[u8]) -> Vec<u8> {
    let mut body = Vec::new();
    loop {
        let Some(line_end) = raw.windows(2).position(|pair| pair == b"\r\n") else {
            return body;
        };
        let size = usize::from_str_radix(String::from_utf8_lossy(&raw[..line_end]).trim(), 16).unwrap_or(0);
        raw = &raw[line_end + 2..];
        if size == 0 || raw.len() < size {
            return body;
        }
        body.extend_from_slice(&raw[..size]);
        raw = raw.get(size + 2..).unwrap_or(&[]);
    }
}

fn parse(raw: &[u8]) -> Reply {
    let split = raw.windows(4).position(|window| window == b"\r\n\r\n").expect("a complete HTTP head");
    let head = String::from_utf8_lossy(&raw[..split]).into_owned();
    let mut lines = head.lines();
    let status = lines.next().and_then(|line| line.split_whitespace().nth(1)).and_then(|code| code.parse().ok()).unwrap_or(0);
    let headers: Vec<(String, String)> = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(name, value)| (name.trim().to_owned(), value.trim().to_owned()))
        .collect();
    let rest = &raw[split + 4..];
    let chunked = headers.iter().any(|(name, value)| name.eq_ignore_ascii_case("transfer-encoding") && value.contains("chunked"));
    let body = if chunked { decode_chunked(rest) } else { rest.to_vec() };
    Reply { status, headers, body }
}

pub async fn send(address: SocketAddr, method: &str, path: &str, headers: &[(&str, &str)], body: &[u8]) -> Reply {
    let mut head = format!("{method} {path} HTTP/1.1\r\nConnection: close\r\n");
    if !headers.iter().any(|(name, _)| name.eq_ignore_ascii_case("host")) {
        head.push_str(&format!("Host: {address}\r\n"));
    }
    for (name, value) in headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str(&format!("Content-Length: {}\r\n\r\n", body.len()));
    let mut stream = TcpStream::connect(address).await.unwrap();
    stream.write_all(head.as_bytes()).await.unwrap();
    let _ = stream.write_all(body).await;
    let mut raw = Vec::new();
    let _ = tokio::time::timeout(IO_TIMEOUT, stream.read_to_end(&mut raw)).await.unwrap();
    parse(&raw)
}

pub struct Device {
    pub id: String,
    pub token: String,
    pub user: String,
    pub instance: String,
}

pub struct Harness {
    pub dir: TempDir,
    pub state: AppState,
    pub address: SocketAddr,
    stop: Option<oneshot::Sender<()>>,
    task: Option<JoinHandle<()>>,
}

impl Harness {
    pub async fn start() -> Self {
        Self::start_with(|_| {}).await
    }

    pub async fn start_with(prepare: impl FnOnce(&Config)) -> Self {
        let dir = TempDir::new("native");
        let music = dir.file("music");
        std::fs::create_dir_all(&music).unwrap();
        let config = Config {
            music_folder: music,
            address: "127.0.0.1".to_owned(),
            port: 0,
            data_dir: Some(dir.file("data")),
            behind_proxy: false,
            mode: Mode::Easy,
            lastfm: Default::default(),
            hosts: Vec::new(),
            backup_dir: None,
        };
        prepare(&config);
        Self::start_in(dir, config).await
    }

    pub async fn start_in(dir: TempDir, config: Config) -> Self {
        let state = AppState::open(config).await.unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let hosts = AllowedHosts::new(&[], TailnetAddresses::default());
        let app = native::app(state.clone(), hosts);
        let (stop, stopped) = oneshot::channel::<()>();
        let task = tokio::spawn(async move {
            let limits = ConnectionLimits::new(Limits::default());
            let _ = serve(listener, app, limits, async move {
                let _ = stopped.await;
            })
            .await;
        });
        Self { dir, state, address, stop: Some(stop), task: Some(task) }
    }

    pub async fn get(&self, path: &str, token: Option<&str>) -> Reply {
        self.call("GET", path, token, &[], &[]).await
    }

    pub async fn call(&self, method: &str, path: &str, token: Option<&str>, extra: &[(&str, &str)], body: &[u8]) -> Reply {
        let bearer = token.map(|token| format!("Bearer {token}"));
        let mut headers: Vec<(&str, &str)> = extra.to_vec();
        if let Some(bearer) = bearer.as_deref() {
            headers.push(("Authorization", bearer));
        }
        send(self.address, method, path, &headers, body).await
    }

    pub async fn post_json(&self, path: &str, token: Option<&str>, extra: &[(&str, &str)], body: &Value) -> Reply {
        let mut headers: Vec<(&str, &str)> = vec![("Content-Type", "application/json")];
        headers.extend_from_slice(extra);
        self.call("POST", path, token, &headers, body.to_string().as_bytes()).await
    }

    pub async fn user(&self, name: &str, role: Role) -> UserId {
        match self.state.0.security.find_user_by_name(name).await.unwrap() {
            Some(user) => user.id,
            None => self.state.0.security.create_user(name, role).await.unwrap().id,
        }
    }

    pub async fn enroll_code(&self, user: &UserId) -> String {
        self.state.0.security.create_enrollment(user, Duration::from_secs(600)).await.unwrap()
    }

    pub async fn enroll(&self, name: &str, role: Role) -> Device {
        let user = self.user(name, role).await;
        let code = self.enroll_code(&user).await;
        let instance = format!("{name}-instance");
        let reply = self
            .post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": code, "name": format!("{name}'s phone"), "platform": "linux", "instance": instance }))
            .await;
        assert_eq!(reply.status, 201, "{}", String::from_utf8_lossy(&reply.body));
        let body = reply.json();
        Device {
            id: body["device"].as_str().unwrap().to_owned(),
            token: body["token"].as_str().unwrap().to_owned(),
            user: user.to_string(),
            instance,
        }
    }

    pub async fn push(&self, device: &Device, first_id: i64, mutations: Vec<(&str, Value)>) -> Reply {
        let list: Vec<Value> = mutations
            .into_iter()
            .enumerate()
            .map(|(offset, (name, args))| {
                let id = first_id + offset as i64;
                json!({ "id": id, "name": name, "stamp": (super::BASE_TIME_MS << 16) + id, "args": args })
            })
            .collect();
        let body = json!({ "device": device.id, "instance": device.instance, "mutations": list });
        self.post_json("/flaccy/v1/sync/push", Some(&device.token), &[], &body).await
    }

    pub async fn pull(&self, device: &Device, since: i64) -> Reply {
        self.get(&format!("/flaccy/v1/sync/pull?since={since}&instance={}", device.instance), Some(&device.token)).await
    }

    pub async fn revoke(&self, device: &str) {
        self.state.0.security.revoke_device(&DeviceId(device.to_owned())).await.unwrap();
    }

    pub async fn halt(mut self) -> (TempDir, Config) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = tokio::time::timeout(IO_TIMEOUT, task).await;
        }
        flaccy_server::shutdown::close_databases(&self.state).await;
        (self.dir, self.state.0.config.clone())
    }

    pub async fn stop(mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(task) = self.task.take() {
            let _ = tokio::time::timeout(IO_TIMEOUT, task).await;
        }
    }
}
