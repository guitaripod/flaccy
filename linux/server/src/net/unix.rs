//! Household mode's listener: a Unix socket only its owner can open.

use std::fs::{self, DirBuilder};
use std::io;
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener as StdUnixListener, UnixStream as StdUnixStream};
use std::path::{Path, PathBuf};

use axum::serve::Listener;
use tokio::net::{UnixListener, UnixStream};

use super::guard::{ConnectionAddr, Origin};
use super::listen::pause_after_accept_error;

const DIRECTORY_MODE: u32 = 0o700;
const SOCKET_MODE: u32 = 0o600;

#[cfg(any(target_os = "linux", target_os = "android"))]
const SOCKET_PATH_BYTES: usize = 108;
#[cfg(not(any(target_os = "linux", target_os = "android")))]
const SOCKET_PATH_BYTES: usize = 104;

/// The peer of a connection on the Unix socket. The socket carries no address,
/// so handlers see a [`TrustedChannel`](super::TrustedChannel) instead.
#[derive(Clone, Copy, Debug)]
pub struct TrustedPeer;

impl ConnectionAddr for TrustedPeer {
    fn origin(&self) -> Origin {
        Origin::Socket
    }
}

/// A Unix socket listener whose directory is mode 0700 when it had to be
/// created and whose socket is mode 0600 from the moment it appears at its
/// path. A leftover socket from a dead server is replaced; a live one, or a
/// file that is not a socket, is refused. The socket file is removed on drop.
pub struct UnixListenerSecure {
    inner: UnixListener,
    path: PathBuf,
    inode: u64,
}

impl UnixListenerSecure {
    /// Binds `path`. Must run inside a Tokio runtime.
    pub fn bind(path: &Path) -> io::Result<Self> {
        let staging = staging_path(path);
        refuse_too_long(path, &staging)?;
        create_private_directory(path)?;
        refuse_live_or_foreign(path)?;
        let result = Self::publish(path, &staging);
        if result.is_err() {
            let _ = fs::remove_file(&staging);
        }
        result
    }

    /// Binds under a private temporary name, sets the mode, then renames over
    /// `path`, so the socket is never visible with a wider mode.
    fn publish(path: &Path, staging: &Path) -> io::Result<Self> {
        let listener = StdUnixListener::bind(staging)?;
        fs::set_permissions(staging, fs::Permissions::from_mode(SOCKET_MODE))?;
        fs::rename(staging, path)?;
        listener.set_nonblocking(true)?;
        let inode = fs::symlink_metadata(path)?.ino();
        Ok(Self {
            inner: UnixListener::from_std(listener)?,
            path: path.to_path_buf(),
            inode,
        })
    }

    /// The path the socket is bound at.
    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for UnixListenerSecure {
    fn drop(&mut self) {
        let still_ours = fs::symlink_metadata(&self.path).is_ok_and(|meta| meta.ino() == self.inode);
        if still_ours {
            let _ = fs::remove_file(&self.path);
        }
    }
}

impl Listener for UnixListenerSecure {
    type Io = UnixStream;
    type Addr = TrustedPeer;

    async fn accept(&mut self) -> (Self::Io, Self::Addr) {
        loop {
            match self.inner.accept().await {
                Ok((stream, _)) => return (stream, TrustedPeer),
                Err(error) => pause_after_accept_error(&error).await,
            }
        }
    }

    fn local_addr(&self) -> io::Result<Self::Addr> {
        Ok(TrustedPeer)
    }
}

fn create_private_directory(path: &Path) -> io::Result<()> {
    let Some(directory) = path.parent().filter(|parent| !parent.as_os_str().is_empty()) else {
        return Ok(());
    };
    if directory.exists() {
        return Ok(());
    }
    DirBuilder::new().recursive(true).mode(DIRECTORY_MODE).create(directory)
}

/// Errors when something else owns `path`: a running server or a non-socket file.
fn refuse_live_or_foreign(path: &Path) -> io::Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_socket() {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("{} exists and is not a socket, so it was left alone; remove it or choose another socket path", path.display()),
        ));
    }
    if StdUnixStream::connect(path).is_ok() {
        return Err(io::Error::new(
            io::ErrorKind::AddrInUse,
            format!("another server is already listening on {}; stop it or choose another socket path", path.display()),
        ));
    }
    Ok(())
}

/// The name `path`'s socket is bound under before it is renamed into place, beside it so the rename is atomic.
fn staging_path(path: &Path) -> PathBuf {
    path.with_file_name(format!(".{:08x}", rand::random::<u32>()))
}

/// Errors when `path`, or the staging name beside it, does not fit the few bytes a socket address holds, which is
/// fewer on a Mac (104) than on Linux (108) and which `bind` would otherwise report as "path must be shorter than SUN_LEN".
fn refuse_too_long(path: &Path, staging: &Path) -> io::Result<()> {
    let used = path.as_os_str().as_bytes().len();
    let staged = staging.as_os_str().as_bytes().len();
    if staged < SOCKET_PATH_BYTES && used < SOCKET_PATH_BYTES {
        return Ok(());
    }
    let allowed = (SOCKET_PATH_BYTES - 1).min((SOCKET_PATH_BYTES - 1 + used).saturating_sub(staged));
    Err(io::Error::new(
        io::ErrorKind::InvalidInput,
        format!(
            "the socket path {} is {used} bytes long, but this system allows at most {allowed} bytes for a socket path; choose a shorter path, such as /tmp/flaccy.sock or a folder closer to the root",
            path.display()
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn path_of(bytes: usize) -> PathBuf {
        PathBuf::from(format!("/{}", "p".repeat(bytes - 1)))
    }

    #[test]
    fn the_staging_name_is_short_and_beside_the_socket() {
        let staging = staging_path(Path::new("/run/flaccy/server.sock"));
        assert_eq!(staging.parent(), Some(Path::new("/run/flaccy")));
        assert_eq!(staging.file_name().unwrap().len(), 9);
    }

    #[test]
    fn a_path_fits_until_its_staging_name_would_not() {
        let longest = SOCKET_PATH_BYTES - 1;
        let socket = path_of(longest);
        let staging = path_of(longest);
        assert!(refuse_too_long(&socket, &staging).is_ok());
        let over = refuse_too_long(&path_of(longest + 1), &path_of(longest + 1)).unwrap_err();
        assert_eq!(over.kind(), io::ErrorKind::InvalidInput);
        assert!(over.to_string().contains(&format!("at most {longest} bytes")), "{over}");
    }

    #[test]
    fn a_staging_name_longer_than_the_socket_name_lowers_what_is_allowed() {
        let socket = path_of(SOCKET_PATH_BYTES - 5);
        let staging = path_of(SOCKET_PATH_BYTES + 3);
        let message = refuse_too_long(&socket, &staging).unwrap_err().to_string();
        assert!(message.contains(&format!("at most {} bytes", SOCKET_PATH_BYTES - 1 - 8)), "{message}");
    }
}
