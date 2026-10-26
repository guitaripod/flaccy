//! The sync routes: push, pull, one entity and the listens.

use axum::extract::State;
use axum::http::{header, HeaderMap, HeaderValue};
use axum::response::{IntoResponse, Response};
use axum::Json;
use flaccy_server_core::model::EntityKind;
use flaccy_server_core::wire::{Change, PullResponse, PushRequest, PushResponse};
use serde::Deserialize;
use serde_json::{json, Value};

use super::extract::{claimed_incarnation, Authed, JsonBody, Query};
use super::ApiError;
use crate::state::AppState;
use crate::sync::{ListenPage, DEFAULT_PULL_LIMIT, MAX_LISTEN_PAGE};

const MAX_INSTANCE_CHARS: usize = 64;
const NDJSON: &str = "application/x-ndjson";

fn check_instance(instance: &str) -> Result<(), ApiError> {
    if instance.is_empty() || instance.chars().count() > MAX_INSTANCE_CHARS {
        return Err(ApiError::bad_request("The instance must be a short id such as a UUID.")
            .hint("Mint one UUID per install and send it with every push and pull."));
    }
    Ok(())
}

/// `POST /sync/push`.
pub async fn push(
    State(state): State<AppState>,
    caller: Authed,
    headers: HeaderMap,
    JsonBody(request): JsonBody<PushRequest>,
) -> Result<Json<PushResponse>, ApiError> {
    let principal = caller.active()?;
    check_instance(&request.instance)?;
    let claimed = claimed_incarnation(&headers);
    let response = state.0.sync.push(principal, request, claimed.as_deref()).await?;
    Ok(Json(response))
}

/// The query of `GET /sync/pull`.
#[derive(Deserialize)]
pub struct PullQuery {
    since: Option<i64>,
    limit: Option<usize>,
    instance: Option<String>,
}

/// `GET /sync/pull`.
pub async fn pull(
    State(state): State<AppState>,
    caller: Authed,
    headers: HeaderMap,
    Query(query): Query<PullQuery>,
) -> Result<Json<PullResponse>, ApiError> {
    let principal = caller.active()?;
    let since = query.since.unwrap_or(0);
    if since < 0 {
        return Err(ApiError::bad_request("`since` must be zero or a sequence number from an earlier pull."));
    }
    let instance = query.instance.unwrap_or_default();
    let claimed = claimed_incarnation(&headers);
    let limit = query.limit.unwrap_or(DEFAULT_PULL_LIMIT);
    let response = state.0.sync.pull(principal, &instance, since, limit, claimed.as_deref()).await?;
    Ok(Json(response))
}

/// The query of `GET /sync/entity`.
#[derive(Deserialize)]
pub struct EntityQuery {
    kind: String,
    id: String,
}

fn change_json(change: Change, now_ms: i64) -> Value {
    let mut body = serde_json::to_value(change).unwrap_or(Value::Null);
    if let Some(object) = body.as_object_mut() {
        object.insert("serverTimeMs".into(), json!(now_ms));
    }
    body
}

/// `GET /sync/entity`.
pub async fn entity(
    State(state): State<AppState>,
    caller: Authed,
    Query(query): Query<EntityQuery>,
) -> Result<Json<Value>, ApiError> {
    let principal = caller.active()?;
    let kind: EntityKind = serde_json::from_value(Value::String(query.kind.clone())).map_err(|_| {
        ApiError::bad_request(format!("'{}' is not an entity kind.", query.kind))
            .hint("Use playlist, playlist_entry, love, rating, scalar, session or listen.")
    })?;
    let missing = || ApiError::not_found(format!("There is no {} '{}' that you may read.", query.kind, query.id));
    let now_ms = state.0.sync.now_ms();
    if kind == EntityKind::Listen {
        let row = state.0.sync.listen(&principal.user, &query.id).await?.ok_or_else(missing)?;
        let value = serde_json::to_value(&row.listen).unwrap_or(Value::Null);
        return Ok(Json(json!({
            "seq": row.seq, "kind": "listen", "id": query.id, "deleted": row.listen.suppressed,
            "value": value, "serverTimeMs": now_ms,
        })));
    }
    let change = state.0.sync.entity(&principal.user, kind, &query.id).await?.ok_or_else(missing)?;
    Ok(Json(change_json(change, now_ms)))
}

/// The query of `GET /listens`.
#[derive(Deserialize)]
pub struct ListensQuery {
    before: Option<i64>,
    after: Option<i64>,
    limit: Option<usize>,
}

fn wants_ndjson(headers: &HeaderMap) -> bool {
    headers
        .get(header::ACCEPT)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|accept| accept.to_ascii_lowercase().contains(NDJSON))
}

fn listens_json(page: &ListenPage, now_ms: i64) -> Value {
    json!({ "listens": page.listens, "more": page.more, "head": page.head, "serverTimeMs": now_ms })
}

fn listens_ndjson(page: &ListenPage) -> Response {
    let mut body = String::new();
    for row in &page.listens {
        if let Ok(line) = serde_json::to_string(row) {
            body.push_str(&line);
            body.push('\n');
        }
    }
    let mut response = body.into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, HeaderValue::from_static(NDJSON));
    headers.insert("flaccy-more", HeaderValue::from_static(if page.more { "true" } else { "false" }));
    if let Ok(head) = HeaderValue::from_str(&page.head.to_string()) {
        headers.insert("flaccy-head", head);
    }
    response
}

/// `GET /listens`: newest first with `before`, ascending by `seq` with `after`; NDJSON on request.
pub async fn listens(
    State(state): State<AppState>,
    caller: Authed,
    headers: HeaderMap,
    Query(query): Query<ListensQuery>,
) -> Result<Response, ApiError> {
    let principal = caller.active()?;
    let limit = query.limit.unwrap_or(DEFAULT_PULL_LIMIT).min(MAX_LISTEN_PAGE);
    let page = match (query.before, query.after) {
        (Some(_), Some(_)) => {
            return Err(ApiError::bad_request("Send `before` or `after`, not both.")
                .hint("`before=<unix ts>` pages back from the newest; `after=<seq>` pages forward from a cursor."))
        }
        (Some(before), None) => state.0.sync.listens_before(&principal.user, before, limit).await?,
        (None, Some(after)) => state.0.sync.listens_after(&principal.user, after, limit).await?,
        (None, None) => state.0.sync.listens_before(&principal.user, i64::MAX, limit).await?,
    };
    if wants_ndjson(&headers) {
        return Ok(listens_ndjson(&page));
    }
    Ok(Json(listens_json(&page, state.0.sync.now_ms())).into_response())
}
