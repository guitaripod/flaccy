//! The machine's name, as clients see it in `hello` and enrollment links.

use std::sync::OnceLock;

const FALLBACK_NAME: &str = "flaccy-server";
const HOSTNAME_FILES: [&str; 2] = ["/proc/sys/kernel/hostname", "/etc/hostname"];

fn from_files() -> Option<String> {
    HOSTNAME_FILES
        .iter()
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .map(|text| text.trim().to_owned())
        .find(|name| !name.is_empty())
}

fn from_environment() -> Option<String> {
    ["HOSTNAME", "COMPUTERNAME"]
        .iter()
        .filter_map(|name| std::env::var(name).ok())
        .map(|text| text.trim().to_owned())
        .find(|name| !name.is_empty())
}

fn from_command() -> Option<String> {
    let output = std::process::Command::new("hostname").output().ok()?;
    let name = String::from_utf8(output.stdout).ok()?.trim().to_owned();
    (output.status.success() && !name.is_empty()).then_some(name)
}

/// The machine's host name, found once: the kernel's, `/etc/hostname`, the environment, the `hostname` program, then a fixed name.
pub fn machine_name() -> &'static str {
    static NAME: OnceLock<String> = OnceLock::new();
    NAME.get_or_init(|| {
        from_files()
            .or_else(from_environment)
            .or_else(from_command)
            .unwrap_or_else(|| FALLBACK_NAME.to_owned())
    })
}
