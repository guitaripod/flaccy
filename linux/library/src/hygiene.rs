use crate::library::{Album, Track};
use crate::keys::{base_title_with, normalize};
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
    "deluxe",
    "edition",
    "remaster",
    "bonus",
    "expanded",
    "anniversary",
    "special",
    "extended",
    "complete",
    "reissue",
    "collector",
    "platinum",
    "legacy",
    "super",
    "tour",
    "explicit",
    "clean",
    "mono",
    "stereo",
    "remastered",
    "remasters",
    "remix",
    "remixed",
    "remixes",
    "reissued",
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
    primary_artist_slice(raw).to_string()
}

const ASCII_ARTIST_SEPARATORS: [&str; 16] = [
    ";",
    " / ",
    " x ",
    " & ",
    " + ",
    " vs. ",
    " vs ",
    " feat. ",
    " feat ",
    " ft. ",
    " ft ",
    " featuring ",
    " (feat.",
    " (ft.",
    " (featuring",
    " with ",
];

const CROSS_ARTIST_SEPARATOR: &str = " \u{00D7} ";

/// `primary_artist` without the allocation: the trimmed lead of `raw`, or all
/// of it trimmed when the lead is empty.
pub fn primary_artist_slice(raw: &str) -> &str {
    let cut = if raw.is_ascii() {
        ascii_separator_start(raw.as_bytes())
    } else {
        lowered_separator_start(raw)
    };
    let lead = raw[..cut].trim();
    if lead.is_empty() {
        raw.trim()
    } else {
        lead
    }
}

/// Where the first separator begins in an all-ASCII credit, matched without
/// regard to case and without lowercasing a copy. The "×" separator cannot
/// occur in ASCII text.
fn ascii_separator_start(raw: &[u8]) -> usize {
    (0..raw.len())
        .find(|&at| {
            matches!(raw[at], b';' | b' ' | b'(')
                && ASCII_ARTIST_SEPARATORS.iter().any(|separator| {
                    raw[at..]
                        .get(..separator.len())
                        .is_some_and(|window| window.eq_ignore_ascii_case(separator.as_bytes()))
                })
        })
        .unwrap_or(raw.len())
}

/// The separator search for credits with non-ASCII text, run on a lowercased
/// copy and mapped back to `raw`'s own offsets: a character whose lowercase
/// has a different UTF-8 length (`İ`, `ẞ`, the Kelvin sign) must not shift
/// the cut, or the slice lands mid-character.
fn lowered_separator_start(raw: &str) -> usize {
    let (lower, origins) = lowercase_with_origins(raw);
    let mut cut = raw.len();
    for separator in ASCII_ARTIST_SEPARATORS
        .iter()
        .copied()
        .chain(std::iter::once(CROSS_ARTIST_SEPARATOR))
    {
        if let Some(index) = lower.find(separator) {
            cut = cut.min(origins[index]);
        }
    }
    cut
}

/// `raw` lowercased, with the byte offset in `raw` of the character each byte
/// of the lowercase came from.
fn lowercase_with_origins(raw: &str) -> (String, Vec<usize>) {
    let mut lower = String::with_capacity(raw.len());
    let mut origins = Vec::with_capacity(raw.len());
    for (at, ch) in raw.char_indices() {
        for lowered in ch.to_lowercase() {
            lower.push(lowered);
            origins.resize(lower.len(), at);
        }
    }
    (lower, origins)
}

/// Aggressive artist grouping key: the lead artist, diacritic-folded and
/// stripped of case, whitespace and punctuation, so "deadmau5"/"Deadmau5",
/// "Beyoncé"/"Beyonce", "Jay-Z"/"Jay Z" and "deadmau5 & Kaskade" all collapse
/// to one artist.
pub fn artist_key(credit: &str) -> String {
    normalize(primary_artist_slice(credit))
}

/// The grouping key that fuses editions of the same release for display and
/// cleanup: lead artist (feat. stripped) ⊕ edition-free base title.
pub fn consolidation_key(title: &str, artist: &str) -> String {
    format!(
        "{}\u{0}{}",
        artist_key(artist),
        consolidation_base_title(title)
    )
}

/// The identity of one physical track across encodings: lead artist ⊕ edition-free
/// album ⊕ track number ⊕ title. Two files sharing it are the same recording.
pub fn dup_key(track: &Track) -> String {
    format!(
        "{}\u{0}{}\u{0}{}\u{0}{}",
        artist_key(&track.artist),
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
    let play_count = cluster
        .iter()
        .map(|track| track.play_count)
        .max()
        .unwrap_or(0);
    let keeper = ranked[0].1.clone();
    let losers = ranked[1..]
        .iter()
        .map(|(_, track)| (*track).clone())
        .collect();
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
        .or_else(|| {
            group
                .iter()
                .find_map(|album| album.year.clone().filter(|v| !v.is_empty()))
        });
    let genre = group[canonical]
        .genre
        .clone()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            group
                .iter()
                .find_map(|album| album.genre.clone().filter(|v| !v.is_empty()))
        });

    let mut order: Vec<String> = Vec::new();
    let mut best: HashMap<String, Track> = HashMap::new();
    for album in &group {
        for track in &album.tracks {
            let key = dup_key(track);
            match best.get(&key) {
                Some(existing) if track_quality_scalar(existing) >= track_quality_scalar(track) => {
                }
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
        .map(|mut track| {
            track.album = title.clone();
            track.artist = artist.clone();
            track
        })
        .collect();
    crate::library::sort_album_tracks(&mut tracks);
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

/// What marks a bracketed or dashed title suffix as the same recording
/// re-released. Live, acoustic, demo, instrumental and remix are left out on
/// purpose: those are different recordings of the song. Must stay in sync with
/// the Apple `LibraryHygiene.songEditionKeywords`.
pub const SONG_EDITION_KEYWORDS: [&str; 17] = [
    "remaster",
    "remastered",
    "remasters",
    "mono",
    "stereo",
    "explicit",
    "clean",
    "deluxe",
    "edition",
    "bonus",
    "reissue",
    "reissued",
    "expanded",
    "anniversary",
    "feat",
    "featuring",
    "ft.",
];

/// Copies of one song whose lengths differ by more than this many seconds are
/// different recordings even when title and artist agree.
pub const SONG_DURATION_TOLERANCE: f64 = 3.0;

/// The identity of a song regardless of the release it sits on: the lead
/// artist and the title with re-release decoration removed.
pub fn song_key(title: &str, artist: &str) -> String {
    format!(
        "{}\u{0}{}",
        artist_key(artist),
        base_title_with(title, &SONG_EDITION_KEYWORDS)
    )
}

/// Remembers the `song_key` of every spelling it is asked about, because
/// folding a title is the costly step of a pass over a whole library and the
/// Songs list asks again on every keystroke.
#[derive(Default)]
pub struct SongKeyMemo {
    keys: HashMap<(String, String), String>,
}

impl SongKeyMemo {
    pub fn key(&mut self, title: &str, artist: &str) -> &str {
        self.keys
            .entry((title.to_string(), artist.to_string()))
            .or_insert_with(|| song_key(title, artist))
    }
}

/// The songs a duplicate pass hid and the copies standing behind each keeper.
#[derive(Default)]
pub struct DuplicateSongs {
    pub hidden: HashSet<String>,
    pub copies: HashMap<String, Vec<Track>>,
}

/// Finds the copies of every song in `tracks` that should be hidden behind one
/// keeper. Same song means the same `song_key` with lengths that chain together
/// within `SONG_DURATION_TOLERANCE`. The keeper is the copy `prefers` ranks
/// highest (the one the person loved or plays), then the highest fidelity, then
/// the oldest row. Songs on a server and songs in the music folder are one
/// pool: a server's copy is as much a duplicate as a local one.
pub fn collapsing_duplicate_songs<'a>(
    tracks: impl IntoIterator<Item = &'a Track>,
    memo: &mut SongKeyMemo,
    prefers: impl Fn(&Track) -> i32,
) -> DuplicateSongs {
    let mut by_key: HashMap<String, Vec<&Track>> = HashMap::new();
    for track in tracks.into_iter().filter(|track| !track.title.is_empty()) {
        let key = memo.key(&track.title, &track.artist).to_string();
        by_key.entry(key).or_default().push(track);
    }
    let mut found = DuplicateSongs::default();
    for mut members in by_key.into_values().filter(|members| members.len() >= 2) {
        members.sort_by(|a, b| a.duration.total_cmp(&b.duration));
        let mut cluster: Vec<&Track> = Vec::new();
        for track in members {
            let breaks = cluster
                .last()
                .is_some_and(|last| track.duration - last.duration > SONG_DURATION_TOLERANCE);
            if breaks {
                hide_copies(std::mem::take(&mut cluster), &prefers, &mut found);
            }
            cluster.push(track);
        }
        hide_copies(cluster, &prefers, &mut found);
    }
    found
}

/// Ranks one run of copies and records every one but the keeper as hidden.
fn hide_copies(mut cluster: Vec<&Track>, prefers: &impl Fn(&Track) -> i32, found: &mut DuplicateSongs) {
    if cluster.len() < 2 {
        return;
    }
    cluster.sort_by(|a, b| {
        prefers(b)
            .cmp(&prefers(a))
            .then_with(|| track_quality_scalar(b).cmp(&track_quality_scalar(a)))
            .then_with(|| a.id.cmp(&b.id))
            .then_with(|| a.rel_path.cmp(&b.rel_path))
    });
    let keeper = cluster[0].rel_path.clone();
    let losers: Vec<Track> = cluster[1..].iter().map(|track| (*track).clone()).collect();
    found
        .hidden
        .extend(losers.iter().map(|track| track.rel_path.clone()));
    found.copies.insert(keeper, losers);
}

/// A pool for stations and suggestions with each song once, so a queue built
/// from it never plays the same recording twice. Tracks in `preferring` always
/// survive as the copy of their song, which lets the caller then exclude them
/// without a hidden twin slipping back in.
pub fn unique_pool(pool: &[Track], preferring: &[Track]) -> Vec<Track> {
    let preferred: HashSet<&str> = preferring.iter().map(|track| track.rel_path.as_str()).collect();
    let found = collapsing_duplicate_songs(pool, &mut SongKeyMemo::default(), |track| {
        i32::from(preferred.contains(track.rel_path.as_str()))
    });
    if found.hidden.is_empty() {
        return pool.to_vec();
    }
    pool.iter()
        .filter(|track| !found.hidden.contains(&track.rel_path))
        .cloned()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::keys::legacy_keys;

    /// Whether lowercasing `text` changes some character's UTF-8 length, the
    /// one case where the old offsets were wrong (or panicked) and the new
    /// ones are meant to differ.
    fn lowercase_shifts_offsets(text: &str) -> bool {
        text.chars()
            .any(|ch| ch.to_lowercase().map(char::len_utf8).sum::<usize>() != ch.len_utf8())
    }

    fn assert_same_keys(text: &str) {
        let owned = text.to_string();
        if lowercase_shifts_offsets(text) {
            assert!(legacy_keys::outcome(|| artist_key(&owned)).is_some(), "artist_key {text:?}");
            return;
        }
        let old_lead = legacy_keys::outcome(|| legacy_keys::primary_artist(&owned));
        let new_lead = legacy_keys::outcome(|| primary_artist(&owned));
        assert_eq!(new_lead, old_lead, "primary_artist {text:?}");
        let old_key = legacy_keys::outcome(|| legacy_keys::artist_key(&owned));
        let new_key = legacy_keys::outcome(|| artist_key(&owned));
        assert_eq!(new_key, old_key, "artist_key {text:?}");
    }

    #[test]
    fn a_lowercase_that_changes_length_cuts_at_the_separator() {
        assert_eq!(primary_artist("İstanbul feat. Someone"), "İstanbul");
        assert_eq!(primary_artist("GROẞ & Klein"), "GROẞ");
        assert_eq!(primary_artist("\u{212A}ent ft. Guest"), "\u{212A}ent");
        assert_eq!(primary_artist("İİİ × B"), "İİİ");
    }

    #[test]
    fn artist_keys_match_the_original_over_the_corpus() {
        for text in legacy_keys::corpus() {
            assert_same_keys(&text);
        }
    }

    #[test]
    fn artist_keys_match_the_original_when_case_changes_byte_length() {
        for text in ["İ feat. X", "Kaskade İ & Y", "ΣΑΣ vs Z", "ǅ + Q", "ẞ / ſ"] {
            assert_same_keys(text);
        }
    }

    #[test]
    #[ignore]
    fn artist_keys_match_the_original_over_the_real_library() {
        for text in crate::library::perf_fixture::distinct_strings() {
            assert_same_keys(&text);
        }
    }


    #[test]
    fn artist_key_folds_collaborators_and_casing() {
        let base = artist_key("deadmau5");
        assert_eq!(
            artist_key("Deadmau5"),
            base,
            "casing variants group together"
        );
        assert_eq!(
            artist_key("deadmau5 & Kaskade"),
            base,
            "& collaborations fold under the lead"
        );
        assert_eq!(
            artist_key("deadmau5 feat. Rob Swire"),
            base,
            "feat. folds under the lead"
        );
        assert_eq!(
            artist_key("Deadmau5 x Skrillex"),
            base,
            "x collaborations fold under the lead"
        );
        assert_eq!(
            primary_artist("Billy Newton-Davis vs. Deadmau5"),
            "Billy Newton-Davis",
            "the first-named artist wins"
        );
        assert_eq!(
            artist_key("Beyoncé"),
            artist_key("Beyonce"),
            "diacritics fold"
        );
        assert_eq!(
            artist_key("Jay-Z"),
            artist_key("Jay Z"),
            "punctuation and whitespace fold"
        );
        assert_eq!(
            artist_key("Takahito Eguchi  & Noriko Matsueda"),
            artist_key("Takahito Eguchi & Noriko Matsueda"),
            "double-spaced collaborations fold"
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
            album_artist: None,
            track_number: number,
            duration: 200.0,
            codec: Some(codec.to_string()),
            bit_depth,
            sample_rate,
            channels: Some(2),
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
        assert_ne!(
            consolidation_key("X - Single", "Artist"),
            base,
            "a single is not the album"
        );
        assert_ne!(
            consolidation_key("X (Acoustic Version)", "Artist"),
            base,
            "an acoustic version is a different recording"
        );
    }

    #[test]
    fn remastered_and_remix_forms_consolidate() {
        let base = consolidation_key("Album", "Artist");
        for variant in [
            "Album (Remastered)",
            "Album (2011 Remaster)",
            "Album (Remixes)",
        ] {
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
        assert_eq!(
            groups.len(),
            1,
            "the 600s edit must not fuse with the 180s pair"
        );
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
        assert_eq!(
            group.canonical_title, "Album (Deluxe Edition)",
            "the fuller pressing wins"
        );
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

    #[test]
    fn featuring_credits_share_album_and_dup_keys() {
        let plain = track("In Da Club", "50 Cent", "Get Rich Or Die Tryin'", 5, "flac");
        let feat = track(
            "Patiently Waiting",
            "50 Cent Feat. Eminem",
            "Get Rich Or Die Tryin'",
            3,
            "flac",
        );
        let feat2 = track(
            "21 Questions",
            "50 Cent Feat. Nate Dogg",
            "Get Rich Or Die Tryin'",
            14,
            "flac",
        );
        assert_eq!(
            consolidation_key(&plain.album, &plain.artist),
            consolidation_key(&feat.album, &feat.artist),
            "feat. credits must not spawn a separate album key"
        );
        assert_eq!(
            consolidation_key(&feat.album, &feat.artist),
            consolidation_key(&feat2.album, &feat2.artist)
        );
        assert_eq!(artist_key("50 Cent Feat. Eminem"), artist_key("50 Cent"));
        assert_eq!(
            artist_key("50 Cent  Feat. Lloyd Banks Of G Unit & Eminem"),
            artist_key("50 Cent")
        );
    }

    #[test]
    fn consolidate_albums_keeps_best_copy_and_bonus_tracks() {
        let standard = Album {
            title: "Album".into(),
            artist: "Artist".into(),
            year: Some("2010".into()),
            genre: None,
            tracks: vec![
                detailed_track(
                    "Song A",
                    "Artist",
                    "Album",
                    1,
                    "flac",
                    Some(16),
                    Some(44100),
                ),
                detailed_track(
                    "Song B",
                    "Artist",
                    "Album",
                    2,
                    "flac",
                    Some(16),
                    Some(44100),
                ),
            ],
        };
        let deluxe = Album {
            title: "Album (Deluxe Edition)".into(),
            artist: "Artist".into(),
            year: None,
            genre: Some("Rock".into()),
            tracks: vec![
                detailed_track(
                    "Song A",
                    "Artist",
                    "Album (Deluxe Edition)",
                    1,
                    "flac",
                    Some(24),
                    Some(96000),
                ),
                detailed_track(
                    "Song B",
                    "Artist",
                    "Album (Deluxe Edition)",
                    2,
                    "flac",
                    Some(24),
                    Some(96000),
                ),
                detailed_track(
                    "Bonus",
                    "Artist",
                    "Album (Deluxe Edition)",
                    3,
                    "flac",
                    Some(24),
                    Some(96000),
                ),
            ],
        };
        let other = album("Unrelated", "Artist", 4);
        let result = consolidate_albums(vec![standard, deluxe, other]);
        assert_eq!(result.len(), 2, "unrelated album stays separate");
        let fused = result
            .iter()
            .find(|a| {
                consolidation_key(&a.title, &a.artist) == consolidation_key("Album", "Artist")
            })
            .expect("edition group fused");
        assert_eq!(fused.title, "Album (Deluxe Edition)");
        assert_eq!(
            fused.tracks.len(),
            3,
            "shared tracks collapse; bonus remains"
        );
        assert_eq!(fused.year.as_deref(), Some("2010"));
        assert_eq!(fused.genre.as_deref(), Some("Rock"));
        let song_a = fused.tracks.iter().find(|t| t.title == "Song A").unwrap();
        assert_eq!(song_a.bit_depth, Some(24));
        assert_eq!(song_a.sample_rate, Some(96000));
        assert_eq!(song_a.album, "Album (Deluxe Edition)");
    }

    fn song(
        title: &str,
        album: &str,
        id: i64,
        duration: f64,
        codec: &str,
        bit_depth: Option<i32>,
    ) -> Track {
        let mut track = detailed_track(title, "Aurelia Vance", album, 1, codec, bit_depth, Some(44_100));
        track.id = id;
        track.duration = duration;
        track
    }

    fn collapse(tracks: &[Track]) -> DuplicateSongs {
        collapsing_duplicate_songs(tracks, &mut SongKeyMemo::default(), |_| 0)
    }

    fn survivors(tracks: &[Track], found: &DuplicateSongs) -> Vec<i64> {
        tracks
            .iter()
            .filter(|track| !found.hidden.contains(&track.rel_path))
            .map(|track| track.id)
            .collect()
    }

    #[test]
    fn the_same_song_on_two_albums_collapses_to_one() {
        let tracks = [
            song("Glass Harbor", "Glass Harbor - Single", 1, 215.0, "flac", Some(16)),
            song("Glass Harbor", "Tidewater", 2, 216.0, "flac", Some(16)),
        ];
        let found = collapse(&tracks);
        assert_eq!(survivors(&tracks, &found), [1]);
        assert_eq!(found.copies.values().next().map(Vec::len), Some(1));
    }

    #[test]
    fn a_remaster_suffix_is_the_same_song() {
        let tracks = [
            song("Glass Harbor", "Tidewater", 1, 215.0, "flac", Some(16)),
            song("Glass Harbor (2011 Remaster)", "Tidewater Deluxe", 2, 215.0, "flac", Some(16)),
        ];
        assert_eq!(survivors(&tracks, &collapse(&tracks)).len(), 1);
    }

    #[test]
    fn live_and_acoustic_versions_stay_separate() {
        let tracks = [
            song("Glass Harbor", "Tidewater", 1, 215.0, "flac", Some(16)),
            song("Glass Harbor (Live)", "Live at the Pier", 2, 215.0, "flac", Some(16)),
            song("Glass Harbor - Acoustic", "Stripped", 3, 215.0, "flac", Some(16)),
        ];
        assert_eq!(survivors(&tracks, &collapse(&tracks)).len(), 3);
    }

    #[test]
    fn different_lengths_are_different_recordings() {
        let tracks = [
            song("Glass Harbor", "Singles", 1, 190.0, "flac", Some(16)),
            song("Glass Harbor", "Tidewater", 2, 261.0, "flac", Some(16)),
        ];
        assert_eq!(survivors(&tracks, &collapse(&tracks)).len(), 2);
    }

    #[test]
    fn lengths_that_chain_within_the_tolerance_are_one_recording() {
        let tracks = [
            song("Glass Harbor", "A", 1, 210.0, "flac", Some(16)),
            song("Glass Harbor", "B", 2, 212.5, "flac", Some(16)),
            song("Glass Harbor", "C", 3, 215.0, "flac", Some(16)),
        ];
        assert_eq!(survivors(&tracks, &collapse(&tracks)).len(), 1);
    }

    #[test]
    fn the_same_title_by_different_artists_stays_separate() {
        let first = song("Intro", "Tidewater", 1, 60.0, "flac", Some(16));
        let mut second = song("Intro", "Roost", 2, 60.0, "flac", Some(16));
        second.artist = "Corvid & Crane".to_string();
        let tracks = [first, second];
        assert_eq!(survivors(&tracks, &collapse(&tracks)).len(), 2);
    }

    #[test]
    fn the_keeper_is_the_highest_fidelity_copy() {
        let tracks = [
            song("Glass Harbor", "Hits", 1, 215.0, "mp3", None),
            song("Glass Harbor", "Tidewater", 2, 215.0, "flac", Some(24)),
        ];
        assert_eq!(survivors(&tracks, &collapse(&tracks)), [2]);
    }

    #[test]
    fn a_preferred_copy_beats_fidelity() {
        let tracks = [
            song("Glass Harbor", "Hits", 1, 215.0, "mp3", None),
            song("Glass Harbor", "Tidewater", 2, 215.0, "flac", Some(24)),
        ];
        let found = collapsing_duplicate_songs(&tracks, &mut SongKeyMemo::default(), |track| {
            i32::from(track.id == 1)
        });
        assert_eq!(survivors(&tracks, &found), [1]);
    }

    #[test]
    fn equal_copies_keep_the_oldest_row() {
        let tracks = [
            song("Glass Harbor", "B", 7, 215.0, "flac", Some(16)),
            song("Glass Harbor", "A", 3, 215.0, "flac", Some(16)),
        ];
        assert_eq!(survivors(&tracks, &collapse(&tracks)), [3]);
    }

    #[test]
    fn survivors_keep_the_list_order() {
        let mut bravo = song("Bravo", "One", 2, 200.0, "flac", Some(16));
        bravo.track_number = 2;
        let tracks = [
            song("Alpha", "One", 1, 200.0, "flac", Some(16)),
            bravo,
            song("Alpha", "Two", 3, 200.0, "mp3", None),
        ];
        assert_eq!(survivors(&tracks, &collapse(&tracks)), [1, 2]);
    }

    #[test]
    fn a_list_without_duplicates_hides_nothing() {
        let tracks = [
            song("Alpha", "One", 1, 200.0, "flac", Some(16)),
            song("Bravo", "One", 2, 200.0, "flac", Some(16)),
        ];
        let found = collapse(&tracks);
        assert!(found.hidden.is_empty());
        assert!(found.copies.is_empty());
    }

    #[test]
    fn a_song_with_no_title_is_never_a_duplicate() {
        let tracks = [
            song("", "One", 1, 200.0, "flac", Some(16)),
            song("", "Two", 2, 200.0, "flac", Some(16)),
        ];
        assert!(collapse(&tracks).hidden.is_empty());
    }

    #[test]
    fn a_unique_pool_keeps_the_preferred_copy() {
        let tracks = vec![
            song("Glass Harbor", "Hits", 1, 215.0, "mp3", None),
            song("Glass Harbor", "Tidewater", 2, 215.0, "flac", Some(24)),
        ];
        let pool = unique_pool(&tracks, &tracks[..1]);
        assert_eq!(pool.iter().map(|track| track.id).collect::<Vec<_>>(), [1]);
        assert_eq!(unique_pool(&tracks, &[]).len(), 1);
    }

    #[test]
    fn song_keys_strip_only_re_release_decoration() {
        let base = song_key("Glass Harbor", "Aurelia Vance");
        assert_eq!(song_key("Glass Harbor (Remastered 2011)", "Aurelia Vance"), base);
        assert_eq!(song_key("Glass Harbor [Explicit]", "Aurelia Vance"), base);
        assert_eq!(song_key("Glass Harbor (feat. Corvid)", "Aurelia Vance & Corvid"), base);
        assert_eq!(song_key("Glass Harbor - Mono", "aurelia vance"), base);
        assert_ne!(song_key("Glass Harbor (Live)", "Aurelia Vance"), base);
        assert_ne!(song_key("Glass Harbor (Remix)", "Aurelia Vance"), base);
        assert_ne!(song_key("Glass Harbor (Demo)", "Aurelia Vance"), base);
    }
}
