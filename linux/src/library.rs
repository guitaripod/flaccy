use crate::db::Db;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};

#[derive(Clone, Debug)]
#[allow(dead_code)]
pub struct TrackRow {
    pub id: i64,
    pub rel_path: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    /// The release this track belongs to, credited: the `ALBUMARTIST` tag when
    /// the file carried one, otherwise the credit `Db::resolve_album_credits`
    /// derived from the whole release. None only until that pass has run.
    pub album_artist: Option<String>,
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
    /// The credit its release is filed under, falling back to the performing
    /// artist for a row `Db::resolve_album_credits` has not settled yet.
    pub fn credit(&self) -> &str {
        self.album_artist
            .as_deref()
            .filter(|credit| !credit.is_empty())
            .unwrap_or(&self.artist)
    }

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

/// "45 min", "3 hr 12 min", "2 d 4 hr": how long a list of songs plays for, in
/// the largest two units that matter, each truncated rather than rounded (the
/// Mac's `SongsStatusFormat` reads the same way).
pub fn format_total_duration(seconds: f64) -> String {
    if !seconds.is_finite() || seconds <= 0.0 {
        return "0 min".to_string();
    }
    let minutes = (seconds / 60.0).floor() as i64;
    if minutes >= 24 * 60 {
        return format!("{} d {} hr", minutes / (24 * 60), minutes % (24 * 60) / 60);
    }
    let (hours, rest) = (minutes / 60, minutes % 60);
    match (hours, rest) {
        (0, minutes) => format!("{minutes} min"),
        (hours, 0) => format!("{hours} hr"),
        (hours, minutes) => format!("{hours} hr {minutes} min"),
    }
}

/// When a song was last played, the way a person says it: "Today",
/// "Yesterday", "3 days ago" for the rest of the week, then the date.
pub fn format_last_played(played_unix: i64, now_unix: i64) -> String {
    use chrono::{Local, TimeZone};
    let local = |unix: i64| Local.timestamp_opt(unix, 0).single();
    let (Some(played), Some(now)) = (local(played_unix), local(now_unix)) else {
        return String::new();
    };
    let days = (now.date_naive() - played.date_naive()).num_days();
    match days {
        d if d < 0 => played.format("%b %-d, %Y").to_string(),
        0 => "Today".to_string(),
        1 => "Yesterday".to_string(),
        2..=6 => format!("{days} days ago"),
        _ => played.format("%b %-d, %Y").to_string(),
    }
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

    /// Whether `key` is this album's `key()`, compared in place so a lookup
    /// across the whole library allocates nothing.
    pub fn key_matches(&self, key: &str) -> bool {
        let title_end = self.title.len();
        key.len() == title_end + 1 + self.artist.len()
            && key.starts_with(self.title.as_str())
            && key.as_bytes()[title_end] == b'|'
            && key.ends_with(self.artist.as_str())
    }

    pub fn total_duration(&self) -> f64 {
        self.tracks.iter().map(|t| t.duration).sum()
    }

    /// Every (title, artist) a surface may ask this release's cover by: album
    /// cards use the grouped title and credit, tracks their own album and
    /// performing artist. A chosen cover is stored under all of them.
    pub fn artwork_keys(&self) -> Vec<(String, String)> {
        let mut seen = HashSet::new();
        let mut keys = Vec::new();
        let candidates = std::iter::once((self.title.as_str(), self.artist.as_str())).chain(
            self.tracks
                .iter()
                .map(|track| (track.album.as_str(), track.artist.as_str())),
        );
        for (title, artist) in candidates {
            if !title.is_empty() && seen.insert((title.to_string(), artist.to_string())) {
                keys.push((title.to_string(), artist.to_string()));
            }
        }
        keys
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
    /// Albums this artist performs on without being the credit — a composer on
    /// a Various Artists soundtrack, a guest on somebody else's record. Kept
    /// apart from `album_count` so a performer is never sold as an author.
    pub appearance_count: usize,
    pub track_count: usize,
    pub play_count: i64,
    pub last_played: Option<i64>,
}

pub struct Library {
    pub tracks: Vec<Track>,
    pub albums: Vec<Album>,
    pub artists: Vec<ArtistEntry>,
    pub index: LibraryIndex,
}

/// Lookup tables over a `Library`'s albums and tracks, built once per loaded
/// library (on the loading thread) instead of once per question. Every table
/// holds positions, never copies, so a clone of the library that only changes
/// a track's flags can share them.
#[derive(Clone, Default)]
pub struct LibraryIndex {
    artists: Arc<OnceLock<ArtistTrackIndex>>,
    charts: Arc<OnceLock<crate::chart_queue::ChartKeys>>,
    durations: Arc<OnceLock<Arc<HashMap<String, i64>>>>,
}

impl LibraryIndex {
    /// The positions of each artist's tracks, built on first use when the
    /// library was assembled without one.
    fn artist_tracks<'a>(&'a self, albums: &[Album]) -> &'a ArtistTrackIndex {
        self.artists
            .get_or_init(|| ArtistTrackIndex::build(albums, &mut KeyMemo::default()))
    }

    /// The `"Title — Artist"` / `"Album — Artist"` tables behind the Stats
    /// charts, built on first use when the library was assembled without one.
    pub fn chart_keys<'a>(&'a self, library: &Library) -> &'a crate::chart_queue::ChartKeys {
        self.charts
            .get_or_init(|| crate::chart_queue::ChartKeys::build(library))
    }
}

impl LibraryIndex {
    /// The whole seconds of every playable song by `recap::track_key`, shared
    /// with whichever thread asks, built on first use.
    fn track_durations(&self, tracks: &[Track]) -> Arc<HashMap<String, i64>> {
        Arc::clone(self.durations.get_or_init(|| {
            Arc::new(
                tracks
                    .iter()
                    .filter(|track| track.duration > 0.0)
                    .map(|track| {
                        (
                            crate::recap::track_key(&track.title, &track.artist),
                            track.duration.round() as i64,
                        )
                    })
                    .collect(),
            )
        }))
    }
}

/// Where each artist's tracks sit: `(album, track)` positions in album order,
/// keyed by `hygiene::artist_key`.
struct ArtistTrackIndex {
    positions: HashMap<String, Vec<(u32, u32)>>,
}

impl ArtistTrackIndex {
    /// An album credited to an artist contributes all of its tracks, any other
    /// album only the tracks that artist performs, matching what walking every
    /// album and testing every track would find.
    fn build(albums: &[Album], memo: &mut KeyMemo) -> Self {
        let mut positions: HashMap<String, Vec<(u32, u32)>> = HashMap::new();
        for (album_at, album) in albums.iter().enumerate() {
            let credit_key = memo.artist_key(&album.artist).to_string();
            let credited = positions.entry(credit_key.clone()).or_default();
            credited.extend((0..album.tracks.len()).map(|at| (album_at as u32, at as u32)));
            for (track_at, track) in album.tracks.iter().enumerate() {
                let performer_key = memo.artist_key(&track.artist);
                if performer_key != credit_key {
                    positions
                        .entry(performer_key.to_string())
                        .or_default()
                        .push((album_at as u32, track_at as u32));
                }
            }
        }
        Self { positions }
    }
}

/// Remembers the key of every distinct string met while a library is
/// assembled: a library has tens of thousands of tracks but only hundreds of
/// distinct artists and albums, so each key is derived once.
#[derive(Default)]
struct KeyMemo {
    artist_keys: HashMap<String, String>,
    normalized: HashMap<String, String>,
}

impl KeyMemo {
    fn artist_key(&mut self, credit: &str) -> &str {
        if !self.artist_keys.contains_key(credit) {
            self.artist_keys
                .insert(credit.to_string(), crate::hygiene::artist_key(credit));
        }
        &self.artist_keys[credit]
    }

    fn normalize(&mut self, text: &str) -> &str {
        if !self.normalized.contains_key(text) {
            self.normalized
                .insert(text.to_string(), crate::wantlist::normalize(text));
        }
        &self.normalized[text]
    }
}

impl Library {
    pub fn empty() -> Self {
        Self {
            tracks: Vec::new(),
            albums: Vec::new(),
            artists: Vec::new(),
            index: LibraryIndex::default(),
        }
    }

    pub fn track_by_rel_path(&self, rel_path: &str) -> Option<&Track> {
        self.tracks.iter().find(|t| t.rel_path == rel_path)
    }

    pub fn album_by_key(&self, key: &str) -> Option<&Album> {
        self.albums.iter().find(|a| a.key_matches(key))
    }

    /// Every library track `artist` is on (feat. credits collapse to the lead
    /// artist), in album order: the albums credited to them in full, plus the
    /// individual tracks they perform on somebody else's record.
    ///
    /// Taking only credited albums would hand a composer on a Various Artists
    /// soundtrack an empty queue while the library holds thirty-one of their
    /// tracks.
    pub fn artist_tracks(&self, artist: &str) -> Vec<Track> {
        let key = crate::hygiene::artist_key(artist);
        let Some(positions) = self.index.artist_tracks(&self.albums).positions.get(&key) else {
            return Vec::new();
        };
        positions
            .iter()
            .map(|&(album, track)| self.albums[album as usize].tracks[track as usize].clone())
            .collect()
    }

    /// Song lengths by `recap::track_key`, for the plays that were imported
    /// without one. Built once per library and shared.
    pub fn track_durations(&self) -> Arc<HashMap<String, i64>> {
        self.index.track_durations(&self.tracks)
    }

    /// Whether the library holds any track by `artist`.
    pub fn owns_artist(&self, artist: &str) -> bool {
        let key = crate::hygiene::artist_key(artist);
        self.index
            .artist_tracks(&self.albums)
            .positions
            .get(&key)
            .is_some_and(|positions| !positions.is_empty())
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
        tracks.sort_by_cached_key(|track| (track.track_number, track.title.to_lowercase()));
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
    if labels
        .iter()
        .collect::<std::collections::HashSet<_>>()
        .len()
        < 2
    {
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
    let stem = file
        .rsplit_once('.')
        .map_or(file, |(s, _)| s)
        .to_lowercase();

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

    // Group by edition-free album title + the release credit, so per-track
    // featuring credits ("50 Cent Feat. Eminem") do not each spawn a one-song
    // album and a compilation's performers do not each spawn a fragment of one.
    // `albumArtist` is settled for the whole library by
    // `Db::resolve_album_credits`; the fall back to the performing artist is
    // what a database that has not been through that pass yet gets.
    let mut memo = KeyMemo::default();
    let mut grouped: HashMap<String, Vec<Track>> = HashMap::new();
    for track in &tracks {
        let mut key = String::from(memo.normalize(&track.album));
        key.push('\u{0}');
        key.push_str(memo.artist_key(track.credit()));
        grouped.entry(key).or_default().push(track.clone());
    }

    let mut albums: Vec<Album> = grouped
        .into_values()
        .filter_map(|mut group| {
            let title = majority_value(group.iter().map(|t| t.album.as_str()));
            let artist = majority_value(
                group
                    .iter()
                    .map(|t| crate::hygiene::primary_artist_slice(t.credit())),
            );
            sort_album_tracks(&mut group);
            let (year, genre) = album_meta_for(&meta, &title, &artist, &group);
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
    albums.sort_by_cached_key(|album| (album.artist.to_lowercase(), album.title.to_lowercase()));

    // Songs list must match the album surface: when editions are folded, every
    // shared track collapses to one best-quality keeper. When grouping is off,
    // keep the raw file inventory so every pressing remains addressable.
    let tracks = if group_album_editions {
        albums
            .iter()
            .flat_map(|album| album.tracks.iter().cloned())
            .collect()
    } else {
        tracks
    };

    let last_played = db.track_sort_keys();
    let artists = build_artists(&albums, &last_played, &mut memo);
    let artist_tracks = ArtistTrackIndex::build(&albums, &mut memo);

    let library = Library {
        tracks,
        albums,
        artists,
        index: LibraryIndex::default(),
    };
    let _ = library.index.artists.set(artist_tracks);
    library.index.chart_keys(&library);
    library
}

/// An album's year and genre, resolved field by field rather than row by row.
///
/// A compilation is credited to someone no metadata provider has ever heard of
/// ("Various Artists"), so enrichment keeps asking under the performing artists
/// and the answers land on *their* rows. The credited release still gets a row
/// of its own — it is where the adopted cover lives — and taking that row whole
/// would hand the album a NULL year while the real one sits one row over, which
/// is exactly how a soundtrack lost its 2007 the moment it gained its cover.
fn album_meta_for(
    meta: &HashMap<(String, String), (Option<String>, Option<String>)>,
    title: &str,
    artist: &str,
    group: &[Track],
) -> (Option<String>, Option<String>) {
    let mut year = None;
    let mut genre = None;
    let rows = std::iter::once((title.to_string(), artist.to_string()))
        .chain(group.iter().map(|t| (t.album.clone(), t.artist.clone())));
    for key in rows {
        let Some((row_year, row_genre)) = meta.get(&key) else {
            continue;
        };
        if year.is_none() {
            year = row_year.clone();
        }
        if genre.is_none() {
            genre = row_genre.clone();
        }
        if year.is_some() && genre.is_some() {
            break;
        }
    }
    (year, genre)
}

/// The Artists tab, built from what people are credited with **and** what they
/// perform.
///
/// Deriving it from album credits alone was fine while every album was one
/// artist's, and became a disappearing act the moment compilations could
/// exist: the seven composers of a Various Artists soundtrack own no album, so
/// an index of credits alone would erase all seven from the library that holds
/// thirty-one of their tracks. Performances therefore count too, tracked
/// separately so the tab can still say which albums are actually theirs.
fn build_artists(
    albums: &[Album],
    last_played: &HashMap<String, Option<i64>>,
    memo: &mut KeyMemo,
) -> Vec<ArtistEntry> {
    let mut map: HashMap<String, ArtistEntry> = HashMap::new();

    let touch = |map: &mut HashMap<String, ArtistEntry>, key: &str, credit: &str, track: &Track| {
        let entry = map
            .entry(key.to_string())
            .or_insert_with(|| ArtistEntry {
                name: crate::hygiene::primary_artist(credit),
                album_count: 0,
                appearance_count: 0,
                track_count: 0,
                play_count: 0,
                last_played: None,
            });
        entry.track_count += 1;
        entry.play_count += track.play_count;
        if let Some(played) = last_played.get(&track.rel_path).copied().flatten() {
            entry.last_played = Some(entry.last_played.map_or(played, |cur| cur.max(played)));
        }
    };

    for album in albums {
        let credit_key = memo.artist_key(&album.artist).to_string();
        let mut appeared: HashSet<String> = HashSet::new();
        for track in &album.tracks {
            touch(&mut map, &credit_key, &album.artist, track);
            let performer_key = memo.artist_key(&track.artist);
            if performer_key != credit_key {
                touch(&mut map, performer_key, &track.artist, track);
                appeared.insert(performer_key.to_string());
            }
        }
        if let Some(entry) = map.get_mut(&credit_key) {
            entry.album_count += 1;
        }
        for key in appeared {
            if let Some(entry) = map.get_mut(&key) {
                entry.appearance_count += 1;
            }
        }
    }

    let mut artists: Vec<ArtistEntry> = map.into_values().collect();
    artists.sort_by_cached_key(|artist| artist.name.to_lowercase());
    artists
}

fn majority_value<'a>(values: impl IntoIterator<Item = &'a str>) -> String {
    let mut counts: HashMap<&str, usize> = HashMap::new();
    let mut first: Option<&str> = None;
    for value in values {
        first.get_or_insert(value);
        *counts.entry(value).or_default() += 1;
    }
    counts
        .into_iter()
        .max_by(|(ka, ca), (kb, cb)| ca.cmp(cb).then_with(|| kb.len().cmp(&ka.len())))
        .map(|(k, _)| k)
        .or(first)
        .unwrap_or_default()
        .to_string()
}

#[cfg(test)]
mod meta_tests {
    use super::*;

    fn track(album: &str, artist: &str) -> Track {
        TrackRow {
            id: 0,
            rel_path: format!("{album}/{artist}.flac"),
            title: "t".into(),
            artist: artist.into(),
            album: album.into(),
            album_artist: Some("Various Artists".into()),
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
        }
    }

    #[test]
    fn a_credited_row_without_a_year_does_not_hide_a_members_year() {
        let mut meta = HashMap::new();
        meta.insert(
            ("Score".to_string(), "Various Artists".to_string()),
            (None, None),
        );
        meta.insert(
            ("Score".to_string(), "Composer A".to_string()),
            (Some("2007".to_string()), Some("score".to_string())),
        );
        let group = vec![track("Score", "Composer A")];

        let (year, genre) = album_meta_for(&meta, "Score", "Various Artists", &group);
        assert_eq!(year.as_deref(), Some("2007"));
        assert_eq!(genre.as_deref(), Some("score"));
    }

    #[test]
    fn the_credited_row_still_wins_where_it_has_an_answer() {
        let mut meta = HashMap::new();
        meta.insert(
            ("Score".to_string(), "Various Artists".to_string()),
            (Some("2009".to_string()), None),
        );
        meta.insert(
            ("Score".to_string(), "Composer A".to_string()),
            (Some("2007".to_string()), Some("score".to_string())),
        );
        let group = vec![track("Score", "Composer A")];

        let (year, genre) = album_meta_for(&meta, "Score", "Various Artists", &group);
        assert_eq!(year.as_deref(), Some("2009"));
        assert_eq!(genre.as_deref(), Some("score"));
    }
}

#[cfg(test)]
mod artwork_key_tests {
    use super::*;

    fn track(album: &str, artist: &str) -> Track {
        TrackRow {
            id: 0,
            rel_path: format!("{album}/{artist}.flac"),
            title: "t".into(),
            artist: artist.into(),
            album: album.into(),
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
        }
    }

    fn album(title: &str, artist: &str, tracks: Vec<Track>) -> Album {
        Album {
            title: title.into(),
            artist: artist.into(),
            year: None,
            genre: None,
            tracks,
        }
    }

    #[test]
    fn a_compilation_is_keyed_by_its_credit_and_every_performer() {
        let release = album(
            "Score",
            "Various Artists",
            vec![
                track("Score", "Composer A"),
                track("Score", "Composer B"),
                track("Score", "Composer A"),
            ],
        );
        let expected: Vec<(String, String)> = [
            ("Score", "Various Artists"),
            ("Score", "Composer A"),
            ("Score", "Composer B"),
        ]
        .iter()
        .map(|(title, artist)| (title.to_string(), artist.to_string()))
        .collect();
        assert_eq!(release.artwork_keys(), expected);
    }

    #[test]
    fn a_plain_album_is_one_key_and_empty_titles_are_skipped() {
        let release = album(
            "Record",
            "Band",
            vec![track("Record", "Band"), track("", "Band")],
        );
        assert_eq!(
            release.artwork_keys(),
            vec![("Record".to_string(), "Band".to_string())]
        );
        assert!(album("", "Band", vec![track("", "Band")])
            .artwork_keys()
            .is_empty());
    }

    #[test]
    fn a_track_filed_under_a_different_album_title_gets_its_own_key() {
        let release = album(
            "Aurora",
            "Aurora Band",
            vec![track("Aurora", "Aurora Band"), track("Aurora (Deluxe)", "Aurora Band")],
        );
        assert_eq!(release.artwork_keys().len(), 2);
    }
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
                album_artist: None,
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
                album_artist: None,
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
                album_artist: None,
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
        assert_eq!(
            grouped.len(),
            1,
            "all featuring credits collapse to one album"
        );
        let group = grouped.into_values().next().unwrap();
        assert_eq!(group.len(), 3);
        let artist = majority_value(
            group
                .iter()
                .map(|t| crate::hygiene::primary_artist_slice(&t.artist)),
        );
        assert_eq!(artist, "50 Cent");
    }

    fn track(rel_path: &str, track_number: i32, title: &str) -> Track {
        TrackRow {
            id: 0,
            rel_path: rel_path.to_string(),
            title: title.to_string(),
            artist: "A".to_string(),
            album: "Alb".to_string(),
            album_artist: None,
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

#[cfg(test)]
mod duration_tests {
    use super::*;
    use chrono::{Local, TimeZone};

    #[test]
    fn total_duration_names_the_two_largest_units() {
        assert_eq!(format_total_duration(0.0), "0 min");
        assert_eq!(format_total_duration(f64::NAN), "0 min");
        assert_eq!(format_total_duration(29.0), "0 min");
        assert_eq!(format_total_duration(119.0), "1 min");
        assert_eq!(format_total_duration(45.0 * 60.0), "45 min");
        assert_eq!(format_total_duration(3600.0), "1 hr");
        assert_eq!(
            format_total_duration(3.0 * 3600.0 + 12.0 * 60.0),
            "3 hr 12 min"
        );
        assert_eq!(
            format_total_duration(27.0 * 3600.0 + 20.0 * 60.0),
            "1 d 3 hr"
        );
        assert_eq!(format_total_duration(2.0 * 86_400.0), "2 d 0 hr");
    }

    fn local_noon(year: i32, month: u32, day: u32) -> i64 {
        Local
            .with_ymd_and_hms(year, month, day, 12, 0, 0)
            .single()
            .expect("valid local time")
            .timestamp()
    }

    #[test]
    fn last_played_reads_like_a_person_says_it() {
        let now = local_noon(2026, 10, 16);
        assert_eq!(format_last_played(now - 3600, now), "Today");
        let said = |unix: i64| format_last_played(unix, now);
        assert_eq!(said(local_noon(2026, 10, 15)), "Yesterday");
        assert_eq!(said(local_noon(2026, 10, 12)), "4 days ago");
        assert_eq!(said(local_noon(2026, 10, 9)), "Oct 9, 2026");
        assert_eq!(said(local_noon(2025, 1, 2)), "Jan 2, 2025");
    }
}

#[cfg(test)]
mod artist_index_tests {
    use super::*;

    fn track(rel_path: &str, artist: &str) -> Track {
        TrackRow {
            id: 0,
            rel_path: rel_path.into(),
            title: rel_path.into(),
            artist: artist.into(),
            album: "Alb".into(),
            album_artist: None,
            track_number: 1,
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

    fn album(title: &str, artist: &str, tracks: Vec<Track>) -> Album {
        Album {
            title: title.into(),
            artist: artist.into(),
            year: None,
            genre: None,
            tracks,
        }
    }

    fn walking_artist_tracks(library: &Library, artist: &str) -> Vec<Track> {
        let key = crate::hygiene::artist_key(artist);
        library
            .albums
            .iter()
            .flat_map(|album| {
                let credited = crate::hygiene::artist_key(&album.artist) == key;
                let key = key.clone();
                album.tracks.iter().filter(move |track| {
                    credited || crate::hygiene::artist_key(&track.artist) == key
                })
            })
            .cloned()
            .collect()
    }

    fn mixed_library() -> Library {
        let mut library = Library::empty();
        library.albums = vec![
            album(
                "Soundtrack",
                "Various Artists",
                vec![
                    track("s/1", "Composer A"),
                    track("s/2", "composer a feat. Guest"),
                    track("s/3", "Composer B"),
                ],
            ),
            album(
                "Own",
                "Composer A",
                vec![track("o/1", "Composer A"), track("o/2", "Composer B")],
            ),
            album("Empty", "Nobody", Vec::new()),
            album("Punctuation", "?!", vec![track("p/1", "...")]),
            album("Sigur", "Sigur Rós", vec![track("g/1", "Sigur Ros")]),
            album("Again", "Composer A", vec![track("o/3", "Someone Else")]),
        ];
        library
    }

    fn paths(tracks: &[Track]) -> Vec<&str> {
        tracks.iter().map(|t| t.rel_path.as_str()).collect()
    }

    #[test]
    fn artist_tracks_match_walking_every_album_and_track() {
        let library = mixed_library();
        for artist in [
            "Composer A",
            "COMPOSER B",
            "Various Artists",
            "Nobody",
            "?!",
            "",
            "Sigur Rós",
            "sigur ros",
            "Absent",
            "Composer A feat. Guest",
        ] {
            assert_eq!(
                paths(&library.artist_tracks(artist)),
                paths(&walking_artist_tracks(&library, artist)),
                "{artist:?}"
            );
            assert_eq!(
                library.owns_artist(artist),
                !walking_artist_tracks(&library, artist).is_empty(),
                "{artist:?}"
            );
        }
    }

    #[test]
    fn artist_tracks_keep_album_order_with_credited_albums_whole() {
        let library = mixed_library();
        assert_eq!(
            paths(&library.artist_tracks("Composer A")),
            ["s/1", "s/2", "o/1", "o/2", "o/3"]
        );
    }

    #[test]
    fn a_copy_sharing_the_index_answers_the_same() {
        let library = mixed_library();
        let first = paths(&library.artist_tracks("Composer B")).len();
        let copy = Library {
            tracks: library.tracks.clone(),
            albums: library.albums.clone(),
            artists: library.artists.clone(),
            index: library.index.clone(),
        };
        assert_eq!(copy.artist_tracks("Composer B").len(), first);
    }

    #[test]
    fn sorting_album_tracks_stays_stable_among_equal_keys() {
        let mut tracks: Vec<Track> = ["b", "A", "a", "B", "a", "C"]
            .iter()
            .enumerate()
            .map(|(at, title)| {
                let mut t = track(&format!("p/{at}"), "X");
                t.title = title.to_string();
                t.track_number = 0;
                t
            })
            .collect();
        let mut expected = tracks.clone();
        expected.sort_by(|a, b| {
            a.track_number
                .cmp(&b.track_number)
                .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
        });
        sort_album_tracks(&mut tracks);
        assert_eq!(paths(&tracks), paths(&expected));
    }

    #[test]
    fn track_durations_keep_only_playable_songs_by_case_folded_key() {
        let mut long = track("a", "Artist");
        long.title = "Song".into();
        long.duration = 200.4;
        let mut silent = track("b", "Artist");
        silent.title = "Silent".into();
        silent.duration = 0.0;
        let mut library = Library::empty();
        library.tracks = vec![long, silent];
        let durations = library.track_durations();
        assert_eq!(durations.len(), 1);
        assert_eq!(durations.get(&crate::recap::track_key("SONG", "ARTIST")), Some(&200));
        assert!(Arc::ptr_eq(&durations, &library.track_durations()));
    }

    #[test]
    fn album_key_matches_agrees_with_key() {
        let albums = [
            album("A|B", "C", Vec::new()),
            album("A", "B|C", Vec::new()),
            album("", "", Vec::new()),
            album("Ágætis", "Sigur Rós", Vec::new()),
            album("x", "", Vec::new()),
        ];
        let keys: Vec<String> = albums
            .iter()
            .map(|a| a.key())
            .chain(["A|B|C".to_string(), "|".to_string(), "x|".to_string(), "x".to_string()])
            .collect();
        for album in &albums {
            for key in &keys {
                assert_eq!(album.key_matches(key), album.key() == *key, "{key:?}");
            }
        }
    }

    #[test]
    #[ignore]
    fn artist_tracks_match_walking_on_the_real_library() {
        let library = load(&perf_fixture::open(), true);
        for entry in &library.artists {
            assert_eq!(
                paths(&library.artist_tracks(&entry.name)),
                paths(&walking_artist_tracks(&library, &entry.name)),
                "{}",
                entry.name
            );
        }
    }
}

#[cfg(test)]
pub(crate) mod perf_fixture {
    use super::*;
    use std::time::Instant;

    pub fn open() -> Db {
        let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("target/perfdb/library.sqlite");
        Db::open(&path).expect("perf database copy")
    }

    pub fn distinct_strings() -> Vec<String> {
        let db = open();
        let mut seen = std::collections::BTreeSet::new();
        for track in db.fetch_all_tracks() {
            seen.insert(track.title);
            seen.insert(track.artist);
            seen.insert(track.album);
            seen.extend(track.album_artist);
        }
        for (title, artist) in db.album_meta().into_keys() {
            seen.insert(title);
            seen.insert(artist);
        }
        seen.into_iter().collect()
    }

    #[test]
    #[ignore]
    fn time_library_pipeline() {
        let db = open();
        let started = Instant::now();
        let tracks = db.fetch_all_tracks();
        println!("fetch_all_tracks {} rows: {:?}", tracks.len(), started.elapsed());
        let started = Instant::now();
        let library = load(&db, true);
        println!("load total: {:?}", started.elapsed());
        let started = Instant::now();
        let index = crate::chart_queue::ChartIndex::new(&library);
        println!("ChartIndex::new: {:?}", started.elapsed());
        let chart: Vec<(String, i64)> = library
            .artists
            .iter()
            .take(50)
            .map(|artist| (artist.name.clone(), 1))
            .collect();
        let started = Instant::now();
        let queue = index.artist_queue(&chart);
        println!("artist_queue(50) {} tracks: {:?}", queue.len(), started.elapsed());
        let started = Instant::now();
        let owned = chart.iter().filter(|(name, _)| index.owns_artist(name)).count();
        println!("owns_artist x50 -> {owned}: {:?}", started.elapsed());
        let started = Instant::now();
        let mut total = 0;
        for artist in &library.artists {
            total += library.artist_tracks(&artist.name).len();
        }
        println!("artist_tracks x{} -> {total}: {:?}", library.artists.len(), started.elapsed());
        let strings = distinct_strings();
        let started = Instant::now();
        let mut length = 0;
        for text in &strings {
            length += crate::hygiene::artist_key(text).len();
        }
        println!("artist_key x{} -> {length}: {:?}", strings.len(), started.elapsed());
        let started = Instant::now();
        let mut length = 0;
        for text in &strings {
            length += crate::wantlist::normalize(text).len();
        }
        println!("normalize x{} -> {length}: {:?}", strings.len(), started.elapsed());
        let keys: Vec<String> = library
            .albums
            .iter()
            .map(|album| album.key())
            .collect();
        let started = Instant::now();
        let mut found = 0;
        for key in &keys {
            found += library.album_by_key(key).is_some() as usize;
        }
        println!("album_by_key x{} -> {found}: {:?}", keys.len(), started.elapsed());
    }
}
