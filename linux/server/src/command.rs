//! The command line: serve, scan, password, keys and status.

use std::io::BufRead;
use std::path::PathBuf;

use clap::{Parser, Subcommand};
use flaccy_library::logger;
use qrcode::render::unicode::Dense1x2;
use qrcode::QrCode;
use tokio::net::TcpListener;

use crate::api;
use crate::config::{Config, ConfigError};
use crate::credentials::{self, Credentials, DEFAULT_USERNAME};
use crate::refresh;
use crate::state::AppState;

/// Exit code for a missing or unreadable configuration.
const EXIT_NO_CONFIG: i32 = 2;
const EXIT_FAILED: i32 = 1;

/// Headless OpenSubsonic server for one person's music folder.
#[derive(Parser, Debug)]
#[command(name = "flaccy-server", version, about)]
pub struct Cli {
    /// Configuration file to use instead of ~/.config/flaccy-server/config.toml.
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
    /// Show library counts, the last scan and the API keys.
    Status,
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
    let path = cli.config.unwrap_or_else(Config::default_path);
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
    let outcome = match cli.command.unwrap_or(Command::Serve) {
        Command::Serve => serve(config).await,
        Command::Scan => scan(config).await,
        Command::Password { action: PasswordAction::Set { stdin, user } } => password_set(&config, stdin, user),
        Command::Key { action } => key(&config, action),
        Command::Status => status(config),
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
    logger::init(&config.data_dir());
    let address = config.listen_address();
    let state = AppState::open(config)?;
    if state.credentials().is_none() {
        logger::warn(
            "server",
            "no account exists yet, so every login will be refused; run `flaccy-server password set` or `flaccy-server key add <name>` in another terminal",
        );
    }
    let listener = TcpListener::bind(&address).await.map_err(|err| {
        format!(
            "Could not listen on {address}: {err}. Another program may be using that port; set a different `port` in the configuration file, or `address` if this machine does not own that address."
        )
    })?;
    logger::info("server", &format!("listening on http://{address}"));
    tokio::spawn(refresh::keep_current(state.clone()));
    axum::serve(listener, api::router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await
        .map_err(|err| format!("The server stopped: {err}. Start it again with `flaccy-server serve`; if this repeats, check the log in the data folder."))
}

async fn shutdown_signal() {
    wait_for_stop_request().await;
    logger::info("server", "stop requested; finishing open requests and exiting");
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
    let state = AppState::open(config)?;
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

fn percent_encode(value: &str) -> String {
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

fn qr_text(link: &str) -> Result<String, String> {
    let code = QrCode::new(link.as_bytes()).map_err(|err| {
        format!("Could not draw a QR code for the pairing link: {err}. Enter the URL and key in the app by hand instead.")
    })?;
    Ok(code.render::<Dense1x2>().quiet_zone(true).build())
}

fn status(config: Config) -> Result<(), String> {
    let account = credentials::load(&config.credentials_path())?;
    let state = AppState::open(config)?;
    let catalog = state.catalog();
    println!("Music folder: {}", state.music_root().display());
    println!("Data folder:  {}", state.0.config.data_dir().display());
    println!(
        "Library:      {} songs, {} albums, {} artists, {} playlists",
        catalog.song_count(),
        catalog.albums().len(),
        catalog.artists().len(),
        state.0.store.playlist_count()
    );
    match state.0.store.state("lastScanAt") {
        Some(at) => println!(
            "Last scan:    {at} ({})",
            state.0.store.state("lastScanSummary").unwrap_or_default()
        ),
        None => println!("Last scan:    never; run `flaccy-server scan` or `flaccy-server serve`"),
    }
    match &account {
        Some(account) if !account.password.is_empty() => println!("Account:      {} (password set)", account.username),
        Some(account) => println!("Account:      {} (no password; API keys only)", account.username),
        None => println!("Account:      none; run `flaccy-server password set`"),
    }
    let keys = account.map(|account| account.keys).unwrap_or_default();
    println!("API keys:     {}", if keys.is_empty() { "none".to_string() } else { keys.len().to_string() });
    for record in keys {
        println!("  {}  created {}", record.name, record.created);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

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
