//! The one account and its API keys, kept in `credentials.toml` with mode 0600.
//!
//! Subsonic token authentication sends `md5(password + salt)`, so the server
//! has to hold the password in clear to check it. API keys are different: only
//! their SHA-256 is stored, and the key itself is shown once when it is made.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;

use md5::{Digest, Md5};
use rand::RngCore;
use serde::{Deserialize, Serialize};

use crate::ids;

/// The account name a first `password set` uses unless `--user` says otherwise.
pub const DEFAULT_USERNAME: &str = "flaccy";
const MINIMUM_PASSWORD_LENGTH: usize = 8;

/// One API key as stored: a name, the SHA-256 of the key and when it was made.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
pub struct ApiKeyRecord {
    pub name: String,
    pub sha256: String,
    pub created: String,
}

/// The whole credentials file.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct Credentials {
    pub username: String,
    pub password: String,
    #[serde(default)]
    pub keys: Vec<ApiKeyRecord>,
}

impl Credentials {
    /// Whether `candidate` is the account name, ignoring case like Subsonic servers do.
    pub fn is_user(&self, candidate: &str) -> bool {
        !self.username.is_empty() && self.username.eq_ignore_ascii_case(candidate)
    }

    /// Whether `candidate` is the password, compared without an early exit.
    pub fn password_matches(&self, candidate: &str) -> bool {
        !self.password.is_empty() && constant_time_eq(self.password.as_bytes(), candidate.as_bytes())
    }

    /// Whether `token` is `md5(password + salt)`, the Subsonic token scheme.
    pub fn token_matches(&self, token: &str, salt: &str) -> bool {
        if self.password.is_empty() {
            return false;
        }
        let mut hasher = Md5::new();
        hasher.update(self.password.as_bytes());
        hasher.update(salt.as_bytes());
        let expected = ids::hex(&hasher.finalize());
        constant_time_eq(expected.as_bytes(), token.to_ascii_lowercase().as_bytes())
    }

    /// The name of the key whose SHA-256 `key` has, `None` for an unknown or revoked key.
    pub fn key_name(&self, key: &str) -> Option<&str> {
        let digest = ids::sha256_hex(key.as_bytes());
        self.keys
            .iter()
            .find(|record| constant_time_eq(record.sha256.as_bytes(), digest.as_bytes()))
            .map(|record| record.name.as_str())
    }

    /// Makes a key called `name` and returns it. The key is not recoverable
    /// afterwards: only its hash is kept.
    pub fn add_key(&mut self, name: &str, now: &str) -> Result<String, String> {
        if name.trim().is_empty() {
            return Err("A key needs a name so you can tell it apart later; run `flaccy-server key add <name>` with a name such as 'iphone'.".to_string());
        }
        if self.keys.iter().any(|record| record.name == name) {
            return Err(format!(
                "A key called '{name}' already exists. Pick another name, or run `flaccy-server key revoke {name}` first and add it again."
            ));
        }
        let mut bytes = [0u8; 32];
        rand::rng().fill_bytes(&mut bytes);
        let key = ids::hex(&bytes);
        self.keys.push(ApiKeyRecord {
            name: name.to_string(),
            sha256: ids::sha256_hex(key.as_bytes()),
            created: now.to_string(),
        });
        Ok(key)
    }

    /// Removes the key called `name`; whether there was one.
    pub fn revoke_key(&mut self, name: &str) -> bool {
        let before = self.keys.len();
        self.keys.retain(|record| record.name != name);
        self.keys.len() != before
    }
}

/// Compares two byte strings in time that depends only on their lengths.
pub fn constant_time_eq(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    left.iter()
        .zip(right)
        .fold(0u8, |difference, (a, b)| difference | (a ^ b))
        == 0
}

/// Rejects a password the server should not accept, naming why.
pub fn check_password(password: &str) -> Result<(), String> {
    if password.chars().count() < MINIMUM_PASSWORD_LENGTH {
        return Err(format!(
            "That password is too short. The server is reachable over the network, so use at least {MINIMUM_PASSWORD_LENGTH} characters and run `flaccy-server password set` again."
        ));
    }
    Ok(())
}

/// Reads the credentials file, `None` when none has been written yet.
pub fn load(path: &Path) -> Result<Option<Credentials>, String> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(format!(
                "Could not read {}: {err}. Check that your user may read it, or delete it and run `flaccy-server password set` to start over.",
                path.display()
            ))
        }
    };
    toml::from_str(&text).map(Some).map_err(|err| {
        format!(
            "{} is not valid: {err}. Fix the line it names, or delete the file and run `flaccy-server password set` to start over.",
            path.display()
        )
    })
}

/// Writes the credentials file with mode 0600, through a temporary file so a
/// crash never leaves half a file.
pub fn save(path: &Path, credentials: &Credentials) -> Result<(), String> {
    let text = toml::to_string(credentials).map_err(|err| {
        format!("Could not encode the credentials: {err}. This is a bug in flaccy-server; report it with this message.")
    })?;
    let directory = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(directory).map_err(|err| {
        format!(
            "Could not create {}: {err}. Check the permissions of its parent folder, or set `data_dir` in config.toml to a folder you own.",
            directory.display()
        )
    })?;
    let temporary = path.with_extension("toml.tmp");
    write_private(&temporary, text.as_bytes())
        .and_then(|_| fs::rename(&temporary, path))
        .map_err(|err| {
            let _ = fs::remove_file(&temporary);
            format!(
                "Could not write {}: {err}. Check that the folder is writable and the disk is not full, then run the command again.",
                path.display()
            )
        })
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let _ = fs::remove_file(path);
    let mut file = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    fs::write(path, bytes)
}

/// The credentials file as the running server sees it, re-read whenever the
/// file changes so `key add` and `key revoke` take effect without a restart.
pub struct CredentialStore {
    path: PathBuf,
    cached: Mutex<Cached>,
}

#[derive(Default)]
struct Cached {
    modified: Option<SystemTime>,
    credentials: Option<Credentials>,
    loaded: bool,
}

impl CredentialStore {
    /// A store reading `path`.
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            cached: Mutex::new(Cached::default()),
        }
    }

    /// The current credentials, `None` while no account exists or the file is unreadable.
    pub fn current(&self) -> Option<Credentials> {
        let modified = fs::metadata(&self.path).and_then(|meta| meta.modified()).ok();
        let mut cached = self.cached.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        if !cached.loaded || cached.modified != modified {
            cached.credentials = match load(&self.path) {
                Ok(credentials) => credentials,
                Err(message) => {
                    flaccy_library::logger::error("server", &message);
                    None
                }
            };
            cached.modified = modified;
            cached.loaded = true;
        }
        cached.credentials.clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn account() -> Credentials {
        Credentials {
            username: "tester".to_string(),
            password: "sesame-seed".to_string(),
            keys: Vec::new(),
        }
    }

    #[test]
    fn a_token_is_the_md5_of_the_password_and_the_salt() {
        let mut hasher = Md5::new();
        hasher.update(b"sesame-seedc19b2d");
        let token = ids::hex(&hasher.finalize());
        assert!(account().token_matches(&token, "c19b2d"));
        assert!(account().token_matches(&token.to_uppercase(), "c19b2d"));
        assert!(!account().token_matches(&token, "other"));
    }

    #[test]
    fn a_key_is_stored_only_as_its_hash_and_revoking_it_ends_it() {
        let mut credentials = account();
        let key = credentials.add_key("iphone", "2026-10-25T12:00:00Z").unwrap();
        assert!(!toml::to_string(&credentials).unwrap().contains(&key));
        assert_eq!(credentials.key_name(&key), Some("iphone"));
        assert_eq!(credentials.key_name("not-the-key"), None);
        assert!(credentials.add_key("iphone", "now").is_err());
        assert!(credentials.revoke_key("iphone"));
        assert_eq!(credentials.key_name(&key), None);
        assert!(!credentials.revoke_key("iphone"));
    }

    #[cfg(unix)]
    #[test]
    fn the_file_is_private_and_the_store_notices_a_change() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("flaccy-creds-{}", std::process::id()));
        let path = dir.join("credentials.toml");
        let store = CredentialStore::new(path.clone());
        assert!(store.current().is_none());
        save(&path, &account()).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(store.current().unwrap().username, "tester");
        let mut changed = account();
        changed.username = "someone".to_string();
        std::thread::sleep(std::time::Duration::from_millis(20));
        save(&path, &changed).unwrap();
        assert_eq!(store.current().unwrap().username, "someone");
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn short_passwords_are_refused_with_the_reason() {
        assert!(check_password("short").unwrap_err().contains("at least 8"));
        assert!(check_password("long enough").is_ok());
    }
}
