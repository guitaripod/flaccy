//! Song identity and the ids clients and the server derive for listens.

use sha2::{Digest, Sha256};

const SONG_KEY_BYTES: usize = 16;
const EVENT_ID_BYTES: usize = 12;

fn truncated_digest(parts: &[&[u8]], bytes: usize) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part);
    }
    hex::encode(&hasher.finalize()[..bytes])
}

fn is_lower_hex(text: &str, length: usize) -> bool {
    text.len() == length && text.bytes().all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// The 32 hex character song key: the first 16 bytes of `SHA-256("fsk1" || artistKey || 0x00 || titleKey)`.
pub fn song_key(artist_key: &str, title_key: &str) -> String {
    truncated_digest(
        &[b"fsk1", artist_key.as_bytes(), &[0], title_key.as_bytes()],
        SONG_KEY_BYTES,
    )
}

/// True for a well formed song key.
pub fn is_song_key(text: &str) -> bool {
    is_lower_hex(text, SONG_KEY_BYTES * 2)
}

/// True for a well formed listen event id.
pub fn is_event_id(text: &str) -> bool {
    is_lower_hex(text, EVENT_ID_BYTES * 2)
}

/// A client's listen id: `SHA-256("rec" || deviceId || instance || counter)`, counter in decimal ASCII.
pub fn event_id_rec(device_id: &str, instance: &str, counter: u64) -> String {
    truncated_digest(
        &[
            b"rec",
            device_id.as_bytes(),
            instance.as_bytes(),
            counter.to_string().as_bytes(),
        ],
        EVENT_ID_BYTES,
    )
}

/// The server's id for a Last.fm scrobble: `SHA-256("lfm" || account || ts || songKey)`, ts in decimal ASCII.
pub fn event_id_lfm(account: &str, ts: i64, song_key: &str) -> String {
    truncated_digest(
        &[
            b"lfm",
            account.as_bytes(),
            ts.to_string().as_bytes(),
            song_key.as_bytes(),
        ],
        EVENT_ID_BYTES,
    )
}

/// The id of a migrated listen: `SHA-256("mig" || ts || titleKey || artistKey)`, ts in decimal ASCII.
pub fn event_id_mig(ts: i64, title_key: &str, artist_key: &str) -> String {
    truncated_digest(
        &[
            b"mig",
            ts.to_string().as_bytes(),
            title_key.as_bytes(),
            artist_key.as_bytes(),
        ],
        EVENT_ID_BYTES,
    )
}
