//! Finding out whether Tailscale is up on this machine, from `tailscale status --json`.

use std::net::IpAddr;

use serde_json::Value;

use crate::runner::{RunError, Runner};

/// The sentence both setup and doctor give when Tailscale cannot be used.
pub const NOT_RUNNING_MESSAGE: &str = "Tailscale isn't running on this machine. Flaccy Server reaches your devices through it. Install it from tailscale.com/download, sign in, then run this again.";

const ENVIRONMENT_VARIABLE: &str = "FLACCY_SERVER_TAILSCALE";
const COMMANDS: [&str; 2] = ["tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"];
const RUNNING: &str = "Running";

/// This machine as the tailnet knows it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tailnet {
    /// Tailscale's version, such as `1.78.1`.
    pub version: String,
    /// The machine's name on the tailnet, such as `arch`.
    pub name: String,
    /// The full MagicDNS name without the trailing dot.
    pub dns_name: String,
    /// The machine's tailnet addresses, IPv4 first.
    pub addresses: Vec<IpAddr>,
}

impl Tailnet {
    /// The first IPv4 tailnet address, or the first address.
    pub fn primary_address(&self) -> Option<IpAddr> {
        self.addresses.iter().copied().find(IpAddr::is_ipv4).or_else(|| self.addresses.first().copied())
    }
}

/// What the probe found.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Tailscale {
    /// There is no `tailscale` program.
    NotInstalled,
    /// It is installed but the machine is not connected, with the reason.
    NotRunning(String),
    /// Connected.
    Running(Tailnet),
}

fn text<'a>(value: &'a Value, path: &[&str]) -> &'a str {
    path.iter().fold(value, |at, key| &at[*key]).as_str().unwrap_or("")
}

/// Reads the JSON `tailscale status --json` prints.
pub fn parse_status(json: &str) -> Tailscale {
    let Ok(status) = serde_json::from_str::<Value>(json) else {
        return Tailscale::NotRunning("tailscale printed something that is not JSON".to_owned());
    };
    let backend = text(&status, &["BackendState"]);
    if backend != RUNNING {
        return Tailscale::NotRunning(format!("its state is {}", if backend.is_empty() { "unknown" } else { backend }));
    }
    let mut addresses: Vec<IpAddr> = status["Self"]["TailscaleIPs"]
        .as_array()
        .map(|list| list.iter().filter_map(|ip| ip.as_str()?.parse().ok()).collect())
        .unwrap_or_default();
    addresses.sort_by_key(|ip| ip.is_ipv6());
    let dns_name = text(&status, &["Self", "DNSName"]).trim_end_matches('.').to_owned();
    let name = dns_name.split('.').next().filter(|label| !label.is_empty()).unwrap_or_else(|| text(&status, &["Self", "HostName"])).to_owned();
    let version = text(&status, &["Version"]).split('-').next().unwrap_or("").to_owned();
    if addresses.is_empty() || name.is_empty() {
        return Tailscale::NotRunning("it reports no address for this machine".to_owned());
    }
    Tailscale::Running(Tailnet { version, name, dns_name, addresses })
}

fn candidates() -> Vec<String> {
    std::env::var(ENVIRONMENT_VARIABLE)
        .ok()
        .filter(|path| !path.is_empty())
        .into_iter()
        .chain(COMMANDS.iter().map(|command| (*command).to_owned()))
        .collect()
}

/// Runs `tailscale status --json` through the first `tailscale` program that exists.
pub fn detect(runner: &dyn Runner) -> Tailscale {
    for command in candidates() {
        match runner.run(&command, &["status", "--json"]) {
            Ok(output) if output.success => return parse_status(&output.stdout),
            Ok(output) => return not_running_from(&output.stdout, &output.stderr),
            Err(RunError::NotFound) => continue,
            Err(RunError::Failed(reason)) => return Tailscale::NotRunning(reason),
        }
    }
    Tailscale::NotInstalled
}

fn not_running_from(stdout: &str, stderr: &str) -> Tailscale {
    match parse_status(stdout) {
        Tailscale::NotRunning(reason) if stdout.trim_start().starts_with('{') => Tailscale::NotRunning(reason),
        _ => Tailscale::NotRunning(stderr.lines().next().unwrap_or("tailscale failed").trim().to_owned()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::fake::FakeRunner;

    const RUNNING_JSON: &str = r#"{
        "Version": "1.78.1-t0123456789-g9876543210",
        "BackendState": "Running",
        "Self": {
            "HostName": "arch",
            "DNSName": "arch.tail1234.ts.net.",
            "TailscaleIPs": ["fd7a:115c:a1e0::6b01:d32d", "100.91.211.44"]
        }
    }"#;

    #[test]
    fn a_running_status_gives_the_name_version_and_addresses() {
        let Tailscale::Running(tailnet) = parse_status(RUNNING_JSON) else {
            panic!("not running");
        };
        assert_eq!(tailnet.name, "arch");
        assert_eq!(tailnet.dns_name, "arch.tail1234.ts.net");
        assert_eq!(tailnet.version, "1.78.1");
        assert_eq!(tailnet.primary_address(), Some("100.91.211.44".parse().unwrap()));
    }

    #[test]
    fn other_backend_states_are_not_running() {
        for state in ["Stopped", "NeedsLogin", "Starting", "NoState"] {
            let json = format!(r#"{{"BackendState": "{state}", "Self": {{}}}}"#);
            assert!(matches!(parse_status(&json), Tailscale::NotRunning(reason) if reason.contains(state)), "{state}");
        }
    }

    #[test]
    fn garbage_and_missing_addresses_are_not_running() {
        assert!(matches!(parse_status("not json"), Tailscale::NotRunning(_)));
        assert!(matches!(parse_status(r#"{"BackendState": "Running", "Self": {"DNSName": "a.b.ts.net."}}"#), Tailscale::NotRunning(_)));
    }

    #[test]
    fn the_host_name_stands_in_for_a_missing_dns_name() {
        let json = r#"{"BackendState": "Running", "Version": "1.80.0", "Self": {"HostName": "nas", "TailscaleIPs": ["100.64.0.2"]}}"#;
        assert!(matches!(parse_status(json), Tailscale::Running(tailnet) if tailnet.name == "nas"));
    }

    #[test]
    fn no_program_means_not_installed_and_a_failure_means_not_running() {
        assert_eq!(detect(&FakeRunner::default()), Tailscale::NotInstalled);
        let failing = FakeRunner::default().on("tailscale status", FakeRunner::fails("failed to connect to local tailscaled\nmore"));
        assert_eq!(detect(&failing), Tailscale::NotRunning("failed to connect to local tailscaled".to_owned()));
        let running = FakeRunner::default().on("tailscale status --json", FakeRunner::ok(RUNNING_JSON));
        assert!(matches!(detect(&running), Tailscale::Running(_)));
    }
}
