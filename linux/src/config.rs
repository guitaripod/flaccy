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
    pub theme: String,
    pub autoplay_continuation: bool,
    pub group_album_editions: bool,
    pub import_page_cursor: u32,
    pub sidebar_index: i32,
    pub album_sort: String,
    pub np_swap_sides: bool,
    pub np_show_lyrics: bool,
    pub np_show_queue: bool,
    /// Which side panel the library shell had open: "lyrics", "queue", or empty
    /// for none.
    pub side_panel: String,
    pub shuffle: bool,
    pub repeat_mode: String,
    pub lyrics_font_size: i32,
    pub np_show_video: bool,
    pub music_video_mode: bool,
    pub music_video_quality: i32,
    pub music_video_llm: bool,
    /// Empty means "whichever installed Ollama model looks most suitable".
    pub music_video_llm_model: String,
    pub music_video_align: bool,
}

/// Bounds for the lyrics type scale, shared by Preferences and the panel's own
/// quick controls.
pub const LYRICS_FONT_MIN: i32 = 12;
pub const LYRICS_FONT_MAX: i32 = 34;
pub const LYRICS_FONT_DEFAULT: i32 = 16;

impl Default for Config {
    fn default() -> Self {
        Self {
            music_dir: None,
            window_width: 1200,
            window_height: 760,
            volume: 0.9,
            appearance: "system".to_string(),
            theme: "adaptive".to_string(),
            autoplay_continuation: true,
            group_album_editions: true,
            import_page_cursor: 1,
            sidebar_index: 0,
            album_sort: "artist".to_string(),
            np_swap_sides: false,
            np_show_lyrics: false,
            np_show_queue: false,
            side_panel: String::new(),
            shuffle: false,
            repeat_mode: "off".to_string(),
            lyrics_font_size: LYRICS_FONT_DEFAULT,
            np_show_video: false,
            music_video_mode: false,
            music_video_quality: MUSIC_VIDEO_QUALITY_DEFAULT,
            music_video_llm: true,
            music_video_llm_model: String::new(),
            music_video_align: true,
        }
    }
}

/// A ceiling rather than a target: 720p is where a music video still looks
/// sharp on a laptop panel without spending a phone tether's worth of data.
pub const MUSIC_VIDEO_QUALITY_DEFAULT: i32 = 720;

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
