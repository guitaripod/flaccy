//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/LocalNetwork.swift`.
//!
//! Which addresses belong to the network a person is on at home: the private
//! IPv4 ranges, IPv4 and IPv6 link-local, and IPv6 unique local addresses, minus
//! the Tailscale ranges inside them. A Flaccy Server shares on these addresses
//! over TLS with a pinned key, so a typed address on them defaults to `https`.

use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

const TAILNET_V6_PREFIX: [u16; 3] = [0xfd7a, 0x115c, 0xa1e0];
const LOCAL_SUFFIX: &str = ".local";

/// True for 10/8, 172.16/12, 192.168/16, 169.254/16, fc00::/7 and fe80::/10, except
/// Tailscale's fd7a:115c:a1e0::/48. An IPv4-mapped IPv6 address counts as the address it wraps.
pub fn is_local_network(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => is_local_v4(v4),
        IpAddr::V6(v6) => is_local_v6(v6),
    }
}

/// True for the local addresses a server can bind without an interface scope:
/// everything [`is_local_network`] accepts except the link-local ranges.
pub fn is_bindable_local_network(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => v4.is_private(),
        IpAddr::V6(v6) => is_unique_local(v6) && !is_tailnet_v6(v6),
    }
}

/// Whether a host as typed names a machine on the local network: a local IP
/// literal (IPv6 with or without brackets) or a `.local` Bonjour name.
pub fn is_local_host(host: &str) -> bool {
    let trimmed = host.trim().trim_end_matches('.');
    let unbracketed = trimmed.trim_start_matches('[').trim_end_matches(']');
    if let Ok(ip) = unbracketed.parse::<IpAddr>() {
        return is_local_network(ip);
    }
    let lowered = trimmed.to_ascii_lowercase();
    lowered.len() > LOCAL_SUFFIX.len() && lowered.ends_with(LOCAL_SUFFIX)
}

fn is_local_v4(ip: Ipv4Addr) -> bool {
    ip.is_private() || ip.is_link_local()
}

fn is_local_v6(ip: Ipv6Addr) -> bool {
    (is_unique_local(ip) && !is_tailnet_v6(ip)) || is_link_local_v6(ip)
}

fn is_unique_local(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xfe00 == 0xfc00
}

fn is_link_local_v6(ip: Ipv6Addr) -> bool {
    ip.segments()[0] & 0xffc0 == 0xfe80
}

fn is_tailnet_v6(ip: Ipv6Addr) -> bool {
    ip.segments()[..3] == TAILNET_V6_PREFIX
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn the_private_ipv4_ranges_and_link_local_are_local() {
        for local in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.20", "169.254.3.4"] {
            assert!(is_local_network(ip(local)), "{local}");
        }
        for other in ["172.32.0.1", "192.169.0.1", "100.64.0.1", "100.91.211.44", "8.8.8.8", "127.0.0.1"] {
            assert!(!is_local_network(ip(other)), "{other}");
        }
    }

    #[test]
    fn unique_local_and_link_local_ipv6_are_local_but_the_tailnet_prefix_is_not() {
        assert!(is_local_network(ip("fd12:3456::1")));
        assert!(is_local_network(ip("fc00::1")));
        assert!(is_local_network(ip("fe80::1")));
        assert!(!is_local_network(ip("fd7a:115c:a1e0::1")));
        assert!(!is_local_network(ip("2001:db8::1")));
        assert!(!is_local_network(ip("::1")));
    }

    #[test]
    fn mapped_addresses_count_as_the_address_they_wrap() {
        assert!(is_local_network(ip("::ffff:192.168.1.5")));
        assert!(!is_local_network(ip("::ffff:100.64.0.1")));
    }

    #[test]
    fn link_local_cannot_be_bound_without_a_scope() {
        assert!(is_bindable_local_network(ip("192.168.1.5")));
        assert!(is_bindable_local_network(ip("fd12::5")));
        assert!(!is_bindable_local_network(ip("169.254.1.1")));
        assert!(!is_bindable_local_network(ip("fe80::1")));
        assert!(!is_bindable_local_network(ip("fd7a:115c:a1e0::5")));
    }

    #[test]
    fn local_hosts_are_local_ips_and_bonjour_names() {
        assert!(is_local_host("192.168.1.5"));
        assert!(is_local_host("[fd12::5]"));
        assert!(is_local_host("Marcuss-MacBook-Pro.local"));
        assert!(is_local_host("arch.LOCAL."));
        assert!(!is_local_host(".local"));
        assert!(!is_local_host("arch"));
        assert!(!is_local_host("arch.tail1234.ts.net"));
        assert!(!is_local_host("100.91.211.44"));
        assert!(!is_local_host("music.example.com"));
    }
}
