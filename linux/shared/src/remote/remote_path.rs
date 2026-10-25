//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/RemoteTrackPath.swift`.
//!
//! The library stores a remote song under `remote://<server>/<song>`, so a
//! track row says which server and which song it is without a second table.
//! Both parts are percent-encoded with the request builder's unreserved set,
//! which keeps a slash inside an id from being read as the separator.

use super::{percent_decode, percent_encode};

pub const SCHEME: &str = "remote://";

/// The stored path for one song on one server.
pub fn encode(server: &str, song: &str) -> String {
    format!(
        "{SCHEME}{}/{}",
        percent_encode(server),
        percent_encode(song)
    )
}

/// The server and song ids of a stored remote path, `None` for any other path.
pub fn decode(path: &str) -> Option<(String, String)> {
    let body = path.strip_prefix(SCHEME)?;
    let (server, song) = body.split_once('/')?;
    let server = percent_decode(server).filter(|server| !server.is_empty())?;
    let song = percent_decode(song).filter(|song| !song.is_empty())?;
    Some((server, song))
}

pub fn is_remote(path: &str) -> bool {
    path.starts_with(SCHEME)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_a_plain_song_id() {
        let path = encode("srv-1", "4vVKvXswBtHVzMYeWVqhKo");
        assert_eq!(path, "remote://srv-1/4vVKvXswBtHVzMYeWVqhKo");
        assert_eq!(
            decode(&path),
            Some(("srv-1".to_string(), "4vVKvXswBtHVzMYeWVqhKo".to_string()))
        );
    }

    #[test]
    fn round_trips_a_song_id_with_a_slash_and_a_space() {
        let path = encode("srv-1", "a/b c");
        assert_eq!(path, "remote://srv-1/a%2Fb%20c");
        assert_eq!(
            decode(&path),
            Some(("srv-1".to_string(), "a/b c".to_string()))
        );
    }

    #[test]
    fn rejects_paths_that_are_not_remote() {
        assert_eq!(decode("remote://only"), None);
        assert_eq!(decode("Music/a.flac"), None);
        assert_eq!(decode("remote:///song"), None);
        assert_eq!(decode("remote://srv/"), None);
        assert!(is_remote("remote://srv/x"));
        assert!(!is_remote("Music/a.flac"));
    }
}
