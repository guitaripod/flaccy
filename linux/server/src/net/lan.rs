//! Sharing on the local network: which of this host's addresses to bind when the
//! `lan` setting is on, who may connect to them, and the address a device on the
//! same network is told to use.
//!
//! Connections from the local network are served over TLS with the key in
//! [`crate::lan_identity`], so a device token never crosses Wi-Fi in clear text.

use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::Path;

use flaccy_shared::remote::local_network::{is_bindable_local_network, is_local_network};

use super::tailnet;

const BONJOUR_SUFFIX: &str = ".local";
const AVAHI_SOCKETS: [&str; 2] = ["/run/avahi-daemon/socket", "/var/run/avahi-daemon/socket"];
const LINUX_ROUTES: &str = "/proc/net/route";
const DEFAULT_DESTINATION: &str = "00000000";
/// Interfaces that carry containers, virtual machines, VPNs or Apple's peer links: devices on the Wi-Fi never reach them.
const VIRTUAL_INTERFACE_PREFIXES: [&str; 25] = [
    "docker", "br-", "veth", "virbr", "vnet", "vmnet", "vboxnet", "cni", "flannel", "cali", "kube", "podman", "lxc", "lxd",
    "zt", "wg", "tun", "tap", "tailscale", "utun", "bridge", "awdl", "llw", "anpi", "vmenet",
];

/// What one look at the interfaces found.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Found {
    pub tailnet: Vec<IpAddr>,
    pub local: Vec<IpAddr>,
}

/// The tailnet addresses and, when `lan` is on, the bindable local network addresses of this host's real interfaces.
pub fn discover(lan: bool) -> io::Result<Found> {
    let interfaces = if_addrs::get_if_addrs()?;
    let tailnet = tailnet::tailnet_only(interfaces.iter().map(|interface| interface.ip()));
    let physical = interfaces.iter().filter(|interface| !is_virtual_interface(&interface.name)).map(|interface| interface.ip());
    Ok(Found { tailnet, local: classify(physical, lan).local })
}

/// Whether an interface name belongs to a container, virtual machine, VPN or peer link rather than the network a person is on.
pub fn is_virtual_interface(name: &str) -> bool {
    VIRTUAL_INTERFACE_PREFIXES.iter().any(|prefix| name.starts_with(prefix))
}

/// `local` with the addresses of the interface that carries the default route first, so a link names the address
/// a phone on the same Wi-Fi can reach. Keeps the order otherwise.
pub fn by_preference(local: Vec<IpAddr>) -> Vec<IpAddr> {
    let Some(interface) = default_route_interface() else {
        return local;
    };
    let on_default: Vec<IpAddr> = if_addrs::get_if_addrs()
        .map(|found| found.into_iter().filter(|candidate| candidate.name == interface).map(|candidate| candidate.ip()).collect())
        .unwrap_or_default();
    let (first, rest): (Vec<IpAddr>, Vec<IpAddr>) = local.into_iter().partition(|ip| on_default.contains(ip));
    first.into_iter().chain(rest).collect()
}

/// The interface the default route leaves through: `/proc/net/route` on Linux, `route -n get default` on a Mac.
fn default_route_interface() -> Option<String> {
    if cfg!(target_os = "linux") {
        return default_route_in(&std::fs::read_to_string(LINUX_ROUTES).ok()?);
    }
    if cfg!(target_os = "macos") {
        let output = std::process::Command::new("/sbin/route").args(["-n", "get", "default"]).output().ok()?;
        let text = String::from_utf8(output.stdout).ok()?;
        return text.lines().find_map(|line| line.trim().strip_prefix("interface:").map(|name| name.trim().to_owned()));
    }
    None
}

/// The interface of the lowest-metric default route in a `/proc/net/route` table.
fn default_route_in(table: &str) -> Option<String> {
    table
        .lines()
        .skip(1)
        .filter_map(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            let metric = fields.get(6)?.parse::<u32>().ok()?;
            (fields.get(1) == Some(&DEFAULT_DESTINATION)).then(|| (metric, fields[0].to_owned()))
        })
        .min()
        .map(|(_, interface)| interface)
}

/// Splits `candidates` into tailnet and local network addresses, each sorted with IPv4 first and deduplicated.
pub fn classify(candidates: impl IntoIterator<Item = IpAddr>, lan: bool) -> Found {
    let candidates: Vec<IpAddr> = candidates.into_iter().collect();
    let tailnet = tailnet::tailnet_only(candidates.iter().copied());
    let mut local: Vec<IpAddr> = if lan {
        candidates.into_iter().filter(|ip| is_bindable_local_network(*ip)).collect()
    } else {
        Vec::new()
    };
    local.sort_by_key(|ip| (ip.is_ipv6(), *ip));
    local.dedup();
    Found { tailnet, local }
}

/// Whether a peer may connect while the server also shares on the local network.
pub fn source_allowed_with_lan(peer: IpAddr) -> bool {
    tailnet::source_allowed(peer) || is_local_network(peer)
}

/// Whether a connection from `peer` is served over TLS: every local network peer is, tailnet and loopback ones are not.
pub fn wants_tls(peer: IpAddr) -> bool {
    is_local_network(peer) && !tailnet::source_allowed(peer)
}

/// The host a device on this network should use: the Bonjour name when this machine answers to one,
/// otherwise the first local IPv4 address, otherwise the first local address, in the order `bound` lists them.
pub fn device_host(bound: &[SocketAddr], machine_name: &str, answers_bonjour: bool) -> Option<String> {
    let local: Vec<IpAddr> = bound.iter().map(SocketAddr::ip).filter(|ip| is_bindable_local_network(*ip)).collect();
    if local.is_empty() {
        return None;
    }
    if answers_bonjour {
        if let Some(name) = bonjour_name(machine_name) {
            return Some(name);
        }
    }
    let chosen = local.iter().find(|ip| ip.is_ipv4()).or_else(|| local.first())?;
    Some(match chosen {
        IpAddr::V4(v4) => v4.to_string(),
        IpAddr::V6(v6) => format!("[{v6}]"),
    })
}

/// The `https://` URL for a host and port.
pub fn url(host: &str, port: u16) -> String {
    format!("https://{host}:{port}")
}

/// `name.local` for a host name, or `None` when the name cannot be one Bonjour label.
pub fn bonjour_name(machine_name: &str) -> Option<String> {
    let trimmed = machine_name.trim().trim_end_matches('.');
    let label = trimmed.strip_suffix(BONJOUR_SUFFIX).unwrap_or(trimmed);
    let label = label.split('.').next().unwrap_or_default();
    let valid = !label.is_empty() && label.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-');
    valid.then(|| format!("{label}{BONJOUR_SUFFIX}"))
}

/// The name this machine answers to over Bonjour, without `.local`: the Mac's LocalHostName, or the name avahi publishes on
/// Linux, which avahi renames (`arch-2`) when another machine already holds the host name. `None` when nothing answers for
/// this machine over Bonjour, so devices are given its IP address instead.
pub fn local_host_name() -> Option<String> {
    if cfg!(target_os = "macos") {
        return command_output("/usr/sbin/scutil", &["--get", "LocalHostName"]).filter(|name| !name.is_empty());
    }
    if !AVAHI_SOCKETS.iter().any(|socket| Path::new(socket).exists()) {
        return None;
    }
    let reply = command_output("busctl", &["--system", "call", "org.freedesktop.Avahi", "/", "org.freedesktop.Avahi.Server", "GetHostNameFqdn"])?;
    avahi_host_name(&reply)
}

/// The label of the name in a `busctl` reply such as `s "arch-2.local"`.
fn avahi_host_name(reply: &str) -> Option<String> {
    let quoted = reply.trim().strip_prefix("s ")?.trim().trim_matches('"');
    let label = quoted.trim_end_matches('.').strip_suffix(BONJOUR_SUFFIX).unwrap_or(quoted);
    (!label.is_empty() && !label.contains('.')).then(|| label.to_owned())
}

fn command_output(program: &str, arguments: &[&str]) -> Option<String> {
    let output = std::process::Command::new(program).args(arguments).output().ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ip(text: &str) -> IpAddr {
        text.parse().unwrap()
    }

    fn at(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    #[test]
    fn local_addresses_are_found_only_when_lan_is_on() {
        let candidates = [ip("192.168.1.5"), ip("100.91.211.44"), ip("127.0.0.1"), ip("fe80::1"), ip("fd12::5"), ip("8.8.8.8")];
        let off = classify(candidates, false);
        assert_eq!(off.tailnet, vec![ip("100.91.211.44")]);
        assert!(off.local.is_empty());
        let on = classify(candidates, true);
        assert_eq!(on.local, vec![ip("192.168.1.5"), ip("fd12::5")]);
    }

    #[test]
    fn local_peers_are_allowed_and_served_over_tls() {
        assert!(source_allowed_with_lan(ip("192.168.1.20")));
        assert!(source_allowed_with_lan(ip("100.64.0.9")));
        assert!(source_allowed_with_lan(ip("127.0.0.1")));
        assert!(!source_allowed_with_lan(ip("8.8.8.8")));
        assert!(wants_tls(ip("192.168.1.20")));
        assert!(wants_tls(ip("fe80::2")));
        assert!(!wants_tls(ip("100.64.0.9")));
        assert!(!wants_tls(ip("127.0.0.1")));
    }

    #[test]
    fn the_device_host_prefers_the_bonjour_name_then_ipv4() {
        let bound = [at("127.0.0.1:4545"), at("[fd12::5]:4545"), at("192.168.1.5:4545")];
        assert_eq!(device_host(&bound, "Marcuss-Mac.local", true).as_deref(), Some("Marcuss-Mac.local"));
        assert_eq!(device_host(&bound, "arch", true).as_deref(), Some("arch.local"));
        assert_eq!(device_host(&bound, "arch", false).as_deref(), Some("192.168.1.5"));
        assert_eq!(device_host(&[at("[fd12::5]:4545")], "arch", false).as_deref(), Some("[fd12::5]"));
        assert_eq!(device_host(&[at("127.0.0.1:4545"), at("100.64.0.1:4545")], "arch", true), None);
    }

    #[test]
    fn a_name_that_cannot_be_a_label_falls_back_to_the_address() {
        assert_eq!(bonjour_name("my box"), None);
        assert_eq!(bonjour_name(""), None);
        assert_eq!(bonjour_name("arch.example.org").as_deref(), Some("arch.local"));
        let bound = [at("192.168.1.5:4545")];
        assert_eq!(device_host(&bound, "my box", true).as_deref(), Some("192.168.1.5"));
    }

    #[test]
    fn container_vm_and_vpn_interfaces_are_virtual() {
        for name in ["docker0", "br-3cd57705626c", "veth12ab", "virbr0", "tailscale0", "utun3", "bridge100", "awdl0", "wg0"] {
            assert!(is_virtual_interface(name), "{name}");
        }
        for name in ["enp7s0", "eth0", "wlan0", "wlp2s0", "en0", "en1"] {
            assert!(!is_virtual_interface(name), "{name}");
        }
    }

    #[test]
    fn the_default_route_is_the_lowest_metric_zero_destination() {
        let table = "Iface\tDestination\tGateway\tFlags\tRefCnt\tUse\tMetric\tMask\n\
            docker0\t000011AC\t00000000\t0001\t0\t0\t0\t0000FFFF\n\
            wlan0\t00000000\t0101A8C0\t0003\t0\t0\t600\t00000000\n\
            enp7s0\t00000000\t0101A8C0\t0003\t0\t0\t100\t00000000\n";
        assert_eq!(default_route_in(table).as_deref(), Some("enp7s0"));
        assert_eq!(default_route_in("Iface\tDestination\n"), None);
    }

    #[test]
    fn avahi_renames_are_read_from_its_reply() {
        assert_eq!(avahi_host_name("s \"arch-2.local\"").as_deref(), Some("arch-2"));
        assert_eq!(avahi_host_name("s \"arch.local.\"\n").as_deref(), Some("arch"));
        assert_eq!(avahi_host_name("s \"\""), None);
        assert_eq!(avahi_host_name("garbage"), None);
    }

    #[test]
    fn urls_are_https_with_the_port() {
        assert_eq!(url("arch.local", 4545), "https://arch.local:4545");
    }
}
