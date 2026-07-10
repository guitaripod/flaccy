use serde::{Deserialize, Serialize};
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone)]
#[serde(default)]
pub struct Config {
    pub music_dir: Option<String>,
    pub window_width: i32,
    pub window_height: i32,
    pub volume: f64,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            music_dir: None,
            window_width: 1200,
            window_height: 760,
            volume: 0.9,
        }
    }
}

impl Config {
    pub fn music_root(&self) -> PathBuf {
        self.music_dir
            .as_ref()
            .map(PathBuf::from)
            .filter(|p| p.is_dir())
            .or_else(|| dirs::audio_dir())
            .unwrap_or_else(|| dirs::home_dir().unwrap_or_default().join("Music"))
    }
}

pub fn config_dir() -> PathBuf {
    dirs::config_dir().unwrap_or_default().join("flaccy")
}

pub fn config_path() -> PathBuf {
    config_dir().join("config.toml")
}

pub fn session_path() -> PathBuf {
    config_dir().join("session")
}

pub fn load() -> Config {
    let path = config_path();
    fs::read_to_string(&path)
        .ok()
        .and_then(|text| toml::from_str(&text).ok())
        .unwrap_or_default()
}

pub fn save(config: &Config) {
    let dir = config_dir();
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    if let Ok(text) = toml::to_string_pretty(config) {
        let _ = fs::write(config_path(), text);
    }
}

#[derive(Clone)]
pub struct Session {
    pub key: String,
    pub username: String,
}

pub fn load_session() -> Option<Session> {
    let text = fs::read_to_string(session_path()).ok()?;
    let mut lines = text.lines();
    let key = lines.next()?.trim().to_string();
    let username = lines.next().unwrap_or("").trim().to_string();
    if key.is_empty() {
        return None;
    }
    Some(Session { key, username })
}

pub fn save_session(session: &Session) {
    let dir = config_dir();
    if fs::create_dir_all(&dir).is_err() {
        return;
    }
    let path = session_path();
    if fs::write(&path, format!("{}\n{}\n", session.key, session.username)).is_ok() {
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o600));
    }
}

pub fn delete_session() {
    let _ = fs::remove_file(session_path());
}
