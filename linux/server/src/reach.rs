//! Which address a new device is told to use, and the one it falls back to.
//!
//! A device added while Tailscale is up gets the tailnet address, so it reaches
//! the server anywhere, and this network's address as the fallback for a phone
//! without Tailscale. Without Tailscale it gets this network's address, by its
//! Bonjour name when the machine answers to one and by IP as the fallback. Every
//! `https` address in the link is checked against the pin it carries.

use std::net::SocketAddr;

use crate::config::Config;
use crate::native::machine_name;
use crate::net::lan;

/// How a device on the local network reaches the server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LocalReach {
    /// `https://` by Bonjour name, or by IP when the machine answers to no name.
    pub url: String,
    /// `https://` by IP when [`url`](Self::url) uses a name.
    pub ip_url: Option<String>,
    /// The pin of the server's key.
    pub pin: String,
}

/// What an enrollment link tells a device.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DeviceReach {
    /// The address to try first.
    pub url: String,
    /// The address to try when the first cannot be reached.
    pub alternate: Option<String>,
    /// The pin for the `https` addresses, when the server shares on the local network.
    pub pin: Option<String>,
}

/// The name devices on this network use: `lan_name` from the configuration, else this machine's Bonjour name.
pub fn bonjour_source(config: &Config) -> (String, bool) {
    match config.lan_name.as_deref().map(str::trim).filter(|name| !name.is_empty()) {
        Some(name) => (name.to_owned(), true),
        None => match lan::local_host_name() {
            Some(name) => (name, true),
            None => (machine_name().to_owned(), false),
        },
    }
}

/// How a device on this network reaches a server bound at `bound`, or `None` without a local address.
pub fn local_reach(bound: &[SocketAddr], name: &str, answers_bonjour: bool, pin: &str) -> Option<LocalReach> {
    let port = bound.iter().find(|address| lan::wants_tls(address.ip()))?.port();
    let preferred = lan::by_preference(bound.iter().map(SocketAddr::ip).collect());
    let bound: Vec<SocketAddr> = preferred.into_iter().map(|ip| SocketAddr::new(ip, port)).collect();
    let bound = bound.as_slice();
    let host = lan::device_host(bound, name, answers_bonjour)?;
    let ip_host = lan::device_host(bound, name, false)?;
    let ip_url = (ip_host != host).then(|| lan::url(&ip_host, port));
    Some(LocalReach { url: lan::url(&host, port), ip_url, pin: pin.to_owned() })
}

/// The tailnet first with this network as the fallback, this network alone, or `fallback` (loopback) when neither exists.
pub fn device_reach(tailnet: Option<String>, local: Option<LocalReach>, fallback: Option<String>) -> Option<DeviceReach> {
    match (tailnet, local) {
        (Some(url), Some(local)) => Some(DeviceReach { url, alternate: Some(local.url), pin: Some(local.pin) }),
        (Some(url), None) => Some(DeviceReach { url, alternate: None, pin: None }),
        (None, Some(local)) => Some(DeviceReach { url: local.url, alternate: local.ip_url, pin: Some(local.pin) }),
        (None, None) => fallback.map(|url| DeviceReach { url, alternate: None, pin: None }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(text: &str) -> SocketAddr {
        text.parse().unwrap()
    }

    #[test]
    fn a_bonjour_name_comes_with_the_ip_as_fallback() {
        let bound = [at("127.0.0.1:4545"), at("192.168.1.5:4545")];
        let reach = local_reach(&bound, "Marcuss-Mac", true, "PIN").unwrap();
        assert_eq!(reach.url, "https://Marcuss-Mac.local:4545");
        assert_eq!(reach.ip_url.as_deref(), Some("https://192.168.1.5:4545"));
        let plain = local_reach(&bound, "arch", false, "PIN").unwrap();
        assert_eq!(plain.url, "https://192.168.1.5:4545");
        assert_eq!(plain.ip_url, None);
    }

    #[test]
    fn no_local_address_means_no_local_reach() {
        assert_eq!(local_reach(&[at("127.0.0.1:4545"), at("100.64.0.1:4545")], "arch", true, "PIN"), None);
    }

    #[test]
    fn the_tailnet_leads_and_this_network_follows() {
        let local = LocalReach { url: "https://arch.local:4545".into(), ip_url: Some("https://192.168.1.5:4545".into()), pin: "PIN".into() };
        let both = device_reach(Some("http://100.64.0.1:4545".into()), Some(local.clone()), None).unwrap();
        assert_eq!(both.url, "http://100.64.0.1:4545");
        assert_eq!(both.alternate.as_deref(), Some("https://arch.local:4545"));
        assert_eq!(both.pin.as_deref(), Some("PIN"));
        let alone = device_reach(None, Some(local), Some("http://127.0.0.1:4545".into())).unwrap();
        assert_eq!(alone.url, "https://arch.local:4545");
        assert_eq!(alone.alternate.as_deref(), Some("https://192.168.1.5:4545"));
        let tailnet_only = device_reach(Some("http://100.64.0.1:4545".into()), None, None).unwrap();
        assert_eq!((tailnet_only.alternate, tailnet_only.pin), (None, None));
        let neither = device_reach(None, None, Some("http://127.0.0.1:4545".into())).unwrap();
        assert_eq!(neither.url, "http://127.0.0.1:4545");
        assert_eq!(device_reach(None, None, None), None);
    }
}
