//! In-process tests: the router is driven with `tower::ServiceExt::oneshot`
//! against a throwaway music folder and data folder.

mod library;
mod media;
mod protocol;
mod versions;

use std::path::PathBuf;

use axum::body::Body;
use axum::http::{HeaderMap, Method, Request, StatusCode};
use axum::Router;
use flaccy_library::fingerprint::fixtures::{info_tags, tone, wav_bytes};
use flaccy_shared::remote::subsonic_response::{Envelope, Root};
use serde_json::Value;
use tower::ServiceExt;

use crate::config::Config;
use crate::credentials::{self, Credentials};
use crate::refresh::{refresh_now, ScanSummary};
use crate::state::AppState;

pub const USER: &str = "tester";
pub const PASSWORD: &str = "sesame-seed";

/// A directory made for one test, unique even when tests start in the same
/// nanosecond, removed when dropped.
pub struct TestDir(PathBuf);

impl TestDir {
    fn new() -> Self {
        static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
        let number = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let path = std::env::temp_dir().join(format!("flaccy-server-test-{}-{number}", std::process::id()));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    pub fn path(&self) -> &std::path::Path {
        &self.0
    }
}

impl Drop for TestDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A finished HTTP answer.
pub struct Reply {
    pub status: StatusCode,
    pub headers: HeaderMap,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.body).into_owned()
    }

    pub fn header(&self, name: &str) -> &str {
        self.headers
            .get(name)
            .and_then(|value| value.to_str().ok())
            .unwrap_or("")
    }
}

/// A JSON answer decoded with the shared client models, plus the raw object.
pub struct Answer {
    pub envelope: Envelope,
    pub raw: Value,
}

impl Answer {
    pub fn ok(&self) -> &Self {
        assert_eq!(self.envelope.status, "ok", "{}", self.raw);
        self
    }

    pub fn error_code(&self) -> i64 {
        assert_eq!(self.envelope.status, "failed", "{}", self.raw);
        self.envelope.error.as_ref().and_then(|error| error.code).unwrap()
    }
}

pub struct TestServer {
    pub dir: TestDir,
    pub state: AppState,
    pub router: Router,
    pub api_key: String,
}

impl TestServer {
    pub fn new() -> Self {
        Self::with_ffmpeg("ffmpeg")
    }

    pub fn with_ffmpeg(ffmpeg: &str) -> Self {
        let dir = TestDir::new();
        let music = dir.path().join("music");
        std::fs::create_dir_all(&music).unwrap();
        let config = Config {
            music_folder: music,
            address: "127.0.0.1".to_string(),
            port: 0,
            data_dir: Some(dir.path().join("data")),
            behind_proxy: false,
        };
        let mut account = Credentials {
            username: USER.to_string(),
            password: PASSWORD.to_string(),
            keys: Vec::new(),
        };
        let api_key = account.add_key("phone", "2026-10-25T12:00:00Z").unwrap();
        credentials::save(&config.credentials_path(), &account).unwrap();
        let state = AppState::open_with_ffmpeg(config, ffmpeg.to_string()).unwrap();
        let router = crate::api::router(state.clone());
        Self { dir, state, router, api_key }
    }

    pub fn music(&self) -> PathBuf {
        self.dir.path().join("music")
    }

    pub fn write_song(&self, rel: &str, title: &str, artist: &str, album: &str, samples: usize, step: i16) {
        let path = self.music().join(rel);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let tags = info_tags(title, artist, album);
        std::fs::write(path, wav_bytes(&tone(samples, step), Some(&tags))).unwrap();
    }

    pub fn standard_library(&self) {
        for (number, title, step) in [(3, "Closing", 9), (1, "Opening", 7), (2, "Middle", 8)] {
            self.write_song(
                &format!("Drill Band/Rough Cuts/0{number} {title}.wav"),
                title,
                "Drill Band",
                "Rough Cuts",
                8000,
                step,
            );
        }
        for (number, title, step) in [(1, "Glow", 5), (2, "Dim", 6)] {
            self.write_song(
                &format!("The Echo/Second Light/0{number} {title}.wav"),
                title,
                "The Echo",
                "Second Light",
                8000,
                step,
            );
        }
        self.write_song("Zed/Third/01 Solo.wav", "Solo", "Zed", "Third", 8000, 4);
        let summary = self.scan();
        assert_eq!(summary.added, 6, "{summary:?}");
    }

    pub fn scan(&self) -> ScanSummary {
        refresh_now(&self.state)
    }

    pub async fn send(&self, request: Request<Body>) -> Reply {
        let response = self.router.clone().oneshot(request).await.unwrap();
        let (parts, body) = response.into_parts();
        let body = axum::body::to_bytes(body, usize::MAX).await.unwrap().to_vec();
        Reply {
            status: parts.status,
            headers: parts.headers,
            body,
        }
    }

    pub async fn get(&self, uri: &str) -> Reply {
        self.send(Request::builder().uri(uri).body(Body::empty()).unwrap()).await
    }

    pub async fn get_with(&self, uri: &str, headers: &[(&str, &str)]) -> Reply {
        let mut builder = Request::builder().uri(uri);
        for (name, value) in headers {
            builder = builder.header(*name, *value);
        }
        self.send(builder.body(Body::empty()).unwrap()).await
    }

    pub fn login() -> String {
        format!("u={USER}&p={PASSWORD}&v=1.16.1&c=tests")
    }

    pub async fn json(&self, method: &str, query: &str) -> Answer {
        let uri = format!("/rest/{method}?{}&f=json&{query}", Self::login());
        let reply = self.get(&uri).await;
        assert_eq!(reply.status, StatusCode::OK);
        assert!(reply.header("content-type").starts_with("application/json"));
        let raw: Value = serde_json::from_slice(&reply.body).unwrap();
        let root: Root = serde_json::from_slice(&reply.body).expect("decodes with the shared client models");
        Answer {
            envelope: root.response,
            raw: raw["subsonic-response"].clone(),
        }
    }

    pub async fn post_form(&self, method: &str, form: &str) -> Reply {
        let request = Request::builder()
            .method(Method::POST)
            .uri(format!("/rest/{method}"))
            .header("content-type", "application/x-www-form-urlencoded")
            .body(Body::from(form.to_string()))
            .unwrap();
        self.send(request).await
    }

    pub async fn song_id(&self, title: &str) -> String {
        let answer = self.json("search3", &format!("query={title}&songCount=50")).await;
        answer
            .envelope
            .search_result3
            .unwrap()
            .song
            .unwrap()
            .into_iter()
            .find(|song| song.title == title)
            .unwrap_or_else(|| panic!("no song called {title}"))
            .id
    }

    pub async fn album_id(&self, name: &str) -> String {
        let answer = self.json("getAlbumList2", "type=alphabeticalByName&size=50").await;
        answer
            .envelope
            .album_list2
            .unwrap()
            .album
            .unwrap()
            .into_iter()
            .find(|album| album.name == name)
            .unwrap_or_else(|| panic!("no album called {name}"))
            .id
    }
}
