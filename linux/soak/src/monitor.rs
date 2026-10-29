use crate::metrics::{read_rss_kb, RssSample};
use crate::server::TermOutcome;
use crate::shared::Shared;
use std::time::{Duration, Instant};

const SAMPLE_EVERY: Duration = Duration::from_secs(2);

/// Watches the server process: samples its memory and restarts it when it dies on its own.
pub struct Monitor {
    last_sample: Instant,
}

impl Monitor {
    /// A monitor that samples at once.
    pub fn new() -> Monitor {
        Monitor { last_sample: Instant::now() - SAMPLE_EVERY }
    }

    /// One look: reap an unexpected exit, restart, and sample memory when due.
    pub fn poll(&mut self, shared: &Shared) {
        if let Some(how) = shared.server.reap_unexpected() {
            shared.tally.bump("unexpected_server_exits");
            shared.record_server_exit(format!("the server exited without being stopped by the harness ({how})"));
            restart(shared);
        }
        if self.last_sample.elapsed() >= SAMPLE_EVERY {
            self.last_sample = Instant::now();
            sample(shared);
        }
    }
}

/// Starts the server, trying a few times, and notes a failure.
pub fn restart(shared: &Shared) {
    let mut last = String::new();
    for _ in 0..3 {
        match shared.server.start() {
            Ok(()) => return,
            Err(error) => last = error,
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    shared.note(format!("server would not restart: {last}"));
}

/// Stops the server with SIGTERM and records an unclean exit as a violation.
pub fn terminate(shared: &Shared) {
    match shared.server.terminate() {
        Some(TermOutcome::Clean) => shared.tally.bump("sigterm_clean_exits"),
        Some(TermOutcome::Unclean(how)) => {
            shared.tally.bump("sigterm_unclean_exits");
            shared.record_server_exit(format!("the server did not exit cleanly after SIGTERM ({how})"));
        }
        None => {}
    }
}

fn sample(shared: &Shared) {
    let Some(pid) = shared.server.pid() else {
        return;
    };
    if let Some(kb) = read_rss_kb(pid) {
        shared.push_rss(RssSample { at_ms: shared.started.elapsed().as_millis() as u64, kb, pid });
    }
}
