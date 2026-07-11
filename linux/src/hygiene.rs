use crate::library::{Album, Track};
use crate::wantlist::{base_title_with, normalize};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::path::Path;

/// The consolidation keyword set = the wantlist `EDITION_KEYWORDS` minus
/// {single, ep, with, feat, ft., version}, plus the past-tense/plural edition
/// forms the exact-word matcher would otherwise miss ("Remastered",
/// "Remixes"). Dropping single/version keeps genuinely distinct records apart
/// (a "Single", an "Acoustic Version", a "feat." remix) while still fusing
/// pressings, remasters and explicit/clean variants. Must stay in sync with the
/// macOS `LibraryHygiene.consolidationKeywords`.
pub const CONSOLIDATION_KEYWORDS: [&str; 25] = [
    "deluxe", "edition", "remaster", "bonus", "expanded", "anniversary", "special", "extended",
    "complete", "reissue", "collector", "platinum", "legacy", "super", "tour", "explicit", "clean",
    "mono", "stereo", "remastered", "remasters", "remix", "remixed", "remixes", "reissued",
];

type QualityRank = (u8, i64, i64, i64, u64);

pub struct DuplicateGroup {
    pub keeper: Track,
    pub losers: Vec<Track>,
    pub loved: bool,
    pub play_count: i64,
}

#[derive(Clone)]
pub struct AlbumVariant {
    pub title: String,
    pub artist: String,
}

pub struct ConsolidationGroup {
    pub canonical_title: String,
    pub artist: String,
    pub variants: Vec<AlbumVariant>,
}

/// The edition-free base title under the consolidation keyword set.
pub fn consolidation_base_title(title: &str) -> String {
    base_title_with(title, &CONSOLIDATION_KEYWORDS)
}

/// The lead artist of a possibly-collaborative credit: the portion before the
/// first unambiguous multi-artist separator (";", " / ", " × "), with any
/// trailing "feat."/"featuring"/"vs" clause stripped. Single names containing
/// "&" or "," ("Corvid & Crane") are preserved. Mirrors the macOS
/// `LibraryHygiene.primaryArtist`.
pub fn primary_artist(raw: &str) -> String {
    let lower = raw.to_lowercase();
    let mut cut = raw.len();
    for sep in [
        ";", " / ", " \u{00D7} ", " x ", " & ", " + ", " vs. ", " vs ", " feat. ", " feat ", " ft. ",
        " ft ", " featuring ", " (feat.", " (ft.", " (featuring", " with ",
    ] {
        if let Some(idx) = lower.find(sep) {
            cut = cut.min(idx);
        }
    }
    let result = raw[..cut].trim();
    if result.is_empty() {
        raw.trim().to_string()
    } else {
        result.to_string()
    }
}

/// Case-insensitive artist grouping key, folding collaborators and casing
/// variants ("deadmau5" / "Deadmau5") together.
pub fn artist_key(credit: &str) -> String {
    primary_artist(credit).to_lowercase()
}

/// The grouping key that fuses editions of the same release for display and
/// cleanup: artist ⊕ edition-free base title, exact base-title equality.
pub fn consolidation_key(title: &str, artist: &str) -> String {
    format!("{}\u{0}{}", normalize(artist), consolidation_base_title(title))
}

/// The identity of one physical track across encodings: artist ⊕ edition-free
/// album ⊕ track number ⊕ title. Two files sharing it are the same recording.
pub fn dup_key(track: &Track) -> String {
    format!(
        "{}\u{0}{}\u{0}{}\u{0}{}",
        normalize(&track.artist),
        consolidation_base_title(&track.album),
        track.track_number,
        normalize(&track.title)
    )
}

pub fn is_lossless(codec: Option<&str>) -> bool {
    matches!(
        codec.map(|c| c.to_uppercase()),
        Some(ref c) if ["FLAC", "ALAC", "WAV", "AIFF", "AIF"].contains(&c.as_str())
    )
}

/// Ranks a track's fidelity as a tuple compared field-by-field, higher wins:
/// lossless, then bit depth, sample rate, channel count, and finally file size.
pub fn quality_rank(track: &Track, root: &Path) -> QualityRank {
    let size = std::fs::metadata(root.join(&track.rel_path))
        .map(|meta| meta.len())
        .unwrap_or(0);
    (
        is_lossless(track.codec.as_deref()) as u8,
        track.bit_depth.unwrap_or(0) as i64,
        track.sample_rate.unwrap_or(0) as i64,
        track.channels.unwrap_or(0) as i64,
        size,
    )
}

/// Groups library tracks that are the same recording in multiple encodings.
/// Members of a `dup_key` are only fused when their durations cluster within
/// ±2s (guarding against different edits sharing a title); a group keeps the
/// highest-fidelity copy and lists the rest as removable losers.
pub fn find_duplicate_groups(tracks: &[Track], root: &Path) -> Vec<DuplicateGroup> {
    let mut by_key: HashMap<String, Vec<&Track>> = HashMap::new();
    for track in tracks {
        by_key.entry(dup_key(track)).or_default().push(track);
    }
    let mut groups = Vec::new();
    for members in by_key.into_values() {
        if members.len() < 2 {
            continue;
        }
        for cluster in duration_clusters(members) {
            if cluster.len() < 2 {
                continue;
            }
            groups.push(build_duplicate_group(cluster, root));
        }
    }
    groups.sort_by(|a, b| a.keeper.rel_path.cmp(&b.keeper.rel_path));
    groups
}

fn duration_clusters<'a>(mut members: Vec<&'a Track>) -> Vec<Vec<&'a Track>> {
    members.sort_by(|a, b| {
        a.duration
            .partial_cmp(&b.duration)
            .unwrap_or(Ordering::Equal)
            .then(a.id.cmp(&b.id))
    });
    let mut clusters = Vec::new();
    let mut current: Vec<&Track> = Vec::new();
    let mut previous: Option<f64> = None;
    for track in members {
        if let Some(previous) = previous {
            if track.duration - previous > 2.0 {
                clusters.push(std::mem::take(&mut current));
            }
        }
        previous = Some(track.duration);
        current.push(track);
    }
    if !current.is_empty() {
        clusters.push(current);
    }
    clusters
}

fn build_duplicate_group(cluster: Vec<&Track>, root: &Path) -> DuplicateGroup {
    let mut ranked: Vec<(QualityRank, &Track)> = cluster
        .iter()
        .map(|track| (quality_rank(track, root), *track))
        .collect();
    ranked.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then(a.1.id.cmp(&b.1.id))
            .then(a.1.rel_path.cmp(&b.1.rel_path))
    });
    let loved = cluster.iter().any(|track| track.loved);
    let play_count = cluster.iter().map(|track| track.play_count).max().unwrap_or(0);
    let keeper = ranked[0].1.clone();
    let losers = ranked[1..].iter().map(|(_, track)| (*track).clone()).collect();
    DuplicateGroup {
        keeper,
        losers,
        loved,
        play_count,
    }
}

/// Groups albums that are editions of one release. Only groups with two or more
/// distinct raw titles are returned; the canonical is the fullest pressing
/// (most tracks, then the cleanest/shortest title, then the highest fidelity).
pub fn consolidation_groups(albums: &[Album]) -> Vec<ConsolidationGroup> {
    let mut by_key: HashMap<String, Vec<&Album>> = HashMap::new();
    for album in albums {
        by_key
            .entry(consolidation_key(&album.title, &album.artist))
            .or_default()
            .push(album);
    }
    let mut groups = Vec::new();
    for members in by_key.into_values() {
        let distinct: HashSet<&str> = members.iter().map(|album| album.title.as_str()).collect();
        if distinct.len() < 2 {
            continue;
        }
        let canonical = canonical_album(&members);
        let mut seen: HashSet<String> = HashSet::new();
        let mut variants: Vec<AlbumVariant> = members
            .iter()
            .filter(|album| album.title != canonical.title)
            .filter(|album| seen.insert(album.title.clone()))
            .map(|album| AlbumVariant {
                title: album.title.clone(),
                artist: album.artist.clone(),
            })
            .collect();
        variants.sort_by(|a, b| a.title.cmp(&b.title));
        groups.push(ConsolidationGroup {
            canonical_title: canonical.title.clone(),
            artist: canonical.artist.clone(),
            variants,
        });
    }
    groups.sort_by(|a, b| {
        a.artist
            .cmp(&b.artist)
            .then(a.canonical_title.cmp(&b.canonical_title))
    });
    groups
}

/// Fuses editions of the same release into one display album: the canonical
/// title/artist, the union of every variant's tracks deduplicated by `dup_key`
/// keeping the highest-fidelity copy, and the richest available metadata. Uses
/// the codec/bit-depth/sample-rate fidelity scalar (no filesystem access) so it
/// is cheap enough to run inside every library load.
pub fn consolidate_albums(albums: Vec<Album>) -> Vec<Album> {
    let mut order: Vec<String> = Vec::new();
    let mut by_key: HashMap<String, Vec<Album>> = HashMap::new();
    for album in albums {
        let key = consolidation_key(&album.title, &album.artist);
        if !by_key.contains_key(&key) {
            order.push(key.clone());
        }
        by_key.entry(key).or_default().push(album);
    }
    let mut result = Vec::new();
    for key in order {
        let group = by_key.remove(&key).expect("keyed group present");
        if group.len() == 1 {
            result.push(group.into_iter().next().expect("single member"));
        } else {
            result.push(merge_album_group(group));
        }
    }
    result
}

fn merge_album_group(group: Vec<Album>) -> Album {
    let canonical = group
        .iter()
        .enumerate()
        .max_by(|(_, a), (_, b)| {
            a.tracks
                .len()
                .cmp(&b.tracks.len())
                .then((b.title.len()).cmp(&a.title.len()))
                .then(album_quality(a).cmp(&album_quality(b)))
        })
        .map(|(index, _)| index)
        .unwrap_or(0);
    let title = group[canonical].title.clone();
    let artist = group[canonical].artist.clone();
    let year = group[canonical]
        .year
        .clone()
        .filter(|value| !value.is_empty())
        .or_else(|| group.iter().find_map(|album| album.year.clone().filter(|v| !v.is_empty())));
    let genre = group[canonical]
        .genre
        .clone()
        .filter(|value| !value.is_empty())
        .or_else(|| group.iter().find_map(|album| album.genre.clone().filter(|v| !v.is_empty())));

    let mut order: Vec<String> = Vec::new();
    let mut best: HashMap<String, Track> = HashMap::new();
    for album in &group {
        for track in &album.tracks {
            let key = dup_key(track);
            match best.get(&key) {
                Some(existing) if track_quality_scalar(existing) >= track_quality_scalar(track) => {}
                Some(_) => {
                    best.insert(key, track.clone());
                }
                None => {
                    order.push(key.clone());
                    best.insert(key, track.clone());
                }
            }
        }
    }
    let mut tracks: Vec<Track> = order
        .into_iter()
        .filter_map(|key| best.remove(&key))
        .collect();
    tracks.sort_by(|a, b| {
        a.track_number
            .cmp(&b.track_number)
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });
    Album {
        title,
        artist,
        year,
        genre,
        tracks,
    }
}

fn canonical_album<'a>(members: &[&'a Album]) -> &'a Album {
    members
        .iter()
        .copied()
        .max_by(|a, b| {
            a.tracks
                .len()
                .cmp(&b.tracks.len())
                .then((b.title.len()).cmp(&a.title.len()))
                .then(album_quality(a).cmp(&album_quality(b)))
        })
        .expect("consolidation group is non-empty")
}

fn album_quality(album: &Album) -> i64 {
    album.tracks.iter().map(track_quality_scalar).sum()
}

fn track_quality_scalar(track: &Track) -> i64 {
    (is_lossless(track.codec.as_deref()) as i64) * 1_000_000_000
        + (track.bit_depth.unwrap_or(0) as i64) * 1_000_000
        + track.sample_rate.unwrap_or(0) as i64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn artist_key_folds_collaborators_and_casing() {
        let base = artist_key("deadmau5");
        assert_eq!(artist_key("Deadmau5"), base, "casing variants group together");
        assert_eq!(artist_key("deadmau5 & Kaskade"), base, "& collaborations fold under the lead");
        assert_eq!(artist_key("deadmau5 feat. Rob Swire"), base, "feat. folds under the lead");
        assert_eq!(artist_key("Deadmau5 x Skrillex"), base, "x collaborations fold under the lead");
        assert_eq!(
            primary_artist("Billy Newton-Davis vs. Deadmau5"),
            "Billy Newton-Davis",
            "the first-named artist wins"
        );
    }

    fn track(title: &str, artist: &str, album: &str, number: i32, codec: &str) -> Track {
        detailed_track(title, artist, album, number, codec, None, None)
    }

    fn detailed_track(
        title: &str,
        artist: &str,
        album: &str,
        number: i32,
        codec: &str,
        bit_depth: Option<i32>,
        sample_rate: Option<i32>,
    ) -> Track {
        Track {
            id: 0,
            rel_path: format!("{artist}/{album}/{number}-{title}.{codec}"),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            track_number: number,
            duration: 200.0,
            codec: Some(codec.to_string()),
            bit_depth,
            sample_rate,
            channels: Some(2),
            loved: false,
            play_count: 0,
        }
    }

    fn album(title: &str, artist: &str, track_count: usize) -> Album {
        let tracks = (1..=track_count)
            .map(|n| track(&format!("T{n}"), artist, title, n as i32, "flac"))
            .collect();
        Album {
            title: title.to_string(),
            artist: artist.to_string(),
            year: None,
            genre: None,
            tracks,
        }
    }

    #[test]
    fn consolidation_merges_edition_variants() {
        let base = consolidation_key("Album", "Artist");
        for variant in [
            "Album (Deluxe)",
            "Album (Deluxe Edition)",
            "Album (Remaster)",
            "Album [Explicit]",
        ] {
            assert_eq!(
                consolidation_key(variant, "Artist"),
                base,
                "'{variant}' must collapse to the base release key"
            );
        }
    }

    #[test]
    fn consolidation_keeps_distinct_releases_apart() {
        let base = consolidation_key("X", "Artist");
        assert_ne!(
            consolidation_key("Greatest Hits Vol. 1", "Artist"),
            consolidation_key("Greatest Hits Vol. 2", "Artist"),
            "numbered volumes are different records"
        );
        assert_ne!(consolidation_key("X - Single", "Artist"), base, "a single is not the album");
        assert_ne!(
            consolidation_key("X (Acoustic Version)", "Artist"),
            base,
            "an acoustic version is a different recording"
        );
    }

    #[test]
    fn remastered_and_remix_forms_consolidate() {
        let base = consolidation_key("Album", "Artist");
        for variant in ["Album (Remastered)", "Album (2011 Remaster)", "Album (Remixes)"] {
            assert_eq!(
                consolidation_key(variant, "Artist"),
                base,
                "common past-tense/plural edition forms fold into the album"
            );
        }
    }

    #[test]
    fn duplicate_group_keeps_highest_fidelity() {
        let root = std::path::Path::new("/nonexistent-hygiene-root");
        let hi = detailed_track("Song", "Artist", "Album", 1, "flac", Some(24), Some(96000));
        let mid = detailed_track("Song", "Artist", "Album", 1, "flac", Some(16), Some(44100));
        let lossy = detailed_track("Song", "Artist", "Album", 1, "mp3", None, Some(44100));
        let groups = find_duplicate_groups(&[mid.clone(), lossy.clone(), hi.clone()], root);
        assert_eq!(groups.len(), 1, "the three encodings are one recording");
        let group = &groups[0];
        assert_eq!(group.keeper.codec.as_deref(), Some("flac"));
        assert_eq!(group.keeper.bit_depth, Some(24));
        assert_eq!(group.keeper.sample_rate, Some(96000));
        assert_eq!(group.losers.len(), 2);
    }

    #[test]
    fn duplicate_group_respects_duration_clusters() {
        let root = std::path::Path::new("/nonexistent-hygiene-root");
        let mut short = track("Song", "Artist", "Album", 1, "flac");
        short.duration = 180.0;
        let mut near = track("Song", "Artist", "Album", 1, "mp3");
        near.duration = 181.0;
        let mut long = track("Song", "Artist", "Album", 1, "mp3");
        long.duration = 600.0;
        let groups = find_duplicate_groups(&[short, near, long], root);
        assert_eq!(groups.len(), 1, "the 600s edit must not fuse with the 180s pair");
        assert_eq!(groups[0].losers.len(), 1);
    }

    #[test]
    fn consolidation_groups_pick_fullest_canonical() {
        let albums = vec![
            album("Album", "Artist", 10),
            album("Album (Deluxe Edition)", "Artist", 15),
            album("Unrelated", "Artist", 8),
        ];
        let groups = consolidation_groups(&albums);
        assert_eq!(groups.len(), 1, "only the two-variant release consolidates");
        let group = &groups[0];
        assert_eq!(group.canonical_title, "Album (Deluxe Edition)", "the fuller pressing wins");
        assert_eq!(group.variants.len(), 1);
        assert_eq!(group.variants[0].title, "Album");
    }

    #[test]
    fn consolidation_canonical_prefers_shorter_title_on_track_tie() {
        let albums = vec![
            album("Album (Deluxe Edition)", "Artist", 12),
            album("Album", "Artist", 12),
        ];
        let groups = consolidation_groups(&albums);
        assert_eq!(groups.len(), 1);
        assert_eq!(
            groups[0].canonical_title, "Album",
            "equal track counts fall back to the cleaner title"
        );
    }

    #[test]
    fn dup_key_ignores_edition_decoration_on_album() {
        let plain = track("Song", "Artist", "Album", 3, "flac");
        let deluxe = track("Song", "Artist", "Album (Deluxe Edition)", 3, "mp3");
        assert_eq!(dup_key(&plain), dup_key(&deluxe));
    }
}
