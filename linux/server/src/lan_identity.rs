//! The key this server answers with on the local network, and the TLS it builds from it.
//!
//! The key is made once and kept in the data folder (`lan-key.der`, readable only by
//! its owner); devices pin its public key, so the certificate around it is issued
//! fresh at every start and never has to be renewed by hand. Restoring the data
//! folder on another machine keeps every pin working.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use chrono::{Datelike, Duration, Utc};
use flaccy_library::remote::certificate_pin;
use rcgen::{CertificateParams, DnType, ExtendedKeyUsagePurpose, KeyPair};
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio_rustls::rustls::{self, ServerConfig};
use tokio_rustls::TlsAcceptor;

/// The file in the data folder that holds the key.
pub const KEY_FILE: &str = "lan-key.der";
const COMMON_NAME: &str = "Flaccy Server";
const VALID_BEFORE_DAYS: i64 = 1;
const VALID_FOR_DAYS: i64 = 820;
const HTTP1: &[u8] = b"http/1.1";

/// The TLS this server speaks to devices on the local network, and the pin they check it by.
#[derive(Clone)]
pub struct LanIdentity {
    acceptor: TlsAcceptor,
    pin: String,
}

impl std::fmt::Debug for LanIdentity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("LanIdentity").field("pin", &self.pin).finish_non_exhaustive()
    }
}

impl LanIdentity {
    /// Loads the key from `data_dir`, making it the first time, and issues a certificate for `names`.
    pub fn load_or_create(data_dir: &Path, names: &[String]) -> Result<Self, String> {
        let key = load_or_create_key(data_dir)?;
        let pin = certificate_pin::pin_of_public_key(key.public_key_raw());
        let certificate = issue(&key, names)?;
        let config = server_config(certificate, key.serialize_der())?;
        Ok(Self { acceptor: TlsAcceptor::from(Arc::new(config)), pin })
    }

    /// The pin of the key in `data_dir`, or `None` when the server has not made one yet.
    /// Commands that run beside a server use it to put the pin in a link without starting TLS.
    pub fn read_pin(data_dir: &Path) -> Result<Option<String>, String> {
        let path = key_path(data_dir);
        if !path.exists() {
            return Ok(None);
        }
        let key = read_key(&path)?;
        Ok(Some(certificate_pin::pin_of_public_key(key.public_key_raw())))
    }

    /// What devices check the server's key against.
    pub fn pin(&self) -> &str {
        &self.pin
    }

    /// Accepts TLS connections with this identity.
    pub fn acceptor(&self) -> TlsAcceptor {
        self.acceptor.clone()
    }
}

fn key_path(data_dir: &Path) -> PathBuf {
    data_dir.join(KEY_FILE)
}

fn load_or_create_key(data_dir: &Path) -> Result<KeyPair, String> {
    let path = key_path(data_dir);
    if path.exists() {
        return read_key(&path);
    }
    let key = KeyPair::generate().map_err(|error| format!("Could not make the key for sharing on this network: {error}."))?;
    write_private(&path, &key.serialize_der())?;
    Ok(key)
}

fn read_key(path: &Path) -> Result<KeyPair, String> {
    let bytes = fs::read(path).map_err(|error| {
        format!("Could not read {}: {error}. Check that this user may read it.", path.display())
    })?;
    KeyPair::try_from(bytes.as_slice()).map_err(|error| {
        format!(
            "{} is not a key Flaccy Server can use ({error}). Move it aside and start the server again; devices on this network will then need to be added again.",
            path.display()
        )
    })
}

/// Writes `bytes` to `path` readable only by its owner, replacing nothing that exists.
fn write_private(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let folder = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(folder).map_err(|error| format!("Could not create {}: {error}.", folder.display()))?;
    let temporary = path.with_extension("der.part");
    let written = open_private(&temporary).and_then(|mut file| {
        file.write_all(bytes)?;
        file.sync_all()
    });
    written
        .and_then(|()| fs::hard_link(&temporary, path))
        .map_err(|error| format!("Could not save the key for sharing on this network to {}: {error}.", path.display()))?;
    let _ = fs::remove_file(&temporary);
    Ok(())
}

#[cfg(unix)]
fn open_private(path: &Path) -> std::io::Result<fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    fs::OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)
}

#[cfg(not(unix))]
fn open_private(path: &Path) -> std::io::Result<fs::File> {
    fs::OpenOptions::new().write(true).create(true).truncate(true).open(path)
}

fn issue(key: &KeyPair, names: &[String]) -> Result<CertificateDer<'static>, String> {
    let mut params = CertificateParams::new(names.to_vec()).map_err(|error| format!("Could not describe this server's certificate: {error}."))?;
    params.distinguished_name.push(DnType::CommonName, COMMON_NAME);
    params.extended_key_usages = vec![ExtendedKeyUsagePurpose::ServerAuth];
    let today = Utc::now().date_naive();
    let (first, last) = (today - Duration::days(VALID_BEFORE_DAYS), today + Duration::days(VALID_FOR_DAYS));
    params.not_before = rcgen::date_time_ymd(first.year(), first.month() as u8, first.day() as u8);
    params.not_after = rcgen::date_time_ymd(last.year(), last.month() as u8, last.day() as u8);
    let certificate = params.self_signed(key).map_err(|error| format!("Could not issue this server's certificate: {error}."))?;
    Ok(certificate.der().clone())
}

fn server_config(certificate: CertificateDer<'static>, key: Vec<u8>) -> Result<ServerConfig, String> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = ServerConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|error| format!("Could not set up TLS: {error}."))?
        .with_no_client_auth()
        .with_single_cert(vec![certificate], PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key)))
        .map_err(|error| format!("Could not set up TLS with this server's key: {error}."))?;
    config.alpn_protocols = vec![HTTP1.to_vec()];
    Ok(config)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn folder(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("flaccy-lan-identity-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        dir
    }

    #[test]
    fn the_key_is_made_once_and_its_pin_survives_a_restart() {
        let dir = folder("restart");
        assert_eq!(LanIdentity::read_pin(&dir).unwrap(), None);
        let first = LanIdentity::load_or_create(&dir, &["localhost".into()]).unwrap();
        let again = LanIdentity::load_or_create(&dir, &["arch.local".into()]).unwrap();
        assert_eq!(first.pin(), again.pin());
        assert_eq!(LanIdentity::read_pin(&dir).unwrap().as_deref(), Some(first.pin()));
        assert_eq!(first.pin().len(), 43);
        fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn only_the_owner_may_read_the_key() {
        use std::os::unix::fs::PermissionsExt;
        let dir = folder("mode");
        LanIdentity::load_or_create(&dir, &[]).unwrap();
        let mode = fs::metadata(dir.join(KEY_FILE)).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        assert!(!dir.join("lan-key.der.part").exists());
        fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_damaged_key_is_refused_with_what_to_do() {
        let dir = folder("damaged");
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(KEY_FILE), b"garbage").unwrap();
        let error = LanIdentity::load_or_create(&dir, &[]).unwrap_err();
        assert!(error.contains("Move it aside"), "{error}");
        fs::remove_dir_all(dir).unwrap();
    }
}
