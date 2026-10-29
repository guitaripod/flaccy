use crate::monitor::{restart, terminate, Monitor};
use crate::rngs::stream;
use crate::shared::Shared;
use rand::Rng;
use std::sync::Arc;
use std::time::{Duration, Instant};

const BASE_RATE_PER_MILLE: u32 = 130;
const STORM_RATE_PER_MILLE: u32 = 550;
const MIN_KILL_GAP: Duration = Duration::from_secs(15);

enum Action {
    Kill,
    Terminate,
    Refuse,
    Storm,
    Quiet,
}

/// Drives the chaos: proxy faults all the way to `chaos_until`, server kills and SIGTERMs until `kills_until`.
pub fn run(shared: Arc<Shared>, kills_until: Instant, chaos_until: Instant) {
    let mut rng = stream(shared.seed, "controller");
    let mut monitor = Monitor::new();
    let mut last_kill = Instant::now();
    shared.faults.set_rate(BASE_RATE_PER_MILLE);
    shared.faults.set_enabled(true);
    while Instant::now() < chaos_until && !shared.halted() {
        let wait = Duration::from_millis(rng.random_range(4_000..22_000));
        idle(&shared, &mut monitor, wait.min(chaos_until.saturating_duration_since(Instant::now())));
        if Instant::now() >= chaos_until {
            break;
        }
        match pick(&mut rng, Instant::now() < kills_until && last_kill.elapsed() > MIN_KILL_GAP) {
            Action::Kill => {
                last_kill = Instant::now();
                kill_and_restart(&shared, &mut monitor, rng.random_range(0..3_000));
            }
            Action::Terminate => {
                last_kill = Instant::now();
                shared.tally.bump("sigterm_restarts");
                terminate(&shared);
                restart(&shared);
            }
            Action::Refuse => refuse_window(&shared, &mut monitor, rng.random_range(1_000..8_000)),
            Action::Storm => storm(&shared, &mut monitor, rng.random_range(6_000..15_000)),
            Action::Quiet => {}
        }
    }
    shared.faults.set_enabled(false);
    shared.faults.set_refusing(false);
    if shared.server.pid().is_none() {
        restart(&shared);
    }
}

fn pick(rng: &mut impl Rng, may_stop_server: bool) -> Action {
    let roll = rng.random_range(0..100);
    match roll {
        0..=34 if may_stop_server => Action::Kill,
        35..=44 if may_stop_server => Action::Terminate,
        45..=64 => Action::Refuse,
        65..=79 => Action::Storm,
        _ => Action::Quiet,
    }
}

fn idle(shared: &Shared, monitor: &mut Monitor, total: Duration) {
    let until = Instant::now() + total;
    while Instant::now() < until && !shared.halted() {
        monitor.poll(shared);
        std::thread::sleep(Duration::from_millis(250).min(until.saturating_duration_since(Instant::now())));
    }
}

fn kill_and_restart(shared: &Shared, monitor: &mut Monitor, downtime_ms: u64) {
    if shared.server.kill() {
        shared.tally.bump("server_kills");
    }
    idle(shared, monitor, Duration::from_millis(downtime_ms));
    restart(shared);
}

fn refuse_window(shared: &Shared, monitor: &mut Monitor, millis: u64) {
    shared.tally.bump("refuse_windows");
    shared.faults.set_refusing(true);
    idle(shared, monitor, Duration::from_millis(millis));
    shared.faults.set_refusing(false);
}

fn storm(shared: &Shared, monitor: &mut Monitor, millis: u64) {
    shared.tally.bump("fault_storms");
    shared.faults.set_rate(STORM_RATE_PER_MILLE);
    idle(shared, monitor, Duration::from_millis(millis));
    shared.faults.set_rate(BASE_RATE_PER_MILLE);
}
