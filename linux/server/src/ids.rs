//! The ids the API hands out and the reverse lookup from an id to what it names.
//!
//! A song is `s` and its row id, so a re-export, which revises the row in
//! place, keeps it. An album or an artist is a prefix and the first 16 hex
//! characters of a SHA-256 over the same normalized key the library groups by,
//! so the id survives a retag that only changes case or punctuation. A playlist
//! is `pl-` and the id its sync entity has.

use flaccy_library::{hygiene, keys};
use sha2::{Digest, Sha256};

const ALBUM_PREFIX: &str = "al-";
const ARTIST_PREFIX: &str = "ar-";
const PLAYLIST_PREFIX: &str = "pl-";
const UUID_CHARS: usize = 36;
const HASH_CHARS: usize = 16;

/// What an id names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entity {
    Song(i64),
    Album(String),
    Artist(String),
    Playlist(String),
}

/// Lowercase hex of `bytes`.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

/// The bytes a hex string spells, `None` for odd length or a non-hex character.
pub fn unhex(text: &str) -> Option<Vec<u8>> {
    if text.len() % 2 != 0 || !text.is_ascii() {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|at| u8::from_str_radix(&text[at..at + 2], 16).ok())
        .collect()
}

/// The SHA-256 of `bytes` as lowercase hex.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

fn short_hash(key: &str) -> String {
    sha256_hex(key.as_bytes())[..HASH_CHARS].to_string()
}

/// The id of the song stored in track row `row_id`.
pub fn song(row_id: i64) -> String {
    format!("s{row_id}")
}

/// The id of the playlist whose sync id is `sync_id`.
pub fn playlist(sync_id: &str) -> String {
    format!("{PLAYLIST_PREFIX}{sync_id}")
}

/// The key the library groups an album by: its normalized title and the
/// normalized lead artist of its release credit.
pub fn album_key(title: &str, credit: &str) -> String {
    format!("{}\u{0}{}", keys::normalize(title), hygiene::artist_key(credit))
}

/// The id of the album grouped under `title` and `credit`.
pub fn album(title: &str, credit: &str) -> String {
    format!("{ALBUM_PREFIX}{}", short_hash(&album_key(title, credit)))
}

/// The id of the artist credited as `name`.
pub fn artist(name: &str) -> String {
    format!("{ARTIST_PREFIX}{}", short_hash(&hygiene::artist_key(name)))
}

/// A fresh version 7 UUID in lowercase hyphenated form: 48 bits of Unix milliseconds, then random bits. The ids of the
/// playlists and entries this server mints for REST calls are shaped like the ones the Flaccy clients mint.
pub fn uuid_v7(now_ms: i64) -> Result<String, crate::security::SecurityError> {
    let mut bytes = crate::security::keys::random_bytes::<16>()?;
    bytes[..6].copy_from_slice(&now_ms.max(0).to_be_bytes()[2..]);
    bytes[6] = (bytes[6] & 0x0f) | 0x70;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let text = hex(&bytes);
    Ok(format!("{}-{}-{}-{}-{}", &text[..8], &text[8..12], &text[12..16], &text[16..20], &text[20..]))
}

/// What `id` names, `None` when it is none of the shapes this server hands out.
pub fn parse(id: &str) -> Option<Entity> {
    if let Some(hash) = id.strip_prefix(ALBUM_PREFIX) {
        return is_hash(hash).then(|| Entity::Album(id.to_string()));
    }
    if let Some(hash) = id.strip_prefix(ARTIST_PREFIX) {
        return is_hash(hash).then(|| Entity::Artist(id.to_string()));
    }
    if let Some(digits) = id.strip_prefix('s') {
        return row_id(digits).map(Entity::Song);
    }
    if let Some(sync_id) = id.strip_prefix(PLAYLIST_PREFIX) {
        return is_uuid(sync_id).then(|| Entity::Playlist(sync_id.to_string()));
    }
    None
}

fn is_uuid(text: &str) -> bool {
    text.len() == UUID_CHARS
        && text
            .bytes()
            .enumerate()
            .all(|(at, byte)| if matches!(at, 8 | 13 | 18 | 23) { byte == b'-' } else { byte.is_ascii_hexdigit() })
}

fn is_hash(text: &str) -> bool {
    text.len() == HASH_CHARS && text.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn row_id(digits: &str) -> Option<i64> {
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    digits.parse().ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn songs_and_playlists_round_trip_through_their_ids() {
        assert_eq!(parse(&song(42)), Some(Entity::Song(42)));
        let sync_id = "0190f3a2-7b1c-7d2e-8f3a-123456789abc";
        assert_eq!(parse(&playlist(sync_id)), Some(Entity::Playlist(sync_id.to_string())));
        assert_eq!(parse("pl-7"), None);
        assert_eq!(parse("p7"), None);
        assert_eq!(parse("s"), None);
        assert_eq!(parse("s4x"), None);
    }

    #[test]
    fn album_and_artist_ids_are_sixteen_hex_characters_after_their_prefix() {
        let id = album("Rough Cuts", "Drill Band");
        assert!(id.starts_with("al-") && id.len() == 3 + 16);
        assert_eq!(parse(&id), Some(Entity::Album(id.clone())));
        let id = artist("Drill Band");
        assert!(id.starts_with("ar-") && id.len() == 3 + 16);
        assert_eq!(parse("al-xyz"), None);
    }

    #[test]
    fn case_and_punctuation_do_not_change_an_album_id() {
        assert_eq!(
            album("Rough Cuts!", "The DRILL band"),
            album("rough cuts", "the drill band")
        );
        assert_ne!(album("Rough Cuts", "Drill Band"), album("Smooth Cuts", "Drill Band"));
    }

    #[test]
    fn minted_uuids_are_version_seven_and_ordered_by_time() {
        let early = uuid_v7(1_700_000_000_000).unwrap();
        let late = uuid_v7(1_800_000_000_000).unwrap();
        assert!(is_uuid(&early) && &early[14..15] == "7");
        assert!(early < late);
        assert_ne!(uuid_v7(1).unwrap(), uuid_v7(1).unwrap());
    }

    #[test]
    fn hex_round_trips() {
        assert_eq!(unhex(&hex(b"pa55 word")), Some(b"pa55 word".to_vec()));
        assert_eq!(unhex("abc"), None);
        assert_eq!(unhex("zz"), None);
    }
}
