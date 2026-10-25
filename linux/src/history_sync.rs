//! Keeps the local listening history in step with the person's Last.fm
//! account. Every scrobble there, from Flaccy or any other app or device, is
//! pulled into the `scrobbles` table, so Stats, play counts, Most Played and
//! the stations are all counted locally. The first sync pulls the whole
//! history page by page and resumes where it stopped; later ones read what
//! arrived since, and once a day the fortnight Last.fm still accepts late
//! scrobbles into. The plan is `listen_history::HistorySyncState`; this module
//! runs it off the main thread and reports how it stands.

use crate::app::AppCore;
use crate::db::{Db, PulledListen};
use crate::events::AppEvent;
use crate::lastfm::{LastFmClient, RecentPage, RecentWindow};
use flaccy_library::listen_history::{
    HistorySyncState, HistorySyncStep, ListenKeyCache, ListenLedger, PERIODIC_SYNC_SECONDS,
};
use gtk::glib;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::{Duration, Instant};

const PAGE_LIMIT: u32 = 200;
const MAX_PAGES: u32 = 10_000;
const MAX_PAGE_RETRIES: u32 = 4;
const RETRY_BACKOFF_MS: u64 = 800;
const LEGACY_SEEDED_THRESHOLD: i64 = 50;

/// How the history sync stands, for the Last.fm settings and Stats.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HistoryStatus {
    NotConnected,
    /// No sync has finished in this session yet.
    Waiting,
    /// The first full pull is under way.
    Backfilling {
        stored: usize,
        page: u32,
        total_pages: u32,
    },
    /// A regular pull is under way.
    Syncing,
    Synced {
        at: i64,
        plays: i64,
    },
    Failed {
        reason: String,
        last_synced: Option<i64>,
        plays: i64,
    },
}

impl HistoryStatus {
    pub fn is_running(&self) -> bool {
        matches!(self, Self::Backfilling { .. } | Self::Syncing)
    }

    /// One line saying how the sync stands, `now` being the current Unix time.
    pub fn line(&self, now: i64) -> String {
        match self {
            Self::NotConnected => "Connect Last.fm to bring in your listening history".to_string(),
            Self::Waiting => "Getting ready to sync with Last.fm".to_string(),
            Self::Backfilling { stored, page, total_pages } if *total_pages > 1 => format!(
                "Bringing in your Last.fm history… {} plays · page {page} of {total_pages}",
                group_thousands(*stored as i64)
            ),
            Self::Backfilling { stored, .. } => format!(
                "Bringing in your Last.fm history… {} plays",
                group_thousands(*stored as i64)
            ),
            Self::Syncing => "Syncing with Last.fm…".to_string(),
            Self::Synced { at, plays } => format!(
                "Synced {} · {} plays",
                relative_time(*at, now),
                group_thousands(*plays)
            ),
            Self::Failed {
                reason,
                last_synced: Some(at),
                ..
            } => format!("Sync paused: {reason} · last synced {}", relative_time(*at, now)),
            Self::Failed { reason, .. } => format!("Sync paused: {reason}"),
        }
    }
}

/// `n` with thousands separators.
pub fn group_thousands(n: i64) -> String {
    let digits = n.unsigned_abs().to_string();
    let len = digits.len();
    let mut out = String::with_capacity(len + len / 3 + 1);
    if n < 0 {
        out.push('-');
    }
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (len - index).is_multiple_of(3) {
            out.push(',');
        }
        out.push(digit);
    }
    out
}

/// "just now", "5 min ago", "3 h ago", "2 days ago".
fn relative_time(at: i64, now: i64) -> String {
    let seconds = (now - at).max(0);
    match seconds {
        0..=59 => "just now".to_string(),
        60..=3_599 => format!("{} min ago", seconds / 60),
        3_600..=86_399 => format!("{} h ago", seconds / 3_600),
        86_400..=172_799 => "yesterday".to_string(),
        _ => format!("{} days ago", seconds / 86_400),
    }
}

/// What asked for a sync: an automatic trigger keeps its distance from the
/// last sync, a person asking does not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Trigger {
    Automatic,
    Requested,
}

enum Progress {
    Status(HistoryStatus),
    Finished {
        stored: usize,
        reconciled: usize,
        state: Option<HistorySyncState>,
        status: HistoryStatus,
    },
}

fn unix_now() -> i64 {
    chrono::Utc::now().timestamp()
}

/// Starts a sync when one is due, Last.fm is connected and none is running.
pub fn start(core: &Rc<AppCore>, trigger: Trigger) {
    if crate::config::demo_mode() || !crate::lastfm::keys_available() {
        return;
    }
    let Some(session) = core.session.borrow().clone() else {
        set_status(core, HistoryStatus::NotConnected);
        return;
    };
    if core.history_sync_in_flight.get() {
        return;
    }
    let known = core
        .history_state
        .borrow()
        .clone()
        .filter(|state| state.account == session.username);
    if trigger == Trigger::Automatic
        && known.as_ref().is_some_and(|state| !state.automatic_sync_due(unix_now()))
    {
        return;
    }
    let Some(client) = LastFmClient::new(Some(session.key.clone())) else {
        return;
    };
    core.history_sync_in_flight.set(true);
    let legacy_page = core.config.borrow().import_page_cursor;
    let db_path = core.db_path.clone();
    let username = session.username.clone();
    let (tx, rx) = async_channel::unbounded::<Progress>();
    let spawned = std::thread::Builder::new()
        .name("flaccy-history-sync".into())
        .spawn(move || {
            let finished = run(&db_path, &client, &username, legacy_page, &tx);
            let _ = tx.send_blocking(finished);
        });
    if spawned.is_err() {
        core.history_sync_in_flight.set(false);
        return;
    }
    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        while let Ok(progress) = rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            match progress {
                Progress::Status(status) => set_status(&core, status),
                Progress::Finished {
                    stored,
                    reconciled,
                    state,
                    status,
                } => {
                    finish(&core, stored, reconciled, state, status);
                    break;
                }
            }
        }
    });
}

/// Applies a finished sync on the main thread: the new state, the status, and
/// a library reload when play counts moved.
fn finish(
    core: &Rc<AppCore>,
    stored: usize,
    reconciled: usize,
    state: Option<HistorySyncState>,
    status: HistoryStatus,
) {
    core.history_sync_in_flight.set(false);
    if let Some(state) = state {
        if state.backfill_complete && core.config.borrow().import_page_cursor != 1 {
            core.config.borrow_mut().import_page_cursor = 1;
            core.save_config();
        }
        *core.history_state.borrow_mut() = Some(state);
    }
    if core.session.borrow().is_none() {
        set_status(core, HistoryStatus::NotConnected);
        return;
    }
    set_status(core, status);
    if stored > 0 {
        core.hub.emit(&AppEvent::HistorySynced { stored });
    }
    if reconciled > 0 {
        core.reload_library();
    }
}

fn set_status(core: &Rc<AppCore>, status: HistoryStatus) {
    if *core.history_status.borrow() == status {
        return;
    }
    *core.history_status.borrow_mut() = status;
    core.hub.emit(&AppEvent::HistorySyncStatus);
}

/// Whether Stats can trust its own top lists: the whole history is local.
pub fn history_complete(core: &AppCore) -> bool {
    let Some(session) = core.session.borrow().clone() else {
        return true;
    };
    core.history_state
        .borrow()
        .as_ref()
        .is_some_and(|state| state.account == session.username && state.backfill_complete)
}

/// Reads the stored sync state for the connected account on launch, so Stats
/// and the settings know where the history stands before the first sync.
pub fn load_state(core: &Rc<AppCore>) {
    let Some(session) = core.session.borrow().clone() else {
        set_status(core, HistoryStatus::NotConnected);
        return;
    };
    let state = core.db.listen_sync_state(&session.username);
    let plays = core.db.scrobble_count();
    let status = match state.as_ref().and_then(|state| state.last_sync_at.filter(|_| state.backfill_complete)) {
        Some(at) => HistoryStatus::Synced { at, plays },
        None => HistoryStatus::Waiting,
    };
    *core.history_state.borrow_mut() = state;
    set_status(core, status);
}

/// Syncs a while after launch, whenever the window comes forward, and every
/// `PERIODIC_SYNC_SECONDS` while Flaccy runs.
pub fn schedule(core: &Rc<AppCore>) {
    load_state(core);
    let weak = Rc::downgrade(core);
    glib::timeout_add_local_once(Duration::from_secs(12), move || {
        if let Some(core) = weak.upgrade() {
            start(&core, Trigger::Automatic);
        }
    });
    let weak = Rc::downgrade(core);
    glib::timeout_add_seconds_local(PERIODIC_SYNC_SECONDS as u32, move || {
        let Some(core) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        start(&core, Trigger::Automatic);
        glib::ControlFlow::Continue
    });
}

/// The whole sync on the worker thread: opens its own connection, takes up the
/// stored state (or the one an older import left), pulls until the plan is
/// done, and reconciles play counts when anything new arrived.
fn run(
    db_path: &Path,
    client: &LastFmClient,
    username: &str,
    legacy_page: u32,
    tx: &async_channel::Sender<Progress>,
) -> Progress {
    let started = Instant::now();
    let db = match Db::open(&PathBuf::from(db_path)) {
        Ok(db) => db,
        Err(err) => {
            return Progress::Finished {
                stored: 0,
                reconciled: 0,
                state: None,
                status: HistoryStatus::Failed {
                    reason: format!("the library database could not be opened ({err})"),
                    last_synced: None,
                    plays: 0,
                },
            };
        }
    };
    let mut state = db
        .listen_sync_state(username)
        .unwrap_or_else(|| adopted_state(&db, username, legacy_page));
    let mut sync = SyncRun {
        db: &db,
        client,
        username,
        tx,
        ledger: None,
        keys: ListenKeyCache::default(),
        stored: 0,
    };
    let outcome = sync.run_plan(&mut state);
    let stored = sync.stored;
    let reconciled = if stored > 0 {
        db.reconcile_play_counts_from_scrobbles()
    } else {
        0
    };
    let plays = db.scrobble_count();
    crate::logger::info(
        "history",
        &format!(
            "history sync for {username}: {stored} new plays, {reconciled} play counts moved, {plays} plays stored, {} ms",
            started.elapsed().as_millis()
        ),
    );
    let status = match outcome {
        Ok(()) => HistoryStatus::Synced {
            at: state.last_sync_at.unwrap_or_else(unix_now),
            plays,
        },
        Err(reason) => {
            crate::logger::warn("history", &format!("history sync stopped: {reason}"));
            HistoryStatus::Failed {
                reason,
                last_synced: state.last_sync_at,
                plays,
            }
        }
    };
    Progress::Finished {
        stored,
        reconciled,
        state: Some(state),
        status,
    }
}

/// The state for an account this database has never synced: picks up what
/// the import that came before the sync left behind.
fn adopted_state(db: &Db, username: &str, legacy_page: u32) -> HistorySyncState {
    let newest = db.newest_pulled_listen();
    let seeded = db.scrobble_count() >= LEGACY_SEEDED_THRESHOLD;
    let state = HistorySyncState::adopting(
        username,
        legacy_page <= 1 && seeded && newest.is_some(),
        legacy_page,
        newest,
        unix_now(),
    );
    crate::logger::info(
        "history",
        &format!(
            "history sync adopting: backfill complete {}, resume page {}",
            state.backfill_complete, state.backfill_page
        ),
    );
    state
}

/// One sync's working set: the connection, the ledger of what is stored, and
/// how many new plays it stored.
struct SyncRun<'a> {
    db: &'a Db,
    client: &'a LastFmClient,
    username: &'a str,
    tx: &'a async_channel::Sender<Progress>,
    ledger: Option<ListenLedger>,
    keys: ListenKeyCache,
    stored: usize,
}

impl SyncRun<'_> {
    /// Runs steps until a regular pull has been recorded. A backfill records
    /// and saves every page, so a sync that stops resumes at the next one.
    fn run_plan(&mut self, state: &mut HistorySyncState) -> Result<(), String> {
        loop {
            let now = unix_now();
            match state.next_step(now) {
                HistorySyncStep::Backfill { page, to } => {
                    self.ensure_ledger(None);
                    let (newest, total_pages) = self.pull_page(page, RecentWindow { from: None, to: Some(to) })?;
                    state.record_backfill_page(page, total_pages.min(MAX_PAGES), to, newest, now);
                    self.save(state);
                    self.report(HistoryStatus::Backfilling {
                        stored: self.stored,
                        page,
                        total_pages,
                    });
                }
                step @ (HistorySyncStep::CatchUp { from } | HistorySyncStep::Settle { from }) => {
                    self.report(HistoryStatus::Syncing);
                    self.ensure_ledger(Some(from - 1));
                    let newest = self.pull_all(from)?;
                    state.record_pull(step, newest, now);
                    self.save(state);
                    return Ok(());
                }
            }
        }
    }

    /// Every page from `from` on, newest first. Nothing is recorded unless
    /// every page arrived, so a pull that breaks off is made again whole.
    fn pull_all(&mut self, from: i64) -> Result<Option<i64>, String> {
        let mut newest: Option<i64> = None;
        let mut page = 1;
        loop {
            let (page_newest, total_pages) = self.pull_page(page, RecentWindow { from: Some(from), to: None })?;
            newest = newest.max(page_newest);
            if page >= total_pages.min(MAX_PAGES) {
                return Ok(newest);
            }
            page += 1;
        }
    }

    /// Fetches one page, stores the plays on it that are new, and answers
    /// the newest time on it with the page count.
    fn pull_page(&mut self, page: u32, window: RecentWindow) -> Result<(Option<i64>, u32), String> {
        let (tracks, total_pages) = fetch_page_with_retry(self.client, self.username, page, window)?;
        let newest = tracks.iter().map(|(uts, ..)| *uts).max();
        let ledger = self.ledger.get_or_insert_with(ListenLedger::default);
        let fresh: Vec<PulledListen> = tracks
            .into_iter()
            .filter(|(uts, title, artist, album)| ledger.admit(*uts, &self.keys.keys(title, artist, album)))
            .map(|(timestamp_unix, title, artist, album)| PulledListen {
                timestamp_unix,
                title,
                artist,
                album,
            })
            .collect();
        match self.db.insert_pulled_listens(&fresh) {
            Ok(count) => self.stored += count,
            Err(err) => return Err(format!("the library database refused new plays ({err})")),
        }
        Ok((newest, total_pages.max(1)))
    }

    /// Reads what is stored once per sync: the whole history for a backfill,
    /// the pulled window for a regular pull.
    fn ensure_ledger(&mut self, since: Option<i64>) {
        if self.ledger.is_none() {
            let stored = self.db.stored_listens_since(since.unwrap_or(0));
            self.ledger = Some(ListenLedger::new(stored));
        }
    }

    fn save(&self, state: &HistorySyncState) {
        if let Err(err) = self.db.save_listen_sync_state(state) {
            crate::logger::error("history", &format!("saving the sync state failed: {err}"));
        }
    }

    fn report(&self, status: HistoryStatus) {
        let _ = self.tx.send_blocking(Progress::Status(status));
    }
}

/// Fetches one page, retrying Last.fm's transient failures (its "backend
/// service failed" answers are common on long pulls) with linear backoff.
fn fetch_page_with_retry(
    client: &LastFmClient,
    username: &str,
    page: u32,
    window: RecentWindow,
) -> Result<RecentPage, String> {
    let mut attempt = 0u32;
    loop {
        match client.fetch_recent_tracks(username, page, PAGE_LIMIT, window) {
            Ok(result) => return Ok(result),
            Err(err) => {
                attempt += 1;
                if attempt > MAX_PAGE_RETRIES {
                    return Err(friendly_reason(&err));
                }
                let backoff = RETRY_BACKOFF_MS * attempt as u64;
                crate::logger::info(
                    "history",
                    &format!("history page {page} attempt {attempt} failed ({err}); retrying in {backoff}ms"),
                );
                std::thread::sleep(Duration::from_millis(backoff));
            }
        }
    }
}

/// What a person is told when Last.fm keeps failing: the cause without the
/// transport detail, which goes to the log.
fn friendly_reason(err: &str) -> String {
    let lowered = err.to_lowercase();
    if lowered.contains("dns") || lowered.contains("connect") || lowered.contains("timed out") || lowered.contains("network") {
        "Last.fm could not be reached".to_string()
    } else if lowered.contains("invalid session") || lowered.contains("authentication") {
        "Last.fm no longer accepts this connection; reconnect in Settings".to_string()
    } else {
        "Last.fm is not answering right now".to_string()
    }
}

/// Synchronous sync for the `--import-history` headless entry point (no GTK,
/// no single-instance lock): runs the whole plan and answers how many new
/// plays it stored.
pub fn sync_blocking(db_path: &Path, session: &crate::config::Session, legacy_page: u32) -> Result<usize, String> {
    let Some(client) = LastFmClient::new(Some(session.key.clone())) else {
        return Err("this build has no Last.fm API keys".to_string());
    };
    let (tx, rx) = async_channel::unbounded::<Progress>();
    let finished = run(db_path, &client, &session.username, legacy_page, &tx);
    while let Ok(progress) = rx.try_recv() {
        if let Progress::Status(HistoryStatus::Backfilling { stored, page, total_pages }) = progress {
            println!("page {page} of {total_pages}: {stored} new plays so far");
        }
    }
    match finished {
        Progress::Finished {
            stored,
            status: HistoryStatus::Failed { reason, .. },
            ..
        } => Err(format!("{reason} (stored {stored} new plays before stopping)")),
        Progress::Finished { stored, .. } => Ok(stored),
        Progress::Status(_) => Ok(0),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn the_status_line_says_where_the_sync_stands() {
        assert_eq!(
            HistoryStatus::Synced { at: NOW - 30, plays: 164_913 }.line(NOW),
            "Synced just now · 164,913 plays"
        );
        assert_eq!(
            HistoryStatus::Synced { at: NOW - 300, plays: 12 }.line(NOW),
            "Synced 5 min ago · 12 plays"
        );
        assert_eq!(
            HistoryStatus::Backfilling { stored: 41_200, page: 206, total_pages: 825 }.line(NOW),
            "Bringing in your Last.fm history… 41,200 plays · page 206 of 825"
        );
        assert_eq!(
            HistoryStatus::Backfilling { stored: 3, page: 1, total_pages: 1 }.line(NOW),
            "Bringing in your Last.fm history… 3 plays"
        );
        assert_eq!(
            HistoryStatus::Failed {
                reason: "Last.fm could not be reached".to_string(),
                last_synced: Some(NOW - 3 * 86_400),
                plays: 5
            }
            .line(NOW),
            "Sync paused: Last.fm could not be reached · last synced 3 days ago"
        );
    }

    #[test]
    fn relative_times_round_down() {
        assert_eq!(relative_time(NOW, NOW), "just now");
        assert_eq!(relative_time(NOW - 59, NOW), "just now");
        assert_eq!(relative_time(NOW - 60, NOW), "1 min ago");
        assert_eq!(relative_time(NOW - 7_200, NOW), "2 h ago");
        assert_eq!(relative_time(NOW - 90_000, NOW), "yesterday");
        assert_eq!(relative_time(NOW + 30, NOW), "just now");
    }

    #[test]
    fn counts_group_their_thousands() {
        assert_eq!(group_thousands(0), "0");
        assert_eq!(group_thousands(999), "999");
        assert_eq!(group_thousands(1_000), "1,000");
        assert_eq!(group_thousands(164_913), "164,913");
        assert_eq!(group_thousands(-1_234_567), "-1,234,567");
    }

    #[test]
    fn failures_are_told_without_transport_detail() {
        assert_eq!(friendly_reason("ureq: Dns Failed: resolve"), "Last.fm could not be reached");
        assert_eq!(
            friendly_reason("lastfm error 9: Invalid session key"),
            "Last.fm no longer accepts this connection; reconnect in Settings"
        );
        assert_eq!(friendly_reason("user.getRecentTracks: Operation failed"), "Last.fm is not answering right now");
    }
}
