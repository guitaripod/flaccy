//! Submits the plays third-party OpenSubsonic clients report to the user's own Last.fm account.
//!
//! The server is a Last.fm device of its own: only listens whose source is `opensubsonic` and that were recorded after
//! `lastfm connect` go out. Flaccy clients scrobble for themselves, so their plays and everything pulled from Last.fm
//! never do. Plays wait in a write-ahead queue in `state.sqlite`, go out in batches of up to 50 and are retried with
//! waits of 1 s doubling to an hour. A rejected session pauses the relay until the person connects again.

use std::sync::Arc;

use flaccy_library::logger;

use super::api::{LastfmApi, ScrobbleEntry, ScrobbleOutcome};
use super::error::{ApiError, ErrorKind};
use super::pacing::{relay_retry_seconds, Pacer, Pacing};
use super::relay_store::QueuedPlay;
use crate::security::{self, UserId};
use crate::sync::Store;

/// The most plays one `track.scrobble` call carries.
pub const BATCH_SIZE: usize = 50;
const CATEGORY: &str = "lastfm";

/// What one pass over a user's queue did.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct RelayPass {
    /// Plays Last.fm took.
    pub submitted: usize,
    /// Plays that failed and wait for a later try.
    pub deferred: usize,
    /// Plays Last.fm refused for good.
    pub rejected: usize,
    /// True when the relay paused during the pass.
    pub paused: bool,
}

/// Runs the relay against one Last.fm client.
#[derive(Clone)]
pub struct RelayWorker {
    sync: Store,
    security: security::Store,
    api: Arc<LastfmApi>,
    pacer: Arc<Pacer>,
}

fn batch_retry_seconds(batch: &[QueuedPlay]) -> i64 {
    relay_retry_seconds(batch.iter().map(|play| play.attempts).max().unwrap_or(0) + 1)
}

fn ids_of(batch: &[QueuedPlay]) -> Vec<String> {
    batch.iter().map(|play| play.event_id.clone()).collect()
}

impl RelayWorker {
    /// A worker that reads `sync`, takes session keys from `security` and submits through `api`.
    pub fn new(sync: Store, security: security::Store, api: Arc<LastfmApi>, pacing: Pacing) -> Self {
        let pacer = Arc::new(Pacer::new(pacing.request_gap));
        Self { sync, security, api, pacer }
    }

    fn now(&self) -> i64 {
        self.sync.now_ms() / 1000
    }

    /// One pass over every connected user; answers the users' passes.
    pub async fn run_cycle(&self) -> Vec<(UserId, RelayPass)> {
        let users = match self.sync.lastfm_relay_users().await {
            Ok(users) => users,
            Err(error) => {
                logger::error(CATEGORY, &format!("could not list the Last.fm relays: {error}"));
                return Vec::new();
            }
        };
        let mut passes = Vec::new();
        for user in users {
            match self.relay_user(&user).await {
                Ok(pass) => passes.push((user, pass)),
                Err(message) => logger::error(CATEGORY, &format!("the Last.fm relay for {user} failed: {message}")),
            }
        }
        passes
    }

    /// Queues the user's new third-party plays and submits what is due, unless the relay is paused.
    pub async fn relay_user(&self, user: &UserId) -> Result<RelayPass, String> {
        let record = self.sync.lastfm_relay_record(user).await.map_err(|error| error.to_string())?;
        let Some(record) = record else { return Ok(RelayPass::default()) };
        self.sync.lastfm_enqueue_new(user, self.now()).await.map_err(|error| error.to_string())?;
        if record.paused_reason.is_some() {
            return Ok(RelayPass { paused: true, ..RelayPass::default() });
        }
        let session = self.security.lastfm_session(user).await.map_err(|error| error.to_string())?;
        let Some(session) = session else {
            let reason = "this user has no Last.fm session; run `flaccy-server lastfm connect --user <name>`";
            self.pause(user, reason).await;
            return Ok(RelayPass { paused: true, ..RelayPass::default() });
        };
        self.drain(user, &session.session_key).await
    }

    async fn pause(&self, user: &UserId, reason: &str) {
        logger::warn(CATEGORY, &format!("the Last.fm relay for {user} is paused: {reason}"));
        if let Err(error) = self.sync.lastfm_pause_relay(user, reason, self.now()).await {
            logger::error(CATEGORY, &format!("could not record the pause for {user}: {error}"));
        }
    }

    async fn drain(&self, user: &UserId, session_key: &str) -> Result<RelayPass, String> {
        let mut pass = RelayPass::default();
        loop {
            let batch = self.sync.lastfm_due(user, self.now(), BATCH_SIZE).await.map_err(|error| error.to_string())?;
            if batch.is_empty() {
                return Ok(pass);
            }
            match self.submit(session_key, &batch).await {
                Ok(ScrobbleOutcome::Done { ignored }) => {
                    self.finish(user, &batch, ignored).await?;
                    pass.submitted += batch.len();
                }
                Ok(ScrobbleOutcome::NothingAccepted) => {
                    self.defer(user, &batch, "Last.fm accepted none of the plays").await?;
                    pass.deferred += batch.len();
                    return Ok(pass);
                }
                Err(error) => {
                    let stop = self.handle_failure(user, session_key, &batch, &error, &mut pass).await?;
                    if stop {
                        return Ok(pass);
                    }
                }
            }
        }
    }

    async fn submit(&self, session_key: &str, batch: &[QueuedPlay]) -> Result<ScrobbleOutcome, ApiError> {
        self.pacer.wait().await;
        let entries: Vec<ScrobbleEntry> = batch.iter().map(|play| play.entry.clone()).collect();
        let (api, key) = (self.api.clone(), session_key.to_owned());
        tokio::task::spawn_blocking(move || api.scrobble(&key, &entries))
            .await
            .map_err(|_| ApiError::transient("the request thread stopped; the server tries again"))?
    }

    async fn finish(&self, user: &UserId, batch: &[QueuedPlay], ignored: usize) -> Result<(), String> {
        self.sync.lastfm_mark_done(user, ids_of(batch), self.now()).await.map_err(|error| error.to_string())?;
        logger::info(CATEGORY, &format!("relayed {} play(s) for {user} to Last.fm ({ignored} ignored by Last.fm)", batch.len()));
        Ok(())
    }

    async fn defer(&self, user: &UserId, batch: &[QueuedPlay], reason: &str) -> Result<(), String> {
        let retry_at = self.now() + batch_retry_seconds(batch);
        self.sync.lastfm_retry_later(user, ids_of(batch), retry_at, reason).await.map_err(|error| error.to_string())
    }

    /// Acts on a failed batch; answers true when the pass should stop.
    async fn handle_failure(&self, user: &UserId, session_key: &str, batch: &[QueuedPlay], error: &ApiError, pass: &mut RelayPass) -> Result<bool, String> {
        match error.kind {
            ErrorKind::Rejected if batch.len() > 1 => self.submit_singly(user, session_key, batch, pass).await,
            ErrorKind::Rejected => {
                self.reject(user, &batch[0], error).await?;
                pass.rejected += 1;
                Ok(false)
            }
            ErrorKind::Credentials | ErrorKind::Transient | ErrorKind::Signer => self.stop_pass(user, batch, error, pass).await,
        }
    }

    async fn reject(&self, user: &UserId, play: &QueuedPlay, error: &ApiError) -> Result<(), String> {
        logger::warn(CATEGORY, &format!("Last.fm refused a play of {user} for good: {error}"));
        self.sync.lastfm_reject(user, &play.event_id, &error.message).await.map_err(|failure| failure.to_string())
    }

    /// Ends the pass after a failure that is not about one play: a dead session pauses, anything else waits for a retry.
    async fn stop_pass(&self, user: &UserId, batch: &[QueuedPlay], error: &ApiError, pass: &mut RelayPass) -> Result<bool, String> {
        if error.kind == ErrorKind::Credentials {
            self.pause(user, &error.message).await;
            pass.paused = true;
            return Ok(true);
        }
        logger::warn(CATEGORY, &format!("relaying {} play(s) for {user} failed: {error}", batch.len()));
        self.defer(user, batch, &error.message).await?;
        pass.deferred += batch.len();
        Ok(true)
    }

    /// Sends a refused batch's plays one at a time, so one bad play cannot hold the others back.
    async fn submit_singly(&self, user: &UserId, session_key: &str, batch: &[QueuedPlay], pass: &mut RelayPass) -> Result<bool, String> {
        for (index, play) in batch.iter().enumerate() {
            let single = std::slice::from_ref(play);
            match self.submit(session_key, single).await {
                Ok(ScrobbleOutcome::Done { ignored }) => {
                    self.finish(user, single, ignored).await?;
                    pass.submitted += 1;
                }
                Ok(ScrobbleOutcome::NothingAccepted) => {
                    self.defer(user, single, "Last.fm accepted none of the plays").await?;
                    pass.deferred += 1;
                }
                Err(error) if error.kind == ErrorKind::Rejected => {
                    self.reject(user, play, &error).await?;
                    pass.rejected += 1;
                }
                Err(error) => return self.stop_pass(user, &batch[index..], &error, pass).await,
            }
        }
        Ok(false)
    }

    /// Tells Last.fm what `user` is playing now. Failures are logged and dropped: a stale "now playing" helps nobody.
    pub async fn update_now_playing(&self, user: &UserId, entry: ScrobbleEntry) {
        let Ok(Some(record)) = self.sync.lastfm_relay_record(user).await else { return };
        if record.paused_reason.is_some() {
            return;
        }
        let Ok(Some(session)) = self.security.lastfm_session(user).await else { return };
        self.pacer.wait().await;
        let (api, key) = (self.api.clone(), session.session_key.clone());
        let outcome = tokio::task::spawn_blocking(move || api.update_now_playing(&key, &entry)).await;
        match outcome {
            Ok(Err(error)) if error.kind == ErrorKind::Credentials => self.pause(user, &error.message).await,
            Ok(Err(error)) => logger::warn(CATEGORY, &format!("now playing for {user} was not sent: {error}")),
            _ => {}
        }
    }
}
