//! The server's configuration file and the paths derived from it.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::lastfm::LastfmSettings;

const DEFAULT_ADDRESS: &str = "127.0.0.1";
const DEFAULT_PORT: u16 = 4545;

/// How the server is reached.
#[derive(Clone, Copy, Debug, Default, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Tailnet addresses and loopback, plain HTTP, device tokens.
    #[default]
    Easy,
    /// A Unix socket behind `tailscale serve`; not available yet.
    Household,
}

/// What `config.toml` holds. Only `music_folder` is required.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct Config {
    pub music_folder: PathBuf,
    #[serde(default = "default_address")]
    pub address: String,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default)]
    pub data_dir: Option<PathBuf>,
    /// Set when a reverse proxy on this machine, such as `tailscale serve`, is the
    /// only thing connecting to the server. Failed logins are then counted against
    /// the first address in `X-Forwarded-For`. Leave it false when clients connect
    /// directly, because any client can then send any address and dodge the lockout.
    #[serde(default)]
    pub behind_proxy: bool,
    /// How the server is reached; only `easy` exists in this release.
    #[serde(default)]
    pub mode: Mode,
    /// Host names clients may use besides this machine's tailnet addresses and localhost.
    #[serde(default)]
    pub hosts: Vec<String>,
    /// The `lastfm_*` keys: the API key and, for tests, other endpoints.
    #[serde(flatten)]
    pub lastfm: LastfmSettings,
    /// Where nightly backups and `flaccy-server backup` put their files; `<data_dir>/backups`
    /// when unset, and an empty string turns the nightly backup off.
    #[serde(default)]
    pub backup_dir: Option<PathBuf>,
}

fn default_address() -> String {
    DEFAULT_ADDRESS.to_string()
}

fn default_port() -> u16 {
    DEFAULT_PORT
}

/// Why the configuration could not be used.
#[derive(Debug)]
pub enum ConfigError {
    Missing(PathBuf),
    Unreadable(PathBuf, String),
    Invalid(PathBuf, String),
    HouseholdUnavailable,
}

impl std::fmt::Display for ConfigError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Missing(path) => write!(
                formatter,
                "There is no configuration file at {path}.\nCreate it with the folder your music lives in:\n\n  mkdir -p {dir}\n  printf 'music_folder = \"/path/to/your/music\"\\n' > {path}\n\n`address` (default {DEFAULT_ADDRESS}), `port` (default {DEFAULT_PORT}) and `data_dir` (default {data}) are optional. Then run `flaccy-server password set` and `flaccy-server serve`.",
                path = path.display(),
                dir = path.parent().unwrap_or(Path::new(".")).display(),
                data = Config::default_data_dir().display()
            ),
            Self::Unreadable(path, cause) => write!(
                formatter,
                "Could not read the configuration file {}: {cause}. Check that it exists and that your user may read it.",
                path.display()
            ),
            Self::HouseholdUnavailable => write!(
                formatter,
                "Household mode is not available in this release; remove `mode` or set it to \"easy\"."
            ),
            Self::Invalid(path, cause) => write!(
                formatter,
                "The configuration file {} is not valid: {cause}. Fix the line it names; `music_folder` must be a quoted path.",
                path.display()
            ),
        }
    }
}

impl std::error::Error for ConfigError {}

impl Config {
    /// `~/.config/flaccy-server/config.toml` on Linux, `~/Library/Application Support/flaccy-server/config.toml` on a Mac.
    pub fn default_path() -> PathBuf {
        dirs::config_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("flaccy-server")
            .join("config.toml")
    }

    /// Reads and checks the configuration at `path`.
    pub fn load(path: &Path) -> Result<Config, ConfigError> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                return Err(ConfigError::Missing(path.to_path_buf()))
            }
            Err(err) => return Err(ConfigError::Unreadable(path.to_path_buf(), err.to_string())),
        };
        let mut config: Config = toml::from_str(&text)
            .map_err(|err| ConfigError::Invalid(path.to_path_buf(), err.to_string()))?;
        if config.mode == Mode::Household {
            return Err(ConfigError::HouseholdUnavailable);
        }
        config.music_folder = expand_home(&config.music_folder);
        config.data_dir = config.data_dir.map(|dir| expand_home(&dir));
        Ok(config)
    }

    /// `~/.local/share/flaccy-server` on Linux, `~/Library/Application Support/flaccy-server` on a Mac.
    pub fn default_data_dir() -> PathBuf {
        dirs::data_dir().unwrap_or_else(|| PathBuf::from(".")).join("flaccy-server")
    }

    /// Where the database, credentials, covers and log live.
    pub fn data_dir(&self) -> PathBuf {
        self.data_dir.clone().unwrap_or_else(Config::default_data_dir)
    }

    /// The SQLite library database.
    pub fn database_path(&self) -> PathBuf {
        self.data_dir().join("library.sqlite")
    }

    /// The security database: users, devices, enrollments, API keys and the audit trail.
    pub fn security_path(&self) -> PathBuf {
        self.data_dir().join("security.sqlite")
    }

    /// The sync state database.
    pub fn state_path(&self) -> PathBuf {
        self.data_dir().join("state.sqlite")
    }

    /// The account and API keys file.
    pub fn credentials_path(&self) -> PathBuf {
        self.data_dir().join("credentials.toml")
    }

    /// Where backups go: the configured folder, `<data_dir>/backups` by default, or `None` when `backup_dir` is empty.
    pub fn backup_dir(&self) -> Option<PathBuf> {
        match &self.backup_dir {
            Some(dir) if dir.as_os_str().is_empty() => None,
            Some(dir) => Some(expand_home(dir)),
            None => Some(self.data_dir().join("backups")),
        }
    }

    /// The resized cover cache.
    pub fn covers_dir(&self) -> PathBuf {
        self.data_dir().join("covers")
    }

    /// `address:port` as the listener binds it.
    pub fn listen_address(&self) -> String {
        if self.address.contains(':') && !self.address.starts_with('[') {
            format!("[{}]:{}", self.address, self.port)
        } else {
            format!("{}:{}", self.address, self.port)
        }
    }
}

fn expand_home(path: &Path) -> PathBuf {
    match path.strip_prefix("~") {
        Ok(rest) => dirs::home_dir().unwrap_or_default().join(rest),
        Err(_) => path.to_path_buf(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(text: &str) -> (PathBuf, PathBuf) {
        let dir = std::env::temp_dir().join(format!(
            "flaccy-server-config-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        std::fs::write(&path, text).unwrap();
        (dir, path)
    }

    #[test]
    fn only_the_music_folder_is_required() {
        let (dir, path) = write("music_folder = \"/music\"\n");
        let config = Config::load(&path).unwrap();
        assert_eq!(config.address, "127.0.0.1");
        assert_eq!(config.port, 4545);
        assert!(!config.behind_proxy);
        assert_eq!(config.listen_address(), "127.0.0.1:4545");
        assert!(config.data_dir().ends_with("flaccy-server"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_missing_file_explains_how_to_create_it() {
        let error = Config::load(Path::new("/nonexistent/flaccy/config.toml")).unwrap_err();
        let text = error.to_string();
        assert!(matches!(error, ConfigError::Missing(_)));
        assert!(text.contains("music_folder") && text.contains("password set"));
    }

    #[test]
    fn a_missing_file_names_the_data_folder_this_system_uses() {
        let text = Config::load(Path::new("/nonexistent/flaccy/config.toml")).unwrap_err().to_string();
        assert!(text.contains(&Config::default_data_dir().display().to_string()), "{text}");
    }

    #[test]
    fn a_file_without_a_music_folder_is_rejected_by_name() {
        let (dir, path) = write("port = 4540\n");
        let error = Config::load(&path).unwrap_err();
        assert!(error.to_string().contains("music_folder"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn mode_and_hosts_default_to_easy_and_none() {
        let (dir, path) = write("music_folder = \"/music\"\n");
        let config = Config::load(&path).unwrap();
        assert_eq!(config.mode, Mode::Easy);
        assert!(config.hosts.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn hosts_are_read_from_the_file() {
        let (dir, path) = write("music_folder = \"/m\"\nmode = \"easy\"\nhosts = [\"music.example.org\"]\n");
        assert_eq!(Config::load(&path).unwrap().hosts, vec!["music.example.org".to_string()]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn household_mode_fails_to_load_with_the_documented_sentence() {
        let (dir, path) = write("music_folder = \"/m\"\nmode = \"household\"\n");
        let error = Config::load(&path).unwrap_err();
        assert_eq!(
            error.to_string(),
            "Household mode is not available in this release; remove `mode` or set it to \"easy\"."
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn behind_proxy_is_read_from_the_file() {
        let (dir, path) = write("music_folder = \"/m\"\nbehind_proxy = true\n");
        assert!(Config::load(&path).unwrap().behind_proxy);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn backups_default_beside_the_data_and_can_be_moved_or_turned_off() {
        let (dir, path) = write("music_folder = \"/m\"\ndata_dir = \"/data\"\n");
        assert_eq!(Config::load(&path).unwrap().backup_dir(), Some(PathBuf::from("/data/backups")));
        std::fs::write(&path, "music_folder = \"/m\"\nbackup_dir = \"/mnt/share/flaccy\"\n").unwrap();
        assert_eq!(Config::load(&path).unwrap().backup_dir(), Some(PathBuf::from("/mnt/share/flaccy")));
        std::fs::write(&path, "music_folder = \"/m\"\nbackup_dir = \"\"\n").unwrap();
        assert_eq!(Config::load(&path).unwrap().backup_dir(), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_ipv6_address_is_bracketed() {
        let (dir, path) = write("music_folder = \"/m\"\naddress = \"::1\"\nport = 9\n");
        assert_eq!(Config::load(&path).unwrap().listen_address(), "[::1]:9");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
