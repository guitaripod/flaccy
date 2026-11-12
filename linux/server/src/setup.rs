//! `flaccy-server setup`: the first-run conversation of `docs/server/UX.md` section 2.
//!
//! It asks for the music folder, decides how devices reach the server (Tailscale,
//! this network, or both), makes the owner, installs the service and prints the
//! QR code and link that enroll the first device. Without Tailscale the server
//! shares on this network only. Running it again keeps the configuration and only
//! offers a new code, turning on sharing on this network when nothing else could
//! reach the server.

use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::Args;
use flaccy_library::logger;

use crate::admin::enrollment_link;
use crate::command::qr_text;
use crate::config::{Config, ConfigError};
use crate::hosting::certificate_names;
use crate::lan_identity::LanIdentity;
use crate::native::machine_name;
use crate::net::lan;
use crate::reach::{self, LocalReach};
use crate::probe::{self, PortState};
use crate::refresh;
use crate::runner::{Runner, SystemRunner};
use crate::security::{self, Role, User};
use crate::service::{self, Installed, Platform, ServiceError, ServiceHome, ServiceSpec};
use crate::state::AppState;
use crate::tailscale::{self, Tailnet, Tailscale, NOT_RUNNING_MESSAGE};
use crate::terminal::{StdTerminal, Terminal};

const DEFAULT_PORT: u16 = 4545;
const DEFAULT_MUSIC: &str = "~/Music";
const CODE_LIFETIME: Duration = Duration::from_secs(10 * 60);
const READY_WAIT: Duration = Duration::from_secs(30);
const MUSIC_ATTEMPTS: usize = 3;
const SCAN_REPORT_EVERY: Duration = Duration::from_secs(3);
const TAILSCALE_DOWNLOAD: &str = "tailscale.com/download";

/// `flaccy-server setup ...`
#[derive(Args, Clone, Debug, Default)]
pub struct SetupArgs {
    /// Take every default and ask nothing.
    #[arg(long)]
    pub yes: bool,
    /// The folder your music lives in.
    #[arg(long)]
    pub music: Option<PathBuf>,
    /// Your name on this server.
    #[arg(long)]
    pub name: Option<String>,
    /// The port to listen on.
    #[arg(long)]
    pub port: Option<u16>,
    /// Share only over Tailscale, not with devices on this network.
    #[arg(long)]
    pub no_lan: bool,
}

/// What setup needs from the machine it runs on.
pub struct SetupEnvironment<'a> {
    /// The configuration file to read or create.
    pub config_path: PathBuf,
    /// Whether `--config` named it, so the service must be told the same.
    pub config_is_explicit: bool,
    /// The home folder.
    pub home: PathBuf,
    /// Where `systemd/user` lives.
    pub config_dir: PathBuf,
    /// This program, as the service will run it.
    pub executable: PathBuf,
    /// The service manager to install into.
    pub platform: Platform,
    /// The login name.
    pub user: String,
    /// Runs `tailscale`, `systemctl` and the like.
    pub runner: &'a dyn Runner,
    /// How long to wait for the started server to answer.
    pub ready_wait: Duration,
    /// Written to the configuration as `data_dir` when set; the default location otherwise.
    pub data_dir: Option<PathBuf>,
}

/// Runs setup on this machine and returns the process exit code.
pub async fn run(config_path: &Path, config_is_explicit: bool, args: SetupArgs) -> i32 {
    let mut terminal = StdTerminal::detect(args.yes);
    let runner = SystemRunner;
    let environment = SetupEnvironment {
        config_path: config_path.to_path_buf(),
        config_is_explicit,
        home: dirs::home_dir().unwrap_or_default(),
        config_dir: dirs::config_dir().unwrap_or_default(),
        executable: std::env::current_exe().unwrap_or_else(|_| PathBuf::from("flaccy-server")),
        platform: Platform::current(),
        user: login_name(),
        runner: &runner,
        ready_wait: READY_WAIT,
        data_dir: None,
    };
    match execute(&environment, &mut terminal, args).await {
        Ok(()) => 0,
        Err(message) => {
            terminal.say(&message);
            1
        }
    }
}

fn login_name() -> String {
    ["USER", "LOGNAME", "USERNAME"]
        .iter()
        .filter_map(|variable| std::env::var(variable).ok())
        .map(|name| name.trim().to_owned())
        .find(|name| !name.is_empty())
        .unwrap_or_default()
}

fn short_version() -> String {
    env!("CARGO_PKG_VERSION").split('.').take(2).collect::<Vec<_>>().join(".")
}

/// Runs the whole conversation.
pub async fn execute(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, args: SetupArgs) -> Result<(), String> {
    terminal.say(&format!("Flaccy Server {}", short_version()));
    terminal.say("");
    let tailscale = tailscale::detect(environment.runner);
    let tailnet = match &tailscale {
        Tailscale::Running(tailnet) => Some(tailnet.clone()),
        Tailscale::NotInstalled | Tailscale::NotRunning(_) => None,
    };
    if tailnet.is_none() && args.no_lan {
        return Err(NOT_RUNNING_MESSAGE.to_owned());
    }
    let config = choose_config(environment, terminal, &args, tailnet.is_some()).await?;
    let (config, turned_on) = make_reachable(environment, terminal, config, tailnet.is_some(), &args)?;
    terminal.say("");
    announce_tailscale(terminal, &tailscale);
    let pin = local_pin(&config)?;
    announce_local(terminal, &config, pin.as_deref());
    let (security, owner) = choose_owner(&config, terminal, &args).await?;
    let installed = start_server(environment, terminal, &config, turned_on).await;
    keep_running(environment, terminal, installed.as_ref());
    show_enrollment(terminal, &config, tailnet.as_ref(), pin.as_deref(), &security, &owner).await
}

fn announce_tailscale(terminal: &mut dyn Terminal, tailscale: &Tailscale) {
    match tailscale {
        Tailscale::Running(tailnet) => {
            let address = tailnet.primary_address().map(|ip| format!(" ({ip})")).unwrap_or_default();
            terminal.say(&format!("Tailscale: connected as {}{address}.", tailnet.name));
        }
        Tailscale::NotInstalled => terminal.say(&format!(
            "Tailscale: not installed. Devices on this network connect directly; add Tailscale ({TAILSCALE_DOWNLOAD}) to listen away from home."
        )),
        Tailscale::NotRunning(reason) => terminal.say(&format!(
            "Tailscale: installed but not connected ({reason}). Devices on this network connect directly; sign in to Tailscale to listen away from home."
        )),
    }
}

/// Makes sure some device can reach the server: an existing setup without Tailscale and without sharing on this
/// network is offered sharing here. Returns the configuration and whether this run turned sharing on.
fn make_reachable(
    environment: &SetupEnvironment<'_>,
    terminal: &mut dyn Terminal,
    config: Config,
    tailnet_up: bool,
    args: &SetupArgs,
) -> Result<(Config, bool), String> {
    if config.lan || tailnet_up {
        return Ok((config, false));
    }
    if args.no_lan || !terminal.confirm("Tailscale isn't running here. Share with devices on this network instead?", true) {
        return Err(NOT_RUNNING_MESSAGE.to_owned());
    }
    append_lan(&environment.config_path)?;
    let config = Config::load(&environment.config_path).map_err(|error| error.to_string())?;
    Ok((config, true))
}

fn append_lan(path: &Path) -> Result<(), String> {
    let existing = std::fs::read_to_string(path).map_err(|error| format!("Could not read {}: {error}.", path.display()))?;
    let separator = if existing.is_empty() || existing.ends_with('\n') { "" } else { "\n" };
    std::fs::write(path, format!("{existing}{separator}lan = true\n"))
        .map_err(|error| format!("Could not write {}: {error}. Add `lan = true` to it yourself, then run this again.", path.display()))
}

/// Makes the key devices on this network pin, when the server shares here, so the link can carry its pin.
fn local_pin(config: &Config) -> Result<Option<String>, String> {
    if !config.lan {
        return Ok(None);
    }
    let identity = LanIdentity::load_or_create(&config.data_dir(), &certificate_names(config))?;
    Ok(Some(identity.pin().to_owned()))
}

/// How a device on this network reaches the server right now, from this machine's interfaces.
fn current_local_reach(config: &Config, pin: &str) -> Option<LocalReach> {
    let found = lan::discover(true).ok()?;
    let bound: Vec<std::net::SocketAddr> = found.local.iter().map(|ip| std::net::SocketAddr::new(*ip, config.port)).collect();
    let (name, answers) = reach::bonjour_source(config);
    reach::local_reach(&bound, &name, answers, pin)
}

fn announce_local(terminal: &mut dyn Terminal, config: &Config, pin: Option<&str>) {
    let Some(pin) = pin else {
        return;
    };
    match current_local_reach(config, pin) {
        Some(local) => terminal.say(&format!("This network: devices on the same Wi-Fi connect to {}.", host_of(&local.url))),
        None => terminal.say("This network: this machine has no local network address yet; devices on Wi-Fi can connect once it joins one."),
    }
}

fn host_of(url: &str) -> &str {
    let rest = url.split_once("://").map_or(url, |(_, rest)| rest);
    rest.rsplit_once(':').map_or(rest, |(host, _)| host)
}

async fn choose_config(
    environment: &SetupEnvironment<'_>,
    terminal: &mut dyn Terminal,
    args: &SetupArgs,
    tailnet_up: bool,
) -> Result<Config, String> {
    match Config::load(&environment.config_path) {
        Ok(config) => {
            keep_existing(environment, terminal, args);
            Ok(config)
        }
        Err(ConfigError::Missing(_)) => create_config(environment, terminal, args, tailnet_up).await,
        Err(other) => Err(other.to_string()),
    }
}

fn keep_existing(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, args: &SetupArgs) {
    terminal.say(&format!("Your setup in {} stays as it is.", environment.config_path.display()));
    if args.music.is_some() || args.port.is_some() {
        terminal.say("  --music and --port are ignored here; edit that file to change them.");
    }
}

async fn create_config(
    environment: &SetupEnvironment<'_>,
    terminal: &mut dyn Terminal,
    args: &SetupArgs,
    tailnet_up: bool,
) -> Result<Config, String> {
    let music = choose_music(terminal, args)?;
    let port = args.port.unwrap_or(DEFAULT_PORT);
    check_port(environment, port).await?;
    let lan = choose_lan(terminal, args, tailnet_up);
    write_config(&environment.config_path, &music, port, lan, environment.data_dir.as_deref())?;
    let config = Config::load(&environment.config_path).map_err(|error| error.to_string())?;
    let library = scan_library(config.clone(), terminal).await?;
    report_library(terminal, library);
    Ok(config)
}

/// Shares on this network unless told not to; with Tailscale up the person is asked, defaulting to yes.
fn choose_lan(terminal: &mut dyn Terminal, args: &SetupArgs, tailnet_up: bool) -> bool {
    if args.no_lan {
        return false;
    }
    !tailnet_up || terminal.confirm("Also share with devices on this network that don't use Tailscale?", true)
}

fn choose_music(terminal: &mut dyn Terminal, args: &SetupArgs) -> Result<PathBuf, String> {
    if let Some(folder) = &args.music {
        terminal.say(&format!("Where is your music? {}", folder.display()));
        return existing_folder(folder);
    }
    let mut last = String::new();
    for _ in 0..MUSIC_ATTEMPTS {
        let answer = terminal.ask("Where is your music?", DEFAULT_MUSIC);
        match existing_folder(Path::new(&answer)) {
            Ok(folder) => return Ok(folder),
            Err(message) if terminal.is_interactive() => {
                terminal.say(&message);
                last = message;
            }
            Err(message) => return Err(message),
        }
    }
    Err(last)
}

fn expand_home(path: &Path) -> PathBuf {
    match path.strip_prefix("~") {
        Ok(rest) => dirs::home_dir().unwrap_or_default().join(rest),
        Err(_) => path.to_path_buf(),
    }
}

fn existing_folder(path: &Path) -> Result<PathBuf, String> {
    let expanded = expand_home(path);
    let absolute = std::path::absolute(&expanded).unwrap_or(expanded);
    if absolute.is_dir() {
        Ok(absolute)
    } else {
        Err(format!(
            "There is no folder at {}. Check the spelling, or make the folder and run this again.",
            absolute.display()
        ))
    }
}

async fn check_port(environment: &SetupEnvironment<'_>, port: u16) -> Result<(), String> {
    match probe::port_state(port, environment.runner).await? {
        PortState::Free => Ok(()),
        PortState::Flaccy => Err(format!("Port {port} is in use by flaccy-server. Use --port, or stop that program.")),
        PortState::Taken(holder) => Err(format!("Port {port} is in use by {holder}. Use --port, or stop that program.")),
    }
}

fn write_config(path: &Path, music: &Path, port: u16, lan: bool, data_dir: Option<&Path>) -> Result<(), String> {
    let quoted = |path: &Path| toml::Value::String(path.display().to_string());
    let folder = quoted(music);
    let data = data_dir.map(|dir| format!("data_dir = {}\n", quoted(dir))).unwrap_or_default();
    let text = format!("music_folder = {folder}\nport = {port}\nmode = \"easy\"\nlan = {lan}\n{data}");
    let write = || -> std::io::Result<()> {
        std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))?;
        std::fs::write(path, text)
    };
    write().map_err(|error| format!("Could not write {}: {error}. Make that folder writable, or pass --config with a path you own.", path.display()))
}

struct Library {
    songs: usize,
    albums: usize,
}

async fn scan_library(config: Config, terminal: &mut dyn Terminal) -> Result<Library, String> {
    logger::silence_console();
    logger::init(&config.data_dir());
    let state = AppState::open(config).await?;
    let worker = state.clone();
    let mut scan = tokio::task::spawn_blocking(move || refresh::refresh_now(&worker));
    let mut ticks = tokio::time::interval_at(tokio::time::Instant::now() + SCAN_REPORT_EVERY, SCAN_REPORT_EVERY);
    let mut reported = 0;
    let summary = loop {
        tokio::select! {
            finished = &mut scan => break finished,
            _ = ticks.tick() => {
                let found = state.catalog().song_count();
                if found > reported {
                    terminal.say(&format!("  {} so far…", counted(found, "song", "songs")));
                    reported = found;
                }
            }
        }
    };
    let summary = summary.map_err(|error| format!("The scan stopped unexpectedly: {error}. Run `flaccy-server setup` again."))?;
    let library = Library { songs: state.catalog().song_count(), albums: state.catalog().albums().len() };
    let _ = state.0.sync.close().await;
    let _ = state.0.security.close().await;
    match summary.failure {
        Some(failure) => Err(failure),
        None => Ok(library),
    }
}

fn report_library(terminal: &mut dyn Terminal, library: Library) {
    if library.songs == 0 {
        terminal.say("  That folder has no music yet. Flaccy Server will pick files up as you add them.");
    } else {
        terminal.say(&format!(
            "  Found {} in {}.",
            counted(library.songs, "song", "songs"),
            counted(library.albums, "album", "albums")
        ));
    }
}

fn counted(number: usize, one: &str, many: &str) -> String {
    format!("{} {}", grouped(number), if number == 1 { one } else { many })
}

pub(crate) fn grouped(number: usize) -> String {
    let digits = number.to_string();
    let mut text = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            text.push(',');
        }
        text.push(digit);
    }
    text
}

async fn choose_owner(config: &Config, terminal: &mut dyn Terminal, args: &SetupArgs) -> Result<(security::Store, User), String> {
    let security = security::Store::open(&config.security_path()).await.map_err(|error| error.to_string())?;
    let users = security.list_users().await.map_err(|error| error.to_string())?;
    let owner = if users.is_empty() {
        let name = match &args.name {
            Some(name) => {
                terminal.say(&format!("Your name on this server? {name}"));
                name.clone()
            }
            None => terminal.ask("Your name on this server?", &default_name()),
        };
        security.create_user(&name, Role::Admin).await.map_err(|error| error.to_string())?
    } else {
        let owner = existing_owner(users, args.name.as_deref())?;
        terminal.say(&format!("Your name on this server: {}", owner.name));
        owner
    };
    Ok((security, owner))
}

fn default_name() -> String {
    let login = login_name();
    if login.is_empty() {
        "me".to_owned()
    } else {
        login
    }
}

fn existing_owner(users: Vec<User>, wanted: Option<&str>) -> Result<User, String> {
    if let Some(name) = wanted {
        return users
            .into_iter()
            .find(|user| user.name.eq_ignore_ascii_case(name))
            .ok_or_else(|| format!("There is no user called '{name}' on this server. Add one with `flaccy-server user add {name}`, then run this again."));
    }
    let admin = users.iter().position(|user| user.role == Role::Admin).unwrap_or(0);
    users.into_iter().nth(admin).ok_or_else(|| "This server has no users.".to_owned())
}

async fn start_server(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, config: &Config, changed: bool) -> Option<Installed> {
    let port = config.port;
    terminal.write(&format!("Starting the server on port {port}... "));
    if probe::hello(port).await.is_some() {
        terminal.say("already running.");
        if changed {
            terminal.say("  Restart it so it shares on this network: `systemctl --user restart flaccy-server` on Linux, or quit and start `flaccy-server serve` again.");
        }
        return None;
    }
    let spec = ServiceSpec {
        executable: environment.executable.clone(),
        config: environment.config_is_explicit.then(|| environment.config_path.clone()),
        log: environment.home.join("Library").join("Logs").join("flaccy-server.log"),
    };
    let home = ServiceHome { config_dir: environment.config_dir.clone(), home: environment.home.clone() };
    match service::install(environment.platform, environment.runner, &home, &spec) {
        Ok(installed) => {
            report_readiness(terminal, config, environment.platform, probe::wait_for_hello(port, environment.ready_wait).await);
            Some(installed)
        }
        Err(error) => {
            report_not_started(terminal, &error);
            None
        }
    }
}

fn report_readiness(terminal: &mut dyn Terminal, config: &Config, platform: Platform, ready: bool) {
    if ready {
        terminal.say("ready.");
        terminal.say("  Your music is indexed in the background and shows up in Flaccy as it is found; `flaccy-server status` shows how far it has got.");
        if platform == Platform::MacOs {
            terminal.say("  If macOS asks whether flaccy-server may accept incoming network connections, choose Allow; until then your other devices cannot reach it.");
        }
    } else {
        terminal.say("started, but not answering yet.");
        terminal.say(&format!("  Its log is {}.", config.data_dir().join("flaccy.log").display()));
    }
}

fn report_not_started(terminal: &mut dyn Terminal, error: &ServiceError) {
    match error {
        ServiceError::Unsupported(message) if message == service::UNSUPPORTED_MESSAGE => {
            terminal.say("not started.");
            terminal.say(&format!("{message}."));
        }
        ServiceError::Unsupported(message) | ServiceError::Manager(message) => {
            terminal.say("not started.");
            terminal.say(&format!("  {message}"));
            terminal.say("  Until then, run `flaccy-server serve` in a terminal.");
        }
    }
}

fn keep_running(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, installed: Option<&Installed>) {
    let Some(installed) = installed.filter(|_| environment.platform == Platform::Linux) else {
        return;
    };
    let runner = environment.runner;
    let user = &environment.user;
    if service::linger_enabled(runner, user) {
        terminal.say(&format!("Keeping it running after you log out... done ({}).", installed.name));
        return;
    }
    if !terminal.confirm("Keep it running after you log out?", true) {
        terminal.say(&format!("Keeping it running after you log out... skipped. `loginctl enable-linger {user}` turns it on later."));
        return;
    }
    terminal.write("Keeping it running after you log out... ");
    match service::enable_linger(runner, user) {
        Ok(()) => terminal.say(&format!("done ({}).", installed.name)),
        Err(error) => {
            terminal.say("not done.");
            terminal.say(&format!("  {error}"));
        }
    }
}

async fn show_enrollment(
    terminal: &mut dyn Terminal,
    config: &Config,
    tailnet: Option<&Tailnet>,
    pin: Option<&str>,
    security: &security::Store,
    owner: &User,
) -> Result<(), String> {
    let tailnet_url = tailnet.map(|tailnet| format!("http://{}:{}", tailnet.name, config.port));
    let local = pin.and_then(|pin| current_local_reach(config, pin));
    let reach = reach::device_reach(tailnet_url, local, None).ok_or_else(|| {
        "This machine has no address on a local network and Tailscale is not up, so no device could reach it. Join a network or start Tailscale, then run `flaccy-server enroll`.".to_owned()
    })?;
    let name = tailnet.map_or_else(|| machine_name().to_owned(), |tailnet| tailnet.name.clone());
    let code = security.create_enrollment(&owner.id, CODE_LIFETIME).await.map_err(|error| error.to_string())?;
    let link = enrollment_link(&reach, &code, &name);
    terminal.say("");
    terminal.say("Scan this with the camera in Flaccy on your iPhone:");
    terminal.say("");
    for line in qr_text(&link)?.lines() {
        terminal.say(&format!("  {line}"));
    }
    terminal.say("");
    terminal.say("On a Mac or Linux, paste this link into Flaccy's Add Flaccy Server window:");
    terminal.say(&format!("  {link}"));
    terminal.say("");
    terminal.say("The code works once and expires in 10 minutes. Make another with `flaccy-server enroll`.");
    let _ = security.close().await;
    Ok(())
}

#[cfg(test)]
mod tests;
