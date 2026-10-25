use crate::library::{Album, Library, Track};
use crate::wantlist::normalize;
use std::collections::{HashMap, HashSet};

const ENTRY_SEPARATOR: &str = " — ";

/// Resolves the Stats top lists, whose entries are Last.fm-shaped names, back
/// to what the library really holds so a chart can be played. Matching is
/// case-, diacritic- and punctuation-insensitive, the same way as the Apple
/// clients' `RecapLibraryIndex`; entries the library does not own are skipped,
/// so a queue is whatever can play.
pub struct ChartIndex<'a> {
    library: &'a Library,
    tracks: HashMap<String, &'a Track>,
    albums: HashMap<String, &'a Album>,
}

impl<'a> ChartIndex<'a> {
    pub fn new(library: &'a Library) -> Self {
        let mut albums = HashMap::new();
        for album in &library.albums {
            albums.insert(key(&album.title, &album.artist), album);
        }
        let mut tracks = HashMap::new();
        for track in &library.tracks {
            tracks.insert(key(&track.title, &track.artist), track);
        }
        Self {
            library,
            tracks,
            albums,
        }
    }

    /// The owned song behind a `"Title — Artist"` entry.
    pub fn track(&self, entry: &str) -> Option<&'a Track> {
        split_candidates(entry)
            .find_map(|(title, artist)| self.tracks.get(&key(title, artist)))
            .copied()
    }

    /// The owned release behind an `"Album — Artist"` entry.
    pub fn album(&self, entry: &str) -> Option<&'a Album> {
        split_candidates(entry)
            .find_map(|(title, artist)| self.albums.get(&key(title, artist)))
            .copied()
    }

    /// Whether the library holds anything by `artist`.
    pub fn owns_artist(&self, artist: &str) -> bool {
        !self.library.artist_tracks(artist).is_empty()
    }

    /// The owned songs behind a top-tracks chart, in rank order.
    pub fn track_queue(&self, entries: &[(String, i64)]) -> Vec<Track> {
        unique(
            entries
                .iter()
                .filter_map(|(entry, _)| self.track(entry))
                .cloned()
                .collect(),
        )
    }

    /// The owned releases behind a top-albums chart, in rank order, each one
    /// whole and in its own track order.
    pub fn album_queue(&self, entries: &[(String, i64)]) -> Vec<Track> {
        unique(
            entries
                .iter()
                .filter_map(|(entry, _)| self.album(entry))
                .flat_map(|album| album.tracks.iter().cloned())
                .collect(),
        )
    }

    /// Everything the library holds by each charted artist, in rank order.
    pub fn artist_queue(&self, entries: &[(String, i64)]) -> Vec<Track> {
        unique(
            entries
                .iter()
                .flat_map(|(artist, _)| self.library.artist_tracks(artist))
                .collect(),
        )
    }
}

/// Every way to read `entry` as `title — artist`. A title can itself contain
/// the separator, and so can an artist, so each occurrence is offered and the
/// first one the library recognises wins.
fn split_candidates(entry: &str) -> impl Iterator<Item = (&str, &str)> {
    entry
        .match_indices(ENTRY_SEPARATOR)
        .map(move |(at, _)| (&entry[..at], &entry[at + ENTRY_SEPARATOR.len()..]))
}

fn key(title: &str, artist: &str) -> String {
    format!("{}\u{0}{}", normalize(title), normalize(artist))
}

fn unique(tracks: Vec<Track>) -> Vec<Track> {
    let mut seen = HashSet::new();
    tracks
        .into_iter()
        .filter(|track| seen.insert(track.rel_path.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(rel_path: &str, title: &str, artist: &str, album: &str) -> Track {
        Track {
            id: 0,
            rel_path: rel_path.to_string(),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            album_artist: None,
            track_number: 1,
            duration: 100.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    fn library() -> Library {
        let a1 = track("a/1.flac", "Domino", "Cascada", "Evacuate the Dancefloor");
        let a2 = track(
            "a/2.flac",
            "Evacuate the Dancefloor",
            "Cascada",
            "Evacuate the Dancefloor",
        );
        let b1 = track("b/1.flac", "Ágætis byrjun", "Sigur Rós", "Ágætis byrjun");
        let c1 = track(
            "c/1.flac",
            "Heroes — 2017 Remaster",
            "David Bowie",
            "Heroes",
        );
        let mut library = Library::empty();
        library.albums = vec![
            Album {
                title: "Evacuate the Dancefloor".into(),
                artist: "Cascada".into(),
                year: None,
                genre: None,
                tracks: vec![a1.clone(), a2.clone()],
            },
            Album {
                title: "Ágætis byrjun".into(),
                artist: "Sigur Rós".into(),
                year: None,
                genre: None,
                tracks: vec![b1.clone()],
            },
            Album {
                title: "Heroes".into(),
                artist: "David Bowie".into(),
                year: None,
                genre: None,
                tracks: vec![c1.clone()],
            },
        ];
        library.tracks = vec![a1, a2, b1, c1];
        library
    }

    fn chart(entries: &[&str]) -> Vec<(String, i64)> {
        entries.iter().map(|e| (e.to_string(), 1)).collect()
    }

    #[test]
    fn track_queue_keeps_rank_order_and_skips_unowned() {
        let library = library();
        let index = ChartIndex::new(&library);
        let queue = index.track_queue(&chart(&[
            "Evacuate the Dancefloor — Cascada",
            "Nothing I Own — Nobody",
            "Domino — Cascada",
        ]));
        let paths: Vec<_> = queue.iter().map(|t| t.rel_path.as_str()).collect();
        assert_eq!(paths, ["a/2.flac", "a/1.flac"]);
    }

    #[test]
    fn matching_ignores_case_diacritics_and_punctuation() {
        let library = library();
        let index = ChartIndex::new(&library);
        assert!(index.track("agætis byrjun — SIGUR ROS").is_some());
        assert!(index.track("domino!! — cascada").is_some());
        assert!(index.album("evacuate the dancefloor — CASCADA").is_some());
        assert!(index
            .album("Evacuate The Dancefloor — Somebody Else")
            .is_none());
    }

    #[test]
    fn a_separator_inside_the_title_still_resolves() {
        let library = library();
        let index = ChartIndex::new(&library);
        let found = index.track("Heroes — 2017 Remaster — David Bowie");
        assert_eq!(found.map(|t| t.rel_path.as_str()), Some("c/1.flac"));
    }

    #[test]
    fn album_queue_plays_each_release_whole_in_rank_order() {
        let library = library();
        let index = ChartIndex::new(&library);
        let queue = index.album_queue(&chart(&[
            "Heroes — David Bowie",
            "Evacuate the Dancefloor — Cascada",
        ]));
        let paths: Vec<_> = queue.iter().map(|t| t.rel_path.as_str()).collect();
        assert_eq!(paths, ["c/1.flac", "a/1.flac", "a/2.flac"]);
    }

    #[test]
    fn artist_queue_is_deduplicated_across_the_chart() {
        let library = library();
        let index = ChartIndex::new(&library);
        let queue = index.artist_queue(&chart(&["Cascada", "Cascada", "Sigur Rós", "Nobody"]));
        let paths: Vec<_> = queue.iter().map(|t| t.rel_path.as_str()).collect();
        assert_eq!(paths, ["a/1.flac", "a/2.flac", "b/1.flac"]);
        assert!(index.owns_artist("Cascada"));
        assert!(!index.owns_artist("Nobody"));
    }
}
