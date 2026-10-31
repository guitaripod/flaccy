//! How far a scan has got, told three ways: a log line every fifteen seconds, the `scanStatus` call and the
//! `status` command; and, for a scan that takes minutes, the catalog rebuilt along the way so a connected app
//! lists the music already indexed instead of an empty library until the last file is read.

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use flaccy_library::logger;
use flaccy_shared::load_progress::{LoadPhase, LoadProgress};

use crate::setup::grouped;
use crate::state::AppState;

const FIRST_PUBLISH_AFTER: Duration = Duration::from_secs(3);
const MIN_PUBLISH_GAP: Duration = Duration::from_secs(10);
const PUBLISH_GAP_PER_COST: u32 = 8;
const MIN_NEW_TRACKS: usize = 200;
const LOG_EVERY: Duration = Duration::from_secs(15);
const STORED_PROGRESS_KEY: &str = "scanProgress";
const STORED_PROGRESS_FRESH_SECS: i64 = 60;

/// Where the running scan stands.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct ScanSnapshot {
    pub scanning: bool,
    /// New files read so far.
    pub read: usize,
    /// New files this scan has to read.
    pub total: usize,
    /// Songs in the library so far, those from earlier scans included.
    pub indexed: usize,
}

/// The running scan's position, shared with the request handlers.
#[derive(Default)]
pub struct ScanProgress {
    scanning: AtomicBool,
    read: AtomicUsize,
    total: AtomicUsize,
    indexed: AtomicUsize,
}

impl ScanProgress {
    pub fn begin(&self) {
        self.read.store(0, Ordering::Relaxed);
        self.total.store(0, Ordering::Relaxed);
        self.scanning.store(true, Ordering::Relaxed);
    }

    pub fn update(&self, progress: &LoadProgress) {
        if progress.phase != LoadPhase::ReadingTags {
            return;
        }
        self.read.store(progress.completed, Ordering::Relaxed);
        self.total.store(progress.total, Ordering::Relaxed);
        self.indexed.store(progress.tracks_indexed, Ordering::Relaxed);
    }

    pub fn finish(&self) {
        self.scanning.store(false, Ordering::Relaxed);
    }

    pub fn snapshot(&self) -> ScanSnapshot {
        ScanSnapshot {
            scanning: self.scanning.load(Ordering::Relaxed),
            read: self.read.load(Ordering::Relaxed),
            total: self.total.load(Ordering::Relaxed),
            indexed: self.indexed.load(Ordering::Relaxed),
        }
    }
}

/// When a scan in progress should show what it has found: not before three seconds in, then not more often than
/// every ten seconds or eight rebuilds' worth of time, and only when two hundred more songs are in.
pub struct PublishPolicy {
    waiting_since: Instant,
    last_cost: Option<Duration>,
    published_rows: Option<usize>,
}

impl PublishPolicy {
    pub fn new(now: Instant) -> Self {
        Self { waiting_since: now, last_cost: None, published_rows: None }
    }

    fn wait(&self) -> Duration {
        match self.last_cost {
            None => FIRST_PUBLISH_AFTER,
            Some(cost) => MIN_PUBLISH_GAP.max(cost * PUBLISH_GAP_PER_COST),
        }
    }

    pub fn due(&mut self, now: Instant, indexed: usize) -> bool {
        let published = *self.published_rows.get_or_insert(indexed);
        indexed >= published + MIN_NEW_TRACKS && now.duration_since(self.waiting_since) >= self.wait()
    }

    pub fn published(&mut self, now: Instant, cost: Duration, indexed: usize) {
        self.waiting_since = now;
        self.last_cost = Some(cost);
        self.published_rows = Some(indexed);
    }
}

/// Feeds a scan's progress events to the log, the stored progress line and the catalog.
pub struct ScanReporter {
    policy: PublishPolicy,
    last_log: Instant,
    announced: bool,
}

impl ScanReporter {
    pub fn new(now: Instant) -> Self {
        Self { policy: PublishPolicy::new(now), last_log: now, announced: false }
    }

    pub fn observe(&mut self, state: &AppState, progress: &LoadProgress) {
        state.0.scan.update(progress);
        if progress.phase != LoadPhase::ReadingTags || progress.total == 0 {
            return;
        }
        let now = Instant::now();
        if !self.announced {
            self.announced = true;
            logger::info("server", &describe_start(progress));
        } else if now.duration_since(self.last_log) >= LOG_EVERY {
            self.last_log = now;
            logger::info("server", &describe(progress));
            state.0.store.set_state(STORED_PROGRESS_KEY, &stored(progress, chrono::Utc::now().timestamp()));
        }
        if self.policy.due(now, progress.tracks_indexed) {
            state.rebuild_catalog();
            self.policy.published(Instant::now(), now.elapsed(), progress.tracks_indexed);
            logger::info("server", &format!("{} songs are listed while the scan goes on", state.catalog().song_count()));
        }
    }

    pub fn finished(&self, state: &AppState) {
        state.0.scan.finish();
        state.0.store.set_state(STORED_PROGRESS_KEY, "");
    }
}

fn describe_start(progress: &LoadProgress) -> String {
    format!(
        "found {} audio files, {} new to read; songs appear in the apps as they are indexed",
        grouped(progress.files_found),
        grouped(progress.total)
    )
}

fn describe(progress: &LoadProgress) -> String {
    format!("indexing the music folder: {} of {} new files read", grouped(progress.completed), grouped(progress.total))
}

fn stored(progress: &LoadProgress, at: i64) -> String {
    format!("{}/{}@{at}", progress.completed, progress.total)
}

/// The progress a running server stored for `status`, `None` when it is empty, malformed or older than a minute,
/// which is what a server that died mid-scan leaves behind.
pub fn stored_progress(value: &str, now: i64) -> Option<(usize, usize)> {
    let (counts, at) = value.split_once('@')?;
    let (read, total) = counts.split_once('/')?;
    let at: i64 = at.parse().ok()?;
    (now - at < STORED_PROGRESS_FRESH_SECS && now >= at).then_some((read.parse().ok()?, total.parse().ok()?))
}

/// `status` text for a scan in progress.
pub fn status_line(read: usize, total: usize) -> String {
    format!("{} of {} new files read; songs appear in the apps as they are indexed", grouped(read), grouped(total))
}

/// The stored progress for `status`, read from the bookkeeping table.
pub fn current_for_status(state: &AppState) -> Option<(usize, usize)> {
    let value = state.0.store.state(STORED_PROGRESS_KEY)?;
    stored_progress(&value, chrono::Utc::now().timestamp())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn at(seconds: u64) -> Instant {
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        *START.get_or_init(Instant::now) + Duration::from_secs(seconds)
    }

    #[test]
    fn a_scan_shows_nothing_before_three_seconds_or_two_hundred_songs() {
        let mut policy = PublishPolicy::new(at(0));
        assert!(!policy.due(at(1), 50));
        assert!(!policy.due(at(5), 150));
        assert!(!policy.due(at(2), 400));
        assert!(policy.due(at(3), 400));
    }

    #[test]
    fn songs_already_indexed_before_the_scan_do_not_count_as_new() {
        let mut policy = PublishPolicy::new(at(0));
        assert!(!policy.due(at(10), 5_000));
        assert!(!policy.due(at(11), 5_100));
        assert!(policy.due(at(12), 5_200));
    }

    #[test]
    fn after_a_rebuild_the_next_waits_ten_seconds_or_eight_times_its_cost() {
        let mut policy = PublishPolicy::new(at(0));
        assert!(!policy.due(at(0), 0));
        assert!(policy.due(at(4), 300));
        policy.published(at(4), Duration::from_millis(500), 300);
        assert!(!policy.due(at(13), 900));
        assert!(policy.due(at(14), 900));
        policy.published(at(14), Duration::from_secs(4), 900);
        assert!(!policy.due(at(45), 2_000));
        assert!(policy.due(at(46), 2_000));
        policy.published(at(46), Duration::from_secs(1), 2_000);
        assert!(!policy.due(at(50), 2_400));
        assert!(policy.due(at(56), 2_400));
    }

    #[test]
    fn the_stored_progress_is_trusted_only_while_fresh() {
        let progress = LoadProgress { completed: 1_240, total: 7_412, ..LoadProgress::default() };
        let value = stored(&progress, 1_000);
        assert_eq!(stored_progress(&value, 1_030), Some((1_240, 7_412)));
        assert_eq!(stored_progress(&value, 1_061), None);
        assert_eq!(stored_progress("", 1_000), None);
        assert_eq!(stored_progress("12/40", 1_000), None);
        assert_eq!(stored_progress("a/b@1000", 1_000), None);
    }

    #[test]
    fn the_status_line_and_log_line_say_how_far_the_scan_is() {
        assert_eq!(status_line(1_240, 7_412), "1,240 of 7,412 new files read; songs appear in the apps as they are indexed");
        let progress = LoadProgress { phase: LoadPhase::ReadingTags, completed: 50, total: 120, files_found: 9_000, ..LoadProgress::default() };
        assert_eq!(describe(&progress), "indexing the music folder: 50 of 120 new files read");
        assert!(describe_start(&progress).starts_with("found 9,000 audio files, 120 new to read"));
    }

    #[test]
    fn the_shared_position_follows_the_reading_phase_only() {
        let scan = ScanProgress::default();
        scan.begin();
        scan.update(&LoadProgress { phase: LoadPhase::FindingFiles, completed: 9, total: 9, tracks_indexed: 9, ..LoadProgress::default() });
        assert_eq!(scan.snapshot(), ScanSnapshot { scanning: true, read: 0, total: 0, indexed: 0 });
        scan.update(&LoadProgress { phase: LoadPhase::ReadingTags, completed: 30, total: 90, tracks_indexed: 130, ..LoadProgress::default() });
        assert_eq!(scan.snapshot(), ScanSnapshot { scanning: true, read: 30, total: 90, indexed: 130 });
        scan.finish();
        assert!(!scan.snapshot().scanning);
    }
}
