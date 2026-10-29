use crate::sync_util::locked;
use rand::rngs::StdRng;
use rand::Rng;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

/// One kind of damage the proxy does to a request.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Fault {
    /// Holds the request for a moment before forwarding it.
    Delay,
    /// Holds the request for seconds before forwarding it.
    Pause,
    /// Closes the client connection without forwarding anything.
    DropRequest,
    /// Forwards the request, then resets the connection instead of answering.
    DropResponse,
    /// Forwards the request and sends only a prefix of the answer.
    Truncate,
    /// Forwards the request twice at once and answers with one reply.
    Duplicate,
}

const ALL: [(Fault, &str, u32); 6] = [
    (Fault::Delay, "delay", 34),
    (Fault::Pause, "pause", 6),
    (Fault::DropRequest, "drop_request", 12),
    (Fault::DropResponse, "drop_response", 22),
    (Fault::Truncate, "truncate", 14),
    (Fault::Duplicate, "duplicate", 12),
];

fn slot(fault: Fault) -> usize {
    ALL.iter().position(|(kind, _, _)| *kind == fault).unwrap_or(0)
}

/// The proxy's fault switchboard: on or off, how often, and what it has done.
pub struct Faults {
    enabled: AtomicBool,
    refusing: AtomicBool,
    per_mille: AtomicU32,
    counts: [AtomicU64; 6],
    refused: AtomicU64,
    rng: Mutex<StdRng>,
}

impl Faults {
    /// A switchboard that starts disabled.
    pub fn new(rng: StdRng) -> Self {
        Faults {
            enabled: AtomicBool::new(false),
            refusing: AtomicBool::new(false),
            per_mille: AtomicU32::new(0),
            counts: Default::default(),
            refused: AtomicU64::new(0),
            rng: Mutex::new(rng),
        }
    }

    /// Turns random faults on or off.
    pub fn set_enabled(&self, enabled: bool) {
        self.enabled.store(enabled, Ordering::SeqCst);
    }

    /// Sets how many requests in a thousand get a fault.
    pub fn set_rate(&self, per_mille: u32) {
        self.per_mille.store(per_mille, Ordering::SeqCst);
    }

    /// Starts or ends a window in which every connection is refused.
    pub fn set_refusing(&self, refusing: bool) {
        self.refusing.store(refusing, Ordering::SeqCst);
    }

    /// True while the refuse-all window is open.
    pub fn refusing(&self) -> bool {
        self.refusing.load(Ordering::SeqCst)
    }

    /// Counts a connection refused during a window.
    pub fn note_refused(&self) {
        self.refused.fetch_add(1, Ordering::SeqCst);
    }

    /// Decides the fate of the next request.
    pub fn roll(&self) -> Option<Fault> {
        if !self.enabled.load(Ordering::SeqCst) {
            return None;
        }
        let mut rng = locked(&self.rng);
        if rng.random_range(0..1000) >= self.per_mille.load(Ordering::SeqCst) {
            return None;
        }
        let mut pick = rng.random_range(0..100);
        for (fault, _, weight) in ALL {
            if pick < weight {
                self.counts[slot(fault)].fetch_add(1, Ordering::SeqCst);
                return Some(fault);
            }
            pick -= weight;
        }
        None
    }

    /// A random number of milliseconds in `low..high`.
    pub fn pick_ms(&self, low: u64, high: u64) -> u64 {
        locked(&self.rng).random_range(low..high)
    }

    /// Where to cut an answer of `length` bytes: at least one byte, never all of it.
    pub fn cut_at(&self, length: usize) -> usize {
        if length < 2 {
            return 0;
        }
        locked(&self.rng).random_range(1..length)
    }

    /// Every counter by kind, refusals included.
    pub fn counts(&self) -> Vec<(&'static str, u64)> {
        let mut rows: Vec<(&'static str, u64)> = ALL
            .iter()
            .map(|(fault, label, _)| (*label, self.counts[slot(*fault)].load(Ordering::SeqCst)))
            .collect();
        rows.push(("refused_connections", self.refused.load(Ordering::SeqCst)));
        rows
    }
}
