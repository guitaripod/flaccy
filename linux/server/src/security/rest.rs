//! The identities the OpenSubsonic API resolves a login to: the owner of an API
//! key, and the synthesized device each key or password login writes as.

use rusqlite::OptionalExtension;

use super::keys::{hash_secret, hashes_match, new_device_token};
use super::users::first_admin;
use super::{KeyId, Role, SecurityError, Store, User, UserId};

/// The working API key a request presented, and who owns it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct KeyHolder {
    /// The key's id.
    pub key: KeyId,
    /// The label its owner gave it.
    pub name: String,
    /// The owner's id.
    pub user: UserId,
    /// The owner's display name.
    pub user_name: String,
    /// What the owner may do.
    pub role: Role,
}

impl Store {
    /// The owner of the API key `key`, `None` for an unknown or revoked key.
    pub async fn find_api_key(&self, key: &str) -> Result<Option<KeyHolder>, SecurityError> {
        let hash = hash_secret(key);
        self.read(move |connection| {
            let found = connection
                .query_row(
                    "SELECT k.id, k.name, u.id, u.name, u.role, k.key_hash FROM api_keys k JOIN users u ON u.id = k.user_id
                     WHERE k.key_hash = ?1 AND k.revoked_at IS NULL",
                    [hash.as_slice()],
                    |row| {
                        Ok((
                            KeyHolder {
                                key: row.get(0)?,
                                name: row.get(1)?,
                                user: row.get(2)?,
                                user_name: row.get(3)?,
                                role: row.get(4)?,
                            },
                            row.get::<_, Vec<u8>>(5)?,
                        ))
                    },
                )
                .optional()?;
            Ok(found.filter(|(_, stored)| hashes_match(stored, &hash)).map(|(holder, _)| holder))
        })
        .await
    }

    /// Whether the key `key` was copied from `credentials.toml`, as the audit trail records it.
    pub async fn was_imported(&self, key: &KeyId) -> Result<bool, SecurityError> {
        let detail = format!("key={key} %");
        self.read(move |connection| {
            Ok(connection
                .query_row(
                    "SELECT 1 FROM audit WHERE action = 'key.import' AND detail LIKE ?1 LIMIT 1",
                    [&detail],
                    |_| Ok(()),
                )
                .optional()?
                .is_some())
        })
        .await
    }

    /// The first admin, the owner of the legacy account, `None` before any user exists.
    pub async fn owner(&self) -> Result<Option<User>, SecurityError> {
        let id = self.read(first_admin).await?;
        match id {
            Some(id) => self.get_user(&id).await,
            None => Ok(None),
        }
    }

    /// Makes sure a device called `name` exists under `id` for `user`, as the writer of an API key or password login.
    ///
    /// Its token is random and thrown away, so nothing can authenticate as the device. Running it again changes nothing.
    pub async fn ensure_rest_device(&self, id: &str, user: &UserId, name: &str) -> Result<(), SecurityError> {
        let token_hash = hash_secret(&new_device_token()?);
        let id = id.to_owned();
        let user = user.clone();
        let name = super::clean_name(name)?;
        self.write(move |transaction, stamp| {
            let added = transaction.execute(
                "INSERT OR IGNORE INTO devices(id, user_id, name, platform, token_hash, created_at) VALUES (?1, ?2, ?3, 'other', ?4, ?5)",
                (&id, &user, &name, token_hash.as_slice(), stamp.at),
            )?;
            if added == 1 {
                stamp.record(transaction, "device.create", &format!("device={id} user={user} platform=other"))?;
            }
            Ok(())
        })
        .await
    }
}
