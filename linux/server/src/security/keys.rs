//! Secrets and API keys.
//!
//! Every secret comes from the operating system's random source and only its
//! SHA-256 is kept. OpenSubsonic API keys hash exactly like the keys in
//! `credentials.toml`, so those import unchanged.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use rand::rngs::OsRng;
use rand::TryRngCore;
use rusqlite::{OptionalExtension, Row};
use sha2::{Digest, Sha256};

use super::users::first_admin;
use super::{clean_name, KeyId, Principal, Role, SecurityError, Store, UserId};
use crate::credentials::{constant_time_eq, Credentials};
use crate::ids;

const CROCKFORD: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
/// Characters in an enrollment code: 128 bits in groups of 5.
pub const ENROLLMENT_CODE_CHARS: usize = 26;
const SHA256_BYTES: usize = 32;

/// Fills an array from the operating system's random source.
pub fn random_bytes<const N: usize>() -> Result<[u8; N], SecurityError> {
    let mut bytes = [0u8; N];
    OsRng
        .try_fill_bytes(&mut bytes)
        .map_err(|error| SecurityError::Randomness(error.to_string()))?;
    Ok(bytes)
}

/// A random version 4 uuid in the usual 8-4-4-4-12 form.
pub fn random_uuid() -> Result<String, SecurityError> {
    let mut bytes = random_bytes::<16>()?;
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = ids::hex(&bytes);
    Ok(format!("{}-{}-{}-{}-{}", &hex[..8], &hex[8..12], &hex[12..16], &hex[16..20], &hex[20..]))
}

/// A new enrollment code: 128 random bits as 26 Crockford base32 characters.
pub fn new_enrollment_code() -> Result<String, SecurityError> {
    Ok(encode_crockford(&random_bytes::<16>()?))
}

/// A new device token: 256 random bits as 43 base64url characters.
pub fn new_device_token() -> Result<String, SecurityError> {
    Ok(URL_SAFE_NO_PAD.encode(random_bytes::<32>()?))
}

/// A new API key: 256 random bits as 64 hex characters, the shape `credentials.toml` keys have.
pub fn new_api_key() -> Result<String, SecurityError> {
    Ok(ids::hex(&random_bytes::<32>()?))
}

/// The SHA-256 of a secret's text, which is all the database keeps of it.
pub fn hash_secret(secret: &str) -> [u8; SHA256_BYTES] {
    Sha256::digest(secret.as_bytes()).into()
}

/// Crockford base32 of `bytes` without padding.
pub fn encode_crockford(bytes: &[u8]) -> String {
    let mut text = String::with_capacity((bytes.len() * 8).div_ceil(5));
    let mut buffer = 0u32;
    let mut bits = 0u32;
    for byte in bytes {
        buffer = (buffer << 8) | u32::from(*byte);
        bits += 8;
        while bits >= 5 {
            bits -= 5;
            text.push(char::from(CROCKFORD[((buffer >> bits) & 0x1f) as usize]));
        }
    }
    if bits > 0 {
        text.push(char::from(CROCKFORD[((buffer << (5 - bits)) & 0x1f) as usize]));
    }
    text
}

/// The canonical form of a typed enrollment code: upper case, no spaces or dashes,
/// `O` read as 0 and `I` or `L` as 1. `None` when it cannot be a code.
pub fn normalize_enrollment_code(typed: &str) -> Option<String> {
    let canonical: String = typed
        .chars()
        .filter(|character| !character.is_whitespace() && *character != '-')
        .map(|character| match character.to_ascii_uppercase() {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .collect();
    let valid = canonical.chars().count() == ENROLLMENT_CODE_CHARS
        && canonical.bytes().all(|byte| CROCKFORD.contains(&byte));
    valid.then_some(canonical)
}

/// A stored hash that matches `expected`, compared without an early exit.
pub(crate) fn hashes_match(stored: &[u8], expected: &[u8; SHA256_BYTES]) -> bool {
    constant_time_eq(stored, expected)
}

/// One API key as listed: never the key itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ApiKey {
    /// The key's id.
    pub id: KeyId,
    /// The user the key acts as.
    pub user_id: UserId,
    /// The label its owner gave it.
    pub name: String,
    /// When it was made, in Unix milliseconds.
    pub created_at: i64,
    /// When it was revoked, `None` while it works.
    pub revoked_at: Option<i64>,
}

/// What [`Store::import_legacy`] did with the keys of `credentials.toml`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct LegacyImport {
    /// Keys added to the owner's API keys.
    pub imported: usize,
    /// Keys that were already there, revoked or not.
    pub already_present: usize,
    /// Keys whose stored hash is not a SHA-256 in hex.
    pub invalid: usize,
}

fn api_key_from_row(row: &Row<'_>) -> rusqlite::Result<ApiKey> {
    Ok(ApiKey {
        id: row.get(0)?,
        user_id: row.get(1)?,
        name: row.get(2)?,
        created_at: row.get(3)?,
        revoked_at: row.get(4)?,
    })
}

impl Store {
    /// Makes an API key called `name` for `user_id`; the key is returned once and only its hash is kept.
    pub async fn create_api_key(&self, user_id: &UserId, name: &str) -> Result<(KeyId, String), SecurityError> {
        let user_id = user_id.clone();
        let name = clean_name(name)?;
        let key = new_api_key()?;
        let hash = hash_secret(&key);
        let id = KeyId(random_uuid()?);
        let stored = id.clone();
        self.write(move |transaction, stamp| {
            super::users::require_user(transaction, &user_id)?;
            let taken = transaction
                .query_row(
                    "SELECT 1 FROM api_keys WHERE user_id = ?1 AND name = ?2 AND revoked_at IS NULL",
                    (&user_id, &name),
                    |_| Ok(()),
                )
                .optional()?
                .is_some();
            if taken {
                return Err(SecurityError::NameTaken(name));
            }
            transaction.execute(
                "INSERT INTO api_keys(id, user_id, name, key_hash, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                (&stored, &user_id, &name, hash.as_slice(), stamp.at),
            )?;
            stamp.record(transaction, "key.create", &format!("key={stored} user={user_id} name={name}"))?;
            Ok(())
        })
        .await?;
        Ok((id, key))
    }

    /// The API keys of `user`, or of everyone when `user` is `None`, oldest first, revoked ones included.
    pub async fn list_api_keys(&self, user: Option<&UserId>) -> Result<Vec<ApiKey>, SecurityError> {
        let user = user.cloned();
        self.read(move |connection| {
            let mut statement = connection.prepare(
                "SELECT id, user_id, name, created_at, revoked_at FROM api_keys
                 WHERE ?1 IS NULL OR user_id = ?1 ORDER BY created_at, rowid",
            )?;
            let rows = statement.query_map([&user], api_key_from_row)?.collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
        .await
    }

    /// Revokes the key `id`; whether it was working until now. Takes effect on the next request.
    pub async fn revoke_api_key(&self, id: &KeyId) -> Result<bool, SecurityError> {
        let id = id.clone();
        self.write(move |transaction, stamp| {
            let changed = transaction.execute(
                "UPDATE api_keys SET revoked_at = ?1 WHERE id = ?2 AND revoked_at IS NULL",
                (stamp.at, &id),
            )?;
            if changed == 1 {
                stamp.record(transaction, "key.revoke", &format!("key={id}"))?;
                return Ok(true);
            }
            let exists = transaction.query_row("SELECT 1 FROM api_keys WHERE id = ?1", [&id], |_| Ok(())).optional()?.is_some();
            if exists {
                Ok(false)
            } else {
                Err(SecurityError::UnknownKey(id))
            }
        })
        .await
    }

    /// Who the API key `key` acts as, `None` for an unknown or revoked key.
    pub async fn authenticate_api_key(&self, key: &str) -> Result<Option<Principal>, SecurityError> {
        let hash = hash_secret(key);
        self.read(move |connection| {
            let found = connection
                .query_row(
                    "SELECT u.id, u.role, k.key_hash FROM api_keys k JOIN users u ON u.id = k.user_id
                     WHERE k.key_hash = ?1 AND k.revoked_at IS NULL",
                    [hash.as_slice()],
                    |row| Ok((row.get::<_, UserId>(0)?, row.get::<_, Role>(1)?, row.get::<_, Vec<u8>>(2)?)),
                )
                .optional()?;
            Ok(found.filter(|(_, _, stored)| hashes_match(stored, &hash)).map(|(user, role, _)| Principal {
                user,
                role,
                device: None,
            }))
        })
        .await
    }

    /// Adds the API keys of `credentials` to the first admin's keys, keeping their names and hashes.
    /// Running it again adds nothing; a key revoked here stays revoked. The account and password are ignored.
    pub async fn import_legacy(&self, credentials: &Credentials) -> Result<LegacyImport, SecurityError> {
        let records = credentials.keys.clone();
        let ids: Vec<String> = records.iter().map(|_| random_uuid()).collect::<Result<_, _>>()?;
        self.write(move |transaction, stamp| {
            let owner = first_admin(transaction)?.ok_or(SecurityError::NoOwner)?;
            let mut summary = LegacyImport::default();
            for (record, id) in records.iter().zip(ids) {
                let hash = ids::unhex(&record.sha256).filter(|bytes| bytes.len() == SHA256_BYTES);
                let (Some(hash), Ok(name)) = (hash, clean_name(&record.name)) else {
                    summary.invalid += 1;
                    continue;
                };
                let created_at = chrono::DateTime::parse_from_rfc3339(&record.created)
                    .map(|moment| moment.timestamp_millis())
                    .unwrap_or(stamp.at);
                let added = transaction.execute(
                    "INSERT OR IGNORE INTO api_keys(id, user_id, name, key_hash, created_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                    (&id, &owner, &name, hash.as_slice(), created_at),
                )?;
                if added == 1 {
                    summary.imported += 1;
                    stamp.record(transaction, "key.import", &format!("key={id} user={owner} name={name}"))?;
                } else {
                    summary.already_present += 1;
                }
            }
            Ok(summary)
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crockford_encoding_matches_known_values() {
        assert_eq!(encode_crockford(&[0u8; 16]), "0".repeat(26));
        assert_eq!(encode_crockford(&[0xff; 16]), format!("{}W", "Z".repeat(25)));
        assert_eq!(encode_crockford(b"f"), "CR");
        assert_eq!(encode_crockford(b"foobar"), "CSQPYRK1E8");
    }

    #[test]
    fn codes_are_26_characters_and_secrets_are_unique() {
        let first = new_enrollment_code().unwrap();
        assert_eq!(first.len(), ENROLLMENT_CODE_CHARS);
        assert_eq!(normalize_enrollment_code(&first).as_deref(), Some(first.as_str()));
        assert_ne!(first, new_enrollment_code().unwrap());
        let token = new_device_token().unwrap();
        assert_eq!(token.len(), 43);
        assert!(token.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'));
        assert_eq!(new_api_key().unwrap().len(), 64);
    }

    #[test]
    fn typed_codes_are_forgiven_the_usual_slips() {
        let code = "0123456789ABCDEFGHJKMNPQRS";
        let typed = "oi23-4567 89ab cdef-ghjk-mnpq-rs";
        assert_eq!(normalize_enrollment_code(typed).as_deref(), Some("0123456789ABCDEFGHJKMNPQRS"));
        assert!(normalize_enrollment_code(&code[..25]).is_none());
        assert!(normalize_enrollment_code("U123456789ABCDEFGHJKMNPQRS").is_none());
    }

    #[test]
    fn uuids_have_version_and_variant_bits() {
        let uuid = random_uuid().unwrap();
        assert_eq!(uuid.len(), 36);
        assert_eq!(&uuid[14..15], "4");
        assert!(matches!(&uuid[19..20], "8" | "9" | "a" | "b"));
    }
}
