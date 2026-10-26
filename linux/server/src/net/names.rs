//! The names this machine answers to: its host name, the short form, and the
//! aliases `/etc/hosts` gives it.

use std::collections::HashSet;
use std::sync::OnceLock;

use crate::native::machine_name;

const HOSTS_FILE: &str = "/etc/hosts";

/// Lower-cased names of this machine, found once.
pub fn own_names() -> &'static HashSet<String> {
    static NAMES: OnceLock<HashSet<String>> = OnceLock::new();
    NAMES.get_or_init(|| {
        let hosts_file = std::fs::read_to_string(HOSTS_FILE).unwrap_or_default();
        names_from(machine_name(), &hosts_file)
    })
}

/// `hostname`, its first label, and every name on an `/etc/hosts` line that mentions `hostname`.
fn names_from(hostname: &str, hosts_file: &str) -> HashSet<String> {
    let hostname = hostname.trim().trim_end_matches('.').to_ascii_lowercase();
    let mut names = HashSet::new();
    if hostname.is_empty() {
        return names;
    }
    if let Some((short, _)) = hostname.split_once('.') {
        names.insert(short.to_owned());
    }
    names.insert(hostname.clone());
    for line in hosts_file.lines() {
        let content = line.split('#').next().unwrap_or("");
        let mut fields = content.split_whitespace().map(str::to_ascii_lowercase);
        let _address = fields.next();
        let aliases: Vec<String> = fields.collect();
        if aliases.contains(&hostname) {
            names.extend(aliases);
        }
    }
    names
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_hostname_and_its_short_form_are_names() {
        let names = names_from("Arch.Example.NET", "");
        assert!(names.contains("arch.example.net") && names.contains("arch"));
    }

    #[test]
    fn hosts_file_aliases_of_the_hostname_are_names() {
        let file = "127.0.0.1 localhost\n127.0.1.1 arch.home.example arch # mine\n10.0.0.9 other.example other\n";
        let names = names_from("arch", file);
        assert!(names.contains("arch.home.example"));
        assert!(!names.contains("other.example"));
    }

    #[test]
    fn an_empty_hostname_gives_no_names() {
        assert!(names_from("  ", "127.0.1.1 a b").is_empty());
    }
}
