//! `flaccy-server setup`: the first-run conversation of `docs/server/UX.md` section 2.
//!
//! It asks for the music folder, checks Tailscale, makes the owner, installs
//! the service and prints the QR code and link that enroll the first device.
//! Running it again keeps the configuration and only offers a new code.

use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::Args;
use flaccy_library::logger;

use crate::admin::enrollment_link;
use crate::command::qr_text;
use crate::config::{Config, ConfigError};
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
    let tailnet = match tailscale::detect(environment.runner) {
        Tailscale::Running(tailnet) => tailnet,
        Tailscale::NotInstalled | Tailscale::NotRunning(_) => return Err(NOT_RUNNING_MESSAGE.to_owned()),
    };
    let config = choose_config(environment, terminal, &args).await?;
    terminal.say("");
    announce_tailscale(terminal, &tailnet);
    let (security, owner) = choose_owner(&config, terminal, &args).await?;
    let installed = start_server(environment, terminal, &config).await;
    keep_running(environment, terminal, installed.as_ref());
    show_enrollment(terminal, &config, &tailnet, &security, &owner).await
}

fn announce_tailscale(terminal: &mut dyn Terminal, tailnet: &Tailnet) {
    let address = tailnet.primary_address().map(|ip| format!(" ({ip})")).unwrap_or_default();
    terminal.say(&format!("Tailscale: connected as {}{address}.", tailnet.name));
}

async fn choose_config(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, args: &SetupArgs) -> Result<Config, String> {
    match Config::load(&environment.config_path) {
        Ok(config) => {
            keep_existing(environment, terminal, args);
            Ok(config)
        }
        Err(ConfigError::Missing(_)) => create_config(environment, terminal, args).await,
        Err(other) => Err(other.to_string()),
    }
}

fn keep_existing(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, args: &SetupArgs) {
    terminal.say(&format!("Your setup in {} stays as it is.", environment.config_path.display()));
    if args.music.is_some() || args.port.is_some() {
        terminal.say("  --music and --port are ignored here; edit that file to change them.");
    }
}

async fn create_config(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, args: &SetupArgs) -> Result<Config, String> {
    let music = choose_music(terminal, args)?;
    let port = args.port.unwrap_or(DEFAULT_PORT);
    check_port(environment, port).await?;
    write_config(&environment.config_path, &music, port, environment.data_dir.as_deref())?;
    let config = Config::load(&environment.config_path).map_err(|error| error.to_string())?;
    report_library(terminal, scan_library(config.clone()).await?);
    Ok(config)
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

fn write_config(path: &Path, music: &Path, port: u16, data_dir: Option<&Path>) -> Result<(), String> {
    let quoted = |path: &Path| toml::Value::String(path.display().to_string());
    let folder = quoted(music);
    let data = data_dir.map(|dir| format!("data_dir = {}\n", quoted(dir))).unwrap_or_default();
    let text = format!("music_folder = {folder}\nport = {port}\nmode = \"easy\"\n{data}");
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

async fn scan_library(config: Config) -> Result<Library, String> {
    logger::silence_console();
    logger::init(&config.data_dir());
    let state = AppState::open(config).await?;
    let worker = state.clone();
    let summary = tokio::task::spawn_blocking(move || refresh::refresh_now(&worker))
        .await
        .map_err(|error| format!("The scan stopped unexpectedly: {error}. Run `flaccy-server setup` again."))?;
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

fn grouped(number: usize) -> String {
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

async fn start_server(environment: &SetupEnvironment<'_>, terminal: &mut dyn Terminal, config: &Config) -> Option<Installed> {
    let port = config.port;
    terminal.write(&format!("Starting the server on port {port}... "));
    if probe::hello(port).await.is_some() {
        terminal.say("already running.");
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
            report_readiness(terminal, config, probe::wait_for_hello(port, environment.ready_wait).await);
            Some(installed)
        }
        Err(error) => {
            report_not_started(terminal, &error);
            None
        }
    }
}

fn report_readiness(terminal: &mut dyn Terminal, config: &Config, ready: bool) {
    if ready {
        terminal.say("ready.");
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
    tailnet: &Tailnet,
    security: &security::Store,
    owner: &User,
) -> Result<(), String> {
    let code = security.create_enrollment(&owner.id, CODE_LIFETIME).await.map_err(|error| error.to_string())?;
    let url = format!("http://{}:{}", tailnet.name, config.port);
    let link = enrollment_link(&url, &code, &tailnet.name);
    terminal.say("");
    terminal.say("Scan this with Flaccy on your iPhone, Mac or Linux:");
    terminal.say("");
    for line in qr_text(&link)?.lines() {
        terminal.say(&format!("  {line}"));
    }
    terminal.say("");
    terminal.say("Or open this link on a device that has Flaccy:");
    terminal.say(&format!("  {link}"));
    terminal.say("");
    terminal.say("The code works once and expires in 10 minutes. Make another with `flaccy-server enroll`.");
    let _ = security.close().await;
    Ok(())
}

#[cfg(test)]
mod tests;
