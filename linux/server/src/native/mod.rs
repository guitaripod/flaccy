//! The native API under `/flaccy/v1`: identity, enrollment and sync.
//!
//! The contract is `docs/server/PROTOCOL.md`. Every answer carries
//! `Flaccy-Protocol: 1`; errors share one JSON shape ([`ApiError`]); CORS is
//! never enabled, and [`app`] puts the browser guard in front of everything.

mod blob_routes;
mod error;
mod extract;
mod guesses;
mod host;
mod identity;
mod sync_routes;

use std::time::Duration;

use axum::extract::Request;
use axum::http::{header, HeaderValue, StatusCode};
use axum::middleware::{from_fn, map_response, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::Router;
use tower_http::compression::CompressionLayer;
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::timeout::TimeoutLayer;

use crate::net::{guard_router, AllowedHosts};
use crate::state::AppState;

pub use error::ApiError;
pub use guesses::BearerThrottle;
pub use host::machine_name;

const BASE: &str = "/flaccy/v1";
const JSON_BODY_LIMIT: usize = 1024 * 1024;
const BLOB_BODY_LIMIT: usize = 2 * 1024 * 1024 + 4096;
const REQUEST_TIMEOUT: Duration = Duration::from_secs(30);
const PROTOCOL_HEADER: &str = "flaccy-protocol";

async fn not_found() -> ApiError {
    ApiError::not_found("This server has no such call.").hint("The calls are listed in docs/server/PROTOCOL.md.")
}

async fn wrong_method() -> ApiError {
    ApiError::new(StatusCode::METHOD_NOT_ALLOWED, "method_not_allowed", "This call does not accept that HTTP method.")
        .hint("Check the method against docs/server/PROTOCOL.md.")
}

fn is_json(response: &Response) -> bool {
    response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("application/json"))
}

async fn shape_layer_errors(response: Response) -> Response {
    if is_json(&response) {
        return response;
    }
    match response.status() {
        StatusCode::PAYLOAD_TOO_LARGE => ApiError::too_large("The request body is larger than this call allows.")
            .hint("Send fewer mutations per push, or a smaller image.")
            .into_response(),
        StatusCode::REQUEST_TIMEOUT => ApiError::new(
            StatusCode::REQUEST_TIMEOUT,
            "timeout",
            "The request took longer than 30 seconds, so the server gave up on it.",
        )
        .hint("Try again; send fewer mutations per push if it repeats.")
        .into_response(),
        _ => response,
    }
}

async fn stamp_protocol(request: Request, next: Next) -> Response {
    let mut response = next.run(request).await;
    response.headers_mut().insert(PROTOCOL_HEADER, HeaderValue::from_static("1"));
    response
}

fn json_routes() -> Router<AppState> {
    Router::new()
        .route("/hello", get(identity::hello))
        .route("/devices", post(identity::enroll).get(identity::list_devices))
        .route(
            "/devices/{id}",
            axum::routing::patch(identity::rename_device).delete(identity::revoke_device),
        )
        .route("/me", get(identity::me))
        .route("/sync/push", post(sync_routes::push))
        .route("/sync/pull", get(sync_routes::pull))
        .route("/sync/entity", get(sync_routes::entity))
        .route("/listens", get(sync_routes::listens))
        .layer(RequestBodyLimitLayer::new(JSON_BODY_LIMIT))
}

fn blob_routes() -> Router<AppState> {
    Router::new()
        .route("/blobs/{sha256}", axum::routing::put(blob_routes::put_blob).get(blob_routes::get_blob))
        .layer(RequestBodyLimitLayer::new(BLOB_BODY_LIMIT))
}

/// The router of `/flaccy/v1`.
pub fn router(state: AppState) -> Router {
    let calls = json_routes()
        .merge(blob_routes())
        .layer(TimeoutLayer::with_status_code(StatusCode::REQUEST_TIMEOUT, REQUEST_TIMEOUT))
        .layer(map_response(shape_layer_errors))
        .fallback(not_found)
        .method_not_allowed_fallback(wrong_method)
        .with_state(state);
    Router::new()
        .nest(BASE, calls)
        .layer(CompressionLayer::new())
        .layer(from_fn(stamp_protocol))
}

/// The whole application: `/rest` and the native API behind the browser guard.
pub fn app(state: AppState, hosts: AllowedHosts) -> Router {
    guard_router(crate::api::router(state.clone()).merge(router(state)), hosts)
}
