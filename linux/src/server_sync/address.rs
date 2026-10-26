use flaccy_shared::remote::server_address::normalize;

const DEFAULT_PORT: u16 = 4545;
const CODE_LENGTH: usize = 26;
const CODE_GROUP: usize = 4;

/// What the code field shows for what was typed or pasted: upper case, grouped by four with dashes, `O` read as `0` and `I` or `L` as `1`, spaces and dashes ignored.
pub fn format_code(typed: &str) -> String {
    let symbols = code_symbols(typed);
    let mut grouped = String::with_capacity(symbols.len() + symbols.len() / CODE_GROUP);
    for (index, symbol) in symbols.into_iter().enumerate() {
        if index > 0 && index % CODE_GROUP == 0 {
            grouped.push('-');
        }
        grouped.push(symbol);
    }
    grouped
}

/// The code as the server expects it: the symbols only, no dashes.
pub fn canonical_code(typed: &str) -> String {
    code_symbols(typed).into_iter().collect()
}

/// Whether the code has all of its symbols, so Connect can be offered.
pub fn code_is_complete(typed: &str) -> bool {
    code_symbols(typed).len() == CODE_LENGTH
}

fn code_symbols(typed: &str) -> Vec<char> {
    typed
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .map(|symbol| match symbol.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .take(CODE_LENGTH)
        .collect()
}

/// Where the cursor belongs in the grouped code after the person typed `cursor` characters into `typed`: just after the same symbol it followed before.
pub fn cursor_after_format(typed: &str, cursor: usize) -> usize {
    let before: String = typed.chars().take(cursor).collect();
    let symbols = code_symbols(&before).len();
    match symbols {
        0 => 0,
        count => count + (count - 1) / CODE_GROUP,
    }
}

/// The base URL for an address the person typed: `arch`, `arch.tailnet.ts.net` or an IP, with or without `http://` and a port. A bare host gets `http` and port 4545.
pub fn typed_address(typed: &str) -> Option<String> {
    let trimmed = typed.trim();
    if trimmed.is_empty() {
        return None;
    }
    let prefixed = if trimmed.contains("://") {
        trimmed.to_owned()
    } else {
        format!("http://{trimmed}")
    };
    normalize(&prefixed).map(with_default_port)
}

fn with_default_port(url: String) -> String {
    let Some(("http", rest)) = url.split_once("://") else {
        return url;
    };
    let authority_end = rest.find('/').unwrap_or(rest.len());
    let (authority, path) = rest.split_at(authority_end);
    if has_port(authority) {
        return url;
    }
    format!("http://{authority}:{DEFAULT_PORT}{path}")
}

fn has_port(authority: &str) -> bool {
    let after_bracket = authority.rfind(']').map_or(0, |bracket| bracket + 1);
    authority[after_bracket..].contains(':')
}

/// The name to call a server in messages when it has not told us one: the host's first label, or the whole host for an IP address.
pub fn short_name(url: &str) -> String {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    let authority = rest.split('/').next().unwrap_or_default();
    let after_bracket = authority.rfind(']').map_or(0, |bracket| bracket + 1);
    let host = match authority[after_bracket..].rfind(':') {
        Some(colon) => &authority[..after_bracket + colon],
        None => authority,
    };
    let is_address = host.starts_with('[') || host.chars().all(|c| c.is_ascii_digit() || c == '.');
    if is_address {
        return host.to_owned();
    }
    host.split('.').next().unwrap_or(host).to_owned()
}

/// What this computer calls itself on the server's device list.
pub fn device_name() -> String {
    let host = gtk::glib::host_name();
    if host.is_empty() {
        "Linux".to_owned()
    } else {
        host.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_code_groups_as_it_is_typed() {
        assert_eq!(format_code("abcd"), "ABCD");
        assert_eq!(format_code("abcde"), "ABCD-E");
        assert_eq!(format_code("abcd-efgh ijkl"), "ABCD-EFGH-1JK1");
    }

    #[test]
    fn o_reads_as_zero_and_i_and_l_as_one() {
        assert_eq!(canonical_code("oOiIlL"), "001111");
        assert_eq!(format_code("o0il"), "0011");
    }

    #[test]
    fn spaces_dashes_and_marks_are_ignored_and_the_length_is_capped() {
        assert_eq!(canonical_code(" a-b c\td!"), "ABCD");
        let long = "A".repeat(40);
        assert_eq!(canonical_code(&long).len(), 26);
        assert!(code_is_complete(&long));
        assert!(!code_is_complete("ABCD-EFGH"));
    }

    #[test]
    fn pasting_a_formatted_code_changes_nothing() {
        let once = format_code("0123456789abcdefghjkmnpqrs");
        assert_eq!(format_code(&once), once);
        assert_eq!(once, "0123-4567-89AB-CDEF-GHJK-MNPQ-RS");
    }

    #[test]
    fn the_cursor_stays_after_the_symbol_it_followed() {
        assert_eq!(cursor_after_format("abcde", 5), 6);
        assert_eq!(cursor_after_format("ABCD-E", 6), 6);
        assert_eq!(cursor_after_format("abcd", 4), 4);
        assert_eq!(cursor_after_format("abcdefgh", 2), 2);
        assert_eq!(cursor_after_format("abcdefgh", 0), 0);
        assert_eq!(cursor_after_format("--", 2), 0);
    }

    #[test]
    fn a_bare_name_gets_http_and_the_default_port() {
        assert_eq!(typed_address("arch").as_deref(), Some("http://arch:4545"));
        assert_eq!(
            typed_address("arch.tail-net.ts.net").as_deref(),
            Some("http://arch.tail-net.ts.net:4545")
        );
        assert_eq!(
            typed_address(" 100.91.211.44 ").as_deref(),
            Some("http://100.91.211.44:4545")
        );
    }

    #[test]
    fn a_typed_scheme_and_port_are_kept() {
        assert_eq!(
            typed_address("http://arch:9000/").as_deref(),
            Some("http://arch:9000")
        );
        assert_eq!(typed_address("arch:9000").as_deref(), Some("http://arch:9000"));
        assert_eq!(typed_address("http://arch").as_deref(), Some("http://arch:4545"));
        assert_eq!(
            typed_address("https://arch.example").as_deref(),
            Some("https://arch.example")
        );
        assert_eq!(typed_address("http://[::1]").as_deref(), Some("http://[::1]:4545"));
    }

    #[test]
    fn nothing_usable_is_refused() {
        assert_eq!(typed_address("   "), None);
        assert_eq!(typed_address("ftp://arch"), None);
        assert_eq!(typed_address("arch:port"), None);
    }

    #[test]
    fn a_server_is_called_by_its_first_label_or_its_address() {
        assert_eq!(short_name("http://arch:4545"), "arch");
        assert_eq!(short_name("http://arch.tail-net.ts.net:4545"), "arch");
        assert_eq!(short_name("http://100.91.211.44:4545"), "100.91.211.44");
        assert_eq!(short_name("http://[::1]:4545"), "[::1]");
    }
}
