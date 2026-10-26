//! Which `Host` header values the server answers to.
//!
//! A DNS-rebinding page can only ever make a browser send a multi-label public
//! name, so the policy refuses exactly those: an IP literal, a single-label
//! name, `localhost`, one of the machine's own names, a name under a private
//! suffix (`.ts.net`, `.local`, `.lan`, `.home.arpa`, `.internal`) or a name the
//! `hosts` setting lists is answered; any other dotted name is not.

use std::collections::HashSet;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::Arc;

use super::names::own_names;
use super::tailnet::TailnetAddresses;

const LOCALHOST_NAME: &str = "localhost";
const WILDCARD_PREFIX: &str = "*.";
const PRIVATE_SUFFIXES: [&str; 5] = [".ts.net", ".local", ".lan", ".home.arpa", ".internal"];
const MAX_NAME_LEN: usize = 253;

/// A host name or address as it appears in a `Host` header, port removed.
#[derive(Clone, Debug, PartialEq, Eq)]
enum HostName {
    Ip(IpAddr),
    Name(String),
}

impl HostName {
    /// Reads `name`, `name:port`, `1.2.3.4[:port]` or `[v6][:port]`; `None` when malformed.
    fn parse(raw: &str) -> Option<Self> {
        let text = raw.trim().to_ascii_lowercase();
        let host = match text.strip_prefix('[') {
            Some(rest) => {
                let (inner, after) = rest.split_once(']')?;
                valid_port_suffix(after)?;
                return inner.parse::<Ipv6Addr>().ok().map(|ip| Self::Ip(IpAddr::V6(ip)));
            }
            None => strip_port(&text)?,
        };
        if host.is_empty() {
            return None;
        }
        Some(match host.parse::<Ipv4Addr>() {
            Ok(ip) => Self::Ip(IpAddr::V4(ip)),
            Err(_) => Self::Name(host.trim_end_matches('.').to_string()),
        })
    }
}

fn valid_port_suffix(after: &str) -> Option<()> {
    match after.strip_prefix(':') {
        None if after.is_empty() => Some(()),
        Some(port) if is_port(port) => Some(()),
        _ => None,
    }
}

fn strip_port(text: &str) -> Option<&str> {
    match text.split_once(':') {
        None => Some(text),
        Some((host, port)) if is_port(port) => Some(host),
        Some(_) => None,
    }
}

fn is_port(text: &str) -> bool {
    !text.is_empty() && text.len() <= 5 && text.bytes().all(|byte| byte.is_ascii_digit())
}

/// True for letters, digits, `-`, `_` and `.` only, with no empty label.
fn is_plain_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME_LEN
        && name.split('.').all(|label| !label.is_empty())
        && name.bytes().all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.'))
}

fn is_plain_host(host: &HostName) -> bool {
    match host {
        HostName::Ip(_) => true,
        HostName::Name(name) => is_plain_name(name),
    }
}

/// One entry of the `hosts` setting.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Configured {
    Exact(HostName),
    Under(String),
}

impl Configured {
    fn parse(entry: &str) -> Option<Self> {
        let trimmed = entry.trim().to_ascii_lowercase();
        match trimmed.strip_prefix(WILDCARD_PREFIX) {
            Some(suffix) if is_plain_name(suffix) && suffix.contains('.') => Some(Self::Under(format!(".{suffix}"))),
            Some(_) => None,
            None => HostName::parse(&trimmed).filter(is_plain_host).map(Self::Exact),
        }
    }

    fn matches(&self, host: &HostName) -> bool {
        match (self, host) {
            (Self::Exact(wanted), host) => wanted == host,
            (Self::Under(suffix), HostName::Name(name)) => name.ends_with(suffix.as_str()),
            (Self::Under(_), HostName::Ip(_)) => false,
        }
    }
}

/// The `Host` values the server answers to; see the module documentation for the rule.
#[derive(Clone, Debug)]
pub struct AllowedHosts {
    configured: Arc<[Configured]>,
    own: Arc<HashSet<String>>,
}

impl AllowedHosts {
    /// `configured` are the `hosts` of the configuration file: exact names, or
    /// `*.example.com` for everything under a domain; entries that are not valid
    /// host names are skipped. `_tailnet` is accepted for compatibility with
    /// existing callers: every IP literal is allowed now, tailnet addresses included.
    pub fn new(configured: &[String], _tailnet: TailnetAddresses) -> Self {
        Self::with_own_names(configured, own_names().clone())
    }

    /// Like [`AllowedHosts::new`] with the machine's own names given, for tests.
    pub fn with_own_names(configured: &[String], own: HashSet<String>) -> Self {
        let parsed: Vec<Configured> = configured.iter().filter_map(|entry| Configured::parse(entry)).collect();
        Self { configured: parsed.into(), own: Arc::new(own) }
    }

    /// Whether a raw `Host` header value is allowed.
    pub fn allows(&self, host_header: &str) -> bool {
        let Some(host) = HostName::parse(host_header) else {
            return false;
        };
        if self.configured.iter().any(|entry| entry.matches(&host)) {
            return true;
        }
        match host {
            HostName::Ip(_) => true,
            HostName::Name(name) => is_plain_name(&name) && self.allows_name(&name),
        }
    }

    fn allows_name(&self, name: &str) -> bool {
        !name.contains('.')
            || name == LOCALHOST_NAME
            || self.own.contains(name)
            || PRIVATE_SUFFIXES.iter().any(|suffix| name.ends_with(suffix))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hosts(configured: &[&str]) -> AllowedHosts {
        let configured: Vec<String> = configured.iter().map(|name| name.to_string()).collect();
        AllowedHosts::with_own_names(&configured, HashSet::from(["arch.example.net".to_string()]))
    }

    #[test]
    fn ports_are_stripped_and_case_is_ignored() {
        let allowed = hosts(&["music.example.org"]);
        for good in ["localhost", "localhost:4545", "127.0.0.1:80", "MUSIC.example.org:4545", "music.example.org."] {
            assert!(allowed.allows(good), "{good}");
        }
    }

    #[test]
    fn ip_literals_of_any_network_are_allowed() {
        let allowed = hosts(&[]);
        for good in ["100.91.211.44", "192.168.1.5:4545", "10.0.0.2", "8.8.8.8", "[::1]", "[::1]:4545", "[fd7a:115c:a1e0::6b01:d32d]:4545", "[2001:db8::1]"] {
            assert!(allowed.allows(good), "{good}");
        }
        assert!(!allowed.allows("::1"));
        assert!(!allowed.allows("[::1]x"));
        assert!(!allowed.allows("[nonsense]"));
    }

    #[test]
    fn single_label_names_are_allowed() {
        let allowed = hosts(&[]);
        for good in ["arch", "arch:4545", "NAS", "my-server_1", "localhost"] {
            assert!(allowed.allows(good), "{good}");
        }
    }

    #[test]
    fn the_machines_own_names_are_allowed() {
        let allowed = hosts(&[]);
        assert!(allowed.allows("arch.example.net"));
        assert!(allowed.allows("ARCH.example.net:4545"));
        assert!(!allowed.allows("other.example.net"));
    }

    #[test]
    fn private_suffixes_are_allowed_with_a_label_in_front() {
        let allowed = hosts(&[]);
        for good in ["arch.tail1234.ts.net:4545", "nas.local", "printer.lan", "box.home.arpa", "db.internal", "a.b.c.local"] {
            assert!(allowed.allows(good), "{good}");
        }
        for bad in ["ts.net", ".ts.net", "evil.local.example.com", "evilts.net", "x.internal.evil.com"] {
            assert!(!allowed.allows(bad), "{bad}");
        }
    }

    #[test]
    fn rebinding_names_are_refused() {
        let allowed = hosts(&[]);
        for bad in [
            "evil.example.com",
            "100.64.0.1.evil.com",
            "127.0.0.1.evil.com:4545",
            "localhost.evil.com",
            "arch.evil.com",
            "evil.com",
            "evil.com:4545",
            "arch.example.net.evil.com",
        ] {
            assert!(!allowed.allows(bad), "{bad}");
        }
    }

    #[test]
    fn configured_names_match_exactly_or_under_a_wildcard() {
        let allowed = hosts(&["music.example.org", "*.media.example.com"]);
        assert!(allowed.allows("music.example.org:443"));
        assert!(allowed.allows("a.media.example.com"));
        assert!(allowed.allows("a.b.media.example.com"));
        assert!(!allowed.allows("media.example.com"));
        assert!(!allowed.allows("evilmedia.example.com"));
        assert!(!allowed.allows("example.org"));
        assert!(!allowed.allows("sub.music.example.org"));
    }

    #[test]
    fn a_wildcard_without_a_domain_matches_nothing() {
        for entry in ["*.com", "*.", "*", "*.*.x"] {
            let allowed = hosts(&[entry]);
            assert!(!allowed.allows("evil.com"), "{entry}");
        }
    }

    #[test]
    fn a_configured_address_with_a_port_matches_without_it() {
        let allowed = hosts(&["192.168.1.5:4545", "[fd00::5]"]);
        assert!(allowed.allows("192.168.1.5"));
        assert!(allowed.allows("[fd00::5]:80"));
    }

    #[test]
    fn malformed_and_odd_hosts_are_refused() {
        let allowed = hosts(&[]);
        for bad in ["", ":80", "a:1:2", "localhost:notaport", "localhost:", "a b", "evil..com", "arch\u{e9}", "a/b", "a@b"] {
            assert!(!allowed.allows(bad), "{bad}");
        }
    }
}
