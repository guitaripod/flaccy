use crate::canon::Canon;
use crate::fixtures::LYRIC_SONGS;
use crate::rngs::stream;
use crate::shared::Shared;
use crate::sync_util::locked;
use crate::tracker::Tracker;
use crate::workload;
use flaccy_library::db::{Db, LyricsContent};
use flaccy_library::server_sync::{Backoff, Driver, ServerLink, SyncState, SyncStatus, TokenStore};
use rand::rngs::StdRng;
use rand::Rng;
use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

const BACKOFF: Backoff = Backoff { base_ms: 150, max_ms: 1200, attempts: 3 };
const ENROLL_LIMIT: Duration = Duration::from_secs(180);
const SYNC_AT_LEAST: Duration = Duration::from_secs(20);
const COPY_EVERY: Duration = Duration::from_secs(150);
const COPY_MIN_AGE: Duration = Duration::from_secs(45);
const TICK_SECONDS: f64 = 1.4;
const REINSTALLS_PER_MINUTE: f64 = 0.06;
const RESTORES_PER_MINUTE: f64 = 0.07;

/// One simulated device: its own database, its own driver and its own random stream.
pub struct Client {
    pub(crate) name: String,
    pub(crate) shared: Arc<Shared>,
    pub(crate) db: Db,
    pub(crate) rng: StdRng,
    driver: Driver,
    root: PathBuf,
    dir: PathBuf,
    generation: u32,
    tracker: Tracker,
    copy: Option<(PathBuf, Instant)>,
    last_copy_attempt: Instant,
    offline_until: Option<Instant>,
    last_sync: Instant,
    last_status: Option<SyncStatus>,
}

impl Client {
    /// Creates the device, scans the library into its database and enrolls it through the proxy.
    pub fn start(index: usize, root: &Path, shared: Arc<Shared>) -> Result<Client, String> {
        let name = format!("client-{index}");
        let root = root.join(&name);
        let dir = root.join("gen-0");
        let (db, driver) = provision(&dir, &shared)?;
        let mut client = Client {
            rng: stream(shared.seed, &name),
            name,
            shared,
            db,
            driver,
            root,
            dir,
            generation: 0,
            tracker: Tracker::default(),
            copy: None,
            last_copy_attempt: Instant::now(),
            offline_until: None,
            last_sync: Instant::now(),
            last_status: None,
        };
        client.enroll()?;
        Ok(client)
    }

    /// Runs the workload until told to stop or the deadline passes.
    pub fn run(mut self, deadline: Instant) -> Client {
        while !self.shared.halted() && Instant::now() < deadline {
            self.tick();
        }
        self
    }

    /// One sync round, with its latency and queue bookkeeping.
    pub fn sync_once(&mut self) -> SyncStatus {
        let started = Instant::now();
        let status = self.driver.run_once(&self.db);
        self.shared.latency.record_round(started.elapsed());
        self.last_sync = Instant::now();
        self.shared.tally.bump("sync_rounds");
        self.count_state(&status);
        self.observe();
        self.last_status = Some(status.clone());
        status
    }

    /// The client's name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// What this client shows.
    pub fn canon(&self) -> Canon {
        Canon::of_client(&self.db, &self.shared.catalog)
    }

    /// The last sync status, for the report.
    pub fn last_status(&self) -> Option<&SyncStatus> {
        self.last_status.as_ref()
    }

    /// Mutations still queued.
    pub fn queued(&self) -> usize {
        self.tracker.queued()
    }

    fn tick(&mut self) {
        self.lifecycle();
        for _ in 0..self.rng.random_range(1..=4) {
            self.work();
        }
        self.observe();
        let due = self.rng.random_bool(0.45) || self.last_sync.elapsed() > SYNC_AT_LEAST;
        if self.online() && due {
            self.sync_once();
        }
        self.maybe_go_offline();
        self.think();
    }

    fn work(&mut self) {
        match workload::step(self) {
            Ok(_) => self.shared.tally.bump("user_actions"),
            Err(error) => {
                self.shared.tally.bump("workload_errors");
                self.shared.note(format!("{}: workload error: {error}", self.name));
            }
        }
    }

    fn online(&mut self) -> bool {
        match self.offline_until {
            Some(until) if Instant::now() < until => false,
            Some(_) => {
                self.offline_until = None;
                true
            }
            None => true,
        }
    }

    fn maybe_go_offline(&mut self) {
        if self.offline_until.is_none() && self.rng.random_bool(0.012) {
            let seconds = self.rng.random_range(8..45);
            self.offline_until = Some(Instant::now() + Duration::from_secs(seconds));
            self.shared.tally.bump("offline_periods");
        }
    }

    fn think(&mut self) {
        let mut remaining = self.rng.random_range(150..2200);
        while remaining > 0 && !self.shared.halted() {
            let slice = remaining.min(100);
            std::thread::sleep(Duration::from_millis(slice));
            remaining -= slice;
        }
    }

    fn rare(&mut self, per_minute: f64, boost: f64) -> bool {
        self.rng.random_bool((per_minute * boost * TICK_SECONDS / 60.0).min(1.0))
    }

    fn lifecycle(&mut self) {
        self.maybe_save_copy();
        if self.rare(REINSTALLS_PER_MINUTE, 1.0) {
            let result = self.reinstall();
            self.report_failure("reinstall", result);
        } else if self.rare(RESTORES_PER_MINUTE, self.shared.lifecycle_boost) {
            let result = self.restore();
            self.report_failure("restore", result);
        }
    }

    fn report_failure(&self, what: &str, result: Result<(), String>) {
        if let Err(error) = result {
            self.shared.tally.bump("lifecycle_errors");
            self.shared.note(format!("{}: {what} failed: {error}", self.name));
        }
    }

    fn database_path(&self) -> PathBuf {
        self.dir.join("library.sqlite")
    }

    fn observe(&mut self) {
        let path = self.database_path();
        let mut oracle = locked(&self.shared.oracle);
        if let Err(error) = self.tracker.observe(&path, &mut oracle) {
            self.shared.tally.bump("tracker_errors");
            self.shared.note(format!("{}: {error}", self.name));
        }
    }

    fn count_state(&self, status: &SyncStatus) {
        let key = match &status.state {
            SyncState::UpToDate => "rounds_up_to_date",
            SyncState::Syncing(_) => "rounds_syncing",
            SyncState::Offline => "rounds_offline",
            SyncState::NeedsAttention(text) => {
                if !text.contains("cannot read") {
                    self.shared.note(format!("{}: needs attention: {text}", self.name));
                }
                "rounds_needs_attention"
            }
            SyncState::Blocked(_) => "rounds_blocked",
        };
        self.shared.tally.bump(key);
    }

    fn enroll(&mut self) -> Result<(), String> {
        let started = Instant::now();
        let mut last_error = String::new();
        while started.elapsed() < ENROLL_LIMIT {
            let code = self.shared.server.enroll_code()?;
            let link = ServerLink::new(&self.shared.proxy_url, Some(&code), Some("soak"));
            match self.driver.enroll(&self.db, &link, &self.name) {
                Ok(_) => return self.adopt_queue(),
                Err(error) => last_error = error.to_string(),
            }
            std::thread::sleep(Duration::from_millis(400));
        }
        Err(format!("{} could not enroll within {}s: {last_error}", self.name, ENROLL_LIMIT.as_secs()))
    }

    fn adopt_queue(&mut self) -> Result<(), String> {
        let path = self.database_path();
        let mut oracle = locked(&self.shared.oracle);
        self.tracker.restart(&path, &mut oracle)
    }

    fn maybe_save_copy(&mut self) {
        if self.last_copy_attempt.elapsed() < COPY_EVERY.div_f64(self.shared.lifecycle_boost.max(0.001)) {
            return;
        }
        self.last_copy_attempt = Instant::now();
        let target = self.dir.join("backup.sqlite");
        let _ = std::fs::remove_file(&target);
        match snapshot(&self.database_path(), &target) {
            Ok(()) => self.copy = Some((target, Instant::now())),
            Err(error) => self.shared.note(format!("{}: backup failed: {error}", self.name)),
        }
    }

    fn reinstall(&mut self) -> Result<(), String> {
        let next = self.next_dir();
        let (db, driver) = provision(&next, &self.shared)?;
        let old = std::mem::replace(&mut self.dir, next);
        self.db = db;
        self.driver = driver;
        self.copy = None;
        let _ = std::fs::remove_dir_all(old);
        self.shared.tally.bump("reinstalls");
        self.enroll()
    }

    fn restore(&mut self) -> Result<(), String> {
        let Some((copy, taken)) = self.copy.clone() else {
            return Ok(());
        };
        if taken.elapsed() < COPY_MIN_AGE.div_f64(self.shared.lifecycle_boost.max(0.001)) {
            return Ok(());
        }
        let next = self.next_dir();
        std::fs::create_dir_all(&next).map_err(|error| format!("cannot create {}: {error}", next.display()))?;
        std::fs::copy(&copy, next.join("library.sqlite")).map_err(|error| format!("cannot copy the backup: {error}"))?;
        std::fs::copy(self.dir.join("sync-token"), next.join("sync-token")).map_err(|error| format!("cannot copy the token: {error}"))?;
        let db = Db::open(&next.join("library.sqlite")).map_err(|error| format!("cannot open the backup: {error}"))?;
        let driver = Driver::new(TokenStore::new(next.join("sync-token")), None).with_backoff(BACKOFF);
        let old = std::mem::replace(&mut self.dir, next);
        self.db = db;
        self.driver = driver;
        self.copy = None;
        let _ = std::fs::remove_dir_all(old);
        self.shared.tally.bump("stale_restores");
        self.adopt_queue()
    }

    fn next_dir(&mut self) -> PathBuf {
        self.generation += 1;
        self.root.join(format!("gen-{}", self.generation))
    }
}

fn provision(dir: &Path, shared: &Shared) -> Result<(Db, Driver), String> {
    std::fs::create_dir_all(dir).map_err(|error| format!("cannot create {}: {error}", dir.display()))?;
    let db = Db::open(&dir.join("library.sqlite")).map_err(|error| format!("cannot open the database: {error}"))?;
    for song in &shared.catalog.songs {
        db.insert_track(&shared.catalog.new_track(song))
            .map_err(|error| format!("cannot scan {}: {error}", song.rel_path))?;
    }
    for song in shared.catalog.songs.iter().take(LYRIC_SONGS) {
        let content = LyricsContent { synced: None, plain: Some("la la".into()), lyricsfile: None, instrumental: false, revision: 0 };
        db.save_lyrics(&song.title, &song.artist, &content)
            .map_err(|error| format!("cannot store lyrics: {error}"))?;
    }
    let driver = Driver::new(TokenStore::new(dir.join("sync-token")), None).with_backoff(BACKOFF);
    Ok((db, driver))
}

fn snapshot(source: &Path, target: &Path) -> Result<(), String> {
    let connection = Connection::open(source).map_err(|error| format!("cannot open for backup: {error}"))?;
    connection
        .execute("VACUUM INTO ?1", [target.to_string_lossy().as_ref()])
        .map(|_| ())
        .map_err(|error| format!("VACUUM INTO failed: {error}"))
}
