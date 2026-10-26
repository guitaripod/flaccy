//! The daily housekeeping task `serve` runs: prune old mutation results, empty the write-ahead logs, refresh statistics.

use std::time::Duration;

use flaccy_library::logger;
use tokio::time::{interval, MissedTickBehavior};

use crate::state::AppState;

const CATEGORY: &str = "maintenance";

/// How often the housekeeping runs.
pub const INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);

/// Runs one pass over `state.sqlite` and `security.sqlite`; failures are logged and never stop the server.
pub async fn tidy_once(state: &AppState) {
    match state.0.sync.tidy().await {
        Ok(tidied) => logger::info(
            CATEGORY,
            &format!(
                "state.sqlite tidied: {} old mutation results and {} unused cover images removed",
                tidied.results_pruned, tidied.blobs_removed
            ),
        ),
        Err(error) => logger::warn(CATEGORY, &format!("could not tidy state.sqlite: {error}; the next pass runs in a day")),
    }
    if let Err(error) = state.0.security.tidy().await {
        logger::warn(CATEGORY, &format!("could not tidy security.sqlite: {error}; the next pass runs in a day"));
    }
}

/// Tidies once at start and then every day, until the task is dropped.
pub async fn keep_tidy(state: AppState) {
    let mut timer = interval(INTERVAL);
    timer.set_missed_tick_behavior(MissedTickBehavior::Delay);
    loop {
        timer.tick().await;
        tidy_once(&state).await;
    }
}
