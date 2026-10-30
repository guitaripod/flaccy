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

/// Resident kilobytes of `pid`: `/proc/<pid>/status` where the system has one, `ps` otherwise (macOS).
pub fn read_rss_kb(pid: u32) -> Option<u64> {
    read_proc_status(pid).or_else(|| read_ps(pid))
}

/// The `VmRSS` line of `/proc/<pid>/status`.
fn read_proc_status(pid: u32) -> Option<u64> {
    let status = std::fs::read_to_string(format!("/proc/{pid}/status")).ok()?;
    let line = status.lines().find(|line| line.starts_with("VmRSS:"))?;
    line.split_whitespace().nth(1)?.parse().ok()
}

/// What `ps -o rss= -p <pid>` prints: the resident kilobytes alone.
fn read_ps(pid: u32) -> Option<u64> {
    let output = std::process::Command::new("ps").args(["-o", "rss=", "-p", &pid.to_string()]).output().ok()?;
    parse_ps(&String::from_utf8_lossy(&output.stdout))
}

fn parse_ps(text: &str) -> Option<u64> {
    text.trim().parse().ok()
}

/// What the memory check concluded about the longest-lived server process.
#[derive(Clone, Debug)]
pub struct RssSummary {
    /// Median over the middle fifth of that process's life, kilobytes.
    pub mid_kb: u64,
    /// Median over the last tenth of that process's life, kilobytes.
    pub late_kb: u64,
    /// Highest sample of the whole run, kilobytes.
    pub peak_kb: u64,
    /// How many samples the run took.
    pub samples: usize,
    /// How long that process lived, seconds.
    pub life_secs: u64,
}

impl RssSummary {
    /// Late over middle.
    pub fn ratio(&self) -> f64 {
        if self.mid_kb == 0 {
            return 0.0;
        }
        self.late_kb as f64 / self.mid_kb as f64
    }
}

const MIN_LIFE_MS: u64 = 180_000;
const MIN_LIFE_SAMPLES: usize = 60;

/// Medians over the middle and the end of the life of the longest-lived server process; `None` when no process lived long enough
/// to tell a plateau from a climb.
pub fn summarise_rss(samples: &[RssSample]) -> Option<RssSummary> {
    let mut lives: Vec<&[RssSample]> = Vec::new();
    let mut start = 0;
    for index in 1..=samples.len() {
        if index == samples.len() || samples[index].pid != samples[start].pid {
            lives.push(&samples[start..index]);
            start = index;
        }
    }
    let life = lives.into_iter().max_by_key(|life| life.len())?;
    let (first, last) = (life.first()?, life.last()?);
    let span = last.at_ms.saturating_sub(first.at_ms);
    if span < MIN_LIFE_MS || life.len() < MIN_LIFE_SAMPLES {
        return None;
    }
    let window = |from: f64, to: f64| -> Vec<u64> {
        life.iter()
            .filter(|sample| {
                let fraction = (sample.at_ms - first.at_ms) as f64 / span as f64;
                fraction >= from && fraction <= to
            })
            .map(|sample| sample.kb)
            .collect()
    };
    Some(RssSummary {
        mid_kb: median(window(0.4, 0.6))?,
        late_kb: median(window(0.9, 1.0))?,
        peak_kb: samples.iter().map(|sample| sample.kb).max().unwrap_or(0),
        samples: samples.len(),
        life_secs: span / 1000,
    })
}

fn median(mut values: Vec<u64>) -> Option<u64> {
    if values.is_empty() {
        return None;
    }
    values.sort_unstable();
    Some(values[values.len() / 2])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ps_prints_the_resident_kilobytes_alone() {
        assert_eq!(parse_ps("  73216\n"), Some(73_216));
        assert_eq!(parse_ps(""), None);
        assert_eq!(parse_ps("RSS\n"), None);
    }

    #[test]
    fn this_process_has_a_resident_size_on_every_unix() {
        assert!(read_rss_kb(std::process::id()).is_some_and(|kb| kb > 0));
        assert!(read_ps(std::process::id()).is_some_and(|kb| kb > 0));
    }

    #[test]
    fn percentiles_pick_the_median_and_the_tail() {
        let latency = Latency::default();
        for millis in 1..=100 {
            latency.record(Route::Push, Duration::from_millis(millis));
        }
        let push = &latency.summary()[0];
        assert_eq!(push.count, 100);
        assert!((push.p50_ms - 51.0).abs() <= 1.0);
        assert!(push.p99_ms >= 99.0);
    }

    fn life(pid: u32, from_ms: u64, count: u64, kb: impl Fn(u64) -> u64) -> Vec<RssSample> {
        (0..count).map(|index| RssSample { at_ms: from_ms + index * 3_000, kb: kb(index), pid }).collect()
    }

    #[test]
    fn the_longest_process_is_judged_by_its_middle_and_its_end() {
        let mut samples = life(1, 0, 70, |_| 20_000);
        samples.extend(life(2, 300_000, 120, |index| if index < 60 { 40_000 } else { 90_000 }));
        let summary = summarise_rss(&samples).unwrap();
        assert_eq!((summary.mid_kb, summary.late_kb), (90_000, 90_000));
        let climbing = life(3, 0, 120, |index| 20_000 + index * 1_000);
        let summary = summarise_rss(&climbing).unwrap();
        assert!(summary.ratio() > 1.4);
    }

    #[test]
    fn a_process_that_lived_briefly_gives_no_verdict() {
        assert!(summarise_rss(&life(1, 0, 30, |_| 20_000)).is_none());
    }
}
