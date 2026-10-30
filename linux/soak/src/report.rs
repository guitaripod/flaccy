use crate::metrics::{Percentiles, RssSummary};

/// The verdict of one invariant.
#[derive(Clone, Debug)]
pub struct Check {
    /// A short label such as `(a) convergence`.
    pub name: &'static str,
    /// The first violating entity and why; `None` when the invariant held.
    pub failure: Option<String>,
}

/// Everything the final block prints.
pub struct Outcome {
    /// The run seed.
    pub seed: u64,
    /// Planned chaos minutes.
    pub minutes: u64,
    /// Client count.
    pub clients: usize,
    /// Wall seconds the whole run took.
    pub wall_secs: u64,
    /// Workload and recovery counters.
    pub counts: Vec<(&'static str, u64)>,
    /// Proxy fault counters.
    pub faults: Vec<(&'static str, u64)>,
    /// Invariant verdicts in order.
    pub checks: Vec<Check>,
    /// Request and round latencies.
    pub latency: Vec<Percentiles>,
    /// Server memory, when enough samples exist.
    pub rss: Option<RssSummary>,
    /// Server lives per kill, for context.
    pub notes: Vec<String>,
}

impl Outcome {
    /// True when every invariant held.
    pub fn passed(&self) -> bool {
        self.checks.iter().all(|check| check.failure.is_none())
    }
}

/// Prints the first line of a run: the seed that reproduces it.
pub fn banner(seed: u64, minutes: u64, clients: usize, binary: &str) {
    println!("flaccy-soak seed={seed} minutes={minutes} clients={clients} server={binary}");
}

/// Prints one progress line.
pub fn progress(message: &str) {
    println!("[soak] {message}");
}

/// Prints the final report block.
pub fn print_outcome(outcome: &Outcome) {
    println!("==== flaccy-soak report ====");
    println!(
        "seed={} minutes={} clients={} wall={}s",
        outcome.seed, outcome.minutes, outcome.clients, outcome.wall_secs
    );
    print_pairs("counts", &outcome.counts);
    print_pairs("proxy faults", &outcome.faults);
    for check in &outcome.checks {
        match &check.failure {
            None => println!("PASS {}", check.name),
            Some(reason) => println!("FAIL {}: {reason}", check.name),
        }
    }
    for series in &outcome.latency {
        println!(
            "latency {}: n={} p50={:.1}ms p99={:.1}ms max={:.1}ms",
            series.label, series.count, series.p50_ms, series.p99_ms, series.max_ms
        );
    }
    match &outcome.rss {
        Some(rss) => println!(
            "server rss (longest process, {}s): middle={}kB end={}kB ratio={:.2} peak of the run={}kB samples={}",
            rss.life_secs,
            rss.mid_kb,
            rss.late_kb,
            rss.ratio(),
            rss.peak_kb,
            rss.samples
        ),
        None => println!("server rss: no process lived long enough to judge"),
    }
    for note in &outcome.notes {
        println!("note: {note}");
    }
    println!("result: {}", if outcome.passed() { "PASS" } else { "FAIL" });
    println!("==== end report ====");
}

fn print_pairs(title: &str, pairs: &[(&'static str, u64)]) {
    let line: Vec<String> = pairs.iter().map(|(key, value)| format!("{key}={value}")).collect();
    println!("{title}: {}", line.join(" "));
}
