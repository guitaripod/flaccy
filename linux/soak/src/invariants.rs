use crate::canon::Canon;
use crate::client::Client;
use crate::metrics::{summarise_rss, RssSummary};
use crate::report::Check;
use crate::shared::Shared;
use crate::sync_util::locked;
use crate::view::{Observer, ServerView};
use flaccy_library::server_sync::SyncState;
use rusqlite::{Connection, OpenFlags};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::time::{Duration, Instant};

const CONVERGENCE: &str = "(a) clients converge on server state";
const ACKNOWLEDGED: &str = "(b) acknowledged mutations survive";
const LISTENS: &str = "(c) listen event ids unique";
const INTEGRITY: &str = "(d) integrity and exit codes";
const MEMORY: &str = "(e) server memory within 2x";
const CURSORS: &str = "(g) cursors monotone";
const ORDER: [&str; 6] = [CONVERGENCE, ACKNOWLEDGED, LISTENS, INTEGRITY, MEMORY, CURSORS];
const SETTLE_LIMIT: Duration = Duration::from_secs(240);
const MEMORY_RATIO_LIMIT: f64 = 2.0;

/// The first violation seen per invariant.
#[derive(Default)]
pub struct Verdicts(BTreeMap<&'static str, String>);

impl Verdicts {
    /// Keeps `reason` unless the invariant already failed earlier.
    pub fn fail(&mut self, name: &'static str, reason: String) {
        self.0.entry(name).or_insert(reason);
    }

    /// One check per invariant, in report order.
    pub fn checks(&self) -> Vec<Check> {
        ORDER.iter().map(|name| Check { name, failure: self.0.get(name).cloned() }).collect()
    }
}

/// The checks that stay valid while the chaos is running.
pub fn live(shared: &Shared, observer: &Observer, verdicts: &mut Verdicts) {
    let mut oracle = locked(&shared.oracle).clone();
    if shared.server.pid().is_none() {
        shared.tally.bump("live_checks_skipped");
        return;
    }
    match observer.snapshot() {
        Ok(view) => {
            shared.tally.bump("live_checks");
            oracle.absorb_removals(&locked(&shared.oracle));
            if let Err(reason) = oracle.check(&view) {
                verdicts.fail(ACKNOWLEDGED, reason);
            }
            check_unique_listens(&view, verdicts);
        }
        Err(reason) if reason.starts_with("cursor not monotone") => verdicts.fail(CURSORS, reason),
        Err(_) => shared.tally.bump("live_checks_skipped"),
    }
    if let Err(reason) = integrity(&shared.server.state_db()) {
        if !reason.contains("locked") && !reason.contains("unable to open") {
            verdicts.fail(INTEGRITY, reason);
        }
    }
}

/// Settles every client to quiescence, then runs every end-of-run check and stops the server.
pub fn finish(shared: &Shared, observer: &Observer, clients: &mut [Client], verdicts: &mut Verdicts) -> Option<RssSummary> {
    let settled = settle(clients);
    let oracle = locked(&shared.oracle).clone();
    match settled {
        Err(reason) => verdicts.fail(CONVERGENCE, reason),
        Ok(()) => match snapshot_with_retries(observer) {
            Err(reason) => verdicts.fail(CONVERGENCE, format!("final server snapshot failed: {reason}")),
            Ok(view) => {
                compare(shared, &view, clients, verdicts);
                if let Err(reason) = oracle.check(&view) {
                    verdicts.fail(ACKNOWLEDGED, reason);
                }
                check_unique_listens(&view, verdicts);
            }
        },
    }
    crate::monitor::terminate(shared);
    for exit in shared.server_exits() {
        verdicts.fail(INTEGRITY, exit);
    }
    for database in ["state.sqlite", "security.sqlite"] {
        let path = shared.server.state_db().with_file_name(database);
        if let Err(reason) = integrity(&path) {
            verdicts.fail(INTEGRITY, format!("{database}: {reason}"));
        }
    }
    memory(shared, verdicts)
}

fn settle(clients: &mut [Client]) -> Result<(), String> {
    let started = Instant::now();
    let mut stable_rounds = 0;
    while started.elapsed() < SETTLE_LIMIT {
        for client in clients.iter_mut() {
            client.sync_once();
        }
        let canons: Vec<Canon> = clients.iter().map(Client::canon).collect();
        let converged = canons.windows(2).all(|pair| pair[0] == pair[1])
            && clients.iter().all(|client| client.queued() == 0)
            && clients.iter().all(|client| client.last_status().is_some_and(|status| status.state == SyncState::UpToDate));
        stable_rounds = if converged { stable_rounds + 1 } else { 0 };
        if stable_rounds >= 2 {
            return Ok(());
        }
    }
    Err(format!("no quiescence after {}s: {}", SETTLE_LIMIT.as_secs(), describe_clients(clients)))
}

fn describe_clients(clients: &[Client]) -> String {
    clients
        .iter()
        .map(|client| format!("{} queued={} status={:?}", client.name(), client.queued(), client.last_status().map(|status| &status.state)))
        .collect::<Vec<_>>()
        .join("; ")
}

fn snapshot_with_retries(observer: &Observer) -> Result<ServerView, String> {
    let mut last = String::new();
    for _ in 0..5 {
        match observer.snapshot() {
            Ok(view) => return Ok(view),
            Err(error) => last = error,
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    Err(last)
}

fn compare(shared: &Shared, view: &ServerView, clients: &[Client], verdicts: &mut Verdicts) {
    let server = Canon::of_server(view, &shared.catalog);
    for client in clients {
        if let Some(difference) = client.canon().first_difference(&server, client.name(), "the server") {
            verdicts.fail(CONVERGENCE, format!("{}: {difference}", client.name()));
        }
    }
}

fn check_unique_listens(view: &ServerView, verdicts: &mut Verdicts) {
    let mut seen = BTreeSet::new();
    for item in &view.listens {
        if !seen.insert(item.event_id.as_str()) {
            verdicts.fail(LISTENS, format!("listen event id {} appears twice on the server", item.event_id));
        }
    }
}

fn memory(shared: &Shared, verdicts: &mut Verdicts) -> Option<RssSummary> {
    let total_ms = shared.chaos_ms();
    let summary = summarise_rss(&shared.rss_samples(), total_ms)?;
    if summary.ratio() > MEMORY_RATIO_LIMIT {
        verdicts.fail(
            MEMORY,
            format!("server RSS grew {:.2}x between the 10% mark ({} kB) and the 100% mark ({} kB)", summary.ratio(), summary.early_kb, summary.late_kb),
        );
    }
    Some(summary)
}

fn integrity(path: &Path) -> Result<(), String> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|error| format!("cannot open {}: {error}", path.display()))?;
    connection.busy_timeout(Duration::from_secs(10)).map_err(|error| error.to_string())?;
    let verdict: String = connection
        .query_row("PRAGMA integrity_check", [], |row| row.get(0))
        .map_err(|error| format!("integrity_check failed to run: {error}"))?;
    if verdict == "ok" {
        Ok(())
    } else {
        Err(format!("integrity_check says: {verdict}"))
    }
}
