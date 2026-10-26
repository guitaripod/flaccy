//! The server's Last.fm features.
//!
//! **History.** For each user with a Last.fm account name (the scalar `lastfm/account`, or `flaccy-server lastfm
//! account`) the server brings the listening history in through the public `user.getRecentTracks`, using the planner
//! of `flaccy-library` the clients use: an anchored first backfill, catch-ups and a daily settle. Pulled plays are
//! listens with source `lastfm` and ids from `event_id_lfm`, so repeats are idempotent, and `/hello` tells the user's
//! clients (`lastfm.history`) to stop running their own sync.
//!
//! **Relay.** The server is a Last.fm device of its own. `flaccy-server lastfm connect` stores its session key in
//! `security.sqlite`, and plays that third-party OpenSubsonic clients report are submitted from a write-ahead queue.
//! Plays recorded by Flaccy clients, pulled from Last.fm or migrated are never submitted.

mod api;
pub mod cli;
mod error;
pub mod health;
mod history;
mod history_store;
mod now_playing;
mod pacing;
mod relay;
mod relay_store;
mod settings;
pub mod status;
mod tables;

use std::sync::Arc;

use flaccy_library::logger;

use crate::security::{Principal, UserId};
use crate::state::AppState;

pub use api::{LastfmApi, RecentPage, RecentTrack, RecentWindow, ScrobbleEntry, ScrobbleOutcome, SessionGrant};
pub use cli::{client_for, Desk, LastfmAction};
pub use error::{ApiError, ErrorKind};
pub use history::{is_due, HistoryError, HistoryWorker};
pub use history_store::{Phase, SyncRecord, ACCOUNT_KEY};
pub use now_playing::note_now_playing;
pub use pacing::{relay_retry_seconds, Pacer, Pacing};
pub use relay::{RelayPass, RelayWorker, BATCH_SIZE};
pub use relay_store::{QueuedPlay, RelayRecord};
pub use settings::{Endpoints, LastfmSettings, AUTH_PAGE_URL, DEFAULT_API_URL, DEFAULT_SIGN_URL};
pub use tables::create_tables;

/// The feature `/hello` adds for a user whose history the server is bringing in.
pub const HISTORY_FEATURE: &str = "lastfm.history";
const CATEGORY: &str = "lastfm";

/// Runs the history sync and the relay until the process ends. Does nothing, and says why, without an API key.
pub async fn run(state: AppState) {
    let Some(key) = state.0.config.lastfm.api_key() else {
        logger::info(CATEGORY, "Last.fm features are off: set `lastfm_api_key` in config.toml (or FLACCY_LASTFM_KEY) to turn them on");
        return;
    };
    let device = match state.0.security.server_id().await {
        Ok(device) => device,
        Err(error) => {
            logger::error(CATEGORY, &format!("Last.fm features are off: the server id could not be read ({error})"));
            return;
        }
    };
    let api = Arc::new(LastfmApi::new(state.0.config.lastfm.endpoints(), key, device));
    let pacing = Pacing::polite();
    let history = HistoryWorker::new(state.0.sync.clone(), api.clone(), pacing);
    let relay = RelayWorker::new(state.0.sync.clone(), state.0.security.clone(), api, pacing);
    logger::info(CATEGORY, "Last.fm history sync and scrobble relay are running");
    tokio::join!(history_loop(history, pacing), relay_loop(relay.clone(), pacing), now_playing_loop(relay));
}

async fn history_loop(worker: HistoryWorker, pacing: Pacing) {
    loop {
        worker.sync_due_users().await;
        tokio::time::sleep(pacing.tick).await;
    }
}

async fn relay_loop(worker: RelayWorker, pacing: Pacing) {
    loop {
        worker.run_cycle().await;
        tokio::time::sleep(pacing.relay_tick).await;
    }
}

async fn now_playing_loop(worker: RelayWorker) {
    let mut songs = now_playing::open_channel();
    while let Some(newest) = now_playing::next_songs(&mut songs).await {
        for (user, entry) in newest {
            worker.update_now_playing(&user, entry).await;
        }
    }
}

/// Whether `/hello` should list `lastfm.history` for the caller: the server has a key and is bringing that user's history in.
pub async fn history_feature_for(state: &AppState, caller: Option<&Principal>) -> bool {
    let Some(caller) = caller else { return false };
    state.0.config.lastfm.api_key().is_some() && history_flowing(state, &caller.user).await
}

async fn history_flowing(state: &AppState, user: &UserId) -> bool {
    state.0.sync.lastfm_history_flowing(user).await.unwrap_or(false)
}
