//! How a playlist's cover is addressed and which albums stand in for it.
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/PlaylistCover.swift`: a
//! playlist's chosen picture is served by the same artwork cache and editor as
//! an album's, so it is addressed by a reserved (title, artist) pair no album
//! can carry.

use std::collections::HashSet;

pub const ARTIST: &str = "\u{1}playlist";

pub const MAXIMUM_MOSAIC_TILES: usize = 4;

pub const MAXIMUM_SHELF_ALBUMS: usize = 12;

const TITLE_PREFIX: &str = "playlist:";

pub fn title_for(playlist_id: i64) -> String {
    format!("{TITLE_PREFIX}{playlist_id}")
}

/// The playlist a cache key names, or None for an ordinary album key.
pub fn playlist_id(title: &str, artist: &str) -> Option<i64> {
    if artist != ARTIST {
        return None;
    }
    title.strip_prefix(TITLE_PREFIX)?.parse().ok()
}

/// The albums whose covers make up the automatic mosaic: the first distinct
/// releases in playlist order, at most four.
pub fn mosaic_albums(albums: &[(String, String)]) -> Vec<(String, String)> {
    distinct(albums, MAXIMUM_MOSAIC_TILES)
}

/// The albums offered as ready-made covers in the editor's shelf: the distinct
/// releases in playlist order, at most twelve.
pub fn shelf_albums(albums: &[(String, String)]) -> Vec<(String, String)> {
    distinct(albums, MAXIMUM_SHELF_ALBUMS)
}

fn distinct(albums: &[(String, String)], limit: usize) -> Vec<(String, String)> {
    let mut seen = HashSet::new();
    let mut kept = Vec::new();
    for (title, artist) in albums {
        if title.is_empty() || !seen.insert((title.clone(), artist.clone())) {
            continue;
        }
        kept.push((title.clone(), artist.clone()));
        if kept.len() == limit {
            break;
        }
    }
    kept
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairs(items: &[(&str, &str)]) -> Vec<(String, String)> {
        items
            .iter()
            .map(|(title, artist)| (title.to_string(), artist.to_string()))
            .collect()
    }

    #[test]
    fn p1_key_round_trips_the_playlist_id() {
        let title = title_for(42);
        assert_eq!(title, "playlist:42");
        assert_eq!(playlist_id(&title, ARTIST), Some(42));
    }

    #[test]
    fn p2_an_ordinary_album_is_never_a_playlist_key() {
        assert_eq!(playlist_id("playlist:42", "Some Band"), None);
        assert_eq!(playlist_id("Abbey Road", ARTIST), None);
        assert_eq!(playlist_id("playlist:x", ARTIST), None);
    }

    #[test]
    fn p3_mosaic_takes_first_four_distinct_albums_in_order() {
        let albums = pairs(&[
            ("A", "x"),
            ("A", "x"),
            ("B", "x"),
            ("A", "y"),
            ("C", "z"),
            ("D", "z"),
            ("E", "z"),
        ]);
        assert_eq!(
            mosaic_albums(&albums),
            pairs(&[("A", "x"), ("B", "x"), ("A", "y"), ("C", "z")])
        );
    }

    #[test]
    fn p4_tracks_without_an_album_title_are_skipped() {
        let kept = mosaic_albums(&pairs(&[("", "x"), ("B", "x")]));
        assert_eq!(kept, pairs(&[("B", "x")]));
    }

    #[test]
    fn p5_shelf_holds_up_to_twelve_distinct_albums() {
        let albums: Vec<(String, String)> = (0..20)
            .map(|index| (format!("Album {}", index % 15), "x".to_string()))
            .collect();
        assert_eq!(shelf_albums(&albums).len(), 12);
    }
}
