//! Each user's Last.fm session. The key is kept in the clear because the
//! scrobbler must send it; the file is mode 0600 and the key never reaches a log.

use std::fmt;

use rusqlite::OptionalExtension;

use super::users::require_user;
use super::{SecurityError, Store, UserId};

/// A user's linked Last.fm account.
#[derive(Clone, PartialEq, Eq)]
pub struct LastfmSession {
    /// The Flaccy user it belongs to.
    pub user_id: UserId,
    /// The Last.fm account name.
    pub username: String,
    /// The Last.fm session key.
    pub session_key: String,
}

impl fmt::Debug for LastfmSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("LastfmSession")
            .field("user_id", &self.user_id)
            .field("username", &self.username)
            .field("session_key", &"<hidden>")
            .finish()
    }
}

impl Store {
    /// Links `user_id` to a Last.fm account, replacing any earlier link.
    pub async fn set_lastfm_session(&self, user_id: &UserId, username: &str, session_key: &str) -> Result<(), SecurityError> {
        let session = LastfmSession {
            user_id: user_id.clone(),
            username: username.trim().to_string(),
            session_key: session_key.to_string(),
        };
        self.write(move |transaction, stamp| {
            require_user(transaction, &session.user_id)?;
            transaction.execute(
                "INSERT INTO lastfm_sessions(user_id, username, session_key) VALUES (?1, ?2, ?3)
                 ON CONFLICT(user_id) DO UPDATE SET username = excluded.username, session_key = excluded.session_key",
                (&session.user_id, &session.username, &session.session_key),
            )?;
            stamp.record(transaction, "lastfm.link", &format!("user={} lastfm={}", session.user_id, session.username))?;
            Ok(())
        })
        .await
    }

    /// The Last.fm link of `user_id`, `None` when there is none.
    pub async fn lastfm_session(&self, user_id: &UserId) -> Result<Option<LastfmSession>, SecurityError> {
        let user_id = user_id.clone();
        self.read(move |connection| {
            Ok(connection
                .query_row(
                    "SELECT username, session_key FROM lastfm_sessions WHERE user_id = ?1",
                    [&user_id],
                    |row| {
                        Ok(LastfmSession {
                            user_id: user_id.clone(),
                            username: row.get(0)?,
                            session_key: row.get(1)?,
                        })
                    },
                )
                .optional()?)
        })
        .await
    }

    /// Removes the Last.fm link of `user_id`; whether there was one.
    pub async fn delete_lastfm_session(&self, user_id: &UserId) -> Result<bool, SecurityError> {
        let user_id = user_id.clone();
        self.write(move |transaction, stamp| {
            let removed = transaction.execute("DELETE FROM lastfm_sessions WHERE user_id = ?1", [&user_id])?;
            if removed == 1 {
                stamp.record(transaction, "lastfm.unlink", &format!("user={user_id}"))?;
            }
            Ok(removed == 1)
        })
        .await
    }
}
