//! TLS to a Flaccy Server on the local network, trusted by the pin of its key
//! ([`super::certificate_pin`]) instead of a certificate authority.
//!
//! A server added from a link is checked against the pin the link carried. A
//! server typed by hand is trusted on first contact: whatever key it shows is
//! remembered and pinned from then on, the way SSH treats a new host.

use std::sync::{Arc, Mutex, PoisonError};

use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::crypto::{self, CryptoProvider};
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{CertificateError, ClientConfig, DigitallySignedStruct, Error, OtherError, SignatureScheme};

use super::certificate_pin::{pin_of_certificate, pins_match};

/// The sentence a pin mismatch carries through every TLS error, so callers can tell it from a broken network.
pub const KEY_CHANGED: &str = "the server's key is not the one this device was added with";

#[derive(Debug)]
struct KeyChanged;

impl std::fmt::Display for KeyChanged {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(KEY_CHANGED)
    }
}

impl std::error::Error for KeyChanged {}

/// A client TLS configuration that trusts one pinned key, or the first key it sees.
#[derive(Clone)]
pub struct PinnedTls {
    config: Arc<ClientConfig>,
    seen: Arc<Mutex<Option<String>>>,
}

impl std::fmt::Debug for PinnedTls {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.debug_struct("PinnedTls").field("seen", &self.seen_pin()).finish_non_exhaustive()
    }
}

impl PinnedTls {
    /// Trusts exactly the key `pin` names.
    pub fn pinned(pin: &str) -> Self {
        Self::build(Some(pin.trim().to_owned()))
    }

    /// Trusts the first key the server shows and remembers its pin, for the first contact with a typed address; every later
    /// handshake through this configuration, a redirect to another host included, must show that same key.
    pub fn first_contact() -> Self {
        Self::build(None)
    }

    /// The configuration to hand to `ureq` or `tungstenite`.
    pub fn config(&self) -> Arc<ClientConfig> {
        self.config.clone()
    }

    /// The pin of the key the last handshake showed, once there was one.
    pub fn seen_pin(&self) -> Option<String> {
        self.seen.lock().unwrap_or_else(PoisonError::into_inner).clone()
    }

    fn build(expected: Option<String>) -> Self {
        let provider = Arc::new(crypto::ring::default_provider());
        let seen = Arc::new(Mutex::new(None));
        let verifier = PinVerifier { expected, seen: seen.clone(), provider: provider.clone() };
        let config = ClientConfig::builder_with_provider(provider)
            .with_safe_default_protocol_versions()
            .expect("the ring provider supports the default TLS versions")
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(verifier))
            .with_no_client_auth();
        Self { config: Arc::new(config), seen }
    }
}

/// Whether an error's text says the server answered with another key than the pinned one.
pub fn is_key_changed(text: &str) -> bool {
    text.contains(KEY_CHANGED)
}

/// Whether `error` or any error under it says the server answered with another key than the pinned one;
/// HTTP and WebSocket libraries wrap the TLS failure a level or two down.
pub fn caused_by_key_change(error: &(dyn std::error::Error + 'static)) -> bool {
    let mut current = Some(error);
    while let Some(error) = current {
        if is_key_changed(&error.to_string()) || is_key_change_error(error) {
            return true;
        }
        current = error.source();
    }
    false
}

fn is_key_change_error(error: &(dyn std::error::Error + 'static)) -> bool {
    let from_io = error.downcast_ref::<std::io::Error>().and_then(|io| io.get_ref()).and_then(|inner| inner.downcast_ref::<Error>());
    let found = error.downcast_ref::<Error>().or(from_io);
    matches!(found, Some(Error::InvalidCertificate(CertificateError::Other(other))) if other.0.downcast_ref::<KeyChanged>().is_some())
}

#[derive(Debug)]
struct PinVerifier {
    expected: Option<String>,
    seen: Arc<Mutex<Option<String>>>,
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for PinVerifier {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        let pin = pin_of_certificate(end_entity.as_ref()).ok_or(Error::InvalidCertificate(CertificateError::BadEncoding))?;
        let mut seen = self.seen.lock().unwrap_or_else(PoisonError::into_inner);
        let trusted = self.expected.as_deref().or(seen.as_deref());
        if trusted.is_some_and(|trusted| !pins_match(trusted, &pin)) {
            return Err(Error::InvalidCertificate(CertificateError::Other(OtherError(Arc::new(KeyChanged)))));
        }
        *seen = Some(pin);
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        crypto::verify_tls12_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, Error> {
        crypto::verify_tls13_signature(message, cert, dss, &self.provider.signature_verification_algorithms)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_configuration_has_seen_no_key() {
        assert_eq!(PinnedTls::pinned("abc").seen_pin(), None);
        assert_eq!(PinnedTls::first_contact().seen_pin(), None);
    }

    #[test]
    fn first_contact_keeps_the_first_key_it_saw() {
        let tls = PinnedTls::first_contact();
        let verifier = verifier_of(None, &tls);
        let first = certificate();
        let second = certificate();
        assert!(check(&verifier, &first).is_ok());
        let seen = tls.seen_pin();
        assert!(check(&verifier, &first).is_ok());
        let refused = check(&verifier, &second).unwrap_err();
        assert!(caused_by_key_change(&refused));
        assert_eq!(tls.seen_pin(), seen);
    }

    #[test]
    fn a_pinned_configuration_refuses_any_other_key() {
        let wanted = certificate();
        let pin = pin_of_certificate(wanted.as_ref()).unwrap();
        let tls = PinnedTls::pinned(&pin);
        let verifier = verifier_of(Some(pin.clone()), &tls);
        assert!(check(&verifier, &certificate()).is_err());
        assert_eq!(tls.seen_pin(), None);
        assert!(check(&verifier, &wanted).is_ok());
        assert_eq!(tls.seen_pin(), Some(pin));
    }

    fn verifier_of(expected: Option<String>, tls: &PinnedTls) -> PinVerifier {
        PinVerifier {
            expected,
            seen: tls.seen.clone(),
            provider: Arc::new(crypto::ring::default_provider()),
        }
    }

    fn certificate() -> CertificateDer<'static> {
        let key = rcgen::KeyPair::generate().unwrap();
        let params = rcgen::CertificateParams::new(vec!["flaccy.local".to_owned()]).unwrap();
        params.self_signed(&key).unwrap().der().clone()
    }

    fn check(verifier: &PinVerifier, certificate: &CertificateDer<'_>) -> Result<ServerCertVerified, Error> {
        let name = ServerName::try_from("flaccy.local").unwrap();
        verifier.verify_server_cert(certificate, &[], &name, &[], UnixTime::now())
    }

    #[test]
    fn the_mismatch_sentence_is_recognised_inside_longer_errors() {
        assert!(is_key_changed(&format!("invalid peer certificate: Other({KEY_CHANGED})")));
        assert!(!is_key_changed("invalid peer certificate: UnknownIssuer"));
    }
}
