//! The client side of Flaccy's OpenSubsonic support: the saved servers, the
//! requests made to them, the catalog sync that turns their songs into library
//! rows, the byte cache and the loopback proxy that lets GStreamer play a song
//! that is only partly on disk.
//!
//! Everything here is UI free and blocking; the app runs it on worker threads
//! and learns of changes through the listener set on [`service::Remote`].

pub mod cache;
pub mod catalog;
pub mod client;
pub mod manager;
pub mod proxy;
pub mod redact;
pub mod servers;
pub mod service;
pub mod sync;

#[cfg(test)]
pub(crate) mod testing;

/// Percent-encodes one URL path segment, leaving the unreserved set as it is.
pub fn encode_segment(value: &str) -> String {
    let mut encoded = String::with_capacity(value.len());
    for byte in value.bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            encoded.push(byte as char);
        } else {
            encoded.push_str(&format!("%{byte:02X}"));
        }
    }
    encoded
}

/// Reverses [`encode_segment`]; `None` for a broken escape or non UTF-8 bytes.
pub fn decode_segment(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if bytes[index] == b'%' {
            let hex = value
                .get(index + 1..index + 3)
                .filter(|hex| hex.bytes().all(|byte| byte.is_ascii_hexdigit()))?;
            decoded.push(u8::from_str_radix(hex, 16).ok()?);
            index += 3;
        } else {
            decoded.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(decoded).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segments_round_trip_through_the_encoding() {
        let original = "a/b c%é";
        assert_eq!(encode_segment(original), "a%2Fb%20c%25%C3%A9");
        assert_eq!(decode_segment(&encode_segment(original)).as_deref(), Some(original));
    }

    #[test]
    fn a_broken_escape_does_not_decode() {
        assert_eq!(decode_segment("%G1"), None);
        assert_eq!(decode_segment("%2"), None);
    }
}
