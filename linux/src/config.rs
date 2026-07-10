use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;

#[derive(Serialize, Deserialize, Clone)]
#[serde(default)]
pub struct Config {
    pub music_dir: Option<String>,
    pub window_width: i32,
    pub window_height: i32,
    pub volume: f64,
    pub appearance: String,
    pub autoplay_continuation: bool,
    pub import_page_cursor: u32,
    pub sidebar_index: i32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            music_dir: None,
            window_width: 1200,
            window_height: 760,
            volume: 0.9,
            appearance: "system".to_string(),
            autoplay_continuation: true,
            import_page_cursor: 1,
            sidebar_index: 0,
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

/// Marketing/demo mode: enabled by `--demo` or `FLACCY_DEMO=1`. Uses a separate
/// GTK application id and MPRIS bus name so a demo instance (pointed at
/// throwaway XDG dirs) can run alongside a normal instance.
pub fn demo_mode() -> bool {
    std::env::var_os("FLACCY_DEMO").is_some()
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
    let result = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(session_path())
        .and_then(|mut file| {
            file.write_all(format!("{}\n{}\n", session.key, session.username).as_bytes())?;
            file.set_permissions(fs::Permissions::from_mode(0o600))
        });
    if let Err(err) = result {
        crate::logger::error("auth", &format!("session save failed: {err}"));
    }
}

pub fn delete_session() {
    let _ = fs::remove_file(session_path());
}
