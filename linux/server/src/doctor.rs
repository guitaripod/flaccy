//! `flaccy-server doctor`: one line per check, `✓` or `✗` with the fix, in the order of `docs/server/UX.md`:
//! Tailscale, bind, clock, disk, ffmpeg, database, last backup, clients.

use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime};

use rusqlite::{Connection, OpenFlags};

use crate::config::Config;
use crate::net;
use crate::probe::{self, PortState};
use crate::retention;
use crate::runner::{Runner, SystemRunner};
use crate::service::Platform;
use crate::storage::{self, Medium};
use crate::tailscale::{self, Tailscale};
use crate::terminal::{StdTerminal, Terminal};

const MIN_FREE_BYTES: u64 = 1 << 30;
const STALE_BACKUP: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const CLOCK_TOLERANCE_MS: i64 = 60 * 60 * 1000;
const RECENT_MS: i64 = 2 * 60 * 1000;
const STAMP_COUNTER_BITS: u32 = 16;

/// How one check came out.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Fine, with what was found.
    Pass(String),
    /// Broken: what is wrong, and what to do about it.
    Fail(String, String),
    /// Worth knowing, not a failure.
    Note(String),
}

/// One line of the report, with detail lines under it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Check {
    /// The topic: `Tailscale`, `Disk`, ...
    pub name: &'static str,
    /// How it came out.
    pub outcome: Outcome,
    /// Lines printed indented under it.
    pub details: Vec<String>,
}

impl Check {
    fn new(name: &'static str, outcome: Outcome) -> Self {
        Self { name, outcome, details: Vec::new() }
    }

    fn pass(name: &'static str, found: impl Into<String>) -> Self {
        Self::new(name, Outcome::Pass(found.into()))
    }

    fn fail(name: &'static str, problem: impl Into<String>, fix: impl Into<String>) -> Self {
        Self::new(name, Outcome::Fail(problem.into(), fix.into()))
    }

    fn note(name: &'static str, found: impl Into<String>) -> Self {
        Self::new(name, Outcome::Note(found.into()))
    }

    /// Whether this check fails the run.
    pub fn failed(&self) -> bool {
        matches!(self.outcome, Outcome::Fail(..))
    }

    /// The line as printed.
    pub fn line(&self) -> String {
        match &self.outcome {
            Outcome::Pass(found) => format!("✓ {}: {found}", self.name),
            Outcome::Fail(problem, fix) => format!("✗ {}: {problem}. {fix}", self.name),
            Outcome::Note(found) => format!("! {}: {found}", self.name),
        }
    }
}

/// Everything the checks read besides the files: programs to run, the machine's own facts.
pub struct DoctorEnvironment<'a> {
    /// The configuration file the server reads.
    pub config_path: PathBuf,
    /// Runs `tailscale`, `ffmpeg`, `df` and `mount`.
    pub runner: &'a dyn Runner,
    /// The service manager, for the hint when the server is down.
    pub platform: Platform,
    /// The program that converts audio.
    pub ffmpeg: String,
    /// Unix milliseconds now.
    pub now_ms: i64,
}

fn unix_ms(time: SystemTime) -> i64 {
    time.duration_since(SystemTime::UNIX_EPOCH).map(|elapsed| elapsed.as_millis() as i64).unwrap_or(0)
}

/// Runs the checks on this machine, prints them and returns the exit code: 1 when any failed.
pub async fn run(config: &Config, config_path: &Path) -> i32 {
    let runner = SystemRunner;
    let environment = DoctorEnvironment {
        config_path: config_path.to_path_buf(),
        runner: &runner,
        platform: Platform::current(),
        ffmpeg: std::env::var("FLACCY_SERVER_FFMPEG").unwrap_or_else(|_| "ffmpeg".to_owned()),
        now_ms: unix_ms(SystemTime::now()),
    };
    let mut terminal = StdTerminal::quiet();
    i32::from(report(config, &environment, &mut terminal).await)
}

/// Runs every check and prints it; true when any check failed.
pub async fn report(config: &Config, environment: &DoctorEnvironment<'_>, terminal: &mut dyn Terminal) -> bool {
    let mut failed = false;
    for check in diagnose(config, environment).await {
        failed |= check.failed();
        terminal.say(&check.line());
        for detail in &check.details {
            terminal.say(&format!("    {detail}"));
        }
    }
    failed
}

/// Every check, in the order they are printed.
pub async fn diagnose(config: &Config, environment: &DoctorEnvironment<'_>) -> Vec<Check> {
    let tailnet = tailscale::detect(environment.runner);
    let tailscale_check = tailscale_check(&tailnet);
    let bind = bind_check(config, environment, net::addresses().unwrap_or_default()).await;
    let mut checks = vec![tailscale_check, bind, clock_check(config, environment.now_ms)];
    checks.extend(disk_checks(config, environment.runner));
    checks.push(ffmpeg_check(environment));
    checks.push(database_check(config));
    checks.push(backup_check(config, environment.now_ms));
    checks.push(devices_check(config, environment.now_ms));
    checks.extend(crate::lastfm::health::checks(config));
    checks
}

/// The Tailscale line.
pub fn tailscale_check(found: &Tailscale) -> Check {
    match found {
        Tailscale::Running(tailnet) => {
            let address = tailnet.primary_address().map(|ip| format!(" ({ip})")).unwrap_or_default();
            let version = if tailnet.version.is_empty() { String::new() } else { format!(", version {}", tailnet.version) };
            Check::pass("Tailscale", format!("connected as {}{address}{version}", tailnet.name))
        }
        Tailscale::NotInstalled => Check::fail(
            "Tailscale",
            "is not installed",
            "Install it from tailscale.com/download, sign in, then run `flaccy-server doctor` again",
        ),
        Tailscale::NotRunning(reason) => Check::fail(
            "Tailscale",
            format!("is not connected ({reason})"),
            "Open Tailscale and sign in, or run `tailscale up`, then run `flaccy-server doctor` again",
        ),
    }
}

fn start_hint(platform: Platform) -> &'static str {
    match platform {
        Platform::Linux => "Start it with `systemctl --user start flaccy-server`, or run `flaccy-server serve`",
        Platform::MacOs => "Start it with `launchctl kickstart gui/$(id -u)/cc.midgarcorp.flaccy-server`, or run `flaccy-server serve`",
        Platform::Other => "Run `flaccy-server serve`",
    }
}

fn listed(addresses: &[IpAddr], port: u16) -> String {
    addresses.iter().map(|ip| if ip.is_ipv6() { format!("[{ip}]:{port}") } else { format!("{ip}:{port}") }).collect::<Vec<_>>().join(", ")
}

/// The bind line: where the server listens and whether it is answering there.
pub async fn bind_check(config: &Config, environment: &DoctorEnvironment<'_>, interface_addresses: Vec<IpAddr>) -> Check {
    let port = config.port;
    let tailnet: Vec<IpAddr> = net::tailnet::tailnet_only(interface_addresses);
    let easy = config.address == "127.0.0.1";
    if easy && tailnet.is_empty() {
        return Check::fail(
            "Bind",
            "no Tailscale address is on this machine's network interfaces, so only this machine can reach the server",
            "Start Tailscale, or set `address` in the configuration file to the address devices should use",
        );
    }
    let mut addresses: Vec<IpAddr> = vec![IpAddr::from([127, 0, 0, 1])];
    if easy {
        addresses.extend(tailnet);
    } else if let Ok(address) = config.address.parse::<IpAddr>() {
        addresses = vec![address];
    }
    let shown = if easy { listed(&addresses, port) } else { config.listen_address() };
    if probe::hello(port).await.is_some() {
        return Check::pass("Bind", format!("serving on {shown}"));
    }
    match probe::port_state(port, environment.runner).await {
        Ok(PortState::Taken(holder)) => Check::fail(
            "Bind",
            format!("port {port} is in use by {holder}"),
            "Stop that program, or set another `port` in the configuration file",
        ),
        Ok(_) => Check::fail("Bind", format!("the server is not answering on port {port}"), start_hint(environment.platform)),
        Err(message) => Check::fail("Bind", message.trim_end_matches('.'), "Set a `port` above 1024 in the configuration file"),
    }
}

fn read_only(path: &Path) -> Option<Connection> {
    path.exists().then(|| Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).ok()).flatten()
}

fn stored_clock_ms(config: &Config) -> Option<i64> {
    let connection = read_only(&config.state_path())?;
    let text: String = connection.query_row("SELECT value FROM server_meta WHERE key = 'server_hlc'", [], |row| row.get(0)).ok()?;
    Some(text.parse::<i64>().ok()? >> STAMP_COUNTER_BITS)
}

fn minutes_text(ms: i64) -> String {
    let minutes = ms / 60_000;
    match minutes {
        0..=89 => format!("{minutes} minutes"),
        90..=2879 => format!("{} hours", minutes / 60),
        _ => format!("{} days", minutes / 1440),
    }
}

/// The clock line: this machine's time against the newest change the server stored.
pub fn clock_check(config: &Config, now_ms: i64) -> Check {
    let Some(stored) = stored_clock_ms(config) else {
        return Check::pass("Clock", "no changes are stored yet, so there is nothing to be behind");
    };
    let behind = stored - now_ms;
    if behind > CLOCK_TOLERANCE_MS {
        return Check::fail(
            "Clock",
            format!("this machine's clock is {} behind the newest change the server stored, so sync refuses writes", minutes_text(behind)),
            "Set the time right: `timedatectl set-ntp true` on Linux, Date & Time in System Settings on a Mac",
        );
    }
    Check::pass("Clock", "not behind the changes the server holds")
}

fn nearest_existing(path: &Path) -> PathBuf {
    path.ancestors().find(|candidate| candidate.exists()).unwrap_or(Path::new("/")).to_path_buf()
}

fn mount_table(runner: &dyn Runner) -> Vec<storage::Mount> {
    if let Ok(text) = std::fs::read_to_string("/proc/mounts") {
        return storage::parse_proc_mounts(&text);
    }
    runner.run("mount", &[]).ok().map(|output| storage::parse_mount_output(&output.stdout)).unwrap_or_default()
}

/// The two disk lines: the data folder is on a local disk, and it has room.
pub fn disk_checks(config: &Config, runner: &dyn Runner) -> Vec<Check> {
    let data = config.data_dir();
    let existing = nearest_existing(&data);
    let resolved = existing.canonicalize().unwrap_or(existing.clone());
    vec![medium_check(&data, &storage::medium_of(&resolved, &mount_table(runner))), room_check(&data, &existing, runner)]
}

/// The line about where the data folder lives.
pub fn medium_check(data: &Path, medium: &Medium) -> Check {
    match medium {
        Medium::Network(kind) => Check::fail(
            "Disk",
            format!("{} is on a network drive ({kind}), where SQLite databases get corrupted", data.display()),
            "Set `data_dir` in the configuration file to a folder on a local disk and move the files there while the server is stopped",
        ),
        Medium::SdCard => Check::note("Disk", format!("{} is on an SD card, which wears out under constant database writes; keep backups, or move `data_dir` to an SSD", data.display())),
        Medium::Local => Check::pass("Disk", format!("{} is on a local disk", data.display())),
        Medium::Unknown => Check::note("Disk", format!("could not tell what disk {} is on", data.display())),
    }
}

fn room_check(data: &Path, existing: &Path, runner: &dyn Runner) -> Check {
    let output = runner.run("df", &["-Pk", &existing.display().to_string()]).ok();
    let Some(free) = output.and_then(|output| storage::available_bytes(&output.stdout)) else {
        return Check::note("Disk space", format!("could not read how much room {} has", data.display()));
    };
    if free < MIN_FREE_BYTES {
        return Check::fail(
            "Disk space",
            format!("only {} is free where {} lives", gigabytes(free), data.display()),
            "Free some space; sync stops when the disk is full",
        );
    }
    Check::pass("Disk space", format!("{} free", gigabytes(free)))
}

fn gigabytes(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1_073_741_824.0)
}

/// The ffmpeg line.
pub fn ffmpeg_check(environment: &DoctorEnvironment<'_>) -> Check {
    match environment.runner.run(&environment.ffmpeg, &["-version"]) {
        Ok(output) if output.success => Check::pass("ffmpeg", output.stdout.lines().next().unwrap_or("installed").trim().to_owned()),
        _ => Check::fail(
            "ffmpeg",
            "is not installed or does not run",
            "Install it (`pacman -S ffmpeg`, `apt install ffmpeg` or `brew install ffmpeg`) to convert songs for clients; playing the original files works without it",
        ),
    }
}

fn integrity(path: &Path) -> Option<String> {
    let connection = read_only(path)?;
    let verdict = connection
        .query_row("PRAGMA integrity_check", [], |row| row.get::<_, String>(0))
        .unwrap_or_else(|error| error.to_string());
    Some(verdict)
}

/// The database line: `PRAGMA integrity_check` on the state and security databases.
pub fn database_check(config: &Config) -> Check {
    let files = [("state.sqlite", config.state_path()), ("security.sqlite", config.security_path())];
    let verdicts: Vec<(&str, Option<String>)> = files.iter().map(|(name, path)| (*name, integrity(path))).collect();
    if verdicts.iter().all(|(_, verdict)| verdict.is_none()) {
        return Check::note("Database", "state.sqlite and security.sqlite do not exist yet; the server makes them when it first starts");
    }
    let broken: Vec<String> = verdicts.iter().filter_map(|(name, verdict)| verdict.as_ref().filter(|text| *text != "ok").map(|text| format!("{name}: {text}"))).collect();
    if broken.is_empty() {
        return Check::pass("Database", "state.sqlite and security.sqlite pass SQLite's integrity check");
    }
    Check::fail(
        "Database",
        broken.join("; "),
        "Stop the server and bring back the newest backup with `flaccy-server restore`, or move the damaged file away to start that part fresh",
    )
}

fn newest_backup(dir: &Path) -> Option<SystemTime> {
    std::fs::read_dir(dir)
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| entry.file_name().to_str().is_some_and(|name| retention::parse_name(name).is_some()))
        .filter_map(|entry| entry.metadata().ok()?.modified().ok())
        .max()
}

/// The backup line: how old the newest backup is.
pub fn backup_check(config: &Config, now_ms: i64) -> Check {
    let Some(dir) = config.backup_dir() else {
        return Check::note("Backups", "the nightly backup is switched off (`backup_dir` is empty)");
    };
    let Some(newest) = newest_backup(&dir) else {
        return Check::note("Backups", "no backups yet");
    };
    let age_ms = (now_ms - unix_ms(newest)).max(0);
    if Duration::from_millis(age_ms as u64) > STALE_BACKUP {
        return Check::fail(
            "Backups",
            format!("the newest backup in {} is {} old", dir.display(), minutes_text(age_ms)),
            "Make one now with `flaccy-server backup` and check that `serve` runs overnight",
        );
    }
    Check::pass("Backups", format!("newest is {} old", minutes_text(age_ms)))
}

fn last_seen_text(last_seen: Option<i64>, now_ms: i64) -> String {
    match last_seen {
        None => "never seen".to_owned(),
        Some(at) if now_ms - at <= RECENT_MS => "connected now".to_owned(),
        Some(at) => format!("last seen {} ago", minutes_text((now_ms - at).max(0))),
    }
}

fn device_lines(path: &Path, now_ms: i64) -> Option<Vec<String>> {
    let connection = read_only(path)?;
    let mut statement = connection
        .prepare(
            "SELECT d.name, d.platform, u.name, d.last_seen_at FROM devices d JOIN users u ON u.id = d.user_id
             WHERE d.revoked_at IS NULL ORDER BY d.last_seen_at IS NULL, d.last_seen_at DESC, d.created_at",
        )
        .ok()?;
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?, row.get::<_, Option<i64>>(3)?)))
        .ok()?;
    Some(
        rows.filter_map(Result::ok)
            .map(|(name, platform, owner, seen)| format!("{name} ({platform}, {owner}): {}", last_seen_text(seen, now_ms)))
            .collect(),
    )
}

/// The clients line: enrolled devices with platform and last seen.
pub fn devices_check(config: &Config, now_ms: i64) -> Check {
    let lines = device_lines(&config.security_path(), now_ms).unwrap_or_default();
    if lines.is_empty() {
        return Check::note("Devices", "none enrolled yet; run `flaccy-server enroll` and scan the code in Flaccy");
    }
    let mut check = Check::pass("Devices", format!("{} enrolled", lines.len()));
    check.details = lines;
    check
}

#[cfg(test)]
mod tests;
