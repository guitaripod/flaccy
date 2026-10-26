//! The administration commands: enroll, user, device, audit and status.
//!
//! They open the security and sync databases directly, so they work whether or
//! not `flaccy-server serve` is running.

use std::io::Write;
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use clap::{Args, Subcommand};
use serde_json::{json, Value};

use crate::backup;
use crate::command::{percent_encode, qr_text};
use crate::config::Config;
use crate::credentials;
use crate::lastfm;
use crate::native::machine_name;
use crate::security::{self, Device, Role, User};
use crate::state::AppState;

const MAX_TTL: Duration = Duration::from_secs(24 * 60 * 60);
const CODE_GROUP: usize = 5;

/// Writes a line to standard output; the commands' answers are data, not log lines.
pub(crate) fn say(text: &str) {
    let _ = writeln!(std::io::stdout(), "{text}");
}

/// `flaccy-server enroll ...`
#[derive(Args, Debug)]
pub struct EnrollArgs {
    /// The user the new device belongs to; the first admin when left out. On a server with no users yet, this creates the first admin.
    #[arg(long)]
    pub user: Option<String>,
    /// How clients reach this server; default http://<this machine's name>:<port>.
    #[arg(long)]
    pub url: Option<String>,
    /// How long the code works: seconds, or a number with s, m or h.
    #[arg(long, default_value = "10m")]
    pub ttl: String,
    /// Print one JSON object instead of text and a QR code.
    #[arg(long)]
    pub json: bool,
}

/// `flaccy-server user ...`
#[derive(Subcommand, Debug)]
pub enum UserAction {
    /// Add a user.
    Add {
        name: String,
        /// admin, member, guest or pending.
        #[arg(long, default_value = "member")]
        role: String,
    },
    /// List users with their roles.
    List,
    /// Change a user's role.
    Role { name: String, role: String },
}

/// `flaccy-server device ...`
#[derive(Subcommand, Debug)]
pub enum DeviceAction {
    /// List devices, revoked ones included.
    List {
        /// Only this user's devices.
        #[arg(long)]
        user: Option<String>,
    },
    /// Revoke a device; it is refused from its next request.
    Revoke { id: String },
}

/// `flaccy-server audit ...`
#[derive(Subcommand, Debug)]
pub enum AuditAction {
    /// Check that no audit entry was edited or removed.
    Verify,
}

fn storage(error: impl std::fmt::Display) -> String {
    error.to_string()
}

async fn open_security(config: &Config) -> Result<security::Store, String> {
    security::Store::open(&config.security_path()).await.map_err(storage)
}

fn parse_role(word: &str) -> Result<Role, String> {
    Role::parse(word).ok_or_else(|| format!("'{word}' is not a role. Use admin, member, guest or pending."))
}

/// Reads `90`, `30s`, `10m` or `2h` as a duration of at least a second and at most a day.
pub(crate) fn parse_ttl(text: &str) -> Result<Duration, String> {
    let trimmed = text.trim();
    let (digits, unit) = match trimmed.char_indices().find(|(_, c)| !c.is_ascii_digit()) {
        Some((at, _)) => trimmed.split_at(at),
        None => (trimmed, "s"),
    };
    let multiplier = match unit {
        "s" => 1,
        "m" => 60,
        "h" => 3600,
        _ => return Err(bad_ttl(text)),
    };
    let seconds: u64 = digits.parse().map_err(|_| bad_ttl(text))?;
    let ttl = Duration::from_secs(seconds.saturating_mul(multiplier));
    if ttl.is_zero() || ttl > MAX_TTL {
        return Err(bad_ttl(text));
    }
    Ok(ttl)
}

fn bad_ttl(text: &str) -> String {
    format!("'{text}' is not a usable --ttl. Use a number of seconds or a number with s, m or h, between 1 second and 24h, for example 10m.")
}

/// The `flaccy://server` link a device opens to enroll.
pub(crate) fn enrollment_link(url: &str, code: &str, name: &str) -> String {
    format!(
        "flaccy://server?url={}&enroll={}&name={}",
        percent_encode(url),
        percent_encode(code),
        percent_encode(name)
    )
}

fn grouped(code: &str) -> String {
    code.as_bytes()
        .chunks(CODE_GROUP)
        .map(|chunk| String::from_utf8_lossy(chunk).into_owned())
        .collect::<Vec<_>>()
        .join("-")
}

async fn enrollee(security: &security::Store, name: &str) -> Result<User, String> {
    if let Some(user) = security.find_user_by_name(name).await.map_err(storage)? {
        return Ok(user);
    }
    if security.list_users().await.map_err(storage)?.is_empty() {
        return security.create_user(name, Role::Admin).await.map_err(storage);
    }
    Err(format!("There is no user called '{name}'. Add one with `flaccy-server user add {name}`, then enroll again."))
}

async fn first_admin(security: &security::Store) -> Result<User, String> {
    let users = security.list_users().await.map_err(storage)?;
    users
        .into_iter()
        .find(|user| user.role == Role::Admin)
        .ok_or_else(|| "This server has no users yet. Run `flaccy-server enroll --user <name>` to make the first one, or `flaccy-server setup`.".to_owned())
}

/// `enroll`: makes a ten-minute code for a user and prints it once with its link and QR code.
pub async fn enroll(config: &Config, args: EnrollArgs) -> Result<(), String> {
    let ttl = parse_ttl(&args.ttl)?;
    let security = open_security(config).await?;
    let user = match &args.user {
        Some(name) => enrollee(&security, name).await?,
        None => first_admin(&security).await?,
    };
    let code = security.create_enrollment(&user.id, ttl).await.map_err(storage)?;
    let url = args.url.unwrap_or_else(|| format!("http://{}:{}", machine_name(), config.port));
    let link = enrollment_link(&url, &code, machine_name());
    let expires = (Utc::now() + chrono::Duration::from_std(ttl).unwrap_or_default()).to_rfc3339_opts(SecondsFormat::Secs, true);
    if args.json {
        say(&json!({ "link": link, "code": code, "url": url, "user": user.name, "expiresAt": expires }).to_string());
        return Ok(());
    }
    say(&format!("Enrollment for {} (shown once, valid until {expires}):", user.name));
    say(&format!("  {}", grouped(&code)));
    say(&format!("\nScan this in Flaccy to add the server, or open the link on the device:\n{}", qr_text(&link)?));
    say(&link);
    Ok(())
}

/// `user ...`
pub async fn user(config: &Config, action: UserAction) -> Result<(), String> {
    let security = open_security(config).await?;
    match action {
        UserAction::Add { name, role } => {
            let user = security.create_user(&name, parse_role(&role)?).await.map_err(storage)?;
            say(&format!("Added {} as {}.", user.name, user.role.as_str()));
        }
        UserAction::List => {
            for user in security.list_users().await.map_err(storage)? {
                say(&format!("{:<24} {:<8} {}", user.name, user.role.as_str(), user.id));
            }
        }
        UserAction::Role { name, role } => {
            let target = security
                .find_user_by_name(&name)
                .await
                .map_err(storage)?
                .ok_or_else(|| format!("There is no user called '{name}'. List the users with `flaccy-server user list`."))?;
            security.set_role(&target.id, parse_role(&role)?).await.map_err(storage)?;
            say(&format!("{} is now {}.", target.name, role));
        }
    }
    Ok(())
}

fn describe_moment(millis: Option<i64>) -> String {
    millis
        .and_then(DateTime::<Utc>::from_timestamp_millis)
        .map(|moment| moment.to_rfc3339_opts(SecondsFormat::Secs, true))
        .unwrap_or_else(|| "never".to_owned())
}

fn device_line(device: &Device, owner: &str) -> String {
    let revoked = device.revoked_at.map(|at| format!("  revoked {}", describe_moment(Some(at)))).unwrap_or_default();
    format!(
        "{}  {:<16} {:<20} {:<8} last seen {}{revoked}",
        device.id,
        owner,
        device.name,
        device.platform,
        describe_moment(device.last_seen_at)
    )
}

/// `device ...`
pub async fn device(config: &Config, action: DeviceAction) -> Result<(), String> {
    let security = open_security(config).await?;
    match action {
        DeviceAction::List { user } => {
            let users = security.list_users().await.map_err(storage)?;
            let scope = match user {
                Some(name) => Some(
                    users
                        .iter()
                        .find(|candidate| candidate.name.eq_ignore_ascii_case(&name))
                        .map(|found| found.id.clone())
                        .ok_or_else(|| format!("There is no user called '{name}'. List the users with `flaccy-server user list`."))?,
                ),
                None => None,
            };
            let devices = security.list_devices(scope.as_ref()).await.map_err(storage)?;
            if devices.is_empty() {
                say("No devices. Enroll one with `flaccy-server enroll --user <name>`.");
            }
            for device in &devices {
                let owner = users.iter().find(|user| user.id == device.user_id).map(|user| user.name.as_str()).unwrap_or("?");
                say(&device_line(device, owner));
            }
        }
        DeviceAction::Revoke { id } => {
            let revoked = security.revoke_device(&security::DeviceId(id.clone())).await.map_err(storage)?;
            if revoked {
                say(&format!("Revoked {id}. The device is refused from its next request."));
            } else {
                say(&format!("{id} was already revoked."));
            }
        }
    }
    Ok(())
}

/// `audit verify`
pub async fn audit(config: &Config, action: AuditAction) -> Result<(), String> {
    let security = open_security(config).await?;
    match action {
        AuditAction::Verify => {
            security.verify_audit().await.map_err(storage)?;
            let entries = security.audit_len().await.map_err(storage)?;
            say(&format!("The audit trail is intact: {entries} entries."));
        }
    }
    Ok(())
}

fn file_bytes(path: &std::path::Path) -> u64 {
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    ["", "-wal"]
        .iter()
        .filter_map(|suffix| std::fs::metadata(path.with_file_name(format!("{name}{suffix}"))).ok())
        .map(|metadata| metadata.len())
        .sum()
}

fn megabytes(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / 1_048_576.0)
}

/// `status`: library counts, the account and keys, and the sync block, as text or JSON.
pub async fn status(config: Config, as_json: bool) -> Result<(), String> {
    let account = credentials::load(&config.credentials_path())?;
    let state = AppState::open(config).await?;
    let report = report(&state, account).await?;
    if as_json {
        say(&serde_json::to_string_pretty(&report).map_err(storage)?);
    } else {
        print_report(&report);
    }
    Ok(())
}

async fn report(state: &AppState, account: Option<credentials::Credentials>) -> Result<Value, String> {
    let config = &state.0.config;
    let (songs, albums, artists) = {
        let catalog = state.catalog();
        (catalog.song_count(), catalog.albums().len(), catalog.artists().len())
    };
    let users = state.0.security.list_users().await.map_err(storage)?;
    let devices = state.0.security.list_devices(None).await.map_err(storage)?;
    let stats = state.0.sync.stats().await.map_err(storage)?;
    let last_backup = backup::last_status(&state.0.security).await?;
    let lastfm = lastfm::status::gather(&state.0.sync, &state.0.security).await?;
    let last_scan = state
        .0
        .store
        .state("lastScanAt")
        .map(|at| json!({ "at": at, "summary": state.0.store.state("lastScanSummary").unwrap_or_default() }));
    let keys: Vec<Value> = account
        .as_ref()
        .map(|account| account.keys.iter().map(|key| json!({ "name": key.name, "created": key.created })).collect())
        .unwrap_or_default();
    let account_block = account
        .as_ref()
        .map(|account| json!({ "username": account.username, "passwordSet": !account.password.is_empty() }));
    Ok(json!({
        "musicFolder": state.music_root().display().to_string(),
        "dataFolder": config.data_dir().display().to_string(),
        "library": { "songs": songs, "albums": albums, "artists": artists, "playlists": state.0.store.playlist_count() },
        "lastScan": last_scan,
        "account": account_block,
        "apiKeys": keys,
        "backup": { "lastAt": last_backup.last_at, "ok": last_backup.last_ok, "error": last_backup.last_error },
        "lastfm": lastfm::status::report(&lastfm, config.lastfm.api_key().is_some()),
        "sync": {
            "users": users.len(),
            "devices": devices.iter().filter(|device| device.revoked_at.is_none()).count(),
            "revokedDevices": devices.iter().filter(|device| device.revoked_at.is_some()).count(),
            "head": stats.head,
            "playlists": stats.playlists,
            "entries": stats.entries,
            "listens": stats.listens,
            "databaseBytes": {
                "library": file_bytes(&config.database_path()),
                "security": file_bytes(&config.security_path()),
                "state": stats.bytes,
            },
        },
    }))
}

fn text(value: &Value) -> String {
    value.as_str().map(str::to_owned).unwrap_or_else(|| value.to_string())
}

fn print_report(report: &Value) {
    let library = &report["library"];
    say(&format!("Music folder: {}", text(&report["musicFolder"])));
    say(&format!("Data folder:  {}", text(&report["dataFolder"])));
    say(&format!(
        "Library:      {} songs, {} albums, {} artists, {} playlists",
        library["songs"], library["albums"], library["artists"], library["playlists"]
    ));
    match report["lastScan"].as_object() {
        Some(scan) => say(&format!("Last scan:    {} ({})", text(&scan["at"]), text(&scan["summary"]))),
        None => say("Last scan:    never; run `flaccy-server scan` or `flaccy-server serve`"),
    }
    match report["account"].as_object() {
        Some(account) if account["passwordSet"] == json!(true) => {
            say(&format!("Account:      {} (password set)", text(&account["username"])))
        }
        Some(account) => say(&format!("Account:      {} (no password; API keys only)", text(&account["username"]))),
        None => say("Account:      none; run `flaccy-server password set`"),
    }
    let keys = report["apiKeys"].as_array().cloned().unwrap_or_default();
    say(&format!("API keys:     {}", if keys.is_empty() { "none".to_owned() } else { keys.len().to_string() }));
    for key in keys {
        say(&format!("  {}  created {}", text(&key["name"]), text(&key["created"])));
    }
    print_sync(&report["sync"]);
    print_backup(&report["backup"]);
}

fn print_backup(backup: &Value) {
    match (backup["lastAt"].as_str(), backup["ok"].as_bool()) {
        (Some(at), Some(true)) => say(&format!("Last backup:  {at}")),
        (Some(at), _) => say(&format!("Last backup:  FAILED at {at}: {}", text(&backup["error"]))),
        _ => say("Last backup:  never; run `flaccy-server backup`"),
    }
}

fn print_sync(sync: &Value) {
    say(&format!(
        "Sync:         {} users, {} devices ({} revoked), head {}, {} playlists, {} entries, {} listens",
        sync["users"], sync["devices"], sync["revokedDevices"], sync["head"], sync["playlists"], sync["entries"], sync["listens"]
    ));
    let sizes = &sync["databaseBytes"];
    let size = |name: &str| megabytes(sizes[name].as_u64().unwrap_or(0));
    say(&format!(
        "Databases:    library {}, security {}, state {}",
        size("library"),
        size("security"),
        size("state")
    ));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ttl_accepts_seconds_minutes_and_hours() {
        assert_eq!(parse_ttl("90").unwrap(), Duration::from_secs(90));
        assert_eq!(parse_ttl("30s").unwrap(), Duration::from_secs(30));
        assert_eq!(parse_ttl("10m").unwrap(), Duration::from_secs(600));
        assert_eq!(parse_ttl("2h").unwrap(), Duration::from_secs(7200));
    }

    #[test]
    fn ttl_refuses_nonsense_zero_and_more_than_a_day() {
        for bad in ["", "m", "0", "0m", "10x", "-5", "25h", "1d", "1.5m"] {
            assert!(parse_ttl(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn the_link_escapes_every_value() {
        let link = enrollment_link("http://my box:4545", "ABC", "My Mac");
        assert_eq!(link, "flaccy://server?url=http%3A%2F%2Fmy%20box%3A4545&enroll=ABC&name=My%20Mac");
    }

    #[test]
    fn codes_group_by_five() {
        assert_eq!(grouped("ABCDEFGHIJKL"), "ABCDE-FGHIJ-KL");
    }
}
