//! The Last.fm line of `flaccy-server doctor`. It reads the databases read-only, so a doctor run never creates a file.

use std::collections::BTreeMap;
use std::path::Path;

use rusqlite::{Connection, OpenFlags};

use crate::config::Config;
use crate::doctor::{Check, Outcome};

const NAME: &str = "Last.fm";

/// What the state database says about the Last.fm features.
#[derive(Default)]
struct Snapshot {
    accounts: Vec<String>,
    stuck: Vec<(String, String)>,
    paused: Vec<(String, String)>,
    syncing: usize,
    relaying: usize,
}

fn open_read_only(path: &Path) -> Option<Connection> {
    Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX).ok()
}

fn user_names(config: &Config) -> BTreeMap<String, String> {
    let Some(connection) = open_read_only(&config.security_path()) else { return BTreeMap::new() };
    let Ok(mut statement) = connection.prepare("SELECT id, name FROM users") else { return BTreeMap::new() };
    let rows = statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)));
    rows.map(|rows| rows.filter_map(Result::ok).collect()).unwrap_or_default()
}

fn pairs(connection: &Connection, sql: &str) -> rusqlite::Result<Vec<(String, String)>> {
    let mut statement = connection.prepare(sql)?;
    let rows = statement.query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?;
    Ok(rows.filter_map(Result::ok).collect())
}

fn snapshot(config: &Config) -> Option<Snapshot> {
    let connection = open_read_only(&config.state_path())?;
    let names = user_names(config);
    let named = |user: String| names.get(&user).cloned().unwrap_or(user);
    let accounts = pairs(&connection, "SELECT user_id, value_json FROM scalars WHERE key = 'lastfm/account' AND deleted = 0").ok()?;
    let stuck = pairs(&connection, "SELECT user_id, last_error FROM lastfm_sync WHERE last_error IS NOT NULL").ok()?;
    let paused = pairs(&connection, "SELECT user_id, paused_reason FROM lastfm_relay WHERE paused_reason IS NOT NULL").ok()?;
    let relaying: i64 = connection.query_row("SELECT COUNT(*) FROM lastfm_relay WHERE paused_reason IS NULL", [], |row| row.get(0)).ok()?;
    Some(Snapshot {
        syncing: accounts.len().saturating_sub(stuck.len()),
        accounts: accounts.into_iter().map(|(user, _)| user).collect(),
        stuck: stuck.into_iter().map(|(user, error)| (named(user), error)).collect(),
        paused: paused.into_iter().map(|(user, reason)| (named(user), reason)).collect(),
        relaying: relaying as usize,
    })
}

fn failure(problem: String, fix: &str) -> Check {
    Check { name: NAME, outcome: Outcome::Fail(problem, fix.to_owned()), details: Vec::new() }
}

/// The Last.fm lines: nothing when no account is set and no relay is connected, else one line per problem or one that passes.
pub fn checks(config: &Config) -> Vec<Check> {
    let Some(found) = snapshot(config) else { return Vec::new() };
    if found.accounts.is_empty() && found.relaying == 0 && found.paused.is_empty() {
        return Vec::new();
    }
    let mut lines = Vec::new();
    if !found.accounts.is_empty() && config.lastfm.api_key().is_none() {
        lines.push(failure(
            "an account is set but there is no API key, so history is not brought in".to_owned(),
            "Set `lastfm_api_key` in config.toml, or FLACCY_LASTFM_KEY in the server's environment",
        ));
    }
    for (user, error) in &found.stuck {
        lines.push(failure(format!("history for {user} is stuck: {error}"), "The server retries by itself; if this stays, fix the cause named here"));
    }
    for (user, reason) in &found.paused {
        lines.push(failure(
            format!("the scrobble relay for {user} is paused: {reason}"),
            &format!("Run `flaccy-server lastfm connect --user {user}` to link Last.fm again"),
        ));
    }
    if lines.is_empty() {
        let found = format!("history syncing for {} user(s), scrobble relay running for {}", found.syncing, found.relaying);
        lines.push(Check { name: NAME, outcome: Outcome::Pass(found), details: Vec::new() });
    }
    lines
}
