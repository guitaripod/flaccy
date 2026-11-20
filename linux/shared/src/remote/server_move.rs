//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/ServerMovePlan.swift`.
//!
//! Pairs the songs on this computer with the copies a server holds, so the
//! library can play the server's copy in their place and keep everything that
//! belongs to them. A song only ever matches a server song with the same song
//! key, so loves, song volumes and synced playlist entries stay attached. Among
//! those it matches one with the same audio fingerprint; or one on the same
//! album that lasts within `DURATION_TOLERANCE_MS` of it; or, on another album,
//! one with the same track number within `OTHER_ALBUM_TOLERANCE_MS`, which
//! catches a copy whose album title only differs by a disc or edition suffix
//! while a live or edited take, which runs differently, stays. Each server song
//! takes one song from this computer as its pair, chosen by the same audio
//! first, then the same album, then the same track number, then the copy the
//! person uses most (`rank`), then the closest length, then the lowest paths,
//! so the result never depends on the order the songs arrive in. A further copy
//! that matches a server song already taken is a duplicate of that pair. A song
//! that matches nothing stays.

use std::collections::{HashMap, HashSet};

pub const DURATION_TOLERANCE_MS: i64 = 2_000;
/// A server stores whole seconds and AAC adds a few milliseconds, so a
/// transcode of the same file lands within a second.
pub const OTHER_ALBUM_TOLERANCE_MS: i64 = 1_000;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Song {
    pub path: String,
    pub song_key: String,
    pub album_key: String,
    pub track: i64,
    pub duration_ms: i64,
    pub fingerprint: Option<String>,
    /// How much the person uses this copy; among copies on this computer, the higher one becomes the pair.
    pub rank: i64,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Pair {
    pub local: String,
    pub server: String,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    /// One song from this computer for each server song it matched, sorted by the local path.
    pub pairs: Vec<Pair>,
    /// Further copies of a server song that already has its pair, sorted the same way.
    pub duplicates: Vec<Pair>,
    /// The paths of the songs no server song matched, sorted.
    pub unmatched: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
enum Kind {
    SameAudio,
    SameAlbum,
    SameTrack,
}

struct Edge {
    local: usize,
    server: usize,
    kind: Kind,
    same_track: bool,
    gap_ms: i64,
}

pub fn plan(local: &[Song], server: &[Song]) -> Plan {
    let mut edges = candidate_edges(local, server);
    edges.sort_by(|a, b| {
        a.kind
            .cmp(&b.kind)
            .then(b.same_track.cmp(&a.same_track))
            .then(local[b.local].rank.cmp(&local[a.local].rank))
            .then(a.gap_ms.cmp(&b.gap_ms))
            .then(local[a.local].path.cmp(&local[b.local].path))
            .then(server[a.server].path.cmp(&server[b.server].path))
    });
    let mut taken_local = HashSet::new();
    let mut taken_server = HashSet::new();
    let mut pairs = Vec::new();
    for edge in &edges {
        if taken_local.contains(&edge.local) || taken_server.contains(&edge.server) {
            continue;
        }
        taken_local.insert(edge.local);
        taken_server.insert(edge.server);
        pairs.push(pair(local, server, edge));
    }
    let mut duplicates = Vec::new();
    for edge in &edges {
        if taken_local.insert(edge.local) {
            duplicates.push(pair(local, server, edge));
        }
    }
    pairs.sort_by(|a, b| a.local.cmp(&b.local));
    duplicates.sort_by(|a, b| a.local.cmp(&b.local));
    let mut unmatched: Vec<String> = (0..local.len())
        .filter(|index| !taken_local.contains(index))
        .map(|index| local[index].path.clone())
        .collect();
    unmatched.sort();
    Plan {
        pairs,
        duplicates,
        unmatched,
    }
}

fn pair(local: &[Song], server: &[Song], edge: &Edge) -> Pair {
    Pair {
        local: local[edge.local].path.clone(),
        server: server[edge.server].path.clone(),
    }
}

fn candidate_edges(local: &[Song], server: &[Song]) -> Vec<Edge> {
    let mut by_fingerprint: HashMap<&str, Vec<usize>> = HashMap::new();
    let mut by_song_key: HashMap<&str, Vec<usize>> = HashMap::new();
    for (index, song) in server.iter().enumerate() {
        if let Some(fingerprint) = non_empty(&song.fingerprint) {
            by_fingerprint.entry(fingerprint).or_default().push(index);
        }
        if !song.song_key.is_empty() {
            by_song_key.entry(song.song_key.as_str()).or_default().push(index);
        }
    }
    let mut edges = Vec::new();
    for (local_index, song) in local.iter().enumerate() {
        if song.song_key.is_empty() {
            continue;
        }
        let mut seen = HashSet::new();
        if let Some(fingerprint) = non_empty(&song.fingerprint) {
            for &server_index in by_fingerprint.get(fingerprint).into_iter().flatten() {
                if server[server_index].song_key == song.song_key && seen.insert(server_index) {
                    edges.push(edge(local_index, server_index, song, &server[server_index], Kind::SameAudio));
                }
            }
        }
        for &server_index in by_song_key.get(song.song_key.as_str()).into_iter().flatten() {
            if seen.contains(&server_index) {
                continue;
            }
            let candidate = &server[server_index];
            if (candidate.duration_ms - song.duration_ms).abs() > DURATION_TOLERANCE_MS {
                continue;
            }
            if candidate.album_key == song.album_key {
                edges.push(edge(local_index, server_index, song, candidate, Kind::SameAlbum));
            } else if song.track > 0
                && candidate.track == song.track
                && (candidate.duration_ms - song.duration_ms).abs() <= OTHER_ALBUM_TOLERANCE_MS
            {
                edges.push(edge(local_index, server_index, song, candidate, Kind::SameTrack));
            }
        }
    }
    edges
}

fn edge(local_index: usize, server_index: usize, local: &Song, server: &Song, kind: Kind) -> Edge {
    Edge {
        local: local_index,
        server: server_index,
        kind,
        same_track: local.track > 0 && local.track == server.track,
        gap_ms: (local.duration_ms - server.duration_ms).abs(),
    }
}

fn non_empty(text: &Option<String>) -> Option<&str> {
    text.as_deref().filter(|text| !text.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    struct S {
        path: &'static str,
        key: &'static str,
        album: &'static str,
        track: i64,
        ms: i64,
        fp: Option<&'static str>,
        rank: i64,
    }

    impl S {
        fn new(path: &'static str) -> S {
            S { path, key: "k", album: "a", track: 1, ms: 200_000, fp: None, rank: 0 }
        }
        fn key(mut self, key: &'static str) -> S {
            self.key = key;
            self
        }
        fn album(mut self, album: &'static str) -> S {
            self.album = album;
            self
        }
        fn track(mut self, track: i64) -> S {
            self.track = track;
            self
        }
        fn ms(mut self, ms: i64) -> S {
            self.ms = ms;
            self
        }
        fn fp(mut self, fp: &'static str) -> S {
            self.fp = Some(fp);
            self
        }
        fn rank(mut self, rank: i64) -> S {
            self.rank = rank;
            self
        }
        fn song(self) -> Song {
            Song {
                path: self.path.into(),
                song_key: self.key.into(),
                album_key: self.album.into(),
                track: self.track,
                duration_ms: self.ms,
                fingerprint: self.fp.map(String::from),
                rank: self.rank,
            }
        }
    }

    fn songs(list: Vec<S>) -> Vec<Song> {
        list.into_iter().map(S::song).collect()
    }

    fn map(pairs: &[Pair]) -> HashMap<String, String> {
        pairs.iter().map(|pair| (pair.local.clone(), pair.server.clone())).collect()
    }

    fn expect(pairs: &[Pair], wanted: &[(&str, &str)]) {
        let wanted: HashMap<String, String> =
            wanted.iter().map(|(local, server)| (local.to_string(), server.to_string())).collect();
        assert_eq!(map(pairs), wanted);
    }

    #[test]
    fn same_keys_album_and_length_pair() {
        let result = plan(&songs(vec![S::new("L/a.m4a").ms(200_400)]), &songs(vec![S::new("remote://s/1")]));
        expect(&result.pairs, &[("L/a.m4a", "remote://s/1")]);
        assert!(result.unmatched.is_empty());
    }

    #[test]
    fn length_beyond_tolerance_stays_on_the_device() {
        let result = plan(&songs(vec![S::new("L/a.m4a").ms(202_001)]), &songs(vec![S::new("remote://s/1")]));
        assert_eq!(result.unmatched, vec!["L/a.m4a"]);
    }

    #[test]
    fn length_at_tolerance_still_pairs() {
        let result = plan(&songs(vec![S::new("L/a.m4a").ms(202_000)]), &songs(vec![S::new("remote://s/1")]));
        expect(&result.pairs, &[("L/a.m4a", "remote://s/1")]);
    }

    #[test]
    fn another_album_with_another_track_number_stays_on_the_device() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a").album("hits").track(7)]),
            &songs(vec![S::new("remote://s/1").track(1)]),
        );
        assert_eq!(result.unmatched, vec!["L/a.m4a"]);
    }

    #[test]
    fn another_album_without_a_track_number_stays_on_the_device() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a").album("hits").track(0)]),
            &songs(vec![S::new("remote://s/1").track(0)]),
        );
        assert_eq!(result.unmatched, vec!["L/a.m4a"]);
    }

    #[test]
    fn same_track_number_pairs_across_a_disc_suffix() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a").album("ost disc 2").track(24).ms(75_700)]),
            &songs(vec![S::new("remote://s/1").album("ost").track(24).ms(75_000)]),
        );
        expect(&result.pairs, &[("L/a.m4a", "remote://s/1")]);
    }

    #[test]
    fn same_album_beats_another_album_with_the_same_track_number() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a").track(3)]),
            &songs(vec![
                S::new("remote://s/1").album("best of").track(3),
                S::new("remote://s/2").track(9),
            ]),
        );
        expect(&result.pairs, &[("L/a.m4a", "remote://s/2")]);
    }

    #[test]
    fn another_song_key_stays_on_the_device() {
        let result = plan(&songs(vec![S::new("L/a.m4a").key("x")]), &songs(vec![S::new("remote://s/1").key("y")]));
        assert_eq!(result.unmatched, vec!["L/a.m4a"]);
    }

    #[test]
    fn empty_song_key_never_pairs_by_metadata() {
        let result = plan(&songs(vec![S::new("L/a.m4a").key("")]), &songs(vec![S::new("remote://s/1").key("")]));
        assert_eq!(result.unmatched, vec!["L/a.m4a"]);
    }

    #[test]
    fn same_audio_pairs_whatever_the_album_and_length_say() {
        let result = plan(
            &songs(vec![S::new("L/a.flac").album("other").track(4).ms(10_000).fp("flac:abc")]),
            &songs(vec![S::new("remote://s/1").track(1).fp("flac:abc")]),
        );
        expect(&result.pairs, &[("L/a.flac", "remote://s/1")]);
    }

    #[test]
    fn same_audio_under_another_song_key_stays_on_the_device() {
        let result = plan(
            &songs(vec![S::new("L/a.flac").key("x").fp("flac:abc")]),
            &songs(vec![S::new("remote://s/1").key("y").fp("flac:abc")]),
        );
        assert_eq!(result.unmatched, vec!["L/a.flac"]);
    }

    #[test]
    fn same_audio_wins_over_metadata() {
        let result = plan(
            &songs(vec![S::new("L/a.flac").fp("flac:abc")]),
            &songs(vec![S::new("remote://s/1"), S::new("remote://s/2").fp("flac:abc")]),
        );
        expect(&result.pairs, &[("L/a.flac", "remote://s/2")]);
    }

    #[test]
    fn a_second_copy_on_the_device_is_a_duplicate_of_the_pair() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a"), S::new("L/b.m4a")]),
            &songs(vec![S::new("remote://s/1")]),
        );
        expect(&result.pairs, &[("L/a.m4a", "remote://s/1")]);
        expect(&result.duplicates, &[("L/b.m4a", "remote://s/1")]);
        assert!(result.unmatched.is_empty());
    }

    #[test]
    fn the_copy_the_person_uses_becomes_the_pair() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a"), S::new("L/b.m4a").rank(3)]),
            &songs(vec![S::new("remote://s/1")]),
        );
        expect(&result.pairs, &[("L/b.m4a", "remote://s/1")]);
        expect(&result.duplicates, &[("L/a.m4a", "remote://s/1")]);
    }

    #[test]
    fn the_copy_on_the_watch_beats_a_closer_length() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a"), S::new("L/b.m4a").ms(201_000).rank(9)]),
            &songs(vec![S::new("remote://s/1")]),
        );
        expect(&result.pairs, &[("L/b.m4a", "remote://s/1")]);
        expect(&result.duplicates, &[("L/a.m4a", "remote://s/1")]);
    }

    #[test]
    fn closer_length_decides_between_copies_used_alike() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a").ms(201_000), S::new("L/b.m4a")]),
            &songs(vec![S::new("remote://s/1")]),
        );
        expect(&result.pairs, &[("L/b.m4a", "remote://s/1")]);
    }

    #[test]
    fn another_album_beyond_a_second_stays_on_the_device() {
        let result = plan(
            &songs(vec![S::new("L/live.m4a").album("x live").track(3).ms(119_600)]),
            &songs(vec![S::new("remote://s/1").album("x").track(3).ms(120_800)]),
        );
        assert_eq!(result.unmatched, vec!["L/live.m4a"]);
    }

    #[test]
    fn track_number_sorts_twins_on_one_album() {
        let result = plan(
            &songs(vec![S::new("L/2-intro.m4a").track(1).ms(61_000), S::new("L/1-intro.m4a").track(9).ms(60_000)]),
            &songs(vec![S::new("remote://s/a").track(9).ms(61_000), S::new("remote://s/b").track(1).ms(60_000)]),
        );
        expect(&result.pairs, &[("L/2-intro.m4a", "remote://s/b"), ("L/1-intro.m4a", "remote://s/a")]);
    }

    #[test]
    fn closest_length_wins_when_track_numbers_do_not_help() {
        let result = plan(
            &songs(vec![S::new("L/a.m4a").track(0).ms(100_000), S::new("L/b.m4a").track(0).ms(101_500)]),
            &songs(vec![S::new("remote://s/1").track(0).ms(101_000), S::new("remote://s/2").track(0).ms(100_000)]),
        );
        expect(&result.pairs, &[("L/a.m4a", "remote://s/2"), ("L/b.m4a", "remote://s/1")]);
    }

    #[test]
    fn order_of_arrival_does_not_change_the_pairs() {
        let local = songs(vec![S::new("L/a.m4a"), S::new("L/b.m4a").ms(200_500), S::new("L/c.m4a").ms(199_000)]);
        let server = songs(vec![S::new("remote://s/1"), S::new("remote://s/2").ms(201_000)]);
        let forward = plan(&local, &server);
        let mut local_reversed = local.clone();
        local_reversed.reverse();
        let mut server_reversed = server.clone();
        server_reversed.reverse();
        assert_eq!(forward, plan(&local_reversed, &server_reversed));
        expect(&forward.pairs, &[("L/a.m4a", "remote://s/1"), ("L/b.m4a", "remote://s/2")]);
        expect(&forward.duplicates, &[("L/c.m4a", "remote://s/1")]);
        assert!(forward.unmatched.is_empty());
    }

    #[test]
    fn nothing_on_the_server_leaves_every_song_sorted() {
        let result = plan(&songs(vec![S::new("L/b.m4a"), S::new("L/a.m4a")]), &[]);
        assert!(result.pairs.is_empty());
        assert!(result.duplicates.is_empty());
        assert_eq!(result.unmatched, vec!["L/a.m4a", "L/b.m4a"]);
    }
}
