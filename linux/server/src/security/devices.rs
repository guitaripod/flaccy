//! Enrolled devices and the tokens they authenticate with.

use std::time::Duration;

use rusqlite::{OptionalExtension, Row, Transaction};

use super::keys::{hash_secret, hashes_match, new_device_token, random_uuid};
use super::users::require_user;
use super::{clean_name, DeviceId, Role, SecurityError, Stamp, Store, UserId};

/// Platforms a device may report; anything else is stored as `other`.
pub const PLATFORMS: [&str; 5] = ["ios", "macos", "linux", "windows", "other"];
/// A device's last-seen time is written at most this often.
pub const LAST_SEEN_INTERVAL: Duration = Duration::from_secs(60);

/// Who a token or API key belongs to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Principal {
    /// The user the request acts as.
    pub user: UserId,
    /// What that user may do.
    pub role: Role,
    /// The device, `None` for an API key.
    pub device: Option<DeviceId>,
}

/// One device as listed: never its token.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Device {
    /// The device's id.
    pub id: DeviceId,
    /// The user that enrolled it.
    pub user_id: UserId,
    /// The name its owner gave it.
    pub name: String,
    /// One of [`PLATFORMS`].
    pub platform: String,
    /// When it enrolled, in Unix milliseconds.
    pub created_at: i64,
    /// The last request it made, rounded to a minute, `None` before its first.
    pub last_seen_at: Option<i64>,
    /// When it was revoked, `None` while it works.
    pub revoked_at: Option<i64>,
}

fn device_from_row(row: &Row<'_>) -> rusqlite::Result<Device> {
    Ok(Device {
        id: row.get(0)?,
        user_id: row.get(1)?,
        name: row.get(2)?,
        platform: row.get(3)?,
        created_at: row.get(4)?,
        last_seen_at: row.get(5)?,
        revoked_at: row.get(6)?,
    })
}

fn known_platform(platform: &str) -> &'static str {
    let lowered = platform.trim().to_ascii_lowercase();
    PLATFORMS.iter().copied().find(|known| *known == lowered).unwrap_or("other")
}

/// A device ready to be written: its id, its token and the hash that is kept of it.
pub(super) struct NewDevice {
    pub(super) id: DeviceId,
    pub(super) token: String,
    name: String,
    platform: &'static str,
    token_hash: Vec<u8>,
}

impl NewDevice {
    pub(super) fn prepare(name: &str, platform: &str) -> Result<Self, SecurityError> {
        let token = new_device_token()?;
        Ok(Self {
            id: DeviceId(random_uuid()?),
            name: clean_name(name)?,
            platform: known_platform(platform),
            token_hash: hash_secret(&token).to_vec(),
            token,
        })
    }

    pub(super) fn insert(&self, transaction: &Transaction<'_>, stamp: &Stamp, user_id: &UserId) -> Result<(), SecurityError> {
        require_user(transaction, user_id)?;
        transaction.execute(
            "INSERT INTO devices(id, user_id, name, platform, token_hash, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            (&self.id, user_id, &self.name, self.platform, self.token_hash.as_slice(), stamp.at),
        )?;
        stamp.record(transaction, "device.create", &format!("device={} user={user_id} platform={}", self.id, self.platform))?;
        Ok(())
    }
}

impl Store {
    /// Enrolls a device for `user_id`. The token is returned once and only its hash is kept.
    pub async fn create_device(
        &self,
        user_id: &UserId,
        name: &str,
        platform: &str,
    ) -> Result<(DeviceId, String), SecurityError> {
        let user_id = user_id.clone();
        let new_device = NewDevice::prepare(name, platform)?;
        let (id, token) = (new_device.id.clone(), new_device.token.clone());
        self.write(move |transaction, stamp| new_device.insert(transaction, stamp, &user_id)).await?;
        Ok((id, token))
    }

    /// Who the device token `token` belongs to, `None` for an unknown or revoked token.
    pub async fn authenticate(&self, token: &str) -> Result<Option<Principal>, SecurityError> {
        let hash = hash_secret(token);
        self.read(move |connection| {
            let found = connection
                .query_row(
                    "SELECT d.id, u.id, u.role, d.token_hash FROM devices d JOIN users u ON u.id = d.user_id
                     WHERE d.token_hash = ?1 AND d.revoked_at IS NULL",
                    [hash.as_slice()],
                    |row| {
                        Ok((
                            row.get::<_, DeviceId>(0)?,
                            row.get::<_, UserId>(1)?,
                            row.get::<_, Role>(2)?,
                            row.get::<_, Vec<u8>>(3)?,
                        ))
                    },
                )
                .optional()?;
            Ok(found
                .filter(|(_, _, _, stored)| hashes_match(stored, &hash))
                .map(|(device, user, role, _)| Principal {
                    user,
                    role,
                    device: Some(device),
                }))
        })
        .await
    }

    /// Records that `device` made a request. Writes at most once a minute per device; whether it wrote.
    pub async fn touch_last_seen(&self, device: &DeviceId) -> Result<bool, SecurityError> {
        let now = self.now();
        let interval = LAST_SEEN_INTERVAL.as_millis() as i64;
        {
            let seen = self.memory.last_seen.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if seen.get(device).is_some_and(|last| now - last < interval) {
                return Ok(false);
            }
        }
        let id = device.clone();
        let changed = self
            .db
            .call(move |connection| connection.execute("UPDATE devices SET last_seen_at = ?1 WHERE id = ?2", (now, &id)))
            .await?;
        if changed == 1 {
            self.memory
                .last_seen
                .lock()
                .unwrap_or_else(|poisoned| poisoned.into_inner())
                .insert(device.clone(), now);
        }
        Ok(changed == 1)
    }

    /// The devices of `user`, or of everyone when `user` is `None`, oldest first, revoked ones included.
    pub async fn list_devices(&self, user: Option<&UserId>) -> Result<Vec<Device>, SecurityError> {
        let user = user.cloned();
        self.read(move |connection| {
            let mut statement = connection.prepare(
                "SELECT id, user_id, name, platform, created_at, last_seen_at, revoked_at FROM devices
                 WHERE ?1 IS NULL OR user_id = ?1 ORDER BY created_at, rowid",
            )?;
            let devices = statement.query_map([&user], device_from_row)?.collect::<Result<Vec<_>, _>>()?;
            Ok(devices)
        })
        .await
    }

    /// Renames `device`.
    pub async fn rename_device(&self, device: &DeviceId, name: &str) -> Result<(), SecurityError> {
        let device = device.clone();
        let name = clean_name(name)?;
        self.write(move |transaction, stamp| {
            let changed = transaction.execute("UPDATE devices SET name = ?1 WHERE id = ?2", (&name, &device))?;
            if changed == 0 {
                return Err(SecurityError::UnknownDevice(device));
            }
            stamp.record(transaction, "device.rename", &format!("device={device} name={name}"))?;
            Ok(())
        })
        .await
    }

    /// Revokes `device`; whether it was working until now. Its token stops authenticating at once.
    pub async fn revoke_device(&self, device: &DeviceId) -> Result<bool, SecurityError> {
        let device = device.clone();
        self.write(move |transaction, stamp| {
            let changed = transaction.execute(
                "UPDATE devices SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL",
                (stamp.at, &device),
            )?;
            if changed == 1 {
                stamp.record(transaction, "device.revoke", &format!("device={device}"))?;
                return Ok(true);
            }
            let exists = transaction
                .query_row("SELECT 1 FROM devices WHERE id = ?1", [&device], |_| Ok(()))
                .optional()?
                .is_some();
            if exists {
                Ok(false)
            } else {
                Err(SecurityError::UnknownDevice(device))
            }
        })
        .await
    }
}
