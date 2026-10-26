//! Request extractors: who is calling, the JSON body and the query string, each failing in the native error shape.

use std::time::Instant;

use axum::body::to_bytes;
use axum::extract::{FromRequest, FromRequestParts, Request};
use axum::http::request::Parts;
use axum::http::{header, HeaderMap};
use flaccy_library::logger;
use serde::de::DeserializeOwned;

use super::ApiError;
use crate::security::{Principal, Role};
use crate::state::AppState;
use crate::throttle;

const INCARNATION_HEADER: &str = "flaccy-incarnation";
const JSON_LIMIT: usize = 1024 * 1024;
const BEARER_PREFIX: &str = "bearer ";

/// What the `Authorization` header said.
pub enum Identity {
    /// No bearer token was sent.
    Anonymous,
    /// The token belongs to this device.
    Known(Principal),
    /// A token was sent and matched no working device.
    Unknown,
}

fn bearer_token(headers: &HeaderMap) -> Option<&str> {
    let value = headers.get(header::AUTHORIZATION)?.to_str().ok()?;
    let split = value.get(..BEARER_PREFIX.len())?;
    if split.eq_ignore_ascii_case(BEARER_PREFIX) {
        Some(value[BEARER_PREFIX.len()..].trim())
    } else {
        None
    }
}

/// Checks the bearer token against the devices, counting a failed one against the peer address.
pub async fn identify(parts: &Parts, state: &AppState) -> Result<Identity, ApiError> {
    let Some(token) = bearer_token(&parts.headers) else {
        return Ok(Identity::Anonymous);
    };
    let address = throttle::client_address(parts, state.0.config.behind_proxy);
    let now = Instant::now();
    if let Some(wait) = state.0.bearer_throttle.locked_for(address, now) {
        return Err(ApiError::rate_limited(
            "Too many unknown device tokens came from this address, so it is locked out for a while.",
            wait.as_secs(),
        )
        .hint("Wait for the time in Retry-After, then enroll the device again if its token was revoked."));
    }
    match state.0.security.authenticate(token).await? {
        Some(principal) => {
            state.0.bearer_throttle.record_success(address, now);
            note_seen(state, &principal).await;
            Ok(Identity::Known(principal))
        }
        None => {
            state.0.bearer_throttle.record_failure(address, now);
            Ok(Identity::Unknown)
        }
    }
}

async fn note_seen(state: &AppState, principal: &Principal) {
    if let Some(device) = &principal.device {
        if let Err(error) = state.0.security.touch_last_seen(device).await {
            logger::warn("native", &format!("could not record that device {device} was seen: {error}"));
        }
    }
}

/// The caller of an authenticated route.
pub struct Authed(pub Principal);

impl FromRequestParts<AppState> for Authed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        match identify(parts, state).await? {
            Identity::Known(principal) => Ok(Authed(principal)),
            Identity::Anonymous | Identity::Unknown => Err(ApiError::unauthorized()),
        }
    }
}

impl Authed {
    /// The principal unless it is a pending device, which may do nothing.
    pub fn active(&self) -> Result<&Principal, ApiError> {
        if self.0.role == Role::Pending {
            return Err(ApiError::forbidden("This device has not been approved yet, so it may not use the server.")
                .hint("Ask the server's admin to approve your user with `flaccy-server user role <name> member`."));
        }
        Ok(&self.0)
    }

    /// The principal if it may write: an admin or a member.
    pub fn writer(&self) -> Result<&Principal, ApiError> {
        let principal = self.active()?;
        if principal.role == Role::Guest {
            return Err(ApiError::forbidden("Guests can listen but not store anything.")
                .hint("Ask the server's admin to make your user a member with `flaccy-server user role <name> member`."));
        }
        Ok(principal)
    }
}

/// The caller of a route that also works without a token; a bad token is the same as none.
pub struct MaybeAuthed(pub Option<Principal>);

impl FromRequestParts<AppState> for MaybeAuthed {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, ApiError> {
        match identify(parts, state).await? {
            Identity::Known(principal) => Ok(MaybeAuthed(Some(principal))),
            Identity::Anonymous | Identity::Unknown => Ok(MaybeAuthed(None)),
        }
    }
}

/// A JSON request body, at most 1 MiB.
pub struct JsonBody<T>(pub T);

impl<T: DeserializeOwned> FromRequest<AppState> for JsonBody<T> {
    type Rejection = ApiError;

    async fn from_request(request: Request, _state: &AppState) -> Result<Self, ApiError> {
        let bytes = to_bytes(request.into_body(), JSON_LIMIT).await.map_err(|error| {
            if error.to_string().contains("length limit") {
                ApiError::too_large("The request body is larger than 1 MiB.")
                    .hint("Send fewer mutations per push.")
            } else {
                ApiError::bad_request(format!("The request body could not be read: {error}."))
            }
        })?;
        serde_json::from_slice(&bytes).map(JsonBody).map_err(|error| {
            ApiError::bad_request(format!("The request body is not the JSON this call expects: {error}."))
                .hint("Check the field names and types against docs/server/PROTOCOL.md.")
        })
    }
}

/// The query string decoded into `T`.
pub struct Query<T>(pub T);

impl<T: DeserializeOwned> FromRequestParts<AppState> for Query<T> {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, _state: &AppState) -> Result<Self, ApiError> {
        serde_urlencoded::from_str(parts.uri.query().unwrap_or(""))
            .map(Query)
            .map_err(|error| {
                ApiError::bad_request(format!("The query string is not valid for this call: {error}."))
                    .hint("Check the parameter names and that numbers are plain integers.")
            })
    }
}

/// The incarnation the client says it last saw, from `Flaccy-Incarnation`.
pub fn claimed_incarnation(headers: &HeaderMap) -> Option<String> {
    headers.get(INCARNATION_HEADER)?.to_str().ok().map(|value| value.trim().to_owned())
}
