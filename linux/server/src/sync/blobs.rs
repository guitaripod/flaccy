//! Content-addressed images: playlist covers.

use std::fmt;

use rusqlite::OptionalExtension;
use sha2::{Digest, Sha256};

use super::{Store, SyncError};
use crate::ids;

/// The largest blob the server stores.
pub const MAX_BLOB_BYTES: usize = 2 * 1024 * 1024;
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
    if ids::hex(&Sha256::digest(data)) != hash {
        return Err(BlobError::HashMismatch);
    }
    Ok(())
}

impl Store {
    /// Stores an image under its SHA-256 after checking the hash, the type and the 2 MiB limit.
    pub async fn put_blob(&self, hash: &str, mime: &str, data: Vec<u8>) -> Result<BlobStored, BlobError> {
        validate(hash, mime, &data)?;
        let hash = hash.to_owned();
        let mime = mime.to_owned();
        let size = data.len();
        self.write(move |connection| {
            let added = connection
                .prepare_cached("INSERT OR IGNORE INTO blobs(hash, mime, size, data) VALUES (?1, ?2, ?3, ?4)")?
                .execute((&hash, &mime, size as i64, data.as_slice()))?;
            Ok::<_, BlobError>(BlobStored { created: added == 1, size })
        })
        .await
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
