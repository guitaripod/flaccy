//! `hello`, enrollment and the device routes.

use axum::extract::{Path, State};
use axum::http::StatusCode;
use axum::Json;
use flaccy_server_core::wire::{Hello, HelloCaller, Role as WireRole, ServerInfo};
use serde::Deserialize;
use serde_json::{json, Value};

use super::extract::{Authed, JsonBody, MaybeAuthed, Source};
use super::ApiError;
use crate::lastfm;
use crate::security::{self, Device, DeviceId, EnrollError, Enrolled, Principal, Role, User};
use crate::state::AppState;
use crate::sync::CURRENT_VERSION;

const PROTOCOL_VERSION: u32 = 1;
const FEATURES: [&str; 2] = ["sync", "live"];
const MODE: &str = "easy";
const MAX_INSTANCE_CHARS: usize = 64;

/// The wire form of a role.
pub fn wire_role(role: Role) -> WireRole {
    match role {
        Role::Admin => WireRole::Admin,
        Role::Member => WireRole::Member,
        Role::Guest => WireRole::Guest,
        Role::Pending => WireRole::Pending,
    }
}

fn caller_of(principal: &Principal) -> HelloCaller {
    HelloCaller {
        user: principal.user.to_string(),
        role: wire_role(principal.role),
        device: principal.device.as_ref().map(|device| device.to_string()),
    }
}

/// `GET /hello`: what this server is and speaks; the caller only when a valid token came along.
pub async fn hello(State(state): State<AppState>, MaybeAuthed(principal): MaybeAuthed) -> Json<Hello> {
    let mut features: Vec<String> = FEATURES.iter().map(|feature| (*feature).to_owned()).collect();
    if lastfm::history_feature_for(&state, principal.as_ref()).await {
        features.push(lastfm::HISTORY_FEATURE.to_owned());
    }
    Json(Hello {
        protocol: vec![PROTOCOL_VERSION],
        server: ServerInfo {
            name: state.server_name().to_owned(),
            version: env!("CARGO_PKG_VERSION").to_owned(),
            schema: CURRENT_VERSION,
        },
        features,
        mode: MODE.to_owned(),
        server_time_ms: state.0.sync.now_ms(),
        incarnation: state.0.sync.incarnation(),
        caller: principal.as_ref().map(caller_of),
    })
}

fn user_json(user: &User) -> Value {
    json!({ "id": user.id.as_str(), "name": user.name, "role": user.role.as_str() })
}

fn device_json(device: &Device, current: Option<&DeviceId>) -> Value {
    json!({
        "id": device.id.as_str(),
        "userId": device.user_id.as_str(),
        "name": device.name,
        "platform": device.platform,
        "createdAt": device.created_at,
        "lastSeenAt": device.last_seen_at,
        "revokedAt": device.revoked_at,
        "current": current == Some(&device.id),
    })
}

/// The body of `POST /devices`.
#[derive(Deserialize)]
pub struct EnrollRequest {
    enroll: String,
    name: String,
    #[serde(default)]
    platform: String,
    #[serde(default)]
    instance: Option<String>,
}

fn check_enroll_fields(request: &EnrollRequest) -> Result<(), ApiError> {
    security::clean_name(&request.name).map_err(ApiError::from)?;
    let instance_ok = request
        .instance
        .as_deref()
        .is_none_or(|instance| !instance.is_empty() && instance.chars().count() <= MAX_INSTANCE_CHARS);
    if !instance_ok {
        return Err(ApiError::bad_request("The instance must be a short id such as a UUID."));
    }
    Ok(())
}

/// `POST /devices`: turns an enrollment code into a device and its token, shown once.
pub async fn enroll(
    State(state): State<AppState>,
    Source(source): Source,
    JsonBody(request): JsonBody<EnrollRequest>,
) -> Result<(StatusCode, Json<Value>), ApiError> {
    check_enroll_fields(&request)?;
    let security = &state.0.security;
    let enrolled = match security.enroll_device(source, &request.enroll, &request.name, &request.platform).await {
        Ok(enrolled) => enrolled,
        Err(EnrollError::Invalid) => return Err(ApiError::enroll_invalid()),
        Err(EnrollError::Locked { retry_after }) => {
            return Err(ApiError::rate_limited(
                "Too many wrong enrollment codes, so enrolling is paused for a moment.",
                retry_after.as_secs(),
            )
            .hint("Wait for the time in Retry-After, then scan a fresh code from `flaccy-server enroll --user <name>`."))
        }
        Err(EnrollError::Storage(error)) => return Err(error.into()),
    };
    let Enrolled { user: user_id, device, token } = enrolled;
    let user = security
        .get_user(&user_id)
        .await?
        .ok_or_else(|| ApiError::internal(&"an enrolled user vanished"))?;
    let body = json!({
        "device": device.as_str(),
        "token": token,
        "user": user_json(&user),
        "serverTimeMs": state.0.sync.now_ms(),
        "incarnation": state.0.sync.incarnation(),
    });
    Ok((StatusCode::CREATED, Json(body)))
}

/// `GET /me`: the caller, its role and its devices.
pub async fn me(State(state): State<AppState>, caller: Authed) -> Result<Json<Value>, ApiError> {
    let principal = &caller.0;
    let user = state
        .0
        .security
        .get_user(&principal.user)
        .await?
        .ok_or_else(ApiError::unauthorized)?;
    let devices = state.0.security.list_devices(Some(&principal.user)).await?;
    Ok(Json(json!({
        "user": user_json(&user),
        "role": user.role.as_str(),
        "devices": devices.iter().map(|device| device_json(device, principal.device.as_ref())).collect::<Vec<_>>(),
        "serverTimeMs": state.0.sync.now_ms(),
    })))
}

/// `GET /devices`: the caller's devices; an admin sees everyone's.
pub async fn list_devices(State(state): State<AppState>, caller: Authed) -> Result<Json<Value>, ApiError> {
    let principal = &caller.0;
    let scope = if principal.role == Role::Admin { None } else { Some(&principal.user) };
    let devices = state.0.security.list_devices(scope).await?;
    Ok(Json(json!({
        "devices": devices.iter().map(|device| device_json(device, principal.device.as_ref())).collect::<Vec<_>>(),
        "serverTimeMs": state.0.sync.now_ms(),
    })))
}

async fn owned_device(state: &AppState, principal: &Principal, id: &str) -> Result<Device, ApiError> {
    let devices = state.0.security.list_devices(None).await?;
    let device = devices
        .into_iter()
        .find(|device| device.id.as_str() == id)
        .ok_or_else(|| ApiError::not_found(format!("No device has the id {id}.")).hint("List yours with GET /devices."))?;
    if device.user_id != principal.user && principal.role != Role::Admin {
        return Err(ApiError::forbidden("That device belongs to another user, and only its owner or an admin may change it."));
    }
    Ok(device)
}

/// The body of `PATCH /devices/{id}`.
#[derive(Deserialize)]
pub struct RenameRequest {
    name: String,
}

/// `PATCH /devices/{id}`: renames a device; its owner or an admin.
pub async fn rename_device(
    State(state): State<AppState>,
    caller: Authed,
    Path(id): Path<String>,
    JsonBody(request): JsonBody<RenameRequest>,
) -> Result<Json<Value>, ApiError> {
    let device = owned_device(&state, &caller.0, &id).await?;
    state.0.security.acting_as(&caller.0.user).rename_device(&device.id, &request.name).await?;
    Ok(Json(json!({ "renamed": true, "serverTimeMs": state.0.sync.now_ms() })))
}

/// `DELETE /devices/{id}`: revokes a device, effective on its next request; its owner or an admin.
pub async fn revoke_device(
    State(state): State<AppState>,
    caller: Authed,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let device = owned_device(&state, &caller.0, &id).await?;
    state.0.security.acting_as(&caller.0.user).revoke_device(&device.id).await?;
    state.0.live.close_device(device.id.as_str());
    Ok(Json(json!({ "revoked": true, "serverTimeMs": state.0.sync.now_ms() })))
}
