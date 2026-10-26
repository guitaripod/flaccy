use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// Where this device's server token lives: a file readable by its owner only, beside `servers.toml`. The token is never stored in the database and never printed.
#[derive(Clone, Debug)]
pub struct TokenStore {
    path: PathBuf,
}

impl TokenStore {
    /// A store backed by `path`.
    pub fn new(path: PathBuf) -> Self {
        TokenStore { path }
    }

    /// The file path.
    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The saved token, none when the file is missing or empty.
    pub fn load(&self) -> Option<String> {
        let text = std::fs::read_to_string(&self.path).ok()?;
        let token = text.trim();
        (!token.is_empty()).then(|| token.to_owned())
    }

    /// Replaces the token, mode 0600 from the first byte written.
    pub fn save(&self, token: &str) -> std::io::Result<()> {
        if let Some(parent) = self.path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let staging = self.path.with_extension("tmp");
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&staging)?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        file.write_all(token.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&staging, &self.path)
    }

    /// Forgets the token.
    pub fn clear(&self) -> std::io::Result<()> {
        match std::fs::remove_file(&self.path) {
            Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_token_file_is_private_and_round_trips() {
        let dir = std::env::temp_dir().join(format!("flaccy-token-{}", std::process::id()));
        let store = TokenStore::new(dir.join("sync-token"));
        store.save("tok").unwrap();
        assert_eq!(store.load().as_deref(), Some("tok"));
        let mode = std::fs::metadata(store.path())
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o600);
        store.clear().unwrap();
        assert_eq!(store.load(), None);
        let _ = std::fs::remove_dir_all(dir);
    }
}
