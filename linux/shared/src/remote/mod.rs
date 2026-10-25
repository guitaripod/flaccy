//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/`.
//!
//! Everything Flaccy decides about talking to an OpenSubsonic server that does
//! not depend on the platform: how a typed address becomes a base URL, how a
//! request is signed, what a response means, how a remote song is named in the
//! library, which bytes of it are cached, what to evict and what a catalog sync
//! changes. The same numbers are asserted on both sides.

pub mod byte_ranges;
pub mod cache_policy;
pub mod catalog_diff;
pub mod remote_path;
pub mod server_address;
pub mod subsonic_request;
pub mod subsonic_response;

pub(crate) fn percent_encode(value: &str) -> String {
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

pub(crate) fn percent_decode(value: &str) -> Option<String> {
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
    fn encodes_every_byte_outside_the_unreserved_set() {
        assert_eq!(percent_encode("a b/ç"), "a%20b%2F%C3%A7");
        assert_eq!(percent_encode("A-z_0.9~"), "A-z_0.9~");
        assert_eq!(percent_encode("K+1"), "K%2B1");
    }

    #[test]
    fn decodes_what_it_encodes_and_rejects_broken_escapes() {
        assert_eq!(percent_decode("a%20b%2F%C3%A7").as_deref(), Some("a b/ç"));
        assert_eq!(percent_decode("%G1"), None);
        assert_eq!(percent_decode("%2"), None);
        assert_eq!(percent_decode("%+1"), None);
    }
}
