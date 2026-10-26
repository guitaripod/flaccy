//! The error answers of the native API: one type, one JSON shape.

use axum::http::{header, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use flaccy_library::logger;
use serde_json::{json, Map, Value};

use crate::security::SecurityError;
use crate::sync::{BlobError, PullError, PushError, SyncError};

const CATEGORY: &str = "native";

/// A failed call: an HTTP status and `{"error": {"code", "message", "hint"?, ...}}`.
#[derive(Debug)]
pub struct ApiError {
    status: StatusCode,
    code: &'static str,
    message: String,
    hint: Option<String>,
    fields: Map<String, Value>,
    retry_after: Option<u64>,
}

impl ApiError {
    /// An error with an explicit status and code.
    pub fn new(status: StatusCode, code: &'static str, message: impl Into<String>) -> Self {
        Self {
            status,
            code,
            message: message.into(),
            hint: None,
            fields: Map::new(),
            retry_after: None,
        }
    }

    /// Adds the next step to the answer.
    pub fn hint(mut self, hint: impl Into<String>) -> Self {
        self.hint = Some(hint.into());
        self
    }

    /// Adds a field to the `error` object, such as `incarnation` or `have`.
    pub fn field(mut self, name: &str, value: Value) -> Self {
        self.fields.insert(name.to_owned(), value);
        self
    }

    /// Adds a `Retry-After` header of this many seconds.
    pub fn retry_after(mut self, seconds: u64) -> Self {
        self.retry_after = Some(seconds);
        self
    }

    /// The HTTP status.
    pub fn status(&self) -> StatusCode {
        self.status
    }

    /// The snake_case code.
    pub fn code(&self) -> &'static str {
        self.code
    }

    /// 401 `unauthorized`: no valid device token.
    pub fn unauthorized() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "unauthorized",
            "This request carries no valid device token, or the device was revoked.",
        )
        .hint("Enroll this device again: run `flaccy-server enroll --user <name>` on the server and scan its code in Flaccy.")
    }

    /// 403 `forbidden`.
    pub fn forbidden(message: impl Into<String>) -> Self {
        Self::new(StatusCode::FORBIDDEN, "forbidden", message)
    }

    /// 404 `not_found`.
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(StatusCode::NOT_FOUND, "not_found", message)
    }

    /// 400 `bad_request`.
    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::new(StatusCode::BAD_REQUEST, "bad_request", message)
    }

    /// 413 `too_large`.
    pub fn too_large(message: impl Into<String>) -> Self {
        Self::new(StatusCode::PAYLOAD_TOO_LARGE, "too_large", message)
    }

    /// 429 `rate_limited` with `Retry-After`.
    pub fn rate_limited(message: impl Into<String>, retry_after_seconds: u64) -> Self {
        Self::new(StatusCode::TOO_MANY_REQUESTS, "rate_limited", message).retry_after(retry_after_seconds.max(1))
    }

    /// 401 `enroll_invalid`: the same body whether the code was wrong, used or expired.
    pub fn enroll_invalid() -> Self {
        Self::new(
            StatusCode::UNAUTHORIZED,
            "enroll_invalid",
            "That enrollment code is wrong, already used or expired.",
        )
        .hint("Make a fresh code with `flaccy-server enroll --user <name>` and scan it again.")
    }

    /// 500 `internal`: the cause goes to the log, not to the client.
    pub fn internal(cause: &dyn std::fmt::Display) -> Self {
        logger::error(CATEGORY, &format!("request failed: {cause}"));
        Self::new(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal",
            "The server could not finish this request because of a problem on its side.",
        )
        .hint("Try again in a moment; if it repeats, look at flaccy.log in the server's data folder.")
    }

    fn body(&self) -> Value {
        let mut error = Map::new();
        error.insert("code".into(), json!(self.code));
        error.insert("message".into(), json!(self.message));
        if let Some(hint) = &self.hint {
            error.insert("hint".into(), json!(hint));
        }
        for (name, value) in &self.fields {
            error.insert(name.clone(), value.clone());
        }
        json!({ "error": error })
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let mut response = (self.status, Json(self.body())).into_response();
        if let Some(seconds) = self.retry_after {
            if let Ok(value) = HeaderValue::from_str(&seconds.to_string()) {
                response.headers_mut().insert(header::RETRY_AFTER, value);
            }
        }
        response
    }
}

impl From<SyncError> for ApiError {
    fn from(error: SyncError) -> Self {
        ApiError::internal(&error)
    }
}

impl From<SecurityError> for ApiError {
    fn from(error: SecurityError) -> Self {
        match error {
            SecurityError::InvalidName(_) => ApiError::bad_request(error.to_string()),
            SecurityError::UnknownDevice(_) | SecurityError::UnknownUser(_) => ApiError::not_found(error.to_string()),
            other => ApiError::internal(&other),
        }
    }
}

impl From<PushError> for ApiError {
    fn from(error: PushError) -> Self {
        let message = error.to_string();
        match error {
            PushError::IncarnationChanged { current } => {
                ApiError::new(StatusCode::CONFLICT, "incarnation_changed", message).field("incarnation", json!(current))
            }
            PushError::InstanceConflict => ApiError::new(StatusCode::CONFLICT, "instance_conflict", message),
            PushError::MutationGap { have } => {
                ApiError::new(StatusCode::CONFLICT, "mutation_gap", message).field("have", json!(have))
            }
            PushError::ClockBehind => ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "clock_behind", message).retry_after(60),
            PushError::DeviceMismatch => ApiError::forbidden(message),
            PushError::TooLarge => ApiError::too_large(message),
            PushError::Storage(source) => source.into(),
        }
    }
}

impl From<PullError> for ApiError {
    fn from(error: PullError) -> Self {
        let message = error.to_string();
        match error {
            PullError::IncarnationChanged { current } => {
                ApiError::new(StatusCode::CONFLICT, "incarnation_changed", message).field("incarnation", json!(current))
            }
            PullError::CookieAhead { current } => {
                ApiError::new(StatusCode::CONFLICT, "cookie_ahead", message).field("incarnation", json!(current))
            }
            PullError::Storage(source) => source.into(),
        }
    }
}

impl From<BlobError> for ApiError {
    fn from(error: BlobError) -> Self {
        let message = error.to_string();
        match error {
            BlobError::TooLarge => ApiError::too_large(message),
            BlobError::BadHash | BlobError::BadMime | BlobError::NotAnImage | BlobError::HashMismatch => {
                ApiError::bad_request(message)
            }
            BlobError::Storage(source) => source.into(),
        }
    }
}
