//! Songs from the person's own library that fit a playlist, offered on a shelf
//! under its songs. Nothing is ever added on its own: a suggestion joins the
//! playlist only when the person adds it, and the shelf can be hidden.
//!
//! A song fits by its artist: the playlist's own artists count by their share
//! of its songs, and artists Last.fm calls similar count by that share times
//! the match. A song from an album the playlist already draws on, a loved song
//! and a much-played one rank a little higher. Every artist's and album's third
//! song waits behind the other artists' and albums' first two, and so on, so a
//! page is never one album. Songs the playlist holds, by file or as the same
//! song from another release, are left out. The ranking is fixed for the same
//! input, and each page is the next `limit` of it, wrapping round. Mirrors
//! `Core/FlaccyCore/Sources/FlaccyCore/Library/PlaylistSuggestions.swift`.

use crate::home::{fold, KEY_SEPARATOR};
use std::collections::{HashMap, HashSet};

pub const PAGE_SIZE: usize = 8;
pub const PER_ARTIST: usize = 2;
pub const PER_ALBUM: usize = 2;

#[derive(Clone, Debug, PartialEq)]
pub struct Song {
    pub file: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub loved: bool,
    pub play_count: i64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct SimilarArtist {
    pub name: String,
    pub match_score: f64,
}

/// The playlist's artists by their share of its songs, most first, so a client
/// knows whose similar artists to look up.
pub fn seed_artists(playlist: &[Song], limit: usize) -> Vec<String> {
    let shares = artist_shares(playlist);
    let mut first_seen: HashMap<String, usize> = HashMap::new();
    for (index, song) in playlist.iter().enumerate() {
        first_seen.entry(fold(&song.artist)).or_insert(index);
    }
    let mut ordered: Vec<&String> = shares.keys().collect();
    ordered.sort_by(|a, b| {
        shares[*b]
            .partial_cmp(&shares[*a])
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(first_seen[*a].cmp(&first_seen[*b]))
    });
    ordered
        .into_iter()
        .take(limit)
        .filter_map(|key| playlist.iter().find(|s| fold(&s.artist) == *key).map(|s| s.artist.clone()))
        .collect()
}

/// The files of page `page` of suggestions for `playlist`, drawn from
/// `library`. `similar` maps a playlist artist, as any spelling the tags carry,
/// to the artists Last.fm calls similar.
pub fn suggest(
    playlist: &[Song],
    library: &[Song],
    similar: &HashMap<String, Vec<SimilarArtist>>,
    page: usize,
    limit: usize,
) -> Vec<String> {
    let ranked = ranking(playlist, library, similar);
    if ranked.is_empty() || limit == 0 {
        return Vec::new();
    }
    let start = (page * limit) % ranked.len();
    let end = (start + limit).min(ranked.len());
    ranked[start..end].to_vec()
}

/// Every suggestion in order, before paging.
pub fn ranking(playlist: &[Song], library: &[Song], similar: &HashMap<String, Vec<SimilarArtist>>) -> Vec<String> {
    if playlist.is_empty() {
        return Vec::new();
    }
    let shares = artist_shares(playlist);
    let mut affinity = shares.clone();
    for (seed, matches) in similar {
        let Some(share) = shares.get(&fold(seed)) else {
            continue;
        };
        for candidate in matches {
            let key = fold(&candidate.name);
            let weight = share * candidate.match_score.clamp(0.0, 1.0) * 0.8;
            let entry = affinity.entry(key).or_insert(0.0);
            if weight > *entry {
                *entry = weight;
            }
        }
    }
    let held: HashSet<&str> = playlist.iter().map(|s| s.file.as_str()).collect();
    let mut held_songs: HashSet<String> = playlist.iter().map(song_key).collect();
    let albums: HashSet<String> = playlist.iter().map(album_key).collect();
    let mut scored: Vec<(&Song, f64)> = Vec::new();
    for song in library {
        if held.contains(song.file.as_str()) {
            continue;
        }
        let Some(&weight) = affinity.get(&fold(&song.artist)) else {
            continue;
        };
        if weight <= 0.0 {
            continue;
        }
        let mut score = weight;
        if albums.contains(&album_key(song)) {
            score += 0.15;
        }
        if song.loved {
            score += 0.2;
        }
        score += (song.play_count.clamp(0, 50) as f64) / 50.0 * 0.15;
        scored.push((song, score));
    }
    scored.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.0.file.as_bytes().cmp(b.0.file.as_bytes()))
    });
    let mut per_artist: HashMap<String, usize> = HashMap::new();
    let mut per_album: HashMap<String, usize> = HashMap::new();
    let mut tiered: Vec<(String, usize)> = Vec::new();
    for (song, _) in scored {
        if !held_songs.insert(song_key(song)) {
            continue;
        }
        let artist = per_artist.entry(fold(&song.artist)).or_insert(0);
        let album = per_album.entry(album_key(song)).or_insert(0);
        let tier = (*artist / PER_ARTIST).max(*album / PER_ALBUM);
        *artist += 1;
        *album += 1;
        tiered.push((song.file.clone(), tier));
    }
    tiered.sort_by_key(|(_, tier)| *tier);
    tiered.into_iter().map(|(file, _)| file).collect()
}

fn artist_shares(playlist: &[Song]) -> HashMap<String, f64> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    for song in playlist {
        *counts.entry(fold(&song.artist)).or_insert(0) += 1;
    }
    let total = playlist.len() as f64;
    counts.into_iter().map(|(artist, count)| (artist, count as f64 / total)).collect()
}

fn song_key(song: &Song) -> String {
    format!("{}{}{}", fold(&song.title), KEY_SEPARATOR, fold(&song.artist))
}

fn album_key(song: &Song) -> String {
    format!("{}{}{}", fold(&song.album), KEY_SEPARATOR, fold(&song.artist))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(file: &str, title: &str, artist: &str, album: &str, loved: bool, plays: i64) -> Song {
        Song {
            file: file.into(),
            title: title.into(),
            artist: artist.into(),
            album: album.into(),
            loved,
            play_count: plays,
        }
    }

    fn playlist() -> Vec<Song> {
        vec![
            song("p1", "Glass", "Nova Bloom", "Tides", false, 0),
            song("p2", "Shore", "Nova Bloom", "Tides", false, 0),
            song("p3", "Ember", "Ash Coast", "Kiln", false, 0),
        ]
    }

    fn library() -> Vec<Song> {
        let mut all = playlist();
        all.extend([
            song("n1", "Undertow", "Nova Bloom", "Tides", false, 0),
            song("n2", "Harbor", "Nova Bloom", "Lanterns", true, 0),
            song("n3", "Reef", "Nova Bloom", "Lanterns", false, 40),
            song("a1", "Cinder", "Ash Coast", "Kiln", false, 0),
            song("s1", "Drift", "Pale Orchard", "Low Sun", false, 0),
            song("s2", "Glass", "nova bloom ", "Tides (Deluxe)", false, 0),
            song("x1", "Elsewhere", "Unrelated", "Other", false, 0),
        ]);
        all
    }

    fn similar(seed: &str) -> HashMap<String, Vec<SimilarArtist>> {
        HashMap::from([(
            seed.to_string(),
            vec![SimilarArtist {
                name: "Pale Orchard".into(),
                match_score: 0.5,
            }],
        )])
    }

    #[test]
    fn s1_an_empty_playlist_suggests_nothing() {
        assert!(suggest(&[], &library(), &HashMap::new(), 0, PAGE_SIZE).is_empty());
    }

    #[test]
    fn s2_the_ranking_weighs_share_album_love_and_plays() {
        assert_eq!(ranking(&playlist(), &library(), &HashMap::new()), ["n2", "n1", "a1", "n3"]);
    }

    #[test]
    fn s3_similar_artists_join_by_their_match() {
        assert_eq!(ranking(&playlist(), &library(), &similar("NOVA BLOOM")), ["n2", "n1", "a1", "s1", "n3"]);
    }

    #[test]
    fn s4_the_same_song_from_another_release_is_left_out() {
        assert!(!ranking(&playlist(), &library(), &HashMap::new()).contains(&"s2".to_string()));
    }

    #[test]
    fn s5_pages_walk_the_ranking_and_wrap_round() {
        let similar = similar("Nova Bloom");
        assert_eq!(suggest(&playlist(), &library(), &similar, 0, 3), ["n2", "n1", "a1"]);
        assert_eq!(suggest(&playlist(), &library(), &similar, 1, 3), ["s1", "n3"]);
        assert_eq!(suggest(&playlist(), &library(), &similar, 2, 3), ["n1", "a1", "s1"]);
    }

    #[test]
    fn s6_no_artist_or_album_crowds_the_top_of_the_list() {
        let mut all = playlist();
        all.extend((0..4).map(|i| song(&format!("c{i}"), &format!("Song {i}"), "Nova Bloom", "Tides", false, 50 - i)));
        all.push(song("a1", "Cinder", "Ash Coast", "Kiln", false, 0));
        assert_eq!(ranking(&playlist(), &all, &HashMap::new()), ["c0", "c1", "a1", "c2", "c3"]);
    }

    #[test]
    fn s7_seed_artists_come_most_frequent_first() {
        assert_eq!(seed_artists(&playlist(), 5), ["Nova Bloom", "Ash Coast"]);
        assert_eq!(seed_artists(&playlist(), 1), ["Nova Bloom"]);
    }
}
