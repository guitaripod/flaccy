//! The Last.fm keys of `config.toml` and the endpoints the server talks to.

use std::fmt;

use serde::Deserialize;

/// Where Last.fm answers.
pub const DEFAULT_API_URL: &str = "https://ws.audioscrobbler.com/2.0/";
/// Where the shared secret signs requests; the secret lives only on that Worker.
pub const DEFAULT_SIGN_URL: &str = "https://flaccy-api.midgarcorp.cc/v1/lastfm/sign";
/// The page a person approves the connection on.
pub const AUTH_PAGE_URL: &str = "https://www.last.fm/api/auth/";
const KEY_VARIABLE: &str = "FLACCY_LASTFM_KEY";
const KEY_LENGTH: usize = 32;

/// The `lastfm_*` settings of `config.toml`, all optional.
#[derive(Clone, Default, Deserialize, PartialEq, Eq)]
pub struct LastfmSettings {
    /// The application's Last.fm API key; the environment variable `FLACCY_LASTFM_KEY` is the fallback.
    #[serde(default)]
    pub lastfm_api_key: Option<String>,
    /// Another Last.fm API root, for tests and mirrors.
    #[serde(default)]
    pub lastfm_api_url: Option<String>,
    /// Another signing endpoint, for tests and mirrors.
    #[serde(default)]
    pub lastfm_sign_url: Option<String>,
}

impl fmt::Debug for LastfmSettings {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LastfmSettings")
            .field("lastfm_api_key", &self.lastfm_api_key.as_ref().map(|_| "<hidden>"))
            .field("lastfm_api_url", &self.lastfm_api_url)
            .field("lastfm_sign_url", &self.lastfm_sign_url)
            .finish()
    }
}

/// A key worth sending: 32 hex characters that are not one repeated character or a `YOUR_` placeholder.
fn usable(value: &str) -> Option<String> {
    let value = value.trim();
    let first = *value.as_bytes().first()?;
    let placeholder = value.starts_with("YOUR_") || value.bytes().all(|byte| byte == first);
    (!placeholder && value.len() == KEY_LENGTH && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .then(|| value.to_owned())
}

impl LastfmSettings {
    /// The API key from the file, else from the environment, when it is a real one.
    pub fn api_key(&self) -> Option<String> {
        self.lastfm_api_key
            .as_deref()
            .and_then(usable)
            .or_else(|| std::env::var(KEY_VARIABLE).ok().as_deref().and_then(usable))
    }

    /// The endpoints with the defaults filled in.
    pub fn endpoints(&self) -> Endpoints {
        Endpoints {
            api_url: self.lastfm_api_url.clone().unwrap_or_else(|| DEFAULT_API_URL.to_owned()),
            sign_url: self.lastfm_sign_url.clone().unwrap_or_else(|| DEFAULT_SIGN_URL.to_owned()),
        }
    }
}

/// The two URLs every call goes to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoints {
    /// The Last.fm API root.
    pub api_url: String,
    /// The signing endpoint of flaccy-api.
    pub sign_url: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn placeholders_and_short_keys_are_not_usable() {
        assert_eq!(usable("00000000000000000000000000000000"), None);
        assert_eq!(usable("YOUR_KEY"), None);
        assert_eq!(usable("abc"), None);
        assert!(usable("2a96cbd8b46e442fc41c2b86b821562f").is_some());
    }

    #[test]
    fn the_debug_form_hides_the_key() {
        let settings = LastfmSettings {
            lastfm_api_key: Some("2a96cbd8b46e442fc41c2b86b821562f".to_owned()),
            ..LastfmSettings::default()
        };
        assert!(!format!("{settings:?}").contains("2a96"));
    }
}
