//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/RemoteCatalogDiff.swift`.
//!
//! What a catalog sync changes in the local rows of one server, decided from
//! the server's songs and those rows alone. A song only the server has is
//! inserted, a row the server no longer lists is removed, and a song on both
//! sides is either a new version (its audio changed) or an update (its tags
//! moved). Two copies with the same Flaccy fingerprint have the same audio
//! whatever their sizes say, so size and duration only decide when a
//! fingerprint is missing on either side.

use std::collections::{HashMap, HashSet};

pub const DURATION_TOLERANCE_SECONDS: f64 = 0.5;

#[derive(Clone, Debug, PartialEq)]
pub struct CatalogSong {
    pub id: String,
    pub size: i64,
    pub duration: f64,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub track: Option<i64>,
    pub fingerprint: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Diff {
    pub inserted: Vec<String>,
    pub removed: Vec<String>,
    pub updated: Vec<String>,
    pub new_versions: Vec<String>,
}

/// `server` is the catalog as the server lists it, `local` the rows already
/// stored for that server. `inserted`, `updated` and `new_versions` follow the
/// server's order; `removed` is sorted by id.
pub fn diff(server: &[CatalogSong], local: &[CatalogSong]) -> Diff {
    let local_by_id: HashMap<&str, &CatalogSong> =
        local.iter().map(|song| (song.id.as_str(), song)).collect();
    let server_ids: HashSet<&str> = server.iter().map(|song| song.id.as_str()).collect();
    let mut removed: Vec<String> = local
        .iter()
        .filter(|song| !server_ids.contains(song.id.as_str()))
        .map(|song| song.id.clone())
        .collect();
    removed.sort();
    let mut result = Diff {
        removed,
        ..Diff::default()
    };
    for song in server {
        match local_by_id.get(song.id.as_str()) {
            None => result.inserted.push(song.id.clone()),
            Some(row) if audio_changed(row, song) => result.new_versions.push(song.id.clone()),
            Some(row) if metadata_changed(row, song) => result.updated.push(song.id.clone()),
            Some(_) => {}
        }
    }
    result
}

/// Two fingerprints decide alone when both are known. Otherwise the size and
/// the duration, within half a second, stand in for the audio.
fn audio_changed(local: &CatalogSong, server: &CatalogSong) -> bool {
    match (&local.fingerprint, &server.fingerprint) {
        (Some(local), Some(server)) => local != server,
        _ => {
            local.size != server.size
                || (local.duration - server.duration).abs() > DURATION_TOLERANCE_SECONDS
        }
    }
}

/// The tags a row shows: title, artist, album and track number.
fn metadata_changed(local: &CatalogSong, server: &CatalogSong) -> bool {
    local.title != server.title
        || local.artist != server.artist
        || local.album != server.album
        || local.track != server.track
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(id: &str) -> CatalogSong {
        CatalogSong {
            id: id.to_string(),
            size: 1000,
            duration: 200.0,
            title: format!("Title {id}"),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            track: Some(1),
            fingerprint: None,
        }
    }

    fn with_fingerprint(id: &str, fingerprint: &str) -> CatalogSong {
        CatalogSong {
            fingerprint: Some(fingerprint.to_string()),
            ..song(id)
        }
    }

    #[test]
    fn an_identical_catalog_changes_nothing() {
        let catalog = [song("a"), song("b")];
        assert_eq!(diff(&catalog, &catalog), Diff::default());
    }

    #[test]
    fn songs_only_on_the_server_are_inserted_in_server_order() {
        let server = [song("b"), song("a"), song("c")];
        let local = [song("a")];
        assert_eq!(diff(&server, &local).inserted, vec!["b", "c"]);
    }

    #[test]
    fn rows_the_server_no_longer_lists_are_removed_sorted() {
        let server = [song("a")];
        let local = [song("z"), song("m"), song("a")];
        assert_eq!(diff(&server, &local).removed, vec!["m", "z"]);
    }

    #[test]
    fn a_retag_with_the_same_audio_is_an_update() {
        let server = [CatalogSong {
            title: "Renamed".to_string(),
            ..with_fingerprint("a", "f1")
        }];
        let local = [with_fingerprint("a", "f1")];
        let result = diff(&server, &local);
        assert_eq!(result.updated, vec!["a"]);
        assert!(result.new_versions.is_empty());
    }

    #[test]
    fn different_fingerprints_are_a_new_version_and_not_also_an_update() {
        let server = [CatalogSong {
            title: "Renamed".to_string(),
            ..with_fingerprint("a", "f2")
        }];
        let local = [with_fingerprint("a", "f1")];
        let result = diff(&server, &local);
        assert_eq!(result.new_versions, vec!["a"]);
        assert!(result.updated.is_empty());
    }

    #[test]
    fn matching_fingerprints_win_over_a_different_size() {
        let server = [CatalogSong {
            size: 2000,
            ..with_fingerprint("a", "f1")
        }];
        let local = [with_fingerprint("a", "f1")];
        let result = diff(&server, &local);
        assert!(result.new_versions.is_empty());
        assert!(result.updated.is_empty());
    }

    #[test]
    fn matching_fingerprints_with_new_tags_are_only_an_update() {
        let server = [CatalogSong {
            size: 2000,
            album: "Other".to_string(),
            ..with_fingerprint("a", "f1")
        }];
        let local = [with_fingerprint("a", "f1")];
        let result = diff(&server, &local);
        assert_eq!(result.updated, vec!["a"]);
        assert!(result.new_versions.is_empty());
    }

    #[test]
    fn without_fingerprints_a_size_change_is_a_new_version() {
        let server = [CatalogSong {
            size: 1001,
            ..song("a")
        }];
        let local = [song("a")];
        assert_eq!(diff(&server, &local).new_versions, vec!["a"]);
    }

    #[test]
    fn without_fingerprints_a_duration_change_past_half_a_second_is_a_new_version() {
        let local = [song("a")];
        let within = [CatalogSong {
            duration: 200.4,
            ..song("a")
        }];
        let past = [CatalogSong {
            duration: 201.0,
            ..song("a")
        }];
        assert!(diff(&within, &local).new_versions.is_empty());
        assert_eq!(diff(&past, &local).new_versions, vec!["a"]);
    }

    #[test]
    fn a_missing_fingerprint_on_one_side_falls_back_to_size() {
        let server = [CatalogSong {
            size: 1001,
            ..with_fingerprint("a", "f1")
        }];
        let local = [song("a")];
        assert_eq!(diff(&server, &local).new_versions, vec!["a"]);
    }

    #[test]
    fn an_empty_server_catalog_removes_every_local_row() {
        let local = [song("b"), song("a")];
        let result = diff(&[], &local);
        assert_eq!(result.removed, vec!["a", "b"]);
        assert!(result.inserted.is_empty());
        assert!(result.updated.is_empty());
        assert!(result.new_versions.is_empty());
    }
}
