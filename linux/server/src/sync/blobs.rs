//! Content-addressed images: playlist covers.

use std::fmt;

use rusqlite::{Connection, OptionalExtension, TransactionBehavior};
use sha2::{Digest, Sha256};

use super::{Store, SyncError};
use crate::{cover, ids};

/// The largest blob the server stores.
pub const MAX_BLOB_BYTES: usize = 2 * 1024 * 1024;
/// The most bytes of blobs one user may have uploaded at a time: 50 MB.
pub const USER_BLOB_QUOTA_BYTES: i64 = 50_000_000;
/// Blobs that no playlist cover names are deleted once they are this many days old.
pub const ORPHAN_BLOB_DAYS: i64 = 7;
const MILLIS_PER_DAY: i64 = 24 * 60 * 60 * 1000;
const HASH_CHARS: usize = 64;
const ALLOWED_MIMES: [&str; 3] = ["image/jpeg", "image/png", "image/webp"];

/// A stored blob.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Blob {
    /// The image type.
    pub mime: String,
    /// The bytes.
    pub data: Vec<u8>,
}

/// What `put_blob` stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BlobStored {
    /// True when the blob was new, false when the server already had it.
    pub created: bool,
    /// The size in bytes.
    pub size: usize,
}

/// Why a blob was refused.
#[derive(Debug)]
pub enum BlobError {
    /// The hash in the path is not 64 lowercase hex characters.
    BadHash,
    /// The type is not one of the three image types.
    BadMime,
    /// The bytes are not an image of the declared type.
    NotAnImage,
    /// The bytes are larger than [`MAX_BLOB_BYTES`].
    TooLarge,
    /// The SHA-256 of the bytes is not the hash in the path.
    HashMismatch,
    /// The picture is wider, taller or has more pixels than [`cover::MAX_SIDE`] and [`cover::MAX_PIXELS`] allow.
    ImageTooBig {
        /// The width the header declares.
        width: u32,
        /// The height the header declares.
        height: u32,
    },
    /// Storing the blob would take the user past [`USER_BLOB_QUOTA_BYTES`].
    QuotaExceeded,
    /// The database failed.
    Storage(SyncError),
}

impl fmt::Display for BlobError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            BlobError::BadHash => write!(
                formatter,
                "A blob is addressed by the 64 lowercase hex characters of its SHA-256. Put the image at /blobs/<sha256 of the bytes>."
            ),
            BlobError::BadMime => write!(
                formatter,
                "Blobs are images of type image/jpeg, image/png or image/webp. Send the image with one of those Content-Type headers."
            ),
            BlobError::NotAnImage => write!(
                formatter,
                "The bytes are not an image of the declared Content-Type. Send the image file itself with its own type."
            ),
            BlobError::TooLarge => write!(
                formatter,
                "A blob is at most {} MiB. Scale the image down and send it again.",
                MAX_BLOB_BYTES / (1024 * 1024)
            ),
            BlobError::HashMismatch => write!(
                formatter,
                "The SHA-256 of the bytes is not the hash in the path. Hash exactly the bytes you send and put them at that hash."
            ),
            BlobError::ImageTooBig { width, height } => write!(
                formatter,
                "A cover is at most {} megapixels and {} pixels on a side; this one is {width} by {height}. Scale the image down and send it again.",
                cover::MAX_PIXELS / 1_000_000,
                cover::MAX_SIDE
            ),
            BlobError::QuotaExceeded => write!(
                formatter,
                "Each user may keep {} MB of cover images on the server and this one would pass that. Replace or remove a playlist cover, wait for the daily tidy to free unused images, then upload again.",
                USER_BLOB_QUOTA_BYTES / 1_000_000
            ),
            BlobError::Storage(source) => write!(formatter, "{source}"),
        }
    }
}

impl std::error::Error for BlobError {}

impl From<SyncError> for BlobError {
    fn from(source: SyncError) -> Self {
        BlobError::Storage(source)
    }
}

impl From<rusqlite::Error> for BlobError {
    fn from(source: rusqlite::Error) -> Self {
        BlobError::Storage(source.into())
    }
}

fn is_hash(text: &str) -> bool {
    text.len() == HASH_CHARS && text.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

fn looks_like(mime: &str, data: &[u8]) -> bool {
    match mime {
        "image/jpeg" => data.starts_with(&[0xFF, 0xD8, 0xFF]),
        "image/png" => data.starts_with(&[0x89, b'P', b'N', b'G']),
        "image/webp" => data.len() > 12 && &data[..4] == b"RIFF" && &data[8..12] == b"WEBP",
        _ => false,
    }
}

fn validate(hash: &str, mime: &str, data: &[u8]) -> Result<(), BlobError> {
    if !is_hash(hash) {
        return Err(BlobError::BadHash);
    }
    if !ALLOWED_MIMES.contains(&mime) {
        return Err(BlobError::BadMime);
    }
    if data.len() > MAX_BLOB_BYTES {
        return Err(BlobError::TooLarge);
    }
    if !looks_like(mime, data) {
        return Err(BlobError::NotAnImage);
    }
    let (width, height) = cover::dimensions(data).ok_or(BlobError::NotAnImage)?;
    if !cover::within_limits(width, height) {
        return Err(BlobError::ImageTooBig { width, height });
    }
    if ids::hex(&Sha256::digest(data)) != hash {
        return Err(BlobError::HashMismatch);
    }
    Ok(())
}

/// True when `user` uploaded the blob `hash` and the server still holds it.
pub(super) fn user_owns_blob(connection: &Connection, user: &str, hash: &str) -> Result<bool, SyncError> {
    Ok(connection
        .prepare_cached("SELECT 1 FROM blob_uploads u JOIN blobs b ON b.hash = u.hash WHERE u.user_id = ?1 AND u.hash = ?2")?
        .exists((user, hash))?)
}

fn bytes_uploaded_by(connection: &Connection, user: &str) -> rusqlite::Result<i64> {
    connection
        .prepare_cached("SELECT COALESCE(SUM(b.size), 0) FROM blob_uploads u JOIN blobs b ON b.hash = u.hash WHERE u.user_id = ?1")?
        .query_row([user], |row| row.get(0))
}

fn store_blob(connection: &mut Connection, owner: &str, hash: &str, mime: &str, data: &[u8], now_ms: i64) -> Result<BlobStored, BlobError> {
    let size = data.len();
    let transaction = connection.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let owned = user_owns_blob(&transaction, owner, hash)?;
    if !owned && bytes_uploaded_by(&transaction, owner)? + size as i64 > USER_BLOB_QUOTA_BYTES {
        return Err(BlobError::QuotaExceeded);
    }
    let added = transaction
        .prepare_cached("INSERT OR IGNORE INTO blobs(hash, mime, size, data) VALUES (?1, ?2, ?3, ?4)")?
        .execute((hash, mime, size as i64, data))?;
    transaction
        .prepare_cached(
            "INSERT INTO blob_uploads(user_id, hash, uploaded_at) VALUES (?1, ?2, ?3)
             ON CONFLICT(user_id, hash) DO UPDATE SET uploaded_at = excluded.uploaded_at",
        )?
        .execute((owner, hash, now_ms))?;
    transaction.commit()?;
    Ok(BlobStored { created: added == 1, size })
}

/// Deletes the blobs no playlist names as its cover whose newest upload is older than the cutoff.
pub(super) fn delete_orphan_blobs(connection: &Connection, now_ms: i64) -> Result<usize, SyncError> {
    let cutoff = now_ms - ORPHAN_BLOB_DAYS * MILLIS_PER_DAY;
    let deleted = connection.execute(
        "DELETE FROM blobs
         WHERE hash NOT IN (SELECT cover_blob FROM playlists WHERE cover_blob IS NOT NULL)
           AND COALESCE((SELECT MAX(uploaded_at) FROM blob_uploads WHERE blob_uploads.hash = blobs.hash), 0) < ?1",
        [cutoff],
    )?;
    connection.execute("DELETE FROM blob_uploads WHERE hash NOT IN (SELECT hash FROM blobs)", [])?;
    Ok(deleted)
}

impl Store {
    /// Stores an image uploaded by `owner` under its SHA-256 after checking the hash, the type, the 2 MiB limit,
    /// the picture's declared size and the owner's quota of [`USER_BLOB_QUOTA_BYTES`].
    pub async fn put_blob(&self, owner: &str, hash: &str, mime: &str, data: Vec<u8>) -> Result<BlobStored, BlobError> {
        validate(hash, mime, &data)?;
        let owner = owner.to_owned();
        let hash = hash.to_owned();
        let mime = mime.to_owned();
        let now_ms = self.now_ms();
        self.write(move |connection| store_blob(connection, &owner, &hash, &mime, &data, now_ms)).await
    }

    /// The blob stored under `hash`, `None` when there is none.
    pub async fn get_blob(&self, hash: &str) -> Result<Option<Blob>, SyncError> {
        if !is_hash(hash) {
            return Ok(None);
        }
        let hash = hash.to_owned();
        self.read(move |connection| {
            Ok(connection
                .prepare_cached("SELECT mime, data FROM blobs WHERE hash = ?1")?
                .query_row([&hash], |row| Ok(Blob { mime: row.get(0)?, data: row.get(1)? }))
                .optional()?)
        })
        .await
    }
}
