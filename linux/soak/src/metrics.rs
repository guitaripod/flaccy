use crate::sync_util::locked;
use std::sync::Mutex;
use std::time::Duration;

/// Which call a latency belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Route {
    /// `POST /sync/push`.
    Push,
    /// `GET /sync/pull`.
    Pull,
    /// Everything else.
    Other,
}

/// Latencies in microseconds, kept per route.
#[derive(Default)]
pub struct Latency {
    push: Mutex<Vec<u64>>,
    pull: Mutex<Vec<u64>>,
    round: Mutex<Vec<u64>>,
}

/// Percentiles of one series.
#[derive(Clone, Debug)]
pub struct Percentiles {
    /// The series name.
    pub label: &'static str,
    /// How many samples.
    pub count: usize,
    /// Median in milliseconds.
    pub p50_ms: f64,
    /// 99th percentile in milliseconds.
    pub p99_ms: f64,
    /// Slowest in milliseconds.
    pub max_ms: f64,
}

impl Latency {
    /// Records a fault-free request that crossed the proxy.
    pub fn record(&self, route: Route, took: Duration) {
        let micros = took.as_micros() as u64;
        match route {
            Route::Push => locked(&self.push).push(micros),
            Route::Pull => locked(&self.pull).push(micros),
            Route::Other => {}
        }
    }

    /// Records the wall time of one client sync round.
    pub fn record_round(&self, took: Duration) {
        locked(&self.round).push(took.as_micros() as u64);
    }

    /// Percentiles of every series.
    pub fn summary(&self) -> Vec<Percentiles> {
        vec![
            percentiles("push (proxy, fault-free)", &self.push),
            percentiles("pull (proxy, fault-free)", &self.pull),
            percentiles("client sync round", &self.round),
        ]
    }
}

fn percentiles(label: &'static str, series: &Mutex<Vec<u64>>) -> Percentiles {
    let mut samples = locked(series).clone();
    samples.sort_unstable();
    let at = |fraction: f64| -> f64 {
        if samples.is_empty() {
            return 0.0;
        }
        let index = ((samples.len() as f64 - 1.0) * fraction).round() as usize;
        samples[index] as f64 / 1000.0
    };
    Percentiles {
        label,
        count: samples.len(),
        p50_ms: at(0.5),
        p99_ms: at(0.99),
        max_ms: at(1.0),
    }
}

/// One resident-set sample of the server process.
#[derive(Clone, Copy, Debug)]
pub struct RssSample {
    /// Milliseconds since the run began.
    pub at_ms: u64,
    /// Resident kilobytes.
    pub kb: u64,
    /// The server process the sample came from.
    pub pid: u32,
}

/// Resident kilobytes of `pid`, from `/proc/<pid>/status`.
pub fn read_rss_kb(pid: u32) -> Option<u64> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let line = status.lines().find(|line| line.starts_with("VmRSS:"))?;
    line.split_whitespace().nth(1)?.parse().ok()
}

/// What the memory check concluded.
#[derive(Clone, Debug)]
pub struct RssSummary {
    /// Median at the 10% mark, kilobytes.
    pub early_kb: u64,
    /// Median at the 100% mark, kilobytes.
    pub late_kb: u64,
    /// Highest sample, kilobytes.
    pub peak_kb: u64,
    /// How many samples.
    pub samples: usize,
}

impl RssSummary {
    /// Late over early.
    pub fn ratio(&self) -> f64 {
        if self.early_kb == 0 {
            return 0.0;
        }
        self.late_kb as f64 / self.early_kb as f64
    }
}

/// Medians around the 10% mark and at the end of the run; `None` when too few samples exist.
pub fn summarise_rss(samples: &[RssSample], total_ms: u64) -> Option<RssSummary> {
    if samples.len() < 4 || total_ms == 0 {
        return None;
    }
    let window = |from: f64, to: f64| -> Vec<u64> {
        samples
            .iter()
            .filter(|sample| {
                let fraction = sample.at_ms as f64 / total_ms as f64;
                fraction >= from && fraction <= to
            })
            .map(|sample| sample.kb)
            .collect()
    };
    let early = median(window(0.07, 0.13));
    let late = median(window(0.95, 1.5));
    Some(RssSummary {
        early_kb: early?,
        late_kb: late?,
        peak_kb: samples.iter().map(|sample| sample.kb).max().unwrap_or(0),
        samples: samples.len(),
    })
}

fn median(mut values: Vec<u64>) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    values.sort_unstable();
    Some(values[values.len() / 2])
}
