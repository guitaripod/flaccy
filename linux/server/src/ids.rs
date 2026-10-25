//! The ids the API hands out and the reverse lookup from an id to what it names.
//!
//! A song is `s` and its row id, so a re-export, which revises the row in
//! place, keeps it. An album or an artist is a prefix and the first 16 hex
//! characters of a SHA-256 over the same normalized key the library groups by,
//! so the id survives a retag that only changes case or punctuation.

use flaccy_library::{hygiene, keys};
use sha2::{Digest, Sha256};

const ALBUM_PREFIX: &str = "al-";
const ARTIST_PREFIX: &str = "ar-";
const HASH_CHARS: usize = 16;

/// What an id names.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Entity {
    Song(i64),
    Album(String),
    Artist(String),
    Playlist(i64),
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

/// The id of the playlist stored in playlist row `row_id`.
pub fn playlist(row_id: i64) -> String {
    format!("p{row_id}")
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
    if let Some(digits) = id.strip_prefix('p') {
        return row_id(digits).map(Entity::Playlist);
    }
    None
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
        assert_eq!(parse(&playlist(7)), Some(Entity::Playlist(7)));
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
    fn hex_round_trips() {
        assert_eq!(unhex(&hex(b"pa55 word")), Some(b"pa55 word".to_vec()));
        assert_eq!(unhex("abc"), None);
        assert_eq!(unhex("zz"), None);
    }
}
