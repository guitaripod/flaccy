//! Serves `GET /` -> `ok` through the easy-mode listener and the browser guard,
//! so a tailnet peer can `curl http://<tailnet address>:<port>/` to try it.
//!
//! Run: `cargo run -p flaccy-server --example easy_probe -- 4546`

use std::process::ExitCode;

use axum::routing::get;
use axum::Router;
use flaccy_server::net::{connections, guard_router, AllowedHosts, EasyListener};

const DEFAULT_PORT: u16 = 4546;

#[tokio::main]
async fn main() -> ExitCode {
    let port = std::env::args().nth(1).and_then(|text| text.parse().ok()).unwrap_or(DEFAULT_PORT);
    match probe(port).await {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            flaccy_library::logger::error("server", &message);
            ExitCode::FAILURE
        }
    }
}

async fn probe(port: u16) -> Result<(), String> {
    let listener = EasyListener::bind(port)
        .await
        .map_err(|error| format!("Could not listen on port {port}: {error}. Pick a free port: `easy_probe <port>`."))?;
    let hosts = AllowedHosts::new(&[], listener.handle().tailnet());
    let router = guard_router(Router::new().route("/", get(|| async { "ok" })), hosts);
    axum::serve(listener, connections(router))
        .await
        .map_err(|error| format!("The probe stopped: {error}"))
}
