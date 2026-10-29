use crate::metrics::read_rss_kb;
use crate::monitor::Monitor;
use crate::shared::Shared;
use std::time::{Duration, Instant};

const FRESH_WARMUP: Duration = Duration::from_secs(4);

fn current_kb(shared: &Shared) -> Option<u64> {
    shared.server.pid().and_then(read_rss_kb)
}

/// Leaves the server idle for the configured time and answers one line comparing its memory before the quiet period, after it, and in a fresh process on the same data.
pub fn memory_probe(shared: &Shared) -> Option<String> {
    if shared.quiet_secs == 0 {
        return None;
    }
    let before = current_kb(shared)?;
    let mut monitor = Monitor::new();
    let until = Instant::now() + Duration::from_secs(shared.quiet_secs);
    while Instant::now() < until {
        monitor.poll(shared);
        std::thread::sleep(Duration::from_millis(500));
    }
    let after = current_kb(shared)?;
    crate::monitor::terminate(shared);
    crate::monitor::restart(shared);
    std::thread::sleep(FRESH_WARMUP);
    let fresh = current_kb(shared)?;
    Some(format!(
        "memory probe: long-lived process {before} kB at the end of the load, {after} kB after {}s idle, fresh process on the same data {fresh} kB",
        shared.quiet_secs
    ))
}
