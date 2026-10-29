use crate::args::RunArgs;
use crate::client::Client;
use crate::controller;
use crate::faults::Faults;
use crate::fixtures::Catalog;
use crate::invariants::{self, Verdicts};
use crate::metrics::Latency;
use crate::monitor::Monitor;
use crate::proxy;
use crate::report::{self, Outcome};
use crate::rngs::stream;
use crate::server::Server;
use crate::shared::Shared;
use crate::view::Observer;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

const LIVE_CHECK_EVERY: Duration = Duration::from_secs(60);
const KILLS_STOP_AT: f64 = 0.8;

/// Runs the whole soak and answers true when every invariant held.
pub fn execute(args: &RunArgs) -> Result<bool, String> {
    let binary = locate_binary(args)?;
    report::banner(args.seed, args.minutes, args.clients, &binary.display().to_string());
    let root = work_dir(args.seed)?;
    let outcome = run_in(&root, args, &binary);
    if !args.keep {
        let _ = std::fs::remove_dir_all(&root);
    } else {
        report::progress(&format!("kept {}", root.display()));
    }
    let outcome = outcome?;
    report::print_outcome(&outcome);
    Ok(outcome.passed())
}

fn run_in(root: &Path, args: &RunArgs, binary: &Path) -> Result<Outcome, String> {
    let started = Instant::now();
    let music = root.join("music");
    report::progress("generating the fixture library");
    let catalog = Catalog::generate(&music)?;
    let pinned = root.join("flaccy-server");
    std::fs::copy(binary, &pinned).map_err(|error| format!("cannot copy {}: {error}", binary.display()))?;
    let server = Server::prepare(&pinned, root, &music)?;
    server.start()?;
    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .map_err(|error| format!("cannot start the proxy runtime: {error}"))?;
    let faults = Arc::new(Faults::new(stream(args.seed, "proxy")));
    let latency = Arc::new(Latency::default());
    let proxy_address = runtime.block_on(proxy::start(server.address(), faults.clone(), latency.clone()))?;
    let observer = Observer::enroll(&server.url(), &server.enroll_code()?)?;
    let shared = Arc::new(Shared::new(args.seed, args.minutes, catalog, server, format!("http://{proxy_address}"), faults, latency));
    let mut clients = start_clients(args, root, &shared)?;
    report::progress(&format!("{} clients enrolled; chaos for {} minutes", clients.len(), args.minutes));
    let (controller, workers, deadline) = launch(args, &shared, &mut clients);
    let mut verdicts = Verdicts::default();
    supervise(&shared, &observer, &mut verdicts, deadline);
    shared.halt.store(true, std::sync::atomic::Ordering::SeqCst);
    let _ = controller.join();
    let mut clients = join_workers(workers, &shared)?;
    report::progress("chaos over; settling");
    let mut monitor = Monitor::new();
    monitor.poll(&shared);
    let rss = invariants::finish(&shared, &observer, &mut clients, &mut verdicts);
    drop(runtime);
    Ok(outcome(args, &shared, verdicts, rss, started.elapsed()))
}

fn start_clients(args: &RunArgs, root: &Path, shared: &Arc<Shared>) -> Result<Vec<Client>, String> {
    let base = root.join("clients");
    (0..args.clients).map(|index| Client::start(index, &base, shared.clone())).collect()
}

type Workers = Vec<JoinHandle<Client>>;

fn launch(args: &RunArgs, shared: &Arc<Shared>, clients: &mut Vec<Client>) -> (JoinHandle<()>, Workers, Instant) {
    let begun = Instant::now();
    let chaos_until = begun + Duration::from_secs(args.minutes * 60);
    let kills_until = begun + Duration::from_secs_f64(args.minutes as f64 * 60.0 * KILLS_STOP_AT);
    let controller = {
        let shared = shared.clone();
        std::thread::spawn(move || controller::run(shared, kills_until, chaos_until))
    };
    let workers = clients.drain(..).map(|client| std::thread::spawn(move || client.run(chaos_until))).collect();
    (controller, workers, chaos_until)
}

fn supervise(shared: &Shared, observer: &Observer, verdicts: &mut Verdicts, deadline: Instant) {
    let mut next_check = Instant::now() + LIVE_CHECK_EVERY;
    while Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(500));
        if Instant::now() >= next_check {
            next_check = Instant::now() + LIVE_CHECK_EVERY;
            invariants::live(shared, observer, verdicts);
            progress(shared);
        }
    }
}

fn progress(shared: &Shared) {
    let oracle = crate::sync_util::locked(&shared.oracle);
    report::progress(&format!(
        "t={}s issued={} acked={} kills={} reinstalls={} restores={}",
        shared.started.elapsed().as_secs(),
        oracle.issued(),
        oracle.acked(),
        shared.tally.get("server_kills"),
        shared.tally.get("reinstalls"),
        shared.tally.get("stale_restores")
    ));
}

fn join_workers(workers: Workers, shared: &Shared) -> Result<Vec<Client>, String> {
    let mut clients = Vec::new();
    for worker in workers {
        match worker.join() {
            Ok(client) => clients.push(client),
            Err(_) => {
                shared.tally.bump("client_panics");
                return Err("a client thread panicked; see its message above".to_owned());
            }
        }
    }
    Ok(clients)
}

fn outcome(args: &RunArgs, shared: &Shared, verdicts: Verdicts, rss: Option<crate::metrics::RssSummary>, wall: Duration) -> Outcome {
    let (issued, acked, refused) = {
        let oracle = crate::sync_util::locked(&shared.oracle);
        (oracle.issued(), oracle.acked(), oracle.refused())
    };
    let mut counts = vec![("mutations_issued", issued), ("mutations_acked", acked), ("mutations_refused_by_server", refused)];
    counts.extend(shared.tally.snapshot());
    let mut notes = shared.notes();
    let lives: std::collections::BTreeSet<u32> = shared.rss_samples().iter().map(|sample| sample.pid).collect();
    notes.push(format!("server processes sampled: {}", lives.len()));
    notes.extend(rss_lives(&shared.rss_samples()));
    Outcome {
        seed: args.seed,
        minutes: args.minutes,
        clients: args.clients,
        wall_secs: wall.as_secs(),
        counts,
        faults: shared.faults.counts(),
        checks: verdicts.checks(),
        latency: shared.latency.summary(),
        rss,
        notes,
    }
}

fn locate_binary(args: &RunArgs) -> Result<PathBuf, String> {
    if let Some(path) = &args.server_bin {
        return Ok(path.clone());
    }
    let exe = std::env::current_exe().map_err(|error| format!("cannot find the harness binary: {error}"))?;
    let target = exe.parent().and_then(Path::parent).ok_or("the harness binary has no target directory")?;
    let profile = if args.release { "release" } else { "debug" };
    let candidate = target.join(profile).join("flaccy-server");
    if candidate.is_file() {
        Ok(candidate)
    } else {
        Err(format!("{} does not exist; run `cargo build{} -p flaccy-server` first", candidate.display(), if args.release { " --release" } else { "" }))
    }
}

fn work_dir(seed: u64) -> Result<PathBuf, String> {
    let base = dirs::cache_dir().ok_or("no cache directory")?.join("flaccy-soak");
    let root = base.join(format!("seed-{seed}-pid-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).map_err(|error| format!("cannot create {}: {error}", root.display()))?;
    Ok(root)
}

fn rss_lives(samples: &[crate::metrics::RssSample]) -> Vec<String> {
    let mut lives: Vec<(u32, Vec<&crate::metrics::RssSample>)> = Vec::new();
    for sample in samples {
        match lives.last_mut() {
            Some((pid, group)) if *pid == sample.pid => group.push(sample),
            _ => lives.push((sample.pid, vec![sample])),
        }
    }
    lives
        .iter()
        .filter(|(_, group)| group.len() >= 60)
        .map(|(pid, group)| {
            let (first, last) = (group[0], group[group.len() - 1]);
            let peak = group.iter().map(|sample| sample.kb).max().unwrap_or(0);
            format!(
                "rss life pid {pid}: t={}s..{}s {}kB -> {}kB peak {}kB",
                first.at_ms / 1000,
                last.at_ms / 1000,
                first.kb,
                last.kb,
                peak
            )
        })
        .collect()
}
