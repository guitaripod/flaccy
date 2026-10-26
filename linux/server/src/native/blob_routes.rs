//! `PUT /blobs/{sha256}` and `GET /blobs/{sha256}`.

use axum::body::Bytes;
use axum::extract::{Path, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

use super::extract::Authed;
use super::ApiError;
use crate::state::AppState;

const IMMUTABLE: &str = "private, max-age=31536000, immutable";

/// `PUT /blobs/{sha256}`: stores an image of at most 2 MiB and 16 megapixels under the SHA-256 of its bytes, within the caller's 50 MB quota.
pub async fn put_blob(
    State(state): State<AppState>,
    caller: Authed,
    Path(hash): Path<String>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Response, ApiError> {
    let owner = caller.writer()?.user.clone();
    let mime = headers
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .map(|value| value.split(';').next().unwrap_or("").trim().to_ascii_lowercase())
        .unwrap_or_default();
    let stored = state.0.sync.put_blob(owner.as_str(), &hash, &mime, body.to_vec()).await?;
    let status = if stored.created { StatusCode::CREATED } else { StatusCode::OK };
    let body = json!({ "hash": hash, "size": stored.size, "serverTimeMs": state.0.sync.now_ms() });
    Ok((status, Json(body)).into_response())
}

/// `GET /blobs/{sha256}`: the stored image.
pub async fn get_blob(
    State(state): State<AppState>,
    caller: Authed,
    Path(hash): Path<String>,
) -> Result<Response, ApiError> {
    caller.active()?;
    let blob = state
        .0
        .sync
        .get_blob(&hash)
        .await?
        .ok_or_else(|| ApiError::not_found(format!("The server holds no blob {hash}.")).hint("Upload it with PUT /blobs/<sha256>."))?;
    let content_type = HeaderValue::from_str(&blob.mime).unwrap_or_else(|_| HeaderValue::from_static("application/octet-stream"));
    let mut response = blob.data.into_response();
    let headers = response.headers_mut();
    headers.insert(header::CONTENT_TYPE, content_type);
    headers.insert(header::CACHE_CONTROL, HeaderValue::from_static(IMMUTABLE));
    headers.insert(header::X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    Ok(response)
}
