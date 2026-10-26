//! Brings each user's Last.fm history into the listen ledger from the public read API.
//!
//! The plan is the client's: `HistorySyncState` of `flaccy-library` decides between the anchored first backfill,
//! catch-ups from the newest play minus an hour and the daily settle over the fortnight Last.fm still accepts late
//! scrobbles into. This module runs it with one request a second, retries with doubling waits, stores every page
//! before saving the plan, and so resumes after a kill at the page it stopped at.

use std::sync::Arc;

use flaccy_library::listen_history::{album_listen_key, HistorySyncStep, PERIODIC_SYNC_SECONDS};
use flaccy_library::logger;
use flaccy_library::server_sync::song_key_of;
use flaccy_server_core::model::{SongRef, Source};
use flaccy_server_core::mutation::ListenInput;
use flaccy_server_core::song::event_id_lfm;

use super::api::{LastfmApi, RecentPage, RecentTrack, RecentWindow};
use super::error::ApiError;
use super::history_store::{Phase, SyncRecord};
use super::pacing::{Pacer, Pacing};
use crate::security::UserId;
use crate::sync::{ServerListen, Store};

const PAGE_LIMIT: u32 = 200;
const MAX_PAGES: u32 = 10_000;
const PERMANENT_RETRY_SECONDS: i64 = 3_600;
const TRANSIENT_RETRY_SECONDS: i64 = 120;
const CATEGORY: &str = "lastfm";

/// Why a user's sync stopped before the plan was done.
#[derive(Debug)]
pub enum HistoryError {
    /// Last.fm or the network failed.
    Api(ApiError),
    /// The database refused a write.
    Storage(String),
}

impl std::fmt::Display for HistoryError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            HistoryError::Api(error) => write!(formatter, "{error}"),
            HistoryError::Storage(message) => write!(formatter, "the state database refused new plays ({message}); check the disk and the data folder's permissions"),
        }
    }
}

impl From<crate::sync::SyncError> for HistoryError {
    fn from(error: crate::sync::SyncError) -> Self {
        HistoryError::Storage(error.to_string())
    }
}

/// The listen a scrobble pulled from `account` becomes.
fn listen_of(account: &str, track: &RecentTrack) -> ServerListen {
    let song_key = song_key_of(&track.title, &track.artist);
    ServerListen {
        source: Source::Lastfm,
        input: ListenInput {
            event_id: event_id_lfm(account, track.uts, &song_key),
            ts: track.uts,
            song: SongRef {
                song_key,
                title: track.title.clone(),
                artist: track.artist.clone(),
                album: track.album.clone(),
                duration_ms: 0,
                fp: None,
                mbid: None,
                album_key: Some(album_listen_key(&track.album)).filter(|key| !key.is_empty()),
                rel_path: None,
            },
            played_s: 0,
            recorded: false,
        },
    }
}

/// Whether a user's sync should run now: never synced, a new account, the first pull unfinished, or the regular spacing is over.
pub fn is_due(record: Option<&SyncRecord>, account: &str, now: i64) -> bool {
    let Some(record) = record else { return true };
    if record.plan.account != account {
        return true;
    }
    if record.retry_at.is_some_and(|at| now < at) {
        return false;
    }
    !record.plan.backfill_complete || record.plan.last_sync_at.is_none_or(|at| now - at >= PERIODIC_SYNC_SECONDS || now < at)
}

/// Runs history syncs against one Last.fm client.
#[derive(Clone)]
pub struct HistoryWorker {
    sync: Store,
    api: Arc<LastfmApi>,
    pacing: Pacing,
    pacer: Arc<Pacer>,
}

impl HistoryWorker {
    /// A worker that writes into `sync` and reads through `api`.
    pub fn new(sync: Store, api: Arc<LastfmApi>, pacing: Pacing) -> Self {
        let pacer = Arc::new(Pacer::new(pacing.request_gap));
        Self { sync, api, pacing, pacer }
    }

    fn now(&self) -> i64 {
        self.sync.now_ms() / 1000
    }

    /// Syncs every user with an account that is due; answers how many users were synced.
    pub async fn sync_due_users(&self) -> usize {
        let accounts = match self.sync.lastfm_accounts().await {
            Ok(accounts) => accounts,
            Err(error) => {
                logger::error(CATEGORY, &format!("could not list the Last.fm accounts: {error}"));
                return 0;
            }
        };
        let mut synced = 0;
        for (user, account) in accounts {
            let record = self.sync.lastfm_sync_record(&user).await.ok().flatten();
            if is_due(record.as_ref(), &account, self.now()) {
                let _ = self.sync_user(&user, &account).await;
                synced += 1;
            }
        }
        synced
    }

    /// Runs the plan for `user` until a regular pull is recorded, or a failure stops it; the outcome is stored either way.
    pub async fn sync_user(&self, user: &UserId, account: &str) -> Result<(), HistoryError> {
        let stored = self.sync.lastfm_sync_record(user).await?;
        let mut record = stored.filter(|record| record.plan.account == account).unwrap_or_else(|| SyncRecord::fresh(account, self.now()));
        let started_with = record.stored;
        match self.run_plan(user, account, &mut record).await {
            Ok(()) => {
                record.phase = Phase::Idle;
                record.last_error = None;
                record.retry_at = None;
                self.save(user, &mut record).await?;
                logger::info(
                    CATEGORY,
                    &format!("history sync for {account} finished: {} new plays, {} stored in all", record.stored - started_with, record.stored),
                );
                Ok(())
            }
            Err(error) => {
                self.record_failure(user, &mut record, &error).await;
                Err(error)
            }
        }
    }

    async fn record_failure(&self, user: &UserId, record: &mut SyncRecord, error: &HistoryError) {
        let wait = match error {
            HistoryError::Api(api) if api.is_transient() => TRANSIENT_RETRY_SECONDS,
            _ => PERMANENT_RETRY_SECONDS,
        };
        record.phase = Phase::Failed;
        record.last_error = Some(error.to_string());
        record.retry_at = Some(self.now() + wait);
        logger::warn(CATEGORY, &format!("history sync for {} stopped: {error}", record.plan.account));
        if let Err(storage) = self.save(user, record).await {
            logger::error(CATEGORY, &format!("could not save the failed sync state: {storage}"));
        }
    }

    async fn save(&self, user: &UserId, record: &mut SyncRecord) -> Result<(), HistoryError> {
        record.updated_at = self.now();
        Ok(self.sync.save_lastfm_sync(user, record).await?)
    }

    async fn run_plan(&self, user: &UserId, account: &str, record: &mut SyncRecord) -> Result<(), HistoryError> {
        loop {
            let now = self.now();
            match record.plan.next_step(now) {
                HistorySyncStep::Backfill { page, to } => {
                    let window = RecentWindow { from: None, to: Some(to) };
                    let (tracks, total_pages) = self.fetch_page(account, page, window).await?;
                    let newest = tracks.iter().map(|track| track.uts).max();
                    record.stored += self.store(user, account, &tracks).await?;
                    record.total_pages = total_pages.min(MAX_PAGES);
                    record.plan.record_backfill_page(page, record.total_pages, to, newest, now);
                    record.phase = Phase::Backfilling;
                    self.save(user, record).await?;
                    logger::info(
                        CATEGORY,
                        &format!("history backfill for {account}: page {page} of {} done, {} plays stored", record.total_pages, record.stored),
                    );
                }
                step @ (HistorySyncStep::CatchUp { from } | HistorySyncStep::Settle { from }) => {
                    record.phase = Phase::Syncing;
                    self.save(user, record).await?;
                    let (newest, added) = self.pull_window(user, account, from).await?;
                    record.stored += added;
                    record.plan.record_pull(step, newest, now);
                    return Ok(());
                }
            }
        }
    }

    /// Every page from `from` on, newest first; answers the newest time seen and how many plays were new.
    async fn pull_window(&self, user: &UserId, account: &str, from: i64) -> Result<(Option<i64>, i64), HistoryError> {
        let (mut newest, mut added, mut page) = (None, 0, 1);
        loop {
            let (tracks, total_pages) = self.fetch_page(account, page, RecentWindow { from: Some(from), to: None }).await?;
            newest = newest.max(tracks.iter().map(|track| track.uts).max());
            added += self.store(user, account, &tracks).await?;
            if page >= total_pages.min(MAX_PAGES) {
                logger::info(CATEGORY, &format!("history pull for {account} from {from}: {page} page(s), {added} new plays"));
                return Ok((newest, added));
            }
            page += 1;
        }
    }

    async fn store(&self, user: &UserId, account: &str, tracks: &[RecentTrack]) -> Result<i64, HistoryError> {
        let listens: Vec<ServerListen> = tracks.iter().filter(|track| track.uts > 0 && !track.title.is_empty()).map(|track| listen_of(account, track)).collect();
        Ok(self.sync.record_listens_as_server(user, listens).await? as i64)
    }

    /// One page, paced to one request a second and retried with doubling waits while the failure is transient.
    async fn fetch_page(&self, account: &str, page: u32, window: RecentWindow) -> Result<RecentPage, HistoryError> {
        let mut attempt = 1;
        loop {
            self.pacer.wait().await;
            let api = self.api.clone();
            let name = account.to_owned();
            let outcome = tokio::task::spawn_blocking(move || api.recent_tracks(&name, page, PAGE_LIMIT, window))
                .await
                .map_err(|_| HistoryError::Api(ApiError::transient("the request thread stopped; the server tries again")))?;
            match outcome {
                Ok(result) => return Ok(result),
                Err(error) if error.is_transient() && attempt < self.pacing.attempts => {
                    let wait = self.pacing.retry_wait(attempt);
                    logger::info(CATEGORY, &format!("history page {page} attempt {attempt} failed ({error}); waiting {} ms", wait.as_millis()));
                    tokio::time::sleep(wait).await;
                    attempt += 1;
                }
                Err(error) => return Err(HistoryError::Api(error)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_library::listen_history::HistorySyncState;

    fn record_at(complete: bool, last_sync: Option<i64>, retry_at: Option<i64>) -> SyncRecord {
        let mut record = SyncRecord::fresh("alice", 0);
        record.plan = HistorySyncState { account: "alice".into(), backfill_complete: complete, backfill_page: 1, last_sync_at: last_sync, ..HistorySyncState::default() };
        record.retry_at = retry_at;
        record
    }

    #[test]
    fn a_user_is_due_until_the_first_pull_finishes_then_every_ten_minutes() {
        assert!(is_due(None, "alice", 1_000));
        assert!(is_due(Some(&record_at(false, None, None)), "alice", 1_000));
        assert!(!is_due(Some(&record_at(true, Some(900), None)), "alice", 1_000));
        assert!(is_due(Some(&record_at(true, Some(900), None)), "alice", 900 + PERIODIC_SYNC_SECONDS));
    }

    #[test]
    fn a_failure_holds_the_user_back_until_its_retry_time_and_a_new_account_overrides_it() {
        assert!(!is_due(Some(&record_at(false, None, Some(2_000))), "alice", 1_000));
        assert!(is_due(Some(&record_at(false, None, Some(2_000))), "alice", 2_000));
        assert!(is_due(Some(&record_at(false, None, Some(2_000))), "bob", 1_000));
    }

    #[test]
    fn a_pulled_play_gets_the_ledger_id_of_its_account_second_and_song() {
        let track = RecentTrack { uts: 1_700_000_000, title: "Song".into(), artist: "Artist".into(), album: "".into() };
        let listen = listen_of("alice", &track);
        assert_eq!(listen.input.event_id, event_id_lfm("alice", 1_700_000_000, &song_key_of("Song", "Artist")));
        assert_eq!(listen.source, Source::Lastfm);
        assert!(!listen.input.recorded && listen.input.song.album_key.is_none());
    }
}
