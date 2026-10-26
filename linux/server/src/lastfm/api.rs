//! The blocking Last.fm client: the public read call, and the signed calls that go through flaccy-api's signer.
//!
//! Callers run these on a blocking thread. No message or `Debug` output holds the API key or a session key.

use std::collections::BTreeMap;
use std::fmt;
use std::time::Duration;

use serde_json::{json, Value};

use super::error::ApiError;
use super::settings::{Endpoints, AUTH_PAGE_URL};

const SIGNED_METHODS: [&str; 4] = ["auth.getToken", "auth.getSession", "track.scrobble", "track.updateNowPlaying"];
const REQUEST_TIMEOUT: Duration = Duration::from_secs(20);
const RATE_LIMITED_STATUS: u16 = 429;
const SERVER_ERROR_FLOOR: u16 = 500;

/// One page of `user.getRecentTracks`: `(uts, title, artist, album)`, newest first, and the page count.
pub type RecentPage = (Vec<RecentTrack>, u32);

/// One dated scrobble read from Last.fm.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecentTrack {
    /// Unix seconds the play was scrobbled at.
    pub uts: i64,
    /// The track title.
    pub title: String,
    /// The artist name.
    pub artist: String,
    /// The album title, empty when unknown.
    pub album: String,
}

/// The stretch of history a page reads, in Unix seconds; `None` leaves that end open.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RecentWindow {
    /// Oldest scrobble wanted.
    pub from: Option<i64>,
    /// Newest scrobble wanted.
    pub to: Option<i64>,
}

/// A play to submit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScrobbleEntry {
    /// The track title.
    pub title: String,
    /// The artist name.
    pub artist: String,
    /// The album title, empty when unknown.
    pub album: String,
    /// Unix seconds the play started.
    pub timestamp: i64,
    /// The song's length in seconds, 0 when unknown.
    pub duration_s: i64,
}

/// What Last.fm made of a submitted batch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ScrobbleOutcome {
    /// Every entry was answered one by one, accepted or ignored (an ignored duplicate counts as done).
    Done {
        /// Entries Last.fm ignored.
        ignored: usize,
    },
    /// Last.fm accepted nothing and gave no per-entry answer; submit again later.
    NothingAccepted,
}

/// A session Last.fm granted.
pub struct SessionGrant {
    /// The session key; never log it.
    pub key: String,
    /// The Last.fm account name.
    pub name: String,
}

impl fmt::Debug for SessionGrant {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("SessionGrant").field("key", &"<hidden>").field("name", &self.name).finish()
    }
}

/// A Last.fm client with the application key and the device id the signer counts quota against.
#[derive(Clone)]
pub struct LastfmApi {
    endpoints: Endpoints,
    api_key: String,
    device_id: String,
    agent: ureq::Agent,
}

impl fmt::Debug for LastfmApi {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.debug_struct("LastfmApi").field("endpoints", &self.endpoints).finish_non_exhaustive()
    }
}

impl LastfmApi {
    /// A client for `endpoints`; `device_id` goes to the signer as `X-Device-ID`.
    pub fn new(endpoints: Endpoints, api_key: String, device_id: String) -> Self {
        let agent = ureq::AgentBuilder::new().timeout(REQUEST_TIMEOUT).build();
        Self { endpoints, api_key, device_id, agent }
    }

    /// The page a person opens to approve `token`.
    pub fn authorisation_url(&self, token: &str) -> String {
        format!("{AUTH_PAGE_URL}?api_key={}&token={token}", self.api_key)
    }

    fn base_params(&self, method: &str) -> BTreeMap<String, String> {
        BTreeMap::from([("method".to_owned(), method.to_owned()), ("api_key".to_owned(), self.api_key.clone())])
    }

    /// Asks the Worker for the `api_sig` of `params`; only the four methods the server needs are sent.
    fn sign(&self, params: &BTreeMap<String, String>) -> Result<String, ApiError> {
        let method = params.get("method").map(String::as_str).unwrap_or_default();
        if !SIGNED_METHODS.contains(&method) {
            return Err(ApiError::signer(format!("the signer is not asked to sign {method}; this is a bug in flaccy-server")));
        }
        let response = self
            .agent
            .post(&self.endpoints.sign_url)
            .set("X-Device-ID", &self.device_id)
            .send_json(json!({ "params": params }));
        let body: Value = match response {
            Ok(reply) => reply.into_json().map_err(|_| ApiError::signer("the signer answered with something that is not JSON; try again later"))?,
            Err(ureq::Error::Status(status, _)) => {
                return Err(ApiError::signer(format!(
                    "the signer answered HTTP {status}; the server tries again, and if this lasts the signer or its daily quota is the cause"
                )))
            }
            Err(ureq::Error::Transport(transport)) => return Err(transport_error("the signer", &transport)),
        };
        body["api_sig"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| ApiError::signer("the signer's answer had no api_sig; try again later"))
    }

    fn signed_params(&self, mut params: BTreeMap<String, String>) -> Result<BTreeMap<String, String>, ApiError> {
        let signature = self.sign(&params)?;
        params.insert("api_sig".to_owned(), signature);
        params.insert("format".to_owned(), "json".to_owned());
        Ok(params)
    }

    fn get(&self, params: &BTreeMap<String, String>) -> Result<Value, ApiError> {
        let mut request = self.agent.get(&self.endpoints.api_url);
        for (name, value) in params {
            request = request.query(name, value);
        }
        parse_reply(request.call())
    }

    fn post(&self, params: &BTreeMap<String, String>) -> Result<Value, ApiError> {
        let pairs: Vec<(&str, &str)> = params.iter().map(|(name, value)| (name.as_str(), value.as_str())).collect();
        parse_reply(self.agent.post(&self.endpoints.api_url).send_form(&pairs))
    }

    /// One page of `user.getRecentTracks` of `window`, newest first. The track playing now has no date and is left out.
    pub fn recent_tracks(&self, user: &str, page: u32, limit: u32, window: RecentWindow) -> Result<RecentPage, ApiError> {
        let mut params = self.base_params("user.getRecentTracks");
        params.insert("user".to_owned(), user.to_owned());
        params.insert("page".to_owned(), page.to_string());
        params.insert("limit".to_owned(), limit.to_string());
        params.insert("format".to_owned(), "json".to_owned());
        if let Some(from) = window.from {
            params.insert("from".to_owned(), from.to_string());
        }
        if let Some(to) = window.to {
            params.insert("to".to_owned(), to.to_string());
        }
        parse_recent(&self.get(&params)?)
    }

    /// `auth.getToken`: the token a person approves on Last.fm's site.
    pub fn get_token(&self) -> Result<String, ApiError> {
        let params = self.signed_params(self.base_params("auth.getToken"))?;
        let reply = self.get(&params)?;
        reply["token"]
            .as_str()
            .map(str::to_owned)
            .ok_or_else(|| ApiError::transient("Last.fm sent no token; try `lastfm connect` again"))
    }

    /// `auth.getSession`: the session key for an approved `token`.
    pub fn get_session(&self, token: &str) -> Result<SessionGrant, ApiError> {
        let mut params = self.base_params("auth.getSession");
        params.insert("token".to_owned(), token.to_owned());
        let reply = self.get(&self.signed_params(params)?)?;
        match (reply["session"]["key"].as_str(), reply["session"]["name"].as_str()) {
            (Some(key), Some(name)) => Ok(SessionGrant { key: key.to_owned(), name: name.to_owned() }),
            _ => Err(ApiError::transient("Last.fm sent no session; approve the connection on its page, then try again")),
        }
    }

    /// `track.updateNowPlaying` for one song.
    pub fn update_now_playing(&self, session_key: &str, entry: &ScrobbleEntry) -> Result<(), ApiError> {
        let mut params = self.base_params("track.updateNowPlaying");
        params.insert("sk".to_owned(), session_key.to_owned());
        params.insert("track".to_owned(), entry.title.clone());
        params.insert("artist".to_owned(), entry.artist.clone());
        params.insert("album".to_owned(), entry.album.clone());
        if entry.duration_s > 0 {
            params.insert("duration".to_owned(), entry.duration_s.to_string());
        }
        self.post(&self.signed_params(params)?).map(|_| ())
    }

    /// `track.scrobble` for up to 50 plays.
    pub fn scrobble(&self, session_key: &str, batch: &[ScrobbleEntry]) -> Result<ScrobbleOutcome, ApiError> {
        let mut params = self.base_params("track.scrobble");
        params.insert("sk".to_owned(), session_key.to_owned());
        for (index, entry) in batch.iter().enumerate() {
            params.insert(format!("track[{index}]"), entry.title.clone());
            params.insert(format!("artist[{index}]"), entry.artist.clone());
            params.insert(format!("album[{index}]"), entry.album.clone());
            params.insert(format!("timestamp[{index}]"), entry.timestamp.to_string());
            if entry.duration_s > 0 {
                params.insert(format!("duration[{index}]"), entry.duration_s.to_string());
            }
        }
        let reply = self.post(&self.signed_params(params)?)?;
        Ok(scrobble_outcome(&reply, batch.len()))
    }
}

fn transport_error(what: &str, transport: &ureq::Transport) -> ApiError {
    ApiError::transient(format!("{what} could not be reached ({}); the server tries again", transport.kind()))
}

fn read_text(response: ureq::Response) -> Result<String, ApiError> {
    response.into_string().map_err(|_| ApiError::transient("Last.fm's answer broke off; the server tries again"))
}

/// Turns an HTTP outcome into Last.fm's JSON, or the error to act on. A Last.fm error body wins over the HTTP status.
fn parse_reply(outcome: Result<ureq::Response, ureq::Error>) -> Result<Value, ApiError> {
    let (status, text) = match outcome {
        Ok(response) => (response.status(), read_text(response)?),
        Err(ureq::Error::Status(status, response)) => (status, read_text(response).unwrap_or_default()),
        Err(ureq::Error::Transport(transport)) => return Err(transport_error("Last.fm", &transport)),
    };
    let body: Option<Value> = serde_json::from_str(&text).ok();
    if let Some(code) = body.as_ref().and_then(|body| body["error"].as_i64()) {
        let message = body.as_ref().and_then(|body| body["message"].as_str()).unwrap_or_default();
        return Err(ApiError::from_lastfm(code, message));
    }
    if status == RATE_LIMITED_STATUS || status >= SERVER_ERROR_FLOOR {
        return Err(ApiError::transient(format!("Last.fm answered HTTP {status}; the server tries again with a longer wait")));
    }
    body.ok_or_else(|| ApiError::transient("Last.fm answered with something that is not JSON; the server tries again"))
}

fn page_count(attributes: &Value) -> u32 {
    let total = &attributes["totalPages"];
    total
        .as_str()
        .and_then(|text| text.parse().ok())
        .or_else(|| total.as_u64().and_then(|count| u32::try_from(count).ok()))
        .unwrap_or(1)
}

fn track_list(recent: &Value) -> Vec<&Value> {
    match &recent["track"] {
        Value::Array(items) => items.iter().collect(),
        single @ Value::Object(_) => vec![single],
        _ => Vec::new(),
    }
}

fn dated_track(entry: &Value) -> Option<RecentTrack> {
    let uts = entry["date"]["uts"].as_str().and_then(|text| text.parse::<i64>().ok())?;
    let artist = entry["artist"]["#text"].as_str().or_else(|| entry["artist"]["name"].as_str()).unwrap_or_default();
    Some(RecentTrack {
        uts,
        title: entry["name"].as_str()?.to_owned(),
        artist: artist.to_owned(),
        album: entry["album"]["#text"].as_str().unwrap_or_default().to_owned(),
    })
}

fn parse_recent(reply: &Value) -> Result<RecentPage, ApiError> {
    let recent = &reply["recenttracks"];
    if recent.is_null() {
        return Err(ApiError::transient("Last.fm's answer held no listening history; the server tries again"));
    }
    let tracks = track_list(recent).into_iter().filter_map(dated_track).collect();
    Ok((tracks, page_count(&recent["@attr"])))
}

fn ignored_entries(reply: &Value) -> usize {
    let entries = match &reply["scrobbles"]["scrobble"] {
        Value::Array(items) => items.iter().collect::<Vec<_>>(),
        single @ Value::Object(_) => vec![single],
        _ => Vec::new(),
    };
    entries.iter().filter(|entry| !entry["ignoredMessage"].is_null() && entry["ignoredMessage"]["code"] != json!("0")).count()
}

fn answered_entries(reply: &Value) -> usize {
    match &reply["scrobbles"]["scrobble"] {
        Value::Array(items) => items.len(),
        Value::Object(_) => 1,
        _ => 0,
    }
}

fn scrobble_outcome(reply: &Value, submitted: usize) -> ScrobbleOutcome {
    if answered_entries(reply) == submitted {
        return ScrobbleOutcome::Done { ignored: ignored_entries(reply) };
    }
    let accepted = &reply["scrobbles"]["@attr"]["accepted"];
    let count = accepted.as_i64().or_else(|| accepted.as_str().and_then(|text| text.parse().ok())).unwrap_or(0);
    if count > 0 {
        ScrobbleOutcome::Done { ignored: 0 }
    } else {
        ScrobbleOutcome::NothingAccepted
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_recent_page_skips_the_track_playing_now_and_reads_the_page_count() {
        let reply = json!({ "recenttracks": {
            "@attr": { "totalPages": "3" },
            "track": [
                { "name": "Live", "artist": { "#text": "A" }, "@attr": { "nowplaying": "true" } },
                { "name": "Old", "artist": { "#text": "B" }, "album": { "#text": "C" }, "date": { "uts": "1700000000" } }
            ] } });
        let (tracks, pages) = parse_recent(&reply).unwrap();
        assert_eq!(pages, 3);
        assert_eq!(tracks, vec![RecentTrack { uts: 1_700_000_000, title: "Old".into(), artist: "B".into(), album: "C".into() }]);
    }

    #[test]
    fn a_batch_answered_entry_by_entry_is_done_even_when_ignored() {
        let reply = json!({ "scrobbles": { "@attr": { "accepted": 0, "ignored": 1 },
            "scrobble": { "ignoredMessage": { "code": "1", "#text": "duplicate" } } } });
        assert_eq!(scrobble_outcome(&reply, 1), ScrobbleOutcome::Done { ignored: 1 });
    }

    #[test]
    fn an_unanswered_batch_with_nothing_accepted_is_retried() {
        let reply = json!({ "scrobbles": { "@attr": { "accepted": 0, "ignored": 0 } } });
        assert_eq!(scrobble_outcome(&reply, 2), ScrobbleOutcome::NothingAccepted);
    }

    #[test]
    fn the_debug_form_of_the_client_and_a_session_hides_keys() {
        let api = LastfmApi::new(
            Endpoints { api_url: "http://x".into(), sign_url: "http://y".into() },
            "2a96cbd8b46e442fc41c2b86b821562f".into(),
            "device".into(),
        );
        assert!(!format!("{api:?}").contains("2a96"));
        let grant = SessionGrant { key: "secretkey".into(), name: "n".into() };
        assert!(!format!("{grant:?}").contains("secretkey"));
    }
}
