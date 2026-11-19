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

/// Headless music server for one folder. Flaccy on iPhone, iPad, Mac and Linux connects to it, and so does any Subsonic app.
///
/// With no command, this is `serve`.
///
/// Connect a phone, iPad or computer that has Flaccy with `flaccy-server enroll --user marcus`. That prints a QR code in this terminal and a flaccy:// link. There is no window to open. Scan the QR in the app, or open the link on the device and tap Connect. The code works once.
///
/// `--user` is an account on this server (`flaccy-server user list`), never the device's name. The device names itself when it connects.
///
/// First run, when this machine is not set up yet: `flaccy-server setup`. What is wrong, and the fix: `flaccy-server doctor`. Each command explains itself: `flaccy-server <command> --help`.
#[derive(Parser, Debug)]
#[command(name = "flaccy-server", version, long_about)]
#[command(after_help = "\
Examples:
  flaccy-server setup
  flaccy-server enroll --user marcus
  flaccy-server enroll --user marcus --json
  flaccy-server doctor
  flaccy-server status")]
pub struct Cli {
    /// Configuration file instead of ~/.config/flaccy-server/config.toml (on a Mac, ~/Library/Application Support/flaccy-server/config.toml). Applies to every command.
    #[arg(long, global = true, env = "FLACCY_SERVER_CONFIG")]
    pub config: Option<PathBuf>,
    #[command(subcommand)]
    pub command: Option<Command>,
}

/// What to do. `serve` is the default when this is left out.
#[derive(Subcommand, Debug)]
pub enum Command {
    /// Set the server up: music folder, how devices reach it, and a code for the first device.
    ///
    /// Asks where the music is, decides whether devices reach it through Tailscale, this network, or both, starts it as a service and prints a QR code and a flaccy:// link for the first device. Without Tailscale it can share on this network only. Run it again later and it keeps the setup and only prints a new code.
    ///
    /// `--yes` takes every default and asks nothing. `--music` and `--port` are ignored when a configuration file already exists; edit that file to change them. `--name` is the account the code is for. On a server with no accounts it creates the admin; otherwise it must already exist. `--no-lan` shares only over Tailscale, and refuses to run when Tailscale is not connected.
    #[command(after_help = "\
Examples:
  flaccy-server setup
  flaccy-server setup --yes --music ~/Music --name marcus
  flaccy-server setup --no-lan")]
    Setup(SetupArgs),
    /// Print a one-time code, link and QR that connects one Flaccy app.
    ///
    /// The QR code and the flaccy://server link are printed in this terminal. There is no window to open. In Flaccy, add a server and scan the QR, or open the link on the device and tap Connect. A scan connects at once. An opened link fills the form; Connect is one tap.
    ///
    /// The code works once. It lasts 10 minutes unless `--ttl` says otherwise.
    ///
    /// This is how Flaccy connects. A Subsonic app that is not Flaccy uses `key add` instead.
    #[command(after_help = "\
Examples:
  flaccy-server enroll --user marcus
  flaccy-server enroll --user marcus --url http://arch:4545 --ttl 30m
  flaccy-server enroll --user marcus --json")]
    Enroll(EnrollArgs),
    /// Listen for apps and rescan when the music folder changes.
    ///
    /// This is what the service runs, and what you get when no command is given. Listens on this machine's Tailscale addresses and on loopback, unless `address` in the configuration says otherwise. Do not run a second copy against the same data folder.
    Serve,
    /// Index the music folder once, then exit.
    ///
    /// Reads tags and runs one revision pass. A running `serve` already rescans when the folder changes; use this to index without leaving a server up. Songs can play before the fingerprint pass finishes.
    Scan,
    /// Show library counts, the last scan, keys, backup and sync state.
    ///
    /// Text by default. `--json` prints one document with musicFolder, dataFolder, library, lastScan, scanning, account, apiKeys, backup, lastfm and sync. Works while the server is running.
    #[command(after_help = "\
Examples:
  flaccy-server status
  flaccy-server status --json")]
    Status {
        /// Print one JSON document instead of text.
        #[arg(long)]
        json: bool,
    },
    /// Check Tailscale, the network, the clock, the disk, ffmpeg, databases, backups and devices.
    ///
    /// One line per check. A failed line names what is wrong and the command that fixes it. Order: Tailscale, where the server listens, the clock, the disk, ffmpeg, the databases, the last backup, enrolled devices, Last.fm. Exit 0 when every check passed, 1 when one failed.
    #[command(after_help = "\
Examples:
  flaccy-server doctor")]
    Doctor,
    /// Exit 0 when a server answers on the configured address.
    ///
    /// For a container health check. Waits up to 5 seconds. Exit 1 when nothing answers. A wildcard bind is probed on loopback.
    Healthcheck,
    /// Add, list and change accounts on this server.
    ///
    /// An account is who a device belongs to. It is not a device name. Roles: admin (everything), member (own playlists, loves, ratings and listens; can edit shared playlists), guest (reads what is shared, stores nothing), pending (a device may do nothing until an admin sets a role).
    #[command(arg_required_else_help = true)]
    #[command(after_help = "\
Examples:
  flaccy-server user list
  flaccy-server user add sam --role member
  flaccy-server user role sam admin")]
    User {
        #[command(subcommand)]
        action: UserAction,
    },
    /// List enrolled devices, and revoke one by its id.
    ///
    /// The name in the list is the name the device sent when it connected. `revoke` takes the id from `list`, not the device's name. A revoked device is refused from its next request.
    #[command(arg_required_else_help = true)]
    #[command(after_help = "\
Examples:
  flaccy-server device list
  flaccy-server device list --user marcus
  flaccy-server device revoke <id>")]
    Device {
        #[command(subcommand)]
        action: DeviceAction,
    },
    /// Set the password other Subsonic apps use. Flaccy apps use enroll.
    ///
    /// At least 8 characters. A running server picks it up on the next request. `--user` here is the OpenSubsonic login name, default `flaccy`, not an account from `user list`.
    #[command(arg_required_else_help = true)]
    #[command(after_help = "\
Examples:
  flaccy-server password set
  printf '%s\\n' \"$PASSWORD\" | flaccy-server password set --stdin")]
    Password {
        #[command(subcommand)]
        action: PasswordAction,
    },
    /// Make API keys for Subsonic apps that are not Flaccy. Flaccy apps use enroll.
    ///
    /// A key is shown once. The name passed to `add` tells keys apart; it is not a device name. `add --url` prints a QR whose link carries the key (`flaccy://server?...&key=`). That is a different link from `enroll`, which carries a one-time code.
    #[command(arg_required_else_help = true)]
    #[command(after_help = "\
Examples:
  flaccy-server key add \"Living room\"
  flaccy-server key add iphone --url https://arch.example.ts.net
  flaccy-server key list
  flaccy-server key revoke iphone")]
    Key {
        #[command(subcommand)]
        action: KeyAction,
    },
    /// Copy sync state and the security database to dated files.
    ///
    /// Safe while the server is running. Writes state-YYYYMMDD-HHMMSS.sqlite (playlists, loves, ratings, history) and security-YYYYMMDD-HHMMSS.sqlite (accounts, devices, token hashes). The default folder is `backup_dir`, or the data folder's backups. An empty `backup_dir` turns this off; pass `--to` or set the folder. Does not copy the music index or Last.fm sessions. Keep the security file as private as the data folder.
    #[command(after_help = "\
Examples:
  flaccy-server backup
  flaccy-server backup --to /mnt/nas/flaccy")]
    Backup {
        /// Folder to write into, instead of `backup_dir`.
        #[arg(long)]
        to: Option<PathBuf>,
    },
    /// Put a state backup back. The server must be stopped.
    ///
    /// Takes a state-YYYYMMDD-HHMMSS.sqlite file. Refuses a security backup, and refuses to run while `serve` holds the data folder. Accounts, devices and tokens stay as they are. The current state file is kept beside it as state.before-restore-<time>.sqlite.
    #[command(after_help = "\
Examples:
  flaccy-server restore ~/.local/share/flaccy-server/backups/state-20261119-033000.sqlite")]
    Restore {
        /// A state-YYYYMMDD-HHMMSS.sqlite file from `backup`. Not a security-*.sqlite file.
        file: PathBuf,
    },
    /// Write one account's playlists, loves, ratings and history for another program.
    ///
    /// `--format json` is one document of playlists, loves, ratings, preferences and player sessions. `--format m3u8` is one playlist file per playlist, with paths relative to the output folder. `--format jsonl` is listens, oldest first, in the shape ListenBrainz imports; suppressed plays are left out. Creates the output folder. Never writes tokens or Last.fm keys. The account must exist (`user list`).
    #[command(after_help = "\
Examples:
  flaccy-server export --user marcus --format json --out ~/flaccy-export
  flaccy-server export --user marcus --format m3u8 --out ~/flaccy-export
  flaccy-server export --user marcus --format jsonl --out ~/flaccy-export")]
    Export(ExportArgs),
    /// Check that the audit trail of account and device changes was not edited.
    ///
    /// `verify` walks the hash chain. It prints the entry count when the trail is intact, and names the first edited or removed entry and exits 1 when it is not.
    #[command(arg_required_else_help = true)]
    #[command(after_help = "\
Examples:
  flaccy-server audit verify")]
    Audit {
        #[command(subcommand)]
        action: AuditAction,
    },
    /// Bring in a Last.fm history, and scrobble plays from apps that are not Flaccy.
    ///
    /// Two different jobs. `account` names the Last.fm profile whose public history is brought in. `connect` links this server's own Last.fm session so plays that other OpenSubsonic apps report are scrobbled. Flaccy apps scrobble for themselves and are not sent twice.
    ///
    /// Needs `lastfm_api_key` in the configuration, or FLACCY_LASTFM_KEY. Works whether or not `serve` is running; a running server notices on its next pass. `--user` is an account from `user list`.
    #[command(arg_required_else_help = true)]
    #[command(after_help = "\
Examples:
  flaccy-server lastfm account --user marcus my_lastfm
  flaccy-server lastfm connect --user marcus
  flaccy-server lastfm status
  flaccy-server lastfm disconnect --user marcus")]
    Lastfm {
        #[command(subcommand)]
        action: LastfmAction,
    },
}

/// `flaccy-server password ...`
#[derive(Subcommand, Debug)]
pub enum PasswordAction {
    /// Set the password, asking twice on a terminal.
    ///
    /// At least 8 characters. Nothing is stored if the two entries differ. A running server picks the new password up on the next request.
    #[command(after_help = "\
Examples:
  flaccy-server password set
  printf '%s\\n' \"$PASSWORD\" | flaccy-server password set --stdin")]
    Set {
        /// Read one line from standard input instead of asking twice. For a script.
        #[arg(long)]
        stdin: bool,
        /// OpenSubsonic login name. Default `flaccy` the first time. Not an account from `user list`, and not a device name.
        #[arg(long)]
        user: Option<String>,
    },
}

/// `flaccy-server key ...`
#[derive(Subcommand, Debug)]
pub enum KeyAction {
    /// Make an API key for a Subsonic app that is not Flaccy. Shown once.
    ///
    /// Flaccy apps should use `enroll` instead. The name is how you tell keys apart in `key list` and `key revoke`, not a device name.
    #[command(after_help = "\
Examples:
  flaccy-server key add \"Living room\"
  flaccy-server key add iphone --url https://arch.example.ts.net")]
    Add {
        /// Name that tells this key apart, such as "iphone". Not a device name.
        name: String,
        /// Public URL of this server. Prints a QR whose link carries this key, not an enrollment code. Flaccy apps should use `enroll`.
        ///
        /// For a Subsonic app that is not Flaccy. Prefer `enroll` for a phone, iPad or Mac running Flaccy.
        #[arg(long)]
        url: Option<String>,
    },
    /// List keys by name and creation time. The key itself is not shown again.
    List,
    /// Revoke a key by the name given to `key add`. Clients using it are refused from their next request.
    Revoke {
        /// Name passed to `key add`. See `key list`.
        name: String,
    },
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
    use clap::CommandFactory;

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

    fn plain(text: &str) -> String {
        let mut out = String::new();
        let mut chars = text.chars().peekable();
        while let Some(c) = chars.next() {
            if c == '\u{1b}' && chars.peek() == Some(&'[') {
                chars.next();
                for next in chars.by_ref() {
                    if next.is_ascii_alphabetic() {
                        break;
                    }
                }
            } else {
                out.push(c);
            }
        }
        out
    }

    fn long_help(path: &[&str]) -> String {
        let mut command = Cli::command();
        for name in path {
            let next = command.find_subcommand(name).unwrap_or_else(|| panic!("no subcommand {name}")).clone();
            command = next;
        }
        plain(&command.render_long_help().to_string())
    }

    fn assert_has(help: &str, needles: &[&str]) {
        for needle in needles {
            assert!(help.contains(needle), "help missing {needle:?}:\n{help}");
        }
    }

    #[test]
    fn the_top_level_help_routes_a_person_and_names_every_command() {
        let help = long_help(&[]);
        assert_has(&help, &[
            "With no command, this is `serve`",
            "never the device's name",
            "no window to open",
            "flaccy-server enroll --user marcus",
            "flaccy-server setup",
            "flaccy-server doctor",

        ]);
        for name in ["setup", "enroll", "serve", "scan", "status", "doctor", "healthcheck", "user", "device", "password", "key", "backup", "restore", "export", "audit", "lastfm"] {
            assert!(help.contains(name), "command list missing {name}:\n{help}");
        }
    }

    #[test]
    fn enroll_help_says_the_account_is_not_the_device_and_names_the_json() {
        let help = long_help(&["enroll"]);
        assert_has(&help, &[
            "Not the device's name",
            "user list",
            "lan = true",
            "link, code, url, user, expiresAt",
            "key add",
            "10m",
            "24h",
            "no window to open",
        ]);
    }

    #[test]
    fn key_and_password_help_send_flaccy_apps_to_enroll() {
        assert_has(&long_help(&["key"]), &["Flaccy apps use enroll", "not a device name", "one-time code"]);
        assert_has(&long_help(&["password"]), &["Flaccy apps use enroll", "not an account from `user list`"]);
        assert_has(&long_help(&["setup"]), &["--no-lan", "this network"]);
    }

    #[test]
    fn a_command_that_only_has_subcommands_prints_its_help() {
        let error = Cli::try_parse_from(["flaccy-server", "user"]).unwrap_err();
        assert_eq!(error.kind(), clap::error::ErrorKind::DisplayHelpOnMissingArgumentOrSubcommand);
        let text = plain(&error.to_string());
        assert!(text.contains("user list") && text.contains("not a device"), "{text}");
    }
}
