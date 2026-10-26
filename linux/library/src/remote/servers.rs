//! The servers a person has added, saved in `servers.toml` beside the app's
//! configuration. The file holds credentials, so it is written with mode 0600
//! and a [`Server`] never prints them.

use flaccy_shared::remote::subsonic_request::Credentials;
use serde::{Deserialize, Serialize};
use std::fmt;
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// One OpenSubsonic server and how to sign in to it. An API key wins over a
/// password when both are set.
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Server {
    pub id: String,
    pub name: String,
    pub address: String,
    #[serde(default)]
    pub username: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub password: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub api_key: Option<String>,
    #[serde(default, skip_serializing_if = "is_false")]
    pub flaccy_server: bool,
}

fn is_false(value: &bool) -> bool {
    !*value
}

impl fmt::Debug for Server {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Server")
            .field("id", &self.id)
            .field("name", &self.name)
            .field("address", &self.address)
            .field("username", &self.username)
            .field("password", &self.password.as_ref().map(|_| "***"))
            .field("api_key", &self.api_key.as_ref().map(|_| "***"))
            .field("flaccy_server", &self.flaccy_server)
            .finish()
    }
}

impl Server {
    /// A server with a fresh id, signing in with `secret` as an API key when
    /// `is_api_key` is set and as the password of `username` otherwise.
    pub fn new(name: &str, address: &str, username: &str, secret: &str, is_api_key: bool) -> Self {
        let secret = Some(secret.to_string()).filter(|secret| !secret.is_empty());
        Self {
            id: new_id(),
            name: name.trim().to_string(),
            address: address.trim().to_string(),
            username: username.trim().to_string(),
            password: if is_api_key { None } else { secret.clone() },
            api_key: if is_api_key { secret } else { None },
            flaccy_server: false,
        }
    }

    /// The library of a Flaccy Server this device is enrolled with: the device token signs in as an API key, and the server is marked so Preferences shows it in the Flaccy Server row instead of the list of regular servers.
    pub fn flaccy_library(name: &str, address: &str, device_token: &str) -> Self {
        Self {
            flaccy_server: true,
            ..Self::new(name, address, "", device_token, true)
        }
    }

    /// The credentials a request is signed with.
    pub fn credentials(&self) -> Credentials {
        match self.api_key.as_deref().filter(|key| !key.is_empty()) {
            Some(key) => Credentials::ApiKey(key.to_string()),
            None => Credentials::Password {
                username: self.username.clone(),
                password: self.password.clone().unwrap_or_default(),
            },
        }
    }

    /// Whether the server signs in with an API key.
    pub fn uses_api_key(&self) -> bool {
        self.api_key.as_deref().is_some_and(|key| !key.is_empty())
    }
}

/// A new server id: `s` and eight hex digits. It names the server in every
/// remote song path and cache folder, so it never changes when the server is
/// renamed.
pub fn new_id() -> String {
    format!("s{:08x}", rand::random::<u32>())
}

#[derive(Default, Serialize, Deserialize)]
struct Document {
    #[serde(default)]
    server: Vec<Server>,
}

/// Where `servers.toml` lives and how it is read and written.
#[derive(Clone, Debug)]
pub struct ServerStore {
    path: PathBuf,
}

impl ServerStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The saved servers, none when the file is missing or unreadable.
    pub fn load(&self) -> Vec<Server> {
        std::fs::read_to_string(&self.path)
            .ok()
            .and_then(|text| toml::from_str::<Document>(&text).ok())
            .map(|document| document.server)
            .unwrap_or_default()
    }

    /// Replaces the file with `servers`, readable by its owner only from the
    /// first byte written.
    pub fn save(&self, servers: &[Server]) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = toml::to_string_pretty(&Document {
            server: servers.to_vec(),
        })
        .map_err(|err| std::io::Error::new(std::io::ErrorKind::InvalidData, err.to_string()))?;
        let staging = self.path.with_extension("toml.tmp");
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&staging)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&staging, &self.path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("flaccy-servers-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn the_credential_file_is_private_to_its_owner() {
        let dir = scratch("mode");
        let store = ServerStore::new(dir.join("servers.toml"));
        store
            .save(&[Server::new("Home", "http://h:4533", "ana", "pw", false)])
            .unwrap();
        let mode = std::fs::metadata(store.path()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        store
            .save(&[Server::new("Home", "http://h:4533", "ana", "pw2", false)])
            .unwrap();
        let mode = std::fs::metadata(store.path()).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn servers_round_trip_with_either_kind_of_secret() {
        let dir = scratch("roundtrip");
        let store = ServerStore::new(dir.join("servers.toml"));
        let password = Server::new("Home", "http://h:4533", "ana", "pw", false);
        let key = Server::new("Work", "https://w.example", "", "KEY", true);
        store.save(&[password.clone(), key.clone()]).unwrap();
        assert_eq!(store.load(), vec![password.clone(), key.clone()]);
        assert_eq!(
            key.credentials(),
            Credentials::ApiKey("KEY".to_string())
        );
        assert_eq!(
            password.credentials(),
            Credentials::Password {
                username: "ana".into(),
                password: "pw".into()
            }
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_missing_file_has_no_servers() {
        let store = ServerStore::new(scratch("missing").join("servers.toml"));
        assert!(store.load().is_empty());
    }

    #[test]
    fn debug_output_never_shows_a_secret() {
        let server = Server::new("Home", "http://h", "ana", "hunter2", false);
        let printed = format!("{server:?}");
        assert!(!printed.contains("hunter2"));
        let keyed = Server::new("Work", "http://h", "", "SECRET-KEY", true);
        assert!(!format!("{keyed:?}").contains("SECRET-KEY"));
    }

    #[test]
    fn ids_are_short_and_distinct() {
        let first = new_id();
        assert_eq!(first.len(), 9);
        assert_ne!(first, new_id());
    }
}
