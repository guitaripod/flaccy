use crate::faults::Faults;
use crate::fixtures::Catalog;
use crate::metrics::{Latency, RssSample};
use crate::oracle::Oracle;
use crate::server::Server;
use crate::sync_util::locked;
use crate::tally::Tally;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Instant;

const MAX_NOTES: usize = 40;

/// Everything the harness threads share.
pub struct Shared {
    /// The run seed.
    pub seed: u64,
    /// Planned minutes of workload and chaos.
    pub minutes: u64,
    /// Multiplier on client reinstall and restore rates.
    pub lifecycle_boost: f64,
    /// Idle seconds for the memory probe after the final checks.
    pub quiet_secs: u64,
    /// The generated library.
    pub catalog: Catalog,
    /// The server child process.
    pub server: Server,
    /// The proxy URL clients are enrolled against.
    pub proxy_url: String,
    /// The proxy fault switchboard.
    pub faults: Arc<Faults>,
    /// Request and round latencies.
    pub latency: Arc<Latency>,
    /// What clients saw acknowledged.
    pub oracle: Mutex<Oracle>,
    /// Counters.
    pub tally: Tally,
    /// Set to stop the workload.
    pub halt: AtomicBool,
    /// When the run began.
    pub started: Instant,
    names: AtomicU64,
    notes: Mutex<Vec<String>>,
    server_exits: Mutex<Vec<String>>,
    rss: Mutex<Vec<RssSample>>,
}

impl Shared {
    /// Wires the shared state together.
    pub fn new(seed: u64, args: &crate::args::RunArgs, catalog: Catalog, server: Server, proxy_url: String, faults: Arc<Faults>, latency: Arc<Latency>) -> Shared {
        Shared {
            seed,
            minutes: args.minutes,
            lifecycle_boost: args.lifecycle_boost,
            quiet_secs: args.quiet_secs,
            catalog,
            server,
            proxy_url,
            faults,
            latency,
            oracle: Mutex::new(Oracle::default()),
            tally: Tally::default(),
            halt: AtomicBool::new(false),
            started: Instant::now(),
            names: AtomicU64::new(0),
            notes: Mutex::new(Vec::new()),
            server_exits: Mutex::new(Vec::new()),
            rss: Mutex::new(Vec::new()),
        }
    }

    /// Planned chaos length in milliseconds.
    pub fn chaos_ms(&self) -> u64 {
        self.minutes * 60_000
    }

    /// A playlist name no other playlist has had in this run.
    pub fn next_playlist_name(&self) -> String {
        format!("Soak Playlist {:05}", self.names.fetch_add(1, Ordering::SeqCst))
    }

    /// True once the workload was told to stop.
    pub fn halted(&self) -> bool {
        self.halt.load(Ordering::SeqCst)
    }

    /// Keeps a line for the final report, up to a cap.
    pub fn note(&self, text: String) {
        let mut notes = locked(&self.notes);
        if notes.len() < MAX_NOTES {
            notes.push(text);
        }
    }

    /// Every note so far.
    pub fn notes(&self) -> Vec<String> {
        locked(&self.notes).clone()
    }

    /// Records a server exit nobody asked for, or a bad exit after SIGTERM.
    pub fn record_server_exit(&self, text: String) {
        locked(&self.server_exits).push(text);
    }

    /// Every bad server exit so far.
    pub fn server_exits(&self) -> Vec<String> {
        locked(&self.server_exits).clone()
    }

    /// Adds a resident-set sample.
    pub fn push_rss(&self, sample: RssSample) {
        locked(&self.rss).push(sample);
    }

    /// Every resident-set sample so far.
    pub fn rss_samples(&self) -> Vec<RssSample> {
        locked(&self.rss).clone()
    }
}
