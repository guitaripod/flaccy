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

/// A playlist name as the first-connect merge compares it: whitespace runs collapsed to one space, trimmed, lower-cased.
pub fn normalize_playlist_name(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

fn uuid_from_digest(parts: &[&[u8]]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part);
    }
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&hasher.finalize()[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32]
    )
}

/// The id every device derives for a playlist that existed before sync: a UUID shaped from `SHA-256("pl0" || 0x00 || normalizedName || 0x00 || occurrence)`, occurrence in decimal ASCII (0 for the first playlist of that name on the device, by creation date then id).
pub fn playlist_id(name: &str, occurrence: u32) -> String {
    uuid_from_digest(&[
        b"pl0",
        &[0],
        normalize_playlist_name(name).as_bytes(),
        &[0],
        occurrence.to_string().as_bytes(),
    ])
}

/// The id every device derives for an entry that existed before sync: a UUID shaped from `SHA-256("e0" || 0x00 || playlistId || 0x00 || songKey || 0x00 || occurrence)`, occurrence in decimal ASCII (0 for the first entry of that song in the playlist, by position).
pub fn entry_id(playlist_id: &str, song_key: &str, occurrence: u32) -> String {
    uuid_from_digest(&[
        b"e0",
        &[0],
        playlist_id.as_bytes(),
        &[0],
        song_key.as_bytes(),
        &[0],
        occurrence.to_string().as_bytes(),
    ])
}
