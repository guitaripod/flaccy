//! `flaccy-server lastfm ...`: connect the server's own Last.fm session, disconnect it, set the account whose history is
//! brought in, and show how both stand.
//!
//! The commands open the databases directly, so they work whether or not `serve` is running; a running server notices
//! the change on its next pass.

use std::io::BufRead;
use std::sync::Arc;

use clap::Subcommand;

use super::api::LastfmApi;
use super::history_store::ACCOUNT_KEY;
use super::status;
use crate::admin::say;
use crate::config::Config;
use crate::security::{self, User};
use crate::sync;

/// `flaccy-server lastfm ...`
#[derive(Subcommand, Debug)]
pub enum LastfmAction {
    /// Link the server's own Last.fm session for a user, so plays from other OpenSubsonic apps are scrobbled.
    Connect {
        /// The Flaccy user the session belongs to.
        #[arg(long)]
        user: String,
    },
    /// Remove the server's Last.fm session for a user and forget the unsent queue.
    Disconnect {
        /// The Flaccy user.
        #[arg(long)]
        user: String,
    },
    /// Show the history sync and the relay.
    Status {
        /// Only this user.
        #[arg(long)]
        user: Option<String>,
        /// Print one JSON document instead of text.
        #[arg(long)]
        json: bool,
    },
    /// Set the Last.fm account whose listening history the server brings in for a user.
    Account {
        /// The Flaccy user.
        #[arg(long)]
        user: String,
        /// The Last.fm account name.
        name: String,
    },
}

/// The two databases the commands work on.
pub struct Desk {
    /// Users, devices and the Last.fm sessions.
    pub security: security::Store,
    /// Listens, the history plan and the relay queue.
    pub sync: sync::Store,
}

impl Desk {
    /// Opens `security.sqlite` and `state.sqlite` of `config`.
    pub async fn open(config: &Config) -> Result<Self, String> {
        let security = security::Store::open(&config.security_path()).await.map_err(|error| error.to_string())?;
        let incarnation = security.incarnation().await.map_err(|error| error.to_string())?;
        let sync = sync::Store::open(&config.state_path(), incarnation).await.map_err(|error| error.to_string())?;
        Ok(Self { security, sync })
    }

    async fn user(&self, name: &str) -> Result<User, String> {
        self.security
            .find_user_by_name(name)
            .await
            .map_err(|error| error.to_string())?
            .ok_or_else(|| format!("There is no user called '{name}'. List the users with `flaccy-server user list`."))
    }

    fn now(&self) -> i64 {
        self.sync.now_ms() / 1000
    }

    /// The token flow the clients use: asks for a token, shows the page to approve it on, waits for Enter on `input`,
    /// trades the token for a session, stores it and starts the relay.
    pub async fn connect(&self, api: &Arc<LastfmApi>, user: &str, input: &mut dyn BufRead, out: &mut dyn FnMut(&str)) -> Result<(), String> {
        let user = self.user(user).await?;
        let token = blocking(api, |api| api.get_token()).await?;
        out(&format!("Open this page, sign in to Last.fm if asked and allow Flaccy:\n\n  {}\n", api.authorisation_url(&token)));
        out("Press Enter here once you have allowed it.");
        let mut line = String::new();
        input.read_line(&mut line).map_err(|error| format!("Could not read from the terminal: {error}. Run the command again in a terminal."))?;
        let grant = blocking(api, move |api| api.get_session(&token)).await?;
        self.security.set_lastfm_session(&user.id, &grant.name, &grant.key).await.map_err(|error| error.to_string())?;
        self.sync.lastfm_start_relay(&user.id, self.now()).await.map_err(|error| error.to_string())?;
        out(&format!("Connected {} to Last.fm account {}. Plays from other OpenSubsonic apps recorded from now on are scrobbled by the server.", user.name, grant.name));
        Ok(())
    }

    /// Removes the session and the unsent queue of `user`.
    pub async fn disconnect(&self, user: &str, out: &mut dyn FnMut(&str)) -> Result<(), String> {
        let user = self.user(user).await?;
        let removed = self.security.delete_lastfm_session(&user.id).await.map_err(|error| error.to_string())?;
        let stopped = self.sync.lastfm_stop_relay(&user.id).await.map_err(|error| error.to_string())?;
        out(&if removed || stopped {
            format!("Disconnected {} from Last.fm. Plays not yet sent were dropped.", user.name)
        } else {
            format!("{} was not connected to Last.fm.", user.name)
        });
        Ok(())
    }

    /// Sets the account whose history is brought in for `user`.
    pub async fn set_account(&self, user: &str, account: &str, out: &mut dyn FnMut(&str)) -> Result<(), String> {
        let account = account.trim();
        if account.is_empty() {
            return Err("The Last.fm account name is empty. Pass the name as shown on your Last.fm profile.".to_owned());
        }
        let user = self.user(user).await?;
        self.sync.set_scalar_as_server(&user.id, ACCOUNT_KEY, serde_json::json!(account)).await.map_err(|error| error.to_string())?;
        out(&format!("The server will bring in the Last.fm history of {account} for {}.", user.name));
        Ok(())
    }

    /// Prints the status of `user`, or of everyone, as text or JSON.
    pub async fn status(&self, user: Option<&str>, as_json: bool, key_configured: bool, out: &mut dyn FnMut(&str)) -> Result<(), String> {
        let mut statuses = status::gather(&self.sync, &self.security).await?;
        if let Some(name) = user {
            statuses.retain(|status| status.user.name.eq_ignore_ascii_case(name));
        }
        if as_json {
            out(&serde_json::to_string_pretty(&status::report(&statuses, key_configured)).map_err(|error| error.to_string())?);
            return Ok(());
        }
        if statuses.is_empty() {
            out("No Last.fm account or connection is set. Use `flaccy-server lastfm account --user <name> <lastfm name>` and `flaccy-server lastfm connect --user <name>`.");
        }
        for line in statuses.iter().flat_map(status::text_lines) {
            out(&line);
        }
        for problem in status::problems(&statuses, key_configured) {
            out(&format!("PROBLEM: {problem}"));
        }
        Ok(())
    }
}

async fn blocking<T: Send + 'static>(api: &Arc<LastfmApi>, call: impl FnOnce(&LastfmApi) -> Result<T, super::error::ApiError> + Send + 'static) -> Result<T, String> {
    let api = api.clone();
    tokio::task::spawn_blocking(move || call(&api))
        .await
        .map_err(|_| "The request thread stopped unexpectedly. Run the command again.".to_owned())?
        .map_err(|error| error.to_string())
}

/// The Last.fm client for `config`, or the sentence saying how to get a key.
pub async fn client_for(config: &Config, security: &security::Store) -> Result<Arc<LastfmApi>, String> {
    let key = config.lastfm.api_key().ok_or_else(|| {
        "There is no Last.fm API key. Set `lastfm_api_key = \"...\"` in config.toml, or FLACCY_LASTFM_KEY in the environment, and run the command again.".to_owned()
    })?;
    let device = security.server_id().await.map_err(|error| error.to_string())?;
    Ok(Arc::new(LastfmApi::new(config.lastfm.endpoints(), key, device)))
}

/// Runs a `lastfm` subcommand, printing through the admin commands' line writer.
pub async fn run(config: &Config, action: LastfmAction) -> Result<(), String> {
    let desk = Desk::open(config).await?;
    let mut out = |text: &str| say(text);
    match action {
        LastfmAction::Connect { user } => {
            let api = client_for(config, &desk.security).await?;
            desk.connect(&api, &user, &mut std::io::stdin().lock(), &mut out).await
        }
        LastfmAction::Disconnect { user } => desk.disconnect(&user, &mut out).await,
        LastfmAction::Account { user, name } => desk.set_account(&user, &name, &mut out).await,
        LastfmAction::Status { user, json } => desk.status(user.as_deref(), json, config.lastfm.api_key().is_some(), &mut out).await,
    }
}
