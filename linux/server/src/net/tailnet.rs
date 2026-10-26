//! What counts as a tailnet address, and which of this host's addresses are one.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use std::sync::{Arc, PoisonError, RwLock};

const TAILNET_V6_PREFIX: [u16; 3] = [0xfd7a, 0x115c, 0xa1e0];
const CGNAT_FIRST_OCTET: u8 = 100;
const CGNAT_SECOND_OCTET_MASK: u8 = 0b1100_0000;
const CGNAT_SECOND_OCTET_BITS: u8 = 0b0100_0000;

/// True for 100.64.0.0/10 and fd7a:115c:a1e0::/48; an IPv4-mapped IPv6 address
/// counts as the IPv4 address it wraps.
pub fn is_tailnet(ip: IpAddr) -> bool {
    match ip.to_canonical() {
        IpAddr::V4(v4) => is_tailnet_v4(v4),
        IpAddr::V6(v6) => is_tailnet_v6(v6),
    }
}

/// True for 127.0.0.0/8 and ::1; an IPv4-mapped IPv6 loopback counts too.
pub fn is_loopback(ip: IpAddr) -> bool {
    ip.to_canonical().is_loopback()
}

/// Whether a peer may talk to the server at all: tailnet or loopback.
pub fn source_allowed(peer: IpAddr) -> bool {
    is_tailnet(peer) || is_loopback(peer)
}

fn is_tailnet_v4(ip: Ipv4Addr) -> bool {
    let [first, second, _, _] = ip.octets();
    first == CGNAT_FIRST_OCTET && second & CGNAT_SECOND_OCTET_MASK == CGNAT_SECOND_OCTET_BITS
}

fn is_tailnet_v6(ip: Ipv6Addr) -> bool {
    ip.segments()[..3] == TAILNET_V6_PREFIX
}

/// The tailnet addresses of this host's interfaces, IPv4 first, without duplicates.
pub fn addresses() -> io::Result<Vec<IpAddr>> {
    let interfaces = if_addrs::get_if_addrs()?;
    Ok(tailnet_only(interfaces.iter().map(|interface| interface.ip())))
}

/// The tailnet addresses among `candidates`, sorted with IPv4 first and deduplicated.
pub fn tailnet_only(candidates: impl IntoIterator<Item = IpAddr>) -> Vec<IpAddr> {
    let mut found: Vec<IpAddr> = candidates.into_iter().filter(|ip| is_tailnet(*ip)).collect();
    found.sort_by_key(|ip| (ip.is_ipv6(), *ip));
    found.dedup();
    found
}

/// The tailnet addresses the server currently answers on, shared between the
/// listener task that updates it and the Host check that reads it per request.
#[derive(Clone, Debug, Default)]
pub struct TailnetAddresses(Arc<RwLock<Vec<IpAddr>>>);

impl TailnetAddresses {
    /// The addresses right now.
    pub fn snapshot(&self) -> Vec<IpAddr> {
        self.0.read().unwrap_or_else(PoisonError::into_inner).clone()
    }

    /// Replaces the addresses.
    pub fn replace(&self, addresses: Vec<IpAddr>) {
        *self.0.write().unwrap_or_else(PoisonError::into_inner) = addresses;
    }

    /// Whether `ip` is one of the addresses.
    pub fn contains(&self, ip: IpAddr) -> bool {
        self.0.read().unwrap_or_else(PoisonError::into_inner).contains(&ip)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    #[test]
    fn the_ipv4_range_edges_are_exact() {
        assert!(!is_tailnet(ip("100.63.255.255")));
        assert!(is_tailnet(ip("100.64.0.0")));
        assert!(is_tailnet(ip("100.127.255.255")));
        assert!(!is_tailnet(ip("100.128.0.0")));
        assert!(!is_tailnet(ip("10.64.0.1")));
    }

    #[test]
    fn the_ipv6_prefix_is_a_48() {
        assert!(is_tailnet(ip("fd7a:115c:a1e0::1")));
        assert!(is_tailnet(ip("fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff")));
        assert!(!is_tailnet(ip("fd7a:115c:a1e1::1")));
        assert!(!is_tailnet(ip("fd7a:115d:a1e0::1")));
    }

    #[test]
    fn mapped_addresses_count_as_the_address_they_wrap() {
        assert!(is_tailnet(ip("::ffff:100.64.1.1")));
        assert!(!is_tailnet(ip("::ffff:100.128.0.1")));
        assert!(is_loopback(ip("::ffff:127.0.0.1")));
        assert!(source_allowed(ip("::ffff:100.64.1.1")));
    }

    #[test]
    fn loopback_and_tailnet_are_the_only_sources() {
        assert!(source_allowed(ip("127.0.0.1")));
        assert!(source_allowed(ip("::1")));
        assert!(source_allowed(ip("100.91.211.44")));
        assert!(!source_allowed(ip("192.168.1.10")));
        assert!(!source_allowed(ip("8.8.8.8")));
        assert!(!source_allowed(ip("fe80::1")));
        assert!(!source_allowed(ip("2001:db8::1")));
    }

    #[test]
    fn tailnet_only_sorts_ipv4_first_and_drops_the_rest() {
        let found = tailnet_only([
            ip("fd7a:115c:a1e0::6b01:d32d"),
            ip("192.168.1.2"),
            ip("100.91.211.44"),
            ip("100.91.211.44"),
            ip("127.0.0.1"),
        ]);
        assert_eq!(found, vec![ip("100.91.211.44"), ip("fd7a:115c:a1e0::6b01:d32d")]);
    }

    #[test]
    fn the_shared_list_is_visible_to_every_clone() {
        let shared = TailnetAddresses::default();
        let reader = shared.clone();
        assert!(!reader.contains(ip("100.64.0.1")));
        shared.replace(vec![ip("100.64.0.1")]);
        assert!(reader.contains(ip("100.64.0.1")));
        assert_eq!(reader.snapshot(), vec![ip("100.64.0.1")]);
    }
}
