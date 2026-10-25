//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/ServerAddress.swift`.
//!
//! What a person types into the server field becomes the base every request is
//! built on: a scheme (https unless typed otherwise), a host with an optional
//! port, and an optional path prefix for a server behind a reverse proxy. A
//! trailing `/rest` is dropped because the request builder adds it.

/// The base URL for a typed server address, or `None` when it cannot be used.
pub fn normalize(input: &str) -> Option<String> {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return None;
    }
    let with_scheme = if trimmed.contains("://") {
        trimmed.to_string()
    } else {
        format!("https://{trimmed}")
    };
    let (scheme, rest) = with_scheme.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    if scheme != "http" && scheme != "https" {
        return None;
    }
    let rest = rest.split(['?', '#']).next().unwrap_or_default();
    let (authority, path) = match rest.find('/') {
        Some(slash) => (&rest[..slash], &rest[slash..]),
        None => (rest, ""),
    };
    if !is_valid_authority(authority) {
        return None;
    }
    let path = strip_rest_suffix(path.trim_end_matches('/'));
    Some(format!("{scheme}://{authority}{path}"))
}

/// Whether the host is present and any port after it is all digits.
fn is_valid_authority(authority: &str) -> bool {
    let after_ipv6_host = authority.rfind(']').map_or(0, |bracket| bracket + 1);
    let (host, port) = match authority[after_ipv6_host..].rfind(':') {
        Some(colon) => (
            &authority[..after_ipv6_host + colon],
            Some(&authority[after_ipv6_host + colon + 1..]),
        ),
        None => (authority, None),
    };
    let port_is_valid = match port {
        Some(port) => !port.is_empty() && port.bytes().all(|byte| byte.is_ascii_digit()),
        None => true,
    };
    !host.is_empty() && port_is_valid
}

/// Drops a trailing `/rest` the person pasted from the server's API address.
fn strip_rest_suffix(path: &str) -> &str {
    path.strip_suffix("/rest")
        .unwrap_or(path)
        .trim_end_matches('/')
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn a_bare_host_gets_https() {
        assert_eq!(
            normalize("music.example.ts.net").as_deref(),
            Some("https://music.example.ts.net")
        );
    }

    #[test]
    fn keeps_an_http_scheme_port_and_drops_the_trailing_slash() {
        assert_eq!(
            normalize("http://192.168.1.5:4533/").as_deref(),
            Some("http://192.168.1.5:4533")
        );
    }

    #[test]
    fn keeps_a_path_prefix_and_drops_a_trailing_rest() {
        assert_eq!(
            normalize("https://h.example/navidrome/rest/").as_deref(),
            Some("https://h.example/navidrome")
        );
        assert_eq!(
            normalize("https://h.example/rest").as_deref(),
            Some("https://h.example")
        );
    }

    #[test]
    fn rejects_other_schemes_and_empty_input() {
        assert_eq!(normalize("ftp://x"), None);
        assert_eq!(normalize(""), None);
        assert_eq!(normalize("   "), None);
        assert_eq!(normalize("https://"), None);
        assert_eq!(normalize("https://:4533"), None);
        assert_eq!(normalize("https://h.example:port"), None);
    }

    #[test]
    fn drops_query_and_fragment_and_trims_whitespace() {
        assert_eq!(
            normalize("  https://h.example:8443?x=1#y ").as_deref(),
            Some("https://h.example:8443")
        );
    }

    #[test]
    fn keeps_a_bracketed_ipv6_host_with_a_port() {
        assert_eq!(
            normalize("http://[::1]:4533").as_deref(),
            Some("http://[::1]:4533")
        );
    }
}
