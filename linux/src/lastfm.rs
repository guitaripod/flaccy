use md5::{Digest, Md5};
use std::collections::BTreeMap;
use std::time::Duration;

pub const API_KEY: Option<&str> = option_env!("FLACCY_LASTFM_KEY");
pub const API_SECRET: Option<&str> = option_env!("FLACCY_LASTFM_SECRET");
const BASE_URL: &str = "https://ws.audioscrobbler.com/2.0/";

pub fn keys_available() -> bool {
    matches!((API_KEY, API_SECRET), (Some(k), Some(s)) if !k.is_empty() && !s.is_empty())
}

#[derive(Clone)]
pub struct LastFmClient {
    pub api_key: String,
    pub api_secret: String,
    pub session_key: Option<String>,
}

pub struct ScrobbleEntry {
    pub id: i64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub timestamp: i64,
    pub duration: i64,
}

pub enum BatchOutcome {
    Retryable { code: i64, message: String },
    Submitted(Vec<i64>),
}

impl LastFmClient {
    pub fn new(session_key: Option<String>) -> Option<Self> {
        match (API_KEY, API_SECRET) {
            (Some(key), Some(secret)) if !key.is_empty() && !secret.is_empty() => Some(Self {
                api_key: key.to_string(),
                api_secret: secret.to_string(),
                session_key,
            }),
            _ => None,
        }
    }

    fn agent() -> ureq::Agent {
        ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(15))
            .build()
    }

    fn signature(&self, params: &BTreeMap<String, String>) -> String {
        let mut concatenated = String::new();
        for (key, value) in params {
            if key == "format" {
                continue;
            }
            concatenated.push_str(key);
            concatenated.push_str(value);
        }
        concatenated.push_str(&self.api_secret);
        let digest = Md5::digest(concatenated.as_bytes());
        digest.iter().map(|b| format!("{:02x}", b)).collect()
    }

    fn signed_query(&self, params: &BTreeMap<String, String>) -> String {
        let signature = self.signature(params);
        let mut all = params.clone();
        all.insert("api_sig".to_string(), signature);
        all.insert("format".to_string(), "json".to_string());
        all.iter()
            .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
            .collect::<Vec<_>>()
            .join("&")
    }

    fn signed_get(&self, params: BTreeMap<String, String>) -> Result<serde_json::Value, String> {
        let url = format!("{}?{}", BASE_URL, self.signed_query(&params));
        let response = Self::agent()
            .get(&url)
            .call()
            .map_err(|e| format!("{e}"))?;
        let text = response.into_string().map_err(|e| format!("{e}"))?;
        serde_json::from_str(&text).map_err(|e| format!("{e}"))
    }

    fn signed_post(&self, params: BTreeMap<String, String>) -> Result<serde_json::Value, String> {
        let body = self.signed_query(&params);
        let response = Self::agent()
            .post(BASE_URL)
            .set("Content-Type", "application/x-www-form-urlencoded")
            .send_string(&body);
        let text = match response {
            Ok(resp) => resp.into_string().map_err(|e| format!("{e}"))?,
            Err(ureq::Error::Status(_, resp)) => {
                resp.into_string().map_err(|e| format!("{e}"))?
            }
            Err(e) => return Err(format!("{e}")),
        };
        serde_json::from_str(&text).map_err(|e| format!("{e}"))
    }

    fn base_params(&self, method: &str) -> BTreeMap<String, String> {
        let mut params = BTreeMap::new();
        params.insert("method".to_string(), method.to_string());
        params.insert("api_key".to_string(), self.api_key.clone());
        params
    }

    pub fn get_token(&self) -> Result<String, String> {
        let json = self.signed_get(self.base_params("auth.getToken"))?;
        json["token"]
            .as_str()
            .map(|s| s.to_string())
            .ok_or_else(|| format!("no token in response: {json}"))
    }

    pub fn get_session(&self, token: &str) -> Result<(String, String), String> {
        let mut params = self.base_params("auth.getSession");
        params.insert("token".to_string(), token.to_string());
        let json = self.signed_get(params)?;
        let session = &json["session"];
        match (session["key"].as_str(), session["name"].as_str()) {
            (Some(key), Some(name)) => Ok((key.to_string(), name.to_string())),
            _ => Err(format!("auth.getSession failed: {json}")),
        }
    }

    pub fn update_now_playing(&self, title: &str, artist: &str, album: &str, duration: i64) {
        let Some(sk) = &self.session_key else { return };
        let mut params = self.base_params("track.updateNowPlaying");
        params.insert("sk".to_string(), sk.clone());
        params.insert("track".to_string(), title.to_string());
        params.insert("artist".to_string(), artist.to_string());
        params.insert("album".to_string(), album.to_string());
        if duration > 0 {
            params.insert("duration".to_string(), duration.to_string());
        }
        if let Err(err) = self.signed_post(params) {
            crate::logger::warn("scrobble", &format!("updateNowPlaying failed: {err}"));
        }
    }

    /// Submits one batch (≤50) with iOS-identical semantics: top-level errors
    /// 11/16/29 are retryable (rows stay pending); a parsed per-entry response
    /// marks every entry submitted — accepted or ignored (code 3 = too old
    /// still counts as submitted); an accepted-count fallback submits the whole
    /// batch only when the count is positive.
    pub fn scrobble_batch(&self, batch: &[ScrobbleEntry]) -> Result<BatchOutcome, String> {
        let Some(sk) = &self.session_key else {
            return Err("not authenticated".to_string());
        };
        let mut params = self.base_params("track.scrobble");
        params.insert("sk".to_string(), sk.clone());
        for (i, entry) in batch.iter().enumerate() {
            params.insert(format!("track[{i}]"), entry.title.clone());
            params.insert(format!("artist[{i}]"), entry.artist.clone());
            params.insert(format!("album[{i}]"), entry.album.clone());
            params.insert(format!("timestamp[{i}]"), entry.timestamp.to_string());
            if entry.duration > 0 {
                params.insert(format!("duration[{i}]"), entry.duration.to_string());
            }
            params.insert(format!("chosenByUser[{i}]"), "1".to_string());
        }
        let json = self.signed_post(params)?;

        if let Some(code) = json["error"].as_i64() {
            let message = json["message"].as_str().unwrap_or("").to_string();
            if [11, 16, 29].contains(&code) {
                return Ok(BatchOutcome::Retryable { code, message });
            }
            return Err(format!("scrobble error {code}: {message}"));
        }

        let scrobbles = &json["scrobbles"];
        let entries: Vec<&serde_json::Value> = match &scrobbles["scrobble"] {
            serde_json::Value::Array(array) => array.iter().collect(),
            single @ serde_json::Value::Object(_) => vec![single],
            _ => Vec::new(),
        };

        if entries.len() == batch.len() {
            let mut submitted = Vec::new();
            for (entry, response) in batch.iter().zip(entries) {
                let code = ignored_code(response);
                if code != 0 {
                    crate::logger::info(
                        "scrobble",
                        &format!("scrobble ignored (code {code}): {} — {}", entry.title, entry.artist),
                    );
                }
                submitted.push(entry.id);
            }
            return Ok(BatchOutcome::Submitted(submitted));
        }

        let accepted = scrobbles["@attr"]["accepted"].as_i64().unwrap_or(0);
        if accepted > 0 {
            Ok(BatchOutcome::Submitted(batch.iter().map(|e| e.id).collect()))
        } else {
            Ok(BatchOutcome::Retryable {
                code: 0,
                message: "accepted 0".to_string(),
            })
        }
    }

    pub fn set_love(&self, title: &str, artist: &str, love: bool) -> Result<(), String> {
        let Some(sk) = &self.session_key else {
            return Err("not authenticated".to_string());
        };
        let method = if love { "track.love" } else { "track.unlove" };
        let mut params = self.base_params(method);
        params.insert("sk".to_string(), sk.clone());
        params.insert("track".to_string(), title.to_string());
        params.insert("artist".to_string(), artist.to_string());
        let json = self.signed_post(params)?;
        if let Some(code) = json["error"].as_i64() {
            return Err(format!(
                "{method} error {code}: {}",
                json["message"].as_str().unwrap_or("")
            ));
        }
        Ok(())
    }
}

fn ignored_code(entry: &serde_json::Value) -> i64 {
    let ignored = &entry["ignoredMessage"];
    ignored["@attr"]["code"]
        .as_i64()
        .or_else(|| ignored["@attr"]["code"].as_str().and_then(|s| s.parse().ok()))
        .or_else(|| ignored["code"].as_i64())
        .or_else(|| ignored["code"].as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0)
}

pub fn auth_url(api_key: &str, token: &str) -> String {
    format!("https://www.last.fm/api/auth/?api_key={api_key}&token={token}")
}

/// Custom percent-encoding matching iOS: URL-query-allowed characters minus
/// `+`, `&`, and `=` so signatures survive transport verbatim.
fn percent_encode(input: &str) -> String {
    const EXTRA_ALLOWED: &[u8] = b"!$'()*,-./:;?@_~";
    let mut result = String::with_capacity(input.len() * 3);
    for byte in input.as_bytes() {
        if byte.is_ascii_alphanumeric() || EXTRA_ALLOWED.contains(byte) {
            result.push(*byte as char);
        } else {
            result.push_str(&format!("%{:02X}", byte));
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_encoding_removes_plus_amp_equals() {
        assert_eq!(percent_encode("a+b&c=d"), "a%2Bb%26c%3Dd");
        assert_eq!(percent_encode("hello world"), "hello%20world");
        assert_eq!(percent_encode("a.b-c_d~e"), "a.b-c_d~e");
    }
}
