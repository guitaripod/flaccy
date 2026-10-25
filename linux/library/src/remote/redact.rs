//! Keeps credentials out of every log line.
//!
//! A request URL carries the API key, or the username, salted token and salt,
//! in its query string, and an HTTP library may repeat that URL in an error.
//! Nothing in Flaccy logs a URL as it is: text that might hold one goes through
//! [`redact`] first, and requests are named by their method and host.

const AUTH_PARAMETERS: [&str; 6] = ["apiKey", "t", "s", "u", "p", "password"];
const MASK: &str = "***";

/// `text` with the value of every authentication parameter replaced by `***`.
pub fn redact(text: &str) -> String {
    AUTH_PARAMETERS
        .iter()
        .fold(text.to_string(), |current, name| mask_parameter(&current, name))
}

/// The scheme, host and path of `url` without its query string or fragment.
pub fn without_query(url: &str) -> String {
    url.split(['?', '#']).next().unwrap_or_default().to_string()
}

/// Masks the value after every `name=` that starts a word.
fn mask_parameter(text: &str, name: &str) -> String {
    let needle = format!("{name}=");
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(found) = rest.find(&needle) {
        let before = &rest[..found];
        let starts_word = before
            .chars()
            .next_back()
            .map_or(true, |previous| !previous.is_ascii_alphanumeric());
        let value_start = found + needle.len();
        result.push_str(&rest[..value_start]);
        let after = &rest[value_start..];
        if starts_word {
            let value_end = value_length(after);
            result.push_str(MASK);
            rest = &after[value_end..];
        } else {
            rest = after;
        }
    }
    result.push_str(rest);
    result
}

/// How many bytes of `text` are the value of a parameter: up to the next
/// separator, where a colon only separates when a space follows it.
fn value_length(text: &str) -> usize {
    let mut chars = text.char_indices().peekable();
    while let Some((index, c)) = chars.next() {
        let ends = match c {
            '&' | ' ' | '"' | '\'' | ')' | '>' | ',' | '\n' => true,
            ':' => chars.peek().map_or(true, |(_, next)| next.is_whitespace()),
            _ => false,
        };
        if ends {
            return index;
        }
    }
    text.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_password_login_url_loses_its_user_token_and_salt() {
        let url = "http://h.example/rest/ping?u=ana&t=0123abcd&s=f00dfeed&v=1.16.1&c=flaccy&f=json";
        let masked = redact(url);
        assert_eq!(
            masked,
            "http://h.example/rest/ping?u=***&t=***&s=***&v=1.16.1&c=flaccy&f=json"
        );
        assert!(!masked.contains("ana"));
        assert!(!masked.contains("0123abcd"));
    }

    #[test]
    fn an_api_key_url_loses_the_key_wherever_it_sits() {
        let url = "http://h.example/rest/getAlbum?id=7&apiKey=SECRET-KEY&v=1.16.1";
        assert_eq!(
            redact(url),
            "http://h.example/rest/getAlbum?id=7&apiKey=***&v=1.16.1"
        );
        assert_eq!(
            redact("GET http://h/rest/stream?apiKey=SECRET-KEY: Connection refused"),
            "GET http://h/rest/stream?apiKey=***: Connection refused"
        );
    }

    #[test]
    fn words_that_only_end_in_a_parameter_name_are_left_alone() {
        assert_eq!(redact("its=5 cost=3 report=ok"), "its=5 cost=3 report=ok");
    }

    #[test]
    fn a_quoted_url_in_an_error_keeps_its_closing_quote() {
        assert_eq!(
            redact("failed \"http://h/rest/ping?u=ana&t=aa&s=bb\" now"),
            "failed \"http://h/rest/ping?u=***&t=***&s=***\" now"
        );
    }

    #[test]
    fn the_query_can_be_cut_off_a_url() {
        assert_eq!(
            without_query("http://h/rest/ping?u=ana&t=aa#x"),
            "http://h/rest/ping"
        );
    }
}
