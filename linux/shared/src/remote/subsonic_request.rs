//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/SubsonicRequest.swift`.
//!
//! The query string of a request to an OpenSubsonic server. The method's own
//! parameters come first, then the credentials, then the protocol version, the
//! client name and the response format. A password is never sent: the request
//! carries `t = md5(password + salt)` and the salt it was made with, which is
//! what the server checks. Every name and value is percent-encoded.

use super::percent_encode;
use serde::{Deserialize, Serialize};

pub const API_VERSION: &str = "1.16.1";
pub const CLIENT_NAME: &str = "flaccy";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Credentials {
    ApiKey(String),
    Password { username: String, password: String },
}

/// The URL of one API method. `md5_hex` hashes the string it is given to
/// lowercase hex, and only a password login calls it.
pub fn url(
    base: &str,
    method: &str,
    parameters: &[(&str, &str)],
    credentials: &Credentials,
    salt: &str,
    md5_hex: &dyn Fn(&str) -> String,
) -> String {
    let mut pairs: Vec<String> = parameters
        .iter()
        .map(|(name, value)| query_pair(name, value))
        .collect();
    match credentials {
        Credentials::ApiKey(key) => pairs.push(query_pair("apiKey", key)),
        Credentials::Password { username, password } => {
            pairs.push(query_pair("u", username));
            pairs.push(query_pair("t", &md5_hex(&format!("{password}{salt}"))));
            pairs.push(query_pair("s", salt));
        }
    }
    pairs.push(query_pair("v", API_VERSION));
    pairs.push(query_pair("c", CLIENT_NAME));
    pairs.push(query_pair("f", "json"));
    format!("{base}/rest/{method}?{}", pairs.join("&"))
}

fn query_pair(name: &str, value: &str) -> String {
    format!("{}={}", percent_encode(name), percent_encode(value))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fake_md5(input: &str) -> String {
        format!("md5({input})")
    }

    #[test]
    fn password_login_sends_a_salted_token_and_no_password() {
        let credentials = Credentials::Password {
            username: "ana".into(),
            password: "pw".into(),
        };
        assert_eq!(
            url(
                "https://h.example",
                "ping",
                &[],
                &credentials,
                "s1",
                &fake_md5
            ),
            "https://h.example/rest/ping?u=ana&t=md5%28pws1%29&s=s1&v=1.16.1&c=flaccy&f=json"
        );
    }

    #[test]
    fn api_key_login_encodes_the_method_parameters_in_order() {
        let credentials = Credentials::ApiKey("K+1".into());
        assert_eq!(
            url(
                "https://h.example/nd",
                "getAlbum",
                &[("id", "a b/ç")],
                &credentials,
                "x",
                &fake_md5
            ),
            "https://h.example/nd/rest/getAlbum?id=a%20b%2F%C3%A7&apiKey=K%2B1&v=1.16.1&c=flaccy&f=json"
        );
    }

    #[test]
    fn stream_parameters_come_before_the_password_auth() {
        let credentials = Credentials::Password {
            username: "ana".into(),
            password: "pw".into(),
        };
        assert_eq!(
            url(
                "https://h.example",
                "stream",
                &[("id", "42"), ("format", "raw")],
                &credentials,
                "s1",
                &fake_md5
            ),
            "https://h.example/rest/stream?id=42&format=raw&u=ana&t=md5%28pws1%29&s=s1&v=1.16.1&c=flaccy&f=json"
        );
    }
}
