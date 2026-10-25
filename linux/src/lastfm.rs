use std::collections::BTreeMap;
use std::sync::OnceLock;
use std::time::Duration;

pub const API_KEY: Option<&str> = option_env!("FLACCY_LASTFM_KEY");
const BASE_URL: &str = "https://ws.audioscrobbler.com/2.0/";
const SIGN_URL: &str = "https://flaccy-api.midgarcorp.cc/v1/lastfm/sign";

/// A credential the build actually stamped in, as opposed to a blank or a
/// placeholder. `build.rs` filters these too, but the check lives here as well
/// so a binary built by any other route can't offer a scrobbling UI that sends
/// every request with a dud key and fails at Last.fm instead of at the door.
fn usable(value: Option<&str>) -> Option<&str> {
    let value = value?.trim();
    let first = *value.as_bytes().first()?;
    if value.starts_with("YOUR_") || value.bytes().all(|byte| byte == first) {
        return None;
    }
    Some(value)
}

pub fn api_key() -> Option<&'static str> {
    usable(API_KEY)
}

pub fn keys_available() -> bool {
    api_key().is_some()
}

/// Sixteen random bytes in a UUID's shape: flaccy-api rate-limits per device and
/// accepts only a v4 UUID in `X-Device-ID`.
fn new_device_id() -> String {
    let mut bytes: [u8; 16] = rand::random();
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// The anonymous per-install identifier flaccy-api counts quota against,
/// created on first use and kept in the config directory so it survives
/// restarts. If the file can't be written the id lasts for the process only.
fn device_id() -> &'static str {
    static DEVICE_ID: OnceLock<String> = OnceLock::new();
    DEVICE_ID.get_or_init(|| {
        let path = crate::config::config_dir().join("device-id");
        if let Ok(existing) = std::fs::read_to_string(&path) {
            let existing = existing.trim();
            if is_device_id(existing) {
                return existing.to_string();
            }
        }
        let fresh = new_device_id();
        let _ = std::fs::create_dir_all(crate::config::config_dir());
        let _ = std::fs::write(&path, &fresh);
        fresh
    })
}

fn is_device_id(value: &str) -> bool {
    let groups: Vec<&str> = value.split('-').collect();
    groups.len() == 5
        && groups
            .iter()
            .zip([8, 4, 4, 4, 12])
            .all(|(group, len)| group.len() == len && group.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// One page of scrobbles as `(uts, title, artist, album)`, newest first, with
/// the page count.
pub type RecentPage = (Vec<(i64, String, String, String)>, u32);

/// The stretch of history a `user.getRecentTracks` page reads, in Unix
/// seconds; `None` leaves that end open.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RecentWindow {
    pub from: Option<i64>,
    pub to: Option<i64>,
}

#[derive(Clone)]
pub struct LastFmClient {
    pub api_key: String,
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
        Some(Self {
            api_key: api_key()?.to_string(),
            session_key,
        })
    }

    fn agent() -> ureq::Agent {
        ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(15))
            .build()
    }

    /// Asks flaccy-api for the `api_sig` of `params`. Last.fm's shared secret
    /// lives only on that Worker, so no build of the player can leak it.
    fn signature(&self, params: &BTreeMap<String, String>) -> Result<String, String> {
        let response = Self::agent()
            .post(SIGN_URL)
            .set("X-Device-ID", device_id())
            .send_json(serde_json::json!({ "params": params }));
        let json: serde_json::Value = match response {
            Ok(resp) => resp.into_json().map_err(|e| format!("{e}"))?,
            Err(ureq::Error::Status(code, _)) => {
                return Err(format!("signing failed (HTTP {code})"));
            }
            Err(e) => return Err(format!("{e}")),
        };
        json["api_sig"]
            .as_str()
            .map(str::to_string)
            .ok_or_else(|| format!("no api_sig in response: {json}"))
    }

    fn signed_query(&self, params: &BTreeMap<String, String>) -> Result<String, String> {
        let signature = self.signature(params)?;
        let mut all = params.clone();
        all.insert("api_sig".to_string(), signature);
        all.insert("format".to_string(), "json".to_string());
        Ok(all
            .iter()
            .map(|(k, v)| format!("{}={}", percent_encode(k), percent_encode(v)))
            .collect::<Vec<_>>()
            .join("&"))
    }

    fn signed_get(&self, params: BTreeMap<String, String>) -> Result<serde_json::Value, String> {
        let url = format!("{}?{}", BASE_URL, self.signed_query(&params)?);
        let response = Self::agent().get(&url).call().map_err(|e| format!("{e}"))?;
        let text = response.into_string().map_err(|e| format!("{e}"))?;
        serde_json::from_str(&text).map_err(|e| format!("{e}"))
    }

    /// POSTs with iOS performWithBackoff semantics: an in-body error 29 (rate
    /// limit) is retried with exponential backoff (1s/2s/4s) up to three extra
    /// attempts before the response is returned as-is.
    fn signed_post(&self, params: BTreeMap<String, String>) -> Result<serde_json::Value, String> {
        let body = self.signed_query(&params)?;
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
                        &format!(
                            "scrobble ignored (code {code}): {} — {}",
                            entry.title, entry.artist
                        ),
                    );
                }
                submitted.push(entry.id);
            }
            return Ok(BatchOutcome::Submitted(submitted));
        }

        let accepted = scrobbles["@attr"]["accepted"].as_i64().unwrap_or(0);
        if accepted > 0 {
            Ok(BatchOutcome::Submitted(
                batch.iter().map(|e| e.id).collect(),
            ))
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
            return Err(format!(
                "album.getInfo: {}",
                json["message"].as_str().unwrap_or("no album")
            ));
        }
        Ok((
            largest_image(&album_dict["image"]),
            album_dict["mbid"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(String::from),
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
            return Err(format!(
                "artist.getInfo: {}",
                json["message"].as_str().unwrap_or("no artist")
            ));
        }
        let bio = dict["bio"]["summary"]
            .as_str()
            .map(strip_lastfm_link)
            .filter(|s| !s.is_empty());
        Ok((
            bio,
            largest_image(&dict["image"]),
            dict["mbid"]
                .as_str()
                .filter(|s| !s.is_empty())
                .map(String::from),
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
    /// One page of `user.getRecentTracks`, newest first, of the scrobbles
    /// stamped in `[from, to]` (either end open), with the page count. The
    /// track playing right now carries no date and is left out.
    pub fn fetch_recent_tracks(
        &self,
        username: &str,
        page: u32,
        limit: u32,
        window: RecentWindow,
    ) -> Result<RecentPage, String> {
        let mut params = self.base_params("user.getRecentTracks");
        params.insert("user".to_string(), username.to_string());
        params.insert("page".to_string(), page.to_string());
        params.insert("limit".to_string(), limit.to_string());
        if let Some(from) = window.from {
            params.insert("from".to_string(), from.to_string());
        }
        if let Some(to) = window.to {
            params.insert("to".to_string(), to.to_string());
        }
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
                Some((
                    entry["name"].as_str()?.to_string(),
                    int_value(&entry["playcount"]),
                ))
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

    /// artist.getTopTracks — what the world plays most by this artist, which is
    /// what the artist page leads with once it is matched against the library.
    pub fn fetch_artist_top_tracks(&self, artist: &str, limit: u32) -> Result<Vec<String>, String> {
        let mut params = self.base_params("artist.getTopTracks");
        params.insert("artist".to_string(), artist.to_string());
        params.insert("autocorrect".to_string(), "1".to_string());
        params.insert("limit".to_string(), limit.to_string());
        let json = self.unsigned_get(params)?;
        Ok(as_object_list(&json["toptracks"]["track"])
            .iter()
            .filter_map(|entry| Some(entry["name"].as_str()?.to_string()))
            .collect())
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
    list.iter().rev().find_map(|entry| {
        entry["#text"]
            .as_str()
            .filter(|s| !s.is_empty())
            .map(String::from)
    })
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
        .or_else(|| {
            ignored["@attr"]["code"]
                .as_str()
                .and_then(|s| s.parse().ok())
        })
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

    #[test]
    fn generated_device_ids_are_v4_uuids_flaccy_api_accepts() {
        let id = new_device_id();
        assert!(is_device_id(&id));
        assert_eq!(id.as_bytes()[14], b'4');
        assert!(matches!(id.as_bytes()[19], b'8' | b'9' | b'a' | b'b'));
        assert_ne!(id, new_device_id());
        assert!(!is_device_id("not-a-uuid"));
    }

    #[test]
    fn placeholder_credentials_count_as_no_credentials() {
        assert_eq!(usable(None), None);
        assert_eq!(usable(Some("")), None);
        assert_eq!(usable(Some("   ")), None);
        assert_eq!(usable(Some(&"0".repeat(32))), None);
        assert_eq!(usable(Some("YOUR_LASTFM_API_KEY")), None);
        let real = "9da251ce70d797e81824def66504aca2";
        assert_eq!(usable(Some(real)), Some(real));
    }
}
