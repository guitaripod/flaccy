use crate::db::Db;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct TrackRow {
    pub id: i64,
    pub rel_path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub track_number: i32,
    pub duration: f64,
    pub codec: Option<String>,
    pub bit_depth: Option<i32>,
    pub sample_rate: Option<i32>,
    pub channels: Option<i32>,
    pub loved: bool,
    pub play_count: i64,
    pub date_added: i64,
    pub last_played: Option<i64>,
}

pub type Track = TrackRow;

impl TrackRow {
    pub fn quality_badge(&self) -> Option<String> {
        let codec = self.codec.as_deref()?;
        let detail = match (self.bit_depth, self.sample_rate) {
            (Some(bits), Some(rate)) => Some(format!("{}/{}", bits, format_sample_rate(rate))),
            (None, Some(rate)) => Some(format_sample_rate(rate)),
            _ => None,
        };
        match detail {
            Some(detail) => Some(format!("{codec} · {detail}")),
            None => Some(codec.to_string()),
        }
    }

    pub fn abs_path(&self, root: &Path) -> PathBuf {
        root.join(&self.rel_path)
    }
}

fn format_sample_rate(hz: i32) -> String {
    let khz = hz as f64 / 1000.0;
    if khz == khz.round() {
        format!("{:.0}", khz)
    } else {
        format!("{:.1}", khz)
    }
}

pub fn format_time(seconds: f64) -> String {
    if !seconds.is_finite() || seconds < 0.0 {
        return "0:00".to_string();
    }
    let total = seconds.round() as i64;
    format!("{}:{:02}", total / 60, total % 60)
}

#[derive(Clone)]
pub struct Album {
    pub title: String,
    pub artist: String,
    pub year: Option<String>,
    pub genre: Option<String>,
    pub tracks: Vec<Track>,
}

impl Album {
    pub fn key(&self) -> String {
        format!("{}|{}", self.title, self.artist)
    }

    pub fn total_duration(&self) -> f64 {
        self.tracks.iter().map(|t| t.duration).sum()
    }

    /// When the album entered the library: the newest track's dateAdded, so a
    /// release that trickles in file-by-file surfaces when it completes
    /// (mirrors LibraryViewModel.albumDateAddedMap on the Apple clients).
    pub fn added_unix(&self) -> i64 {
        self.tracks.iter().map(|t| t.date_added).max().unwrap_or(0)
    }

    pub fn last_played_unix(&self) -> Option<i64> {
        self.tracks.iter().filter_map(|t| t.last_played).max()
    }
}

#[derive(Clone)]
pub struct ArtistEntry {
    pub name: String,
    pub album_count: usize,
    pub track_count: usize,
    pub play_count: i64,
    pub last_played: Option<i64>,
}

pub struct Library {
    pub tracks: Vec<Track>,
    pub albums: Vec<Album>,
    pub artists: Vec<ArtistEntry>,
}

impl Library {
    pub fn empty() -> Self {
        Self {
            tracks: Vec::new(),
            albums: Vec::new(),
            artists: Vec::new(),
        }
    }

    pub fn track_by_rel_path(&self, rel_path: &str) -> Option<&Track> {
        self.tracks.iter().find(|t| t.rel_path == rel_path)
    }

    pub fn album_by_key(&self, key: &str) -> Option<&Album> {
        self.albums.iter().find(|a| a.key() == key)
    }
}

/// Orders an album's tracks for display. `trackNumber` restarts at 1 on every
/// disc of a multi-disc release and there is no disc column, so sorting by it
/// alone collapses each disc's opener together and then falls back to an
/// alphabetical tie-break. When the same non-zero track number appears more
/// than once the release is multi-disc, and the file path (e.g. `a1, a2, b1`
/// or `1-01, 2-01`) is the only reliable ordering signal, natural-sorted so
/// numeric runs compare by value rather than lexically.
pub fn sort_album_tracks(tracks: &mut [Track]) {
    if is_multi_disc(tracks) {
        tracks.sort_by(|a, b| natural_cmp(&a.rel_path.to_lowercase(), &b.rel_path.to_lowercase()));
    } else {
        tracks.sort_by(|a, b| {
            a.track_number
                .cmp(&b.track_number)
                .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
        });
    }
}

/// A contiguous run of an album's tracks belonging to one physical disc or
/// vinyl side, named the way a listener holding the release would read it.
pub struct DiscSection {
    pub label: String,
    pub tracks: Vec<Track>,
}

impl DiscSection {
    pub fn duration(&self) -> f64 {
        self.tracks.iter().map(|t| t.duration).sum()
    }
}

/// Splits already-ordered album tracks into physical disc/side sections when
/// every track's path carries a consistent disc or side marker and at least
/// two distinct sections result. Returns `None` for a single unmarked unit so
/// the caller renders one plain list — a normal album shouldn't sprout headers.
pub fn disc_sections(tracks: &[Track]) -> Option<Vec<DiscSection>> {
    let labels = tracks
        .iter()
        .map(|t| disc_label(&t.rel_path))
        .collect::<Option<Vec<_>>>()?;
    if labels.iter().collect::<std::collections::HashSet<_>>().len() < 2 {
        return None;
    }
    let mut sections: Vec<DiscSection> = Vec::new();
    for (track, label) in tracks.iter().zip(labels) {
        match sections.last_mut() {
            Some(section) if section.label == label => section.tracks.push(track.clone()),
            _ => sections.push(DiscSection {
                label,
                tracks: vec![track.clone()],
            }),
        }
    }
    Some(sections)
}

/// Reads the disc/side marker from a track's file path: a leading vinyl side
/// letter (`a1` → "Side A"), a `disc-track` numeric prefix (`1-05` → "Disc 1"),
/// or a `CD2`/`Disc 3` parent folder. Track-title prefixes like `03-title` do
/// not match because the character after the dash is not a digit.
fn disc_label(rel_path: &str) -> Option<String> {
    let file = rel_path.rsplit('/').next().unwrap_or(rel_path);
    let stem = file.rsplit_once('.').map_or(file, |(s, _)| s).to_lowercase();

    let mut chars = stem.chars();
    if let (Some(letter), Some(next)) = (chars.next(), chars.next()) {
        if letter.is_ascii_alphabetic() && next.is_ascii_digit() {
            return Some(format!("Side {}", letter.to_ascii_uppercase()));
        }
    }

    if let Some((head, tail)) = stem.split_once('-') {
        if !head.is_empty()
            && head.chars().all(|c| c.is_ascii_digit())
            && tail.chars().next().is_some_and(|c| c.is_ascii_digit())
        {
            if let Ok(disc) = head.parse::<u32>() {
                return Some(format!("Disc {disc}"));
            }
        }
    }

    let parts: Vec<&str> = rel_path.split('/').collect();
    if parts.len() >= 2 {
        let parent = parts[parts.len() - 2].to_lowercase();
        for prefix in ["disc", "cd"] {
            if let Some(rest) = parent.strip_prefix(prefix) {
                let digits: String = rest
                    .trim_start_matches([' ', '-', '_'])
                    .chars()
                    .take_while(|c| c.is_ascii_digit())
                    .collect();
                if let Ok(disc) = digits.parse::<u32>() {
                    return Some(format!("Disc {disc}"));
                }
            }
        }
    }

    None
}

fn is_multi_disc(tracks: &[Track]) -> bool {
    let mut seen = std::collections::HashSet::new();
    tracks
        .iter()
        .filter(|t| t.track_number > 0)
        .any(|t| !seen.insert(t.track_number))
}

/// Compares two strings so that embedded digit runs order by numeric value
/// (`track2` before `track10`) while everything else compares by byte.
fn natural_cmp(a: &str, b: &str) -> std::cmp::Ordering {
    let mut ai = a.chars().peekable();
    let mut bi = b.chars().peekable();
    loop {
        match (ai.peek().copied(), bi.peek().copied()) {
            (Some(ac), Some(bc)) if ac.is_ascii_digit() && bc.is_ascii_digit() => {
                let an: String = collect_digits(&mut ai);
                let bn: String = collect_digits(&mut bi);
                let ord = an
                    .trim_start_matches('0')
                    .len()
                    .cmp(&bn.trim_start_matches('0').len())
                    .then_with(|| an.cmp(&bn));
                if ord != std::cmp::Ordering::Equal {
                    return ord;
                }
            }
            (Some(ac), Some(bc)) => {
                if ac != bc {
                    return ac.cmp(&bc);
                }
                ai.next();
                bi.next();
            }
            (None, None) => return std::cmp::Ordering::Equal,
            (None, Some(_)) => return std::cmp::Ordering::Less,
            (Some(_), None) => return std::cmp::Ordering::Greater,
        }
    }
}

fn collect_digits(iter: &mut std::iter::Peekable<std::str::Chars>) -> String {
    let mut out = String::new();
    while let Some(&c) = iter.peek() {
        if c.is_ascii_digit() {
            out.push(c);
            iter.next();
        } else {
            break;
        }
    }
    out
}

pub fn load(db: &Db, group_album_editions: bool) -> Library {
    let tracks = db.fetch_all_tracks();
    let meta = db.album_meta();

    // Group by edition-free album title + lead artist so per-track featuring
    // credits ("50 Cent Feat. Eminem") do not each spawn a one-song album.
    let mut grouped: HashMap<String, Vec<Track>> = HashMap::new();
    for track in &tracks {
        let key = format!(
            "{}\u{0}{}",
            crate::wantlist::normalize(&track.album),
            crate::hygiene::artist_key(&track.artist)
        );
        grouped.entry(key).or_default().push(track.clone());
    }

    let mut albums: Vec<Album> = grouped
        .into_values()
        .filter_map(|mut group| {
            let title = majority_value(group.iter().map(|t| t.album.as_str()));
            let artist = majority_value(
                group
                    .iter()
                    .map(|t| crate::hygiene::primary_artist(&t.artist)),
            );
            sort_album_tracks(&mut group);
            let (year, genre) = meta
                .get(&(title.clone(), artist.clone()))
                .cloned()
                .or_else(|| {
                    group.iter().find_map(|t| {
                        meta.get(&(t.album.clone(), t.artist.clone())).cloned()
                    })
                })
                .unwrap_or((None, None));
            Some(Album {
                title,
                artist,
                year,
                genre,
                tracks: group,
            })
        })
        .collect();
    if group_album_editions {
        albums = crate::hygiene::consolidate_albums(albums);
    }
    albums.sort_by(|a, b| {
        a.artist
            .to_lowercase()
            .cmp(&b.artist.to_lowercase())
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
    });

    // Songs list must match the album surface: when editions are folded, every
    // shared track collapses to one best-quality keeper. When grouping is off,
    // keep the raw file inventory so every pressing remains addressable.
    let tracks = if group_album_editions {
        albums.iter().flat_map(|album| album.tracks.iter().cloned()).collect()
    } else {
        tracks
    };

    let last_played = db.track_sort_keys();
    let mut artist_map: HashMap<String, (String, usize, usize, i64, Option<i64>)> = HashMap::new();
    for album in &albums {
        let primary = crate::hygiene::primary_artist(&album.artist);
        let entry = artist_map
            .entry(crate::hygiene::artist_key(&album.artist))
            .or_insert_with(|| (primary.clone(), 0, 0, 0, None));
        entry.1 += 1;
        entry.2 += album.tracks.len();
        for track in &album.tracks {
            entry.3 += track.play_count;
            if let Some(played) = last_played.get(&track.rel_path).copied().flatten() {
                entry.4 = Some(entry.4.map_or(played, |current| current.max(played)));
            }
        }
    }
    let mut artists: Vec<ArtistEntry> = artist_map
        .into_values()
        .map(|(name, album_count, track_count, play_count, last_played)| ArtistEntry {
            name,
            album_count,
            track_count,
            play_count,
            last_played,
        })
        .collect();
    artists.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));

    Library {
        tracks,
        albums,
        artists,
    }
}

fn majority_value<I, S>(values: I) -> String
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut counts: HashMap<String, usize> = HashMap::new();
    let mut first: Option<String> = None;
    for value in values {
        let s = value.as_ref().to_string();
        if first.is_none() {
            first = Some(s.clone());
        }
        *counts.entry(s).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|(ka, ca), (kb, cb)| ca.cmp(cb).then_with(|| kb.len().cmp(&ka.len())))
        .map(|(k, _)| k)
        .or(first)
        .unwrap_or_default()
}

#[cfg(test)]
mod sort_tests {
    use super::*;

    #[test]
    fn featuring_tracks_group_into_one_album() {
        let tracks = vec![
            TrackRow {
                id: 1,
                rel_path: "a/01.flac".into(),
                title: "Intro".into(),
                artist: "50 Cent".into(),
                album: "Get Rich Or Die Tryin'".into(),
                track_number: 1,
                duration: 60.0,
                codec: Some("FLAC".into()),
                bit_depth: Some(16),
                sample_rate: Some(44100),
                channels: Some(2),
                loved: false,
                play_count: 0,
                date_added: 0,
                last_played: None,
            },
            TrackRow {
                id: 2,
                rel_path: "a/03.flac".into(),
                title: "Patiently Waiting".into(),
                artist: "50 Cent Feat. Eminem".into(),
                album: "Get Rich Or Die Tryin'".into(),
                track_number: 3,
                duration: 200.0,
                codec: Some("FLAC".into()),
                bit_depth: Some(16),
                sample_rate: Some(44100),
                channels: Some(2),
                loved: false,
                play_count: 0,
                date_added: 0,
                last_played: None,
            },
            TrackRow {
                id: 3,
                rel_path: "a/14.flac".into(),
                title: "21 Questions".into(),
                artist: "50 Cent Feat. Nate Dogg".into(),
                album: "Get Rich Or Die Tryin'".into(),
                track_number: 14,
                duration: 220.0,
                codec: Some("FLAC".into()),
                bit_depth: Some(16),
                sample_rate: Some(44100),
                channels: Some(2),
                loved: false,
                play_count: 0,
                date_added: 0,
                last_played: None,
            },
        ];
        let mut grouped: HashMap<String, Vec<Track>> = HashMap::new();
        for track in &tracks {
            let key = format!(
                "{}\u{0}{}",
                crate::wantlist::normalize(&track.album),
                crate::hygiene::artist_key(&track.artist)
            );
            grouped.entry(key).or_default().push(track.clone());
        }
        assert_eq!(grouped.len(), 1, "all featuring credits collapse to one album");
        let group = grouped.into_values().next().unwrap();
        assert_eq!(group.len(), 3);
        let artist = majority_value(group.iter().map(|t| crate::hygiene::primary_artist(&t.artist)));
        assert_eq!(artist, "50 Cent");
    }

    fn track(rel_path: &str, track_number: i32, title: &str) -> Track {
        TrackRow {
            id: 0,
            rel_path: rel_path.to_string(),
            title: title.to_string(),
            artist: "A".to_string(),
            album: "Alb".to_string(),
            track_number,
            duration: 1.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
        }
    }

    #[test]
    fn multi_disc_orders_by_path_not_alphabetical_title() {
        let mut tracks = vec![
            track("c1-big_interlude.flac", 1, "B.I.G. Interlude"),
            track("a1-intro.flac", 1, "Life After Death Intro"),
            track("b1-fuckin_you.flac", 1, "Fuckin' You Tonight"),
            track("a2-somebody.flac", 2, "Somebody's Gotta Die"),
        ];
        sort_album_tracks(&mut tracks);
        let order: Vec<&str> = tracks.iter().map(|t| t.rel_path.as_str()).collect();
        assert_eq!(
            order,
            vec![
                "a1-intro.flac",
                "a2-somebody.flac",
                "b1-fuckin_you.flac",
                "c1-big_interlude.flac"
            ]
        );
    }

    #[test]
    fn single_disc_orders_by_track_number() {
        let mut tracks = vec![
            track("10-last.flac", 10, "Last"),
            track("02-second.flac", 2, "Second"),
            track("01-first.flac", 1, "First"),
        ];
        sort_album_tracks(&mut tracks);
        let order: Vec<i32> = tracks.iter().map(|t| t.track_number).collect();
        assert_eq!(order, vec![1, 2, 10]);
    }

    #[test]
    fn natural_cmp_orders_numeric_runs_by_value() {
        assert_eq!(natural_cmp("track2", "track10"), std::cmp::Ordering::Less);
        assert_eq!(natural_cmp("cd1/09", "cd1/10"), std::cmp::Ordering::Less);
    }

    #[test]
    fn vinyl_sides_become_sections() {
        let tracks = vec![
            track("a1-intro.flac", 1, "Intro"),
            track("a2-somebody.flac", 2, "Somebody"),
            track("b1-fuckin.flac", 1, "Fuckin"),
            track("c1-interlude.flac", 1, "Interlude"),
        ];
        let sections = disc_sections(&tracks).expect("multi-side");
        let labels: Vec<&str> = sections.iter().map(|s| s.label.as_str()).collect();
        assert_eq!(labels, vec!["Side A", "Side B", "Side C"]);
        assert_eq!(sections[0].tracks.len(), 2);
    }

    #[test]
    fn cd_disc_track_prefix_becomes_sections() {
        let tracks = vec![
            track("Disc/1-01-a.flac", 1, "A"),
            track("Disc/1-02-b.flac", 2, "B"),
            track("Disc/2-01-c.flac", 1, "C"),
        ];
        let sections = disc_sections(&tracks).expect("multi-disc");
        let labels: Vec<&str> = sections.iter().map(|s| s.label.as_str()).collect();
        assert_eq!(labels, vec!["Disc 1", "Disc 2"]);
    }

    #[test]
    fn cd_disc_folders_become_sections() {
        let tracks = vec![
            track("CD1/01-a.flac", 1, "A"),
            track("CD2/01-b.flac", 1, "B"),
        ];
        let labels: Vec<String> = disc_sections(&tracks)
            .expect("multi-disc")
            .iter()
            .map(|s| s.label.clone())
            .collect();
        assert_eq!(labels, vec!["Disc 1", "Disc 2"]);
    }

    #[test]
    fn single_disc_album_has_no_sections() {
        let tracks = vec![
            track("01-first.flac", 1, "First"),
            track("02-second.flac", 2, "Second"),
            track("03-third.flac", 3, "Third"),
        ];
        assert!(disc_sections(&tracks).is_none());
    }
}
