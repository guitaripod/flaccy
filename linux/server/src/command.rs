//! The command line: serve, scan, password, keys, status, healthcheck, enroll, users, devices and the audit trail.

use std::io::BufRead;
use std::path::PathBuf;
use std::time::Duration;

use clap::{Parser, Subcommand};
use flaccy_library::logger;
use qrcode::render::unicode::Dense1x2;
use qrcode::QrCode;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

use crate::admin::{self, AuditAction, DeviceAction, EnrollArgs, UserAction};
use crate::backup;
use crate::config::{Config, ConfigError};
use crate::credentials::{self, Credentials, DEFAULT_USERNAME};
use crate::doctor;
use crate::export::{self, ExportArgs};
use crate::lastfm::{self, LastfmAction};
use crate::hosting::{self, ffmpeg_program, Settings, CONFIG_FILE_PORT_ADVICE};
use crate::lock::DataDirLock;
use crate::refresh;
use crate::restore;
use crate::setup::{self, SetupArgs};
use crate::shutdown::StopSignal;
use crate::state::{AppState, OpenOptions};

/// Exit code for a missing or unreadable configuration.
const EXIT_NO_CONFIG: i32 = 2;
const EXIT_FAILED: i32 = 1;

/// Headless OpenSubsonic server for one person's music folder.
#[derive(Parser, Debug)]
#[command(name = "flaccy-server", version, about)]
pub struct Cli {
    /// Configuration file to use instead of ~/.config/flaccy-server/config.toml (~/Library/Application Support/flaccy-server/config.toml on a Mac).
    #[arg(long, global = true, env = "FLACCY_SERVER_CONFIG")]
    pub config: Option<PathBuf>,
    #[command(subcommand)]
    pub command: Option<Command>,
}

/// What to do. `serve` is the default.
#[derive(Subcommand, Debug)]
pub enum Command {
    /// Serve the library over HTTP, rescanning when the music folder changes.
    Serve,
    /// Scan the music folder and run the revision pass once, then exit.
    Scan,
    /// Manage the account password.
    Password {
        #[command(subcommand)]
        action: PasswordAction,
    },
    /// Manage API keys.
    Key {
        #[command(subcommand)]
        action: KeyAction,
    },
    /// Show library counts, the last scan, the API keys and the sync state.
    Status {
        /// Print one JSON document instead of text.
        #[arg(long)]
        json: bool,
    },
    /// Make a one-time code, link and QR code that enrolls a device for a user.
    Enroll(EnrollArgs),
    /// Manage users.
    User {
        #[command(subcommand)]
        action: UserAction,
    },
    /// List and revoke enrolled devices.
    Device {
        #[command(subcommand)]
        action: DeviceAction,
    },
    /// Check the audit trail.
    Audit {
        #[command(subcommand)]
        action: AuditAction,
    },
    /// Exit 0 when a server answers on the configured address, for container health checks.
    Healthcheck,
    /// Connect the server's own Last.fm session, set the account whose history is brought in, and show how both stand.
    Lastfm {
        #[command(subcommand)]
        action: LastfmAction,
    },
    /// Copy the sync state and the security database into dated files, while the server runs.
    Backup {
        /// Write into this folder instead of `backup_dir`.
        #[arg(long)]
        to: Option<PathBuf>,
    },
    /// Replace the sync state with a backup. The server must be stopped.
    Restore {
        /// A `state-YYYYMMDD-HHMMSS.sqlite` file made by `backup`.
        file: PathBuf,
    },
    /// Write one user's playlists, loves, ratings and history as files other programs read.
    Export(ExportArgs),
    /// Set the server up: pick the music folder, start it as a service and enroll the first device.
    Setup(SetupArgs),
    /// Check Tailscale, the network, the clock, the disk, ffmpeg, the databases, backups and devices.
    Doctor,
}

/// `flaccy-server password ...`
#[derive(Subcommand, Debug)]
pub enum PasswordAction {
    /// Set the password, asking twice on the terminal.
    Set {
        /// Read the password as one line from standard input instead.
        #[arg(long)]
        stdin: bool,
        /// The account name; the first time it defaults to "flaccy".
        #[arg(long)]
        user: Option<String>,
    },
}

/// `flaccy-server key ...`
#[derive(Subcommand, Debug)]
pub enum KeyAction {
    /// Make an API key, shown once.
    Add {
        /// A name to tell the key apart, such as "iphone".
        name: String,
        /// The public https URL of this server; prints a QR code the Flaccy app can scan.
        #[arg(long)]
        url: Option<String>,
    },
    /// List keys by name and creation time.
    List,
    /// Revoke a key by name.
    Revoke { name: String },
}

/// Runs the command and returns the process exit code.
pub async fn run(cli: Cli) -> i32 {
    let config_is_explicit = cli.config.is_some();
    let path = cli.config.unwrap_or_else(Config::default_path);
    let command = cli.command.unwrap_or(Command::Serve);
    if let Command::Setup(args) = command {
        return setup::run(&path, config_is_explicit, args).await;
    }
    let config = match Config::load(&path) {
        Ok(config) => config,
        Err(error) => {
            eprintln!("{error}");
            return match error {
                ConfigError::Missing(_) => EXIT_NO_CONFIG,
                _ => EXIT_FAILED,
            };
        }
    };
    let outcome = match command {
        Command::Serve => serve(config).await,
        Command::Scan => scan(config).await,
        Command::Password { action: PasswordAction::Set { stdin, user } } => password_set(&config, stdin, user),
        Command::Key { action } => key(&config, action),
        Command::Status { json } => admin::status(config, json).await,
        Command::Enroll(args) => admin::enroll(&config, args).await,
        Command::User { action } => admin::user(&config, action).await,
        Command::Device { action } => admin::device(&config, action).await,
        Command::Audit { action } => admin::audit(&config, action).await,
        Command::Healthcheck => healthcheck(&config).await,
        Command::Lastfm { action } => lastfm::cli::run(&config, action).await,
        Command::Backup { to } => backup::command(&config, to).await,
        Command::Restore { file } => restore::command(&config, &file).await,
        Command::Export(args) => export::command(&config, args).await,
        Command::Doctor => return doctor::run(&config, &path).await,
        Command::Setup(_) => Err("`setup` runs before the configuration is read.".to_owned()),
    };
    match outcome {
        Ok(()) => 0,
        Err(message) => {
            eprintln!("{message}");
            EXIT_FAILED
        }
    }
}

async fn serve(config: Config) -> Result<(), String> {
    let _data_dir_lock = DataDirLock::acquire(&config.data_dir()).map_err(|error| error.to_string())?;
    logger::init(&config.data_dir());
    let stop = StopSignal::new();
    tokio::spawn(raise_on_stop_request(stop.clone()));
    let settings = Settings { open: OpenOptions { ffmpeg: Some(ffmpeg_program()), name: None }, warn_without_account: true, port_advice: CONFIG_FILE_PORT_ADVICE };
    hosting::run(config, settings, stop, None).await
}

async fn raise_on_stop_request(stop: StopSignal) {
    wait_for_stop_request().await;
    logger::info("server", "stop requested; finishing open requests and exiting");
    stop.raise();
}

async fn wait_for_stop_request() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        if let Ok(mut terminate) = signal(SignalKind::terminate()) {
            tokio::select! {
                _ = tokio::signal::ctrl_c() => {}
                _ = terminate.recv() => {}
            }
            return;
        }
    }
    let _ = tokio::signal::ctrl_c().await;
}

async fn scan(config: Config) -> Result<(), String> {
    logger::init(&config.data_dir());
    let state = AppState::open(config).await?;
    let worker = state.clone();
    let summary = tokio::task::spawn_blocking(move || refresh::refresh_now(&worker))
        .await
        .map_err(|err| format!("The scan thread stopped unexpectedly: {err}. Run `flaccy-server scan` again."))?;
    println!("{}", summary.describe(state.catalog().song_count()));
    match summary.failure {
        Some(failure) => Err(failure),
        None => Ok(()),
    }
}

fn password_set(config: &Config, from_stdin: bool, user: Option<String>) -> Result<(), String> {
    let password = if from_stdin {
        read_line_from_stdin()?
    } else {
        prompt_twice()?
    };
    credentials::check_password(&password)?;
    let path = config.credentials_path();
    let mut account = credentials::load(&path)?.unwrap_or_default();
    account.password = password;
    if let Some(user) = user.filter(|user| !user.trim().is_empty()) {
        account.username = user;
    } else if account.username.is_empty() {
        account.username = DEFAULT_USERNAME.to_string();
    }
    credentials::save(&path, &account)?;
    println!("Password set for '{}'. Running servers pick it up on the next request.", account.username);
    Ok(())
}

fn read_line_from_stdin() -> Result<String, String> {
    let mut line = String::new();
    std::io::stdin()
        .lock()
        .read_line(&mut line)
        .map_err(|err| format!("Could not read the password from standard input: {err}. Pipe it in, for example `printf '%s\\n' \"$PASSWORD\" | flaccy-server password set --stdin`."))?;
    Ok(line.trim_end_matches(['\n', '\r']).to_string())
}

fn prompt_twice() -> Result<String, String> {
    let ask = |label: &str| {
        rpassword::prompt_password(label).map_err(|err| {
            format!("Could not read from the terminal: {err}. Run this in a terminal, or use `flaccy-server password set --stdin` to pipe the password in.")
        })
    };
    let first = ask("New password: ")?;
    let second = ask("Repeat it: ")?;
    if first != second {
        return Err("The two passwords differ, so nothing was changed. Run `flaccy-server password set` again and type the same password twice.".to_string());
    }
    Ok(first)
}

fn key(config: &Config, action: KeyAction) -> Result<(), String> {
    let path = config.credentials_path();
    let mut account = credentials::load(&path)?.unwrap_or_else(|| Credentials {
        username: DEFAULT_USERNAME.to_string(),
        ..Credentials::default()
    });
    match action {
        KeyAction::Add { name, url } => {
            let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
            let key = account.add_key(&name, &now)?;
            credentials::save(&path, &account)?;
            println!("API key '{name}' (shown once, store it now):\n{key}");
            if let Some(url) = url {
                let link = pairing_link(&url, &key, &name);
                println!("\nScan this in the Flaccy app to add the server:\n{}", qr_text(&link)?);
            }
            Ok(())
        }
        KeyAction::List => {
            if account.keys.is_empty() {
                println!("No API keys. Make one with `flaccy-server key add <name>`.");
            }
            for record in &account.keys {
                println!("{}  created {}", record.name, record.created);
            }
            Ok(())
        }
        KeyAction::Revoke { name } => {
            if !account.revoke_key(&name) {
                return Err(format!(
                    "There is no API key called '{name}'. Run `flaccy-server key list` to see the names."
                ));
            }
            credentials::save(&path, &account)?;
            println!("Revoked '{name}'. Clients using it are refused from their next request.");
            Ok(())
        }
    }
}

/// The `flaccy://server` link the Flaccy app opens to add this server.
pub fn pairing_link(url: &str, key: &str, name: &str) -> String {
    format!(
        "flaccy://server?url={}&key={}&name={}",
        percent_encode(url),
        percent_encode(key),
        percent_encode(name)
    )
}

pub(crate) fn percent_encode(value: &str) -> String {
    value
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect()
}

pub(crate) fn qr_text(link: &str) -> Result<String, String> {
    let code = QrCode::new(link.as_bytes()).map_err(|err| {
        format!("Could not draw a QR code for the pairing link: {err}. Enter the URL and key in the app by hand instead.")
    })?;
    Ok(code.render::<Dense1x2>().quiet_zone(true).build())
}

const HEALTHCHECK_TIMEOUT: Duration = Duration::from_secs(5);

async fn healthcheck(config: &Config) -> Result<(), String> {
    let address = probe_address(config);
    tokio::time::timeout(HEALTHCHECK_TIMEOUT, ask_for_ping(&address))
        .await
        .map_err(|_| format!("No answer from {address} within {} seconds. Check that `flaccy-server serve` is running and look at the log in the data folder.", HEALTHCHECK_TIMEOUT.as_secs()))?
}

async fn ask_for_ping(address: &str) -> Result<(), String> {
    let mut stream = TcpStream::connect(address)
        .await
        .map_err(|err| format!("Could not connect to {address}: {err}. Start the server with `flaccy-server serve`."))?;
    let request = format!("GET /rest/ping.view HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n");
    stream
        .write_all(request.as_bytes())
        .await
        .map_err(|err| format!("Could not send a request to {address}: {err}."))?;
    let mut head = [0u8; 8];
    stream
        .read_exact(&mut head)
        .await
        .map_err(|err| format!("{address} closed the connection without answering: {err}."))?;
    if head.starts_with(b"HTTP/1.") {
        Ok(())
    } else {
        Err(format!("{address} answered, but not with HTTP. Another program may be using that port."))
    }
}

/// The address a probe on this machine reaches, with a wildcard bind turned into loopback.
fn probe_address(config: &Config) -> String {
    let host = match config.address.as_str() {
        "0.0.0.0" => "127.0.0.1",
        "::" | "[::]" => "::1",
        other => other,
    };
    if host.contains(':') && !host.starts_with('[') {
        format!("[{host}]:{}", config.port)
    } else {
        format!("{host}:{}", config.port)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config_on(address: &str) -> Config {
        toml::from_str(&format!("music_folder = \"/m\"\naddress = \"{address}\"\nport = 4545\n")).unwrap()
    }

    #[test]
    fn a_wildcard_bind_is_probed_on_loopback() {
        assert_eq!(probe_address(&config_on("0.0.0.0")), "127.0.0.1:4545");
        assert_eq!(probe_address(&config_on("::")), "[::1]:4545");
        assert_eq!(probe_address(&config_on("192.168.1.5")), "192.168.1.5:4545");
    }

    #[test]
    fn the_pairing_link_escapes_every_value() {
        let link = pairing_link("https://box.tail1234.ts.net/music", "abc123", "My Phone");
        assert_eq!(
            link,
            "flaccy://server?url=https%3A%2F%2Fbox.tail1234.ts.net%2Fmusic&key=abc123&name=My%20Phone"
        );
    }

    #[test]
    fn a_qr_code_draws_for_the_link() {
        let text = qr_text(&pairing_link("https://x.test", "k", "n")).unwrap();
        assert!(text.lines().count() > 10);
    }
}
