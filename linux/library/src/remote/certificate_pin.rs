//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/CertificatePin.swift`.
//!
//! A Flaccy Server that shares on the local network answers over TLS with a
//! self-signed certificate. Clients trust it by its key, never by a certificate
//! authority: the pin is the SHA-256 of the uncompressed public key point, written
//! as unpadded base64url. The server can issue new certificates for the same key
//! without breaking a pin.

use sha2::{Digest, Sha256};

const SEQUENCE: u8 = 0x30;
const BIT_STRING: u8 = 0x03;
const EXPLICIT_VERSION: u8 = 0xa0;
const FIELDS_BEFORE_KEY_INFO: usize = 5;
const BASE64URL: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// The pin of a raw public key, as a server computes it for the key it holds.
pub fn pin_of_public_key(raw: &[u8]) -> String {
    base64url(&Sha256::digest(raw))
}

/// The pin of the key a DER certificate carries, as a client computes it for the certificate it was shown.
pub fn pin_of_certificate(der: &[u8]) -> Option<String> {
    public_key_of_certificate(der).map(pin_of_public_key)
}

/// Whether two pins name the same key; surrounding whitespace is ignored.
pub fn pins_match(expected: &str, actual: &str) -> bool {
    let expected = expected.trim();
    !expected.is_empty() && expected == actual.trim()
}

/// The subject public key bits of an X.509 certificate in DER, or `None` when the bytes are not one.
pub fn public_key_of_certificate(der: &[u8]) -> Option<&[u8]> {
    let (certificate, _) = element(der, SEQUENCE)?;
    let (tbs, _) = element(certificate, SEQUENCE)?;
    let mut rest = tbs;
    if rest.first() == Some(&EXPLICIT_VERSION) {
        rest = skip(rest)?;
    }
    for _ in 0..FIELDS_BEFORE_KEY_INFO {
        rest = skip(rest)?;
    }
    let (key_info, _) = element(rest, SEQUENCE)?;
    let algorithm_skipped = skip(key_info)?;
    let (bits, _) = element(algorithm_skipped, BIT_STRING)?;
    let (unused, key) = bits.split_first()?;
    (*unused == 0 && !key.is_empty()).then_some(key)
}

/// The contents of the element at the start of `bytes` when its tag is `tag`, and what follows it.
fn element(bytes: &[u8], tag: u8) -> Option<(&[u8], &[u8])> {
    if *bytes.first()? != tag {
        return None;
    }
    split(bytes)
}

/// What follows the element at the start of `bytes`, whatever its tag.
fn skip(bytes: &[u8]) -> Option<&[u8]> {
    split(bytes).map(|(_, rest)| rest)
}

fn split(bytes: &[u8]) -> Option<(&[u8], &[u8])> {
    let (&first, after_tag) = bytes.get(1..).and_then(|rest| rest.split_first())?;
    let (length, after_length) = if first & 0x80 == 0 {
        (usize::from(first), after_tag)
    } else {
        let count = usize::from(first & 0x7f);
        if count == 0 || count > 4 || after_tag.len() < count {
            return None;
        }
        let length = after_tag[..count].iter().fold(0usize, |total, byte| (total << 8) | usize::from(*byte));
        (length, &after_tag[count..])
    };
    (after_length.len() >= length).then(|| after_length.split_at(length))
}

fn base64url(bytes: &[u8]) -> String {
    let mut text = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let value = chunk.iter().enumerate().fold(0u32, |total, (index, byte)| total | (u32::from(*byte) << (16 - 8 * index)));
        let symbols = chunk.len() + 1;
        for index in 0..symbols {
            text.push(char::from(BASE64URL[((value >> (18 - 6 * index)) & 0x3f) as usize]));
        }
    }
    text
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pin_is_unpadded_base64url_of_the_key_hash_the_swift_side_asserts_too() {
        let raw: Vec<u8> = std::iter::once(4).chain(1..=64).collect();
        assert_eq!(pin_of_public_key(&raw), "DtOmq5V_9vWaljCkc9MafQT8tGVIuJAWGWmAx-llhPY");
        assert_eq!(pin_of_public_key(&[]), "47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU");
    }

    #[test]
    fn a_certificate_pins_to_the_key_it_was_issued_for() {
        let key = rcgen::KeyPair::generate().unwrap();
        let certificate = rcgen::CertificateParams::new(vec!["flaccy.local".into()]).unwrap().self_signed(&key).unwrap();
        let pin = pin_of_certificate(certificate.der()).unwrap();
        assert_eq!(pin, pin_of_public_key(key.public_key_raw()));
        let reissued = rcgen::CertificateParams::new(vec!["other.local".into()]).unwrap().self_signed(&key).unwrap();
        assert_eq!(pin_of_certificate(reissued.der()).unwrap(), pin);
        let other = rcgen::KeyPair::generate().unwrap();
        let foreign = rcgen::CertificateParams::new(vec!["flaccy.local".into()]).unwrap().self_signed(&other).unwrap();
        assert_ne!(pin_of_certificate(foreign.der()).unwrap(), pin);
    }

    #[test]
    fn bytes_that_are_not_a_certificate_have_no_pin() {
        assert_eq!(pin_of_certificate(&[]), None);
        assert_eq!(pin_of_certificate(&[0x30, 0x82, 0xff]), None);
        assert_eq!(pin_of_certificate(&[0x30, 0x03, 0x02, 0x01, 0x00]), None);
        assert_eq!(pin_of_certificate(b"not a certificate"), None);
    }

    #[test]
    fn pins_compare_exactly_after_trimming() {
        assert!(pins_match(" abc ", "abc"));
        assert!(!pins_match("abc", "abd"));
        assert!(!pins_match("", ""));
    }
}
