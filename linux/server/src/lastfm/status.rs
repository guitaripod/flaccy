//! What `status --json`, `lastfm status` and `doctor` say about the Last.fm features. Nothing here reads a key.

use chrono::{DateTime, SecondsFormat, Utc};
use serde_json::{json, Value};

use super::history_store::SyncRecord;
use super::relay_store::RelayRecord;
use crate::security::{self, User};
use crate::sync::Store;

/// One user's Last.fm state, gathered once so the JSON and the text agree.
pub struct UserStatus {
    /// The user.
    pub user: User,
    /// The Last.fm account whose history is brought in, if one is set.
    pub account: Option<String>,
    /// The history sync, once it has run.
    pub history: Option<SyncRecord>,
    /// The relay, once connected.
    pub relay: Option<RelayRecord>,
    /// The Last.fm account the relay submits to.
    pub relay_account: Option<String>,
    /// Plays waiting in the relay's queue.
    pub queued: i64,
}

/// Gathers the status of every user who has a Last.fm account name or a relay.
pub async fn gather(sync: &Store, security: &security::Store) -> Result<Vec<UserStatus>, String> {
    let failure = |error: &dyn std::fmt::Display| error.to_string();
    let accounts = sync.lastfm_accounts().await.map_err(|error| failure(&error))?;
    let mut statuses = Vec::new();
    for user in security.list_users().await.map_err(|error| failure(&error))? {
        let account = accounts.iter().find(|(id, _)| *id == user.id).map(|(_, name)| name.clone());
        let history = sync.lastfm_sync_record(&user.id).await.map_err(|error| failure(&error))?;
        let relay = sync.lastfm_relay_record(&user.id).await.map_err(|error| failure(&error))?;
        if account.is_none() && relay.is_none() {
            continue;
        }
        let relay_account = security.lastfm_session(&user.id).await.map_err(|error| failure(&error))?.map(|session| session.username);
        let queued = if relay.is_some() { sync.lastfm_queue_len(&user.id).await.map_err(|error| failure(&error))? } else { 0 };
        statuses.push(UserStatus { user, account, history, relay, relay_account, queued });
    }
    Ok(statuses)
}

fn moment(seconds: Option<i64>) -> Value {
    seconds
        .and_then(|at| DateTime::<Utc>::from_timestamp(at, 0))
        .map(|at| json!(at.to_rfc3339_opts(SecondsFormat::Secs, true)))
        .unwrap_or(Value::Null)
}

fn history_json(account: &Option<String>, history: &Option<SyncRecord>) -> Value {
    let Some(account) = account else { return Value::Null };
    let Some(record) = history else {
        return json!({ "account": account, "phase": "waiting", "complete": false });
    };
    json!({
        "account": account,
        "phase": record.phase.word(),
        "complete": record.plan.backfill_complete,
        "page": record.plan.backfill_page,
        "totalPages": record.total_pages,
        "stored": record.stored,
        "lastSync": moment(record.plan.last_sync_at),
        "lastSettle": moment(record.plan.last_settle_at),
        "error": record.last_error,
    })
}

fn relay_json(status: &UserStatus) -> Value {
    let Some(relay) = &status.relay else { return Value::Null };
    json!({
        "account": status.relay_account,
        "paused": relay.paused_reason.is_some(),
        "pausedReason": relay.paused_reason,
        "queued": status.queued,
        "submitted": relay.submitted,
        "rejected": relay.rejected,
        "lastSubmit": moment(relay.last_submit),
        "lastError": relay.last_error,
    })
}

/// The `lastfm` block of `status --json`.
pub fn report(statuses: &[UserStatus], key_configured: bool) -> Value {
    let users: Vec<Value> = statuses
        .iter()
        .map(|status| json!({ "user": status.user.name, "history": history_json(&status.account, &status.history), "relay": relay_json(status) }))
        .collect();
    json!({ "apiKeyConfigured": key_configured, "users": users })
}

/// What `doctor` should flag: each sentence names what is wrong, the cause and the next step.
pub fn problems(statuses: &[UserStatus], key_configured: bool) -> Vec<String> {
    let mut found = Vec::new();
    let wants_history = statuses.iter().any(|status| status.account.is_some());
    if wants_history && !key_configured {
        found.push("A Last.fm account is set but there is no API key, so history is not brought in. Set `lastfm_api_key` in config.toml or FLACCY_LASTFM_KEY in the server's environment.".to_owned());
    }
    for status in statuses {
        let name = &status.user.name;
        if let Some(error) = status.history.as_ref().and_then(|record| record.last_error.as_ref()) {
            found.push(format!("Last.fm history for {name} is stuck: {error}"));
        }
        if let Some(reason) = status.relay.as_ref().and_then(|relay| relay.paused_reason.as_ref()) {
            found.push(format!("The Last.fm relay for {name} is paused: {reason}"));
        }
    }
    found
}

fn describe_history(status: &UserStatus) -> String {
    let (Some(account), record) = (&status.account, &status.history) else { return "no Last.fm account set".to_owned() };
    match record {
        None => format!("history of {account}: waiting for the first sync"),
        Some(record) if !record.plan.backfill_complete => format!(
            "history of {account}: {} (page {} of {}, {} plays stored){}",
            record.phase.word(),
            record.plan.backfill_page,
            record.total_pages.max(1),
            record.stored,
            record.last_error.as_ref().map(|error| format!(" - {error}")).unwrap_or_default()
        ),
        Some(record) => format!(
            "history of {account}: up to date, {} plays stored, last sync {}{}",
            record.stored,
            moment(record.plan.last_sync_at).as_str().unwrap_or("never"),
            record.last_error.as_ref().map(|error| format!(" - {error}")).unwrap_or_default()
        ),
    }
}

fn describe_relay(status: &UserStatus) -> String {
    let Some(relay) = &status.relay else { return "relay: not connected (run `flaccy-server lastfm connect --user <name>`)".to_owned() };
    let account = status.relay_account.as_deref().unwrap_or("?");
    match &relay.paused_reason {
        Some(reason) => format!("relay to {account}: PAUSED - {reason}"),
        None => format!(
            "relay to {account}: running, {} queued, {} submitted, {} refused{}",
            status.queued,
            relay.submitted,
            relay.rejected,
            relay.last_error.as_ref().map(|error| format!(", last error: {error}")).unwrap_or_default()
        ),
    }
}

/// The lines `lastfm status` prints for one user.
pub fn text_lines(status: &UserStatus) -> Vec<String> {
    vec![format!("{}:", status.user.name), format!("  {}", describe_history(status)), format!("  {}", describe_relay(status))]
}
