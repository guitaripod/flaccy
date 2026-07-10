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

    /// POSTs with iOS performWithBackoff semantics: an in-body error 29 (rate
    /// limit) is retried with exponential backoff (1s/2s/4s) up to three extra
    /// attempts before the response is returned as-is.
    fn signed_post(&self, params: BTreeMap<String, String>) -> Result<serde_json::Value, String> {
        let body = self.signed_query(&params);
        let mut attempt = 0;
        loop {
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
            let json: serde_json::Value =
                serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
            if json["error"].as_i64() == Some(29) && attempt < 3 {
                std::thread::sleep(Duration::from_secs(1 << attempt));
                attempt += 1;
                continue;
            }
            return Ok(json);
        }
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

    fn unsigned_get(&self, params: BTreeMap<String, String>) -> Result<serde_json::Value, String> {
        let mut query: Vec<String> = params
            .iter()
            .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
            .collect();
        query.push("format=json".to_string());
        let url = format!("{}?{}", BASE_URL, query.join("&"));
        let response = Self::agent().get(&url).call();
        let text = match response {
            Ok(resp) => resp.into_string().map_err(|e| format!("{e}"))?,
            Err(ureq::Error::Status(_, resp)) => resp.into_string().map_err(|e| format!("{e}"))?,
            Err(e) => return Err(format!("{e}")),
        };
        serde_json::from_str(&text).map_err(|e| format!("{e}"))
    }

    /// album.getInfo → (largest image URL, musicBrainzID).
    pub fn fetch_album_info(
        &self,
        artist: &str,
        album: &str,
    ) -> Result<(Option<String>, Option<String>), String> {
        let mut params = self.base_params("album.getInfo");
        params.insert("artist".to_string(), artist.to_string());
        params.insert("album".to_string(), album.to_string());
        params.insert("autocorrect".to_string(), "1".to_string());
        let json = self.unsigned_get(params)?;
        let album_dict = &json["album"];
        if album_dict.is_null() {
            return Err(format!("album.getInfo: {}", json["message"].as_str().unwrap_or("no album")));
        }
        Ok((
            largest_image(&album_dict["image"]),
            album_dict["mbid"].as_str().filter(|s| !s.is_empty()).map(String::from),
        ))
    }

    /// artist.getInfo → (bio summary, image URL, musicBrainzID).
    pub fn fetch_artist_info(
        &self,
        artist: &str,
    ) -> Result<(Option<String>, Option<String>, Option<String>), String> {
        let mut params = self.base_params("artist.getInfo");
        params.insert("artist".to_string(), artist.to_string());
        params.insert("autocorrect".to_string(), "1".to_string());
        let json = self.unsigned_get(params)?;
        let dict = &json["artist"];
        if dict.is_null() {
            return Err(format!("artist.getInfo: {}", json["message"].as_str().unwrap_or("no artist")));
        }
        let bio = dict["bio"]["summary"]
            .as_str()
            .map(strip_lastfm_link)
            .filter(|s| !s.is_empty());
        Ok((
            bio,
            largest_image(&dict["image"]),
            dict["mbid"].as_str().filter(|s| !s.is_empty()).map(String::from),
        ))
    }

    /// artist.getSimilar (limit 100) → [(name, match)].
    pub fn fetch_similar_artists(&self, artist: &str) -> Result<Vec<(String, f64)>, String> {
        let mut params = self.base_params("artist.getSimilar");
        params.insert("artist".to_string(), artist.to_string());
        params.insert("autocorrect".to_string(), "1".to_string());
        params.insert("limit".to_string(), "100".to_string());
        let json = self.unsigned_get(params)?;
        let list = json["similarartists"]["artist"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        Ok(list
            .iter()
            .filter_map(|entry| {
                let name = entry["name"].as_str()?.to_string();
                let matched = entry["match"]
                    .as_f64()
                    .or_else(|| entry["match"].as_str().and_then(|s| s.parse().ok()))
                    .unwrap_or(0.0);
                Some((name, matched))
            })
            .collect())
    }

    /// user.getRecentTracks for history import. Returns (tracks, totalPages)
    /// where each track is (uts, title, artist, album); now-playing rows carry
    /// no uts and are skipped.
    pub fn fetch_recent_tracks(
        &self,
        username: &str,
        page: u32,
        limit: u32,
    ) -> Result<(Vec<(i64, String, String, String)>, u32), String> {
        let mut params = self.base_params("user.getRecentTracks");
        params.insert("user".to_string(), username.to_string());
        params.insert("page".to_string(), page.to_string());
        params.insert("limit".to_string(), limit.to_string());
        let json = self.unsigned_get(params)?;
        let recent = &json["recenttracks"];
        if recent.is_null() {
            return Err(format!(
                "user.getRecentTracks: {}",
                json["message"].as_str().unwrap_or("no data")
            ));
        }
        let total_pages = recent["@attr"]["totalPages"]
            .as_str()
            .and_then(|s| s.parse().ok())
            .or_else(|| recent["@attr"]["totalPages"].as_u64().map(|v| v as u32))
            .unwrap_or(1);
        let list: Vec<serde_json::Value> = match &recent["track"] {
            serde_json::Value::Array(array) => array.clone(),
            single @ serde_json::Value::Object(_) => vec![single.clone()],
            _ => Vec::new(),
        };
        let tracks = list
            .iter()
            .filter_map(|entry| {
                let uts = entry["date"]["uts"]
                    .as_str()
                    .and_then(|s| s.parse::<i64>().ok())?;
                let title = entry["name"].as_str()?.to_string();
                let artist = entry["artist"]["#text"]
                    .as_str()
                    .or_else(|| entry["artist"]["name"].as_str())
                    .unwrap_or("")
                    .to_string();
                let album = entry["album"]["#text"].as_str().unwrap_or("").to_string();
                Some((uts, title, artist, album))
            })
            .collect();
        Ok((tracks, total_pages))
    }

    /// user.getTopArtists → [(name, playCount)] ranked.
    pub fn fetch_top_artists(
        &self,
        username: &str,
        period: &str,
        limit: u32,
    ) -> Result<Vec<(String, i64)>, String> {
        let mut params = self.base_params("user.getTopArtists");
        params.insert("user".to_string(), username.to_string());
        params.insert("period".to_string(), period.to_string());
        params.insert("limit".to_string(), limit.to_string());
        let json = self.unsigned_get(params)?;
        let list = as_object_list(&json["topartists"]["artist"]);
        Ok(list
            .iter()
            .filter_map(|entry| {
                Some((entry["name"].as_str()?.to_string(), int_value(&entry["playcount"])))
            })
            .collect())
    }

    /// user.getTopAlbums → [(album, artist, playCount, imageURL)] ranked.
    pub fn fetch_top_albums(
        &self,
        username: &str,
        period: &str,
        limit: u32,
    ) -> Result<Vec<(String, String, i64, Option<String>)>, String> {
        let mut params = self.base_params("user.getTopAlbums");
        params.insert("user".to_string(), username.to_string());
        params.insert("period".to_string(), period.to_string());
        params.insert("limit".to_string(), limit.to_string());
        let json = self.unsigned_get(params)?;
        let list = as_object_list(&json["topalbums"]["album"]);
        Ok(list
            .iter()
            .filter_map(|entry| {
                Some((
                    entry["name"].as_str()?.to_string(),
                    entry["artist"]["name"]
                        .as_str()
                        .or_else(|| entry["artist"]["#text"].as_str())
                        .unwrap_or("")
                        .to_string(),
                    int_value(&entry["playcount"]),
                    largest_image(&entry["image"]),
                ))
            })
            .collect())
    }

    /// user.getTopTracks → [(title, artist, playCount)] ranked.
    pub fn fetch_top_tracks(
        &self,
        username: &str,
        period: &str,
        limit: u32,
    ) -> Result<Vec<(String, String, i64)>, String> {
        let mut params = self.base_params("user.getTopTracks");
        params.insert("user".to_string(), username.to_string());
        params.insert("period".to_string(), period.to_string());
        params.insert("limit".to_string(), limit.to_string());
        let json = self.unsigned_get(params)?;
        let list = as_object_list(&json["toptracks"]["track"]);
        Ok(list
            .iter()
            .filter_map(|entry| {
                Some((
                    entry["name"].as_str()?.to_string(),
                    entry["artist"]["name"]
                        .as_str()
                        .or_else(|| entry["artist"]["#text"].as_str())
                        .unwrap_or("")
                        .to_string(),
                    int_value(&entry["playcount"]),
                ))
            })
            .collect())
    }

    /// user.getLovedTracks → ([(title, artist)], totalPages).
    pub fn fetch_loved_tracks(
        &self,
        username: &str,
        page: u32,
        limit: u32,
    ) -> Result<(Vec<(String, String)>, u32), String> {
        let mut params = self.base_params("user.getLovedTracks");
        params.insert("user".to_string(), username.to_string());
        params.insert("page".to_string(), page.to_string());
        params.insert("limit".to_string(), limit.to_string());
        let json = self.unsigned_get(params)?;
        let loved = &json["lovedtracks"];
        if loved.is_null() {
            return Err(format!(
                "user.getLovedTracks: {}",
                json["message"].as_str().unwrap_or("no data")
            ));
        }
        let total_pages = loved["@attr"]["totalPages"]
            .as_str()
            .and_then(|s| s.parse().ok())
            .or_else(|| loved["@attr"]["totalPages"].as_u64().map(|v| v as u32))
            .unwrap_or(1);
        let tracks = as_object_list(&loved["track"])
            .iter()
            .filter_map(|entry| {
                Some((
                    entry["name"].as_str()?.to_string(),
                    entry["artist"]["name"]
                        .as_str()
                        .or_else(|| entry["artist"]["#text"].as_str())
                        .unwrap_or("")
                        .to_string(),
                ))
            })
            .collect();
        Ok((tracks, total_pages))
    }

    /// artist.getTopTags → first `limit` tag names.
    pub fn fetch_top_tags(&self, artist: &str, limit: usize) -> Result<Vec<String>, String> {
        let mut params = self.base_params("artist.getTopTags");
        params.insert("artist".to_string(), artist.to_string());
        params.insert("autocorrect".to_string(), "1".to_string());
        let json = self.unsigned_get(params)?;
        Ok(as_object_list(&json["toptags"]["tag"])
            .iter()
            .filter_map(|entry| entry["name"].as_str().map(String::from))
            .take(limit)
            .collect())
    }

    /// artist.getTopAlbums → [(album, artist, imageURL)] ranked.
    pub fn fetch_artist_top_albums(
        &self,
        artist: &str,
        limit: u32,
    ) -> Result<Vec<(String, String, Option<String>)>, String> {
        let mut params = self.base_params("artist.getTopAlbums");
        params.insert("artist".to_string(), artist.to_string());
        params.insert("autocorrect".to_string(), "1".to_string());
        params.insert("limit".to_string(), limit.to_string());
        let json = self.unsigned_get(params)?;
        Ok(as_object_list(&json["topalbums"]["album"])
            .iter()
            .filter_map(|entry| {
                Some((
                    entry["name"].as_str()?.to_string(),
                    entry["artist"]["name"]
                        .as_str()
                        .or_else(|| entry["artist"]["#text"].as_str())
                        .unwrap_or("")
                        .to_string(),
                    largest_image(&entry["image"]),
                ))
            })
            .collect())
    }

    /// album.getInfo with username → the user's personal play count.
    pub fn fetch_album_user_playcount(
        &self,
        artist: &str,
        album: &str,
        username: &str,
    ) -> Result<Option<i64>, String> {
        let mut params = self.base_params("album.getInfo");
        params.insert("artist".to_string(), artist.to_string());
        params.insert("album".to_string(), album.to_string());
        params.insert("autocorrect".to_string(), "1".to_string());
        params.insert("username".to_string(), username.to_string());
        let json = self.unsigned_get(params)?;
        let value = &json["album"]["userplaycount"];
        if value.is_null() {
            return Ok(None);
        }
        Ok(Some(int_value(value)))
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

/// Picks the largest usable image URL from a Last.fm image array
/// (mega → extralarge → large → medium → small), skipping empty entries.
fn largest_image(images: &serde_json::Value) -> Option<String> {
    let list = images.as_array()?;
    for wanted in ["mega", "extralarge", "large", "medium", "small"] {
        for entry in list {
            if entry["size"].as_str() == Some(wanted) {
                if let Some(url) = entry["#text"].as_str().filter(|s| !s.is_empty()) {
                    return Some(url.to_string());
                }
            }
        }
    }
    list.iter()
        .rev()
        .find_map(|entry| entry["#text"].as_str().filter(|s| !s.is_empty()).map(String::from))
}

/// Removes the trailing `<a href="https://www.last.fm/...">Read more…</a>`
/// boilerplate Last.fm appends to bio summaries.
fn strip_lastfm_link(bio: &str) -> String {
    match bio.find("<a href") {
        Some(index) => bio[..index].trim().to_string(),
        None => bio.trim().to_string(),
    }
}

/// Last.fm returns a single object instead of an array when a list has exactly
/// one entry; this normalizes both shapes.
fn as_object_list(value: &serde_json::Value) -> Vec<serde_json::Value> {
    match value {
        serde_json::Value::Array(array) => array.clone(),
        single @ serde_json::Value::Object(_) => vec![single.clone()],
        _ => Vec::new(),
    }
}

/// Numeric fields arrive as strings or numbers depending on the endpoint.
fn int_value(value: &serde_json::Value) -> i64 {
    value
        .as_i64()
        .or_else(|| value.as_str().and_then(|s| s.parse().ok()))
        .unwrap_or(0)
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
