use super::engine::PullRequest;
use super::listens::{ListensPage, ListensRequest};
use flaccy_server_core::wire::{Hello, PullResponse, PushRequest, PushResponse};
use serde::Deserialize;
use serde_json::{json, Value};
use std::fmt;
use std::time::Duration;

const API_PREFIX: &str = "/flaccy/v1";
const PROTOCOL: &str = "1";
const CONNECT_TIMEOUT: Duration = Duration::from_secs(8);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);

/// Why a call to the server did not return its answer.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApiError {
    /// The server could not be reached or the connection broke.
    Offline(String),
    /// `401`: the token is not valid. For an enrollment, the code was wrong, used or expired.
    Unauthorized,
    /// `409 incarnation_changed` with the server's current incarnation.
    IncarnationChanged(String),
    /// `409 cookie_ahead`, with the incarnation when the server named it.
    CookieAhead(Option<String>),
    /// `409 instance_conflict`.
    InstanceConflict,
    /// `409 mutation_gap`; `have` is the last id the server applied.
    MutationGap {
        /// The last mutation id the server applied for this instance.
        have: i64,
    },
    /// `503 clock_behind`.
    ClockBehind,
    /// `429`, with the seconds to wait when the server said.
    RateLimited(Option<u64>),
    /// Another `5xx`.
    Server(u16),
    /// Any other refusal, with the status and the error code the server gave.
    Refused {
        /// The HTTP status.
        status: u16,
        /// The `error.code` of the body, if any.
        code: String,
    },
    /// The answer was not the JSON the protocol describes.
    Malformed(String),
}

impl fmt::Display for ApiError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ApiError::Offline(cause) => write!(formatter, "Can't reach the server ({cause}). Check that Tailscale is on; Flaccy retries by itself."),
            ApiError::Unauthorized => write!(formatter, "The server did not accept this device. Add the server again with a new link."),
            ApiError::IncarnationChanged(_) | ApiError::CookieAhead(_) => write!(formatter, "The server's data was replaced."),
            ApiError::InstanceConflict => write!(formatter, "The server met a different history for this device."),
            ApiError::MutationGap { have } => write!(formatter, "The server is missing changes after {have}."),
            ApiError::ClockBehind => write!(formatter, "The server's clock is behind. Fix its date and time; changes wait until then."),
            ApiError::RateLimited(_) => write!(formatter, "The server asked Flaccy to slow down."),
            ApiError::Server(status) => write!(formatter, "The server failed with status {status}."),
            ApiError::Refused { status, code } => write!(formatter, "The server refused the request ({status} {code})."),
            ApiError::Malformed(cause) => write!(formatter, "The server sent something Flaccy cannot read ({cause})."),
        }
    }
}

impl std::error::Error for ApiError {}

impl ApiError {
    /// True for failures worth retrying after a pause.
    pub fn is_transient(&self) -> bool {
        matches!(
            self,
            ApiError::Offline(_) | ApiError::Server(_) | ApiError::RateLimited(_)
        )
    }
}

/// What `POST /devices` returned.
#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EnrollReply {
    /// This device's id.
    pub device: String,
    /// The device token. Secret: keep it in the [`super::TokenStore`] only.
    pub token: String,
    /// The user the device belongs to.
    pub user: EnrolledUser,
    /// The server's clock in milliseconds.
    pub server_time_ms: i64,
    /// The server incarnation.
    pub incarnation: String,
}

impl fmt::Debug for EnrollReply {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("EnrollReply")
            .field("device", &self.device)
            .field("token", &"***")
            .field("user", &self.user)
            .finish()
    }
}

/// The user block of an enrollment reply.
#[derive(Clone, Debug, Deserialize)]
pub struct EnrolledUser {
    /// The user id.
    pub id: String,
}

/// The blocking HTTP client for one server.
#[derive(Clone)]
pub struct Transport {
    base: String,
    token: Option<String>,
    agent: ureq::Agent,
}

impl fmt::Debug for Transport {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("Transport")
            .field("base", &self.base)
            .field("token", &self.token.as_ref().map(|_| "***"))
            .finish()
    }
}

impl Transport {
    /// A client for the server at `base_url`, with no token.
    pub fn new(base_url: &str) -> Self {
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(CONNECT_TIMEOUT)
            .timeout(REQUEST_TIMEOUT)
            .build();
        Transport {
            base: base_url.trim_end_matches('/').to_owned(),
            token: None,
            agent,
        }
    }

    /// The same client signed in with `token`.
    pub fn with_token(mut self, token: Option<String>) -> Self {
        self.token = token;
        self
    }

    /// `GET /hello`.
    pub fn hello(&self) -> Result<Hello, ApiError> {
        decode(self.request("GET", "/hello", None).call())
    }

    /// `POST /devices`: exchanges a single-use code for a device token.
    pub fn enroll(&self, code: &str, name: &str, instance: &str) -> Result<EnrollReply, ApiError> {
        let body =
            json!({ "enroll": code, "name": name, "platform": "linux", "instance": instance });
        decode(self.request("POST", "/devices", None).send_json(body))
    }

    /// `POST /sync/push`.
    pub fn push(
        &self,
        request: &PushRequest,
        incarnation: Option<&str>,
    ) -> Result<PushResponse, ApiError> {
        let body = serde_json::to_value(request)
            .map_err(|error| ApiError::Malformed(error.to_string()))?;
        decode(
            self.request("POST", "/sync/push", incarnation)
                .send_json(body),
        )
    }

    /// `GET /sync/pull`.
    pub fn pull(&self, request: &PullRequest) -> Result<PullResponse, ApiError> {
        let call = self
            .request("GET", "/sync/pull", request.incarnation.as_deref())
            .query("since", &request.since.to_string())
            .query("limit", &request.limit.to_string())
            .query("instance", &request.instance)
            .call();
        decode(call)
    }

    /// `GET /listens`, as one gzip JSON page.
    pub fn listens(
        &self,
        request: &ListensRequest,
        incarnation: Option<&str>,
    ) -> Result<ListensPage, ApiError> {
        let mut call = self
            .request("GET", "/listens", incarnation)
            .query("limit", &request.limit.to_string());
        if let Some(before) = request.before {
            call = call.query("before", &before.to_string());
        }
        if let Some(after) = request.after {
            call = call.query("after", &after.to_string());
        }
        decode(call.call())
    }

    fn request(&self, method: &str, path: &str, incarnation: Option<&str>) -> ureq::Request {
        let mut request = self
            .agent
            .request(method, &format!("{}{API_PREFIX}{path}", self.base))
            .set("Flaccy-Protocol", PROTOCOL)
            .set("Accept", "application/json");
        if let Some(incarnation) = incarnation {
            request = request.set("Flaccy-Incarnation", incarnation);
        }
        if let Some(token) = &self.token {
            request = request.set("Authorization", &format!("Bearer {token}"));
        }
        request
    }
}

fn decode<T: serde::de::DeserializeOwned>(
    outcome: Result<ureq::Response, ureq::Error>,
) -> Result<T, ApiError> {
    match outcome {
        Ok(response) => response
            .into_json::<T>()
            .map_err(|error| ApiError::Malformed(error.to_string())),
        Err(ureq::Error::Status(status, response)) => Err(classify(status, response)),
        Err(ureq::Error::Transport(transport)) => {
            Err(ApiError::Offline(transport.kind().to_string()))
        }
    }
}

fn classify(status: u16, response: ureq::Response) -> ApiError {
    let retry_after = response
        .header("Retry-After")
        .and_then(|value| value.parse().ok());
    let body: Value = response.into_json().unwrap_or(Value::Null);
    let error = &body["error"];
    let code = error["code"].as_str().unwrap_or_default().to_owned();
    let incarnation = error["incarnation"]
        .as_str()
        .or(body["incarnation"].as_str())
        .map(str::to_owned);
    let have = error["have"]
        .as_i64()
        .or(body["have"].as_i64())
        .unwrap_or(0);
    match (status, code.as_str()) {
        (401, _) => ApiError::Unauthorized,
        (409, "incarnation_changed") => {
            ApiError::IncarnationChanged(incarnation.unwrap_or_default())
        }
        (409, "cookie_ahead") => ApiError::CookieAhead(incarnation),
        (409, "instance_conflict") => ApiError::InstanceConflict,
        (409, "mutation_gap") => ApiError::MutationGap { have },
        (503, "clock_behind") => ApiError::ClockBehind,
        (429, _) => ApiError::RateLimited(retry_after),
        (500..=599, _) => ApiError::Server(status),
        _ => ApiError::Refused { status, code },
    }
}
