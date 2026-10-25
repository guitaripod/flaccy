use crate::library::{Album, ArtistEntry, Library, Track};
use crate::recap::Period;
use flaccy_shared::library_filter::{
    self as rules, AddedEntry, PlayedEntry, RediscoverEntry, ALBUM_THRESHOLDS, SONG_THRESHOLDS,
};
use std::cell::RefCell;
use std::cmp::Ordering;
use std::collections::hash_map::DefaultHasher;
use std::collections::{HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::rc::{Rc, Weak};

/// The quick-pivot chips above the Songs and Albums pages: the same set the
/// Apple clients offer (`LibraryFilter`), plus Most Played, which only the
/// desktop Songs list carries because it needs a time range to mean anything.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum LibraryFilter {
    All,
    MostPlayed,
    Favorites,
    Lossless,
    RecentlyAdded,
    RecentlyPlayed,
    Rediscover,
}

impl LibraryFilter {
    pub const SONGS: [LibraryFilter; 7] = [
        LibraryFilter::All,
        LibraryFilter::MostPlayed,
        LibraryFilter::Favorites,
        LibraryFilter::Lossless,
        LibraryFilter::RecentlyAdded,
        LibraryFilter::RecentlyPlayed,
        LibraryFilter::Rediscover,
    ];

    pub const ALBUMS: [LibraryFilter; 6] = [
        LibraryFilter::All,
        LibraryFilter::Favorites,
        LibraryFilter::Lossless,
        LibraryFilter::RecentlyAdded,
        LibraryFilter::RecentlyPlayed,
        LibraryFilter::Rediscover,
    ];

    pub fn id(self) -> &'static str {
        match self {
            LibraryFilter::All => "all",
            LibraryFilter::MostPlayed => "most_played",
            LibraryFilter::Favorites => "favorites",
            LibraryFilter::Lossless => "lossless",
            LibraryFilter::RecentlyAdded => "recently_added",
            LibraryFilter::RecentlyPlayed => "recently_played",
            LibraryFilter::Rediscover => "rediscover",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            LibraryFilter::All => "All",
            LibraryFilter::MostPlayed => "Most Played",
            LibraryFilter::Favorites => "Favorites",
            LibraryFilter::Lossless => "Lossless",
            LibraryFilter::RecentlyAdded => "Recently Added",
            LibraryFilter::RecentlyPlayed => "Recently Played",
            LibraryFilter::Rediscover => "Rediscover",
        }
    }

    pub fn from_id(id: &str) -> LibraryFilter {
        Self::SONGS
            .into_iter()
            .find(|filter| filter.id() == id)
            .unwrap_or(LibraryFilter::All)
    }
}

/// The source id of the music folder in the Songs source chips and in the saved
/// Songs source; a server's chip carries the server's id.
pub const LOCAL_SOURCE: &str = "local";

/// Whether a song belongs to the source the source chips narrow the list to:
/// every song while none is lit (`source` empty), the music folder's songs for
/// `LOCAL_SOURCE`, and a server's songs for its id.
pub fn source_admits(source: &str, rel_path: &str) -> bool {
    if source.is_empty() {
        return true;
    }
    match crate::remote::server_of(rel_path) {
        Some(server) => source == server,
        None => source == LOCAL_SOURCE,
    }
}

/// The range a saved Most Played chip comes back with.
pub const DEFAULT_RANGE: Period = Period::Month;

pub fn range_from_id(id: &str) -> Period {
    crate::recap::ALL_PERIODS
        .into_iter()
        .find(|period| period.api_value() == id)
        .unwrap_or(DEFAULT_RANGE)
}

const LOSSLESS_CODECS: [&str; 4] = ["FLAC", "ALAC", "WAV", "AIFF"];

pub fn is_lossless(track: &Track) -> bool {
    track.codec.as_deref().is_some_and(|codec| {
        LOSSLESS_CODECS
            .iter()
            .any(|lossless| codec.eq_ignore_ascii_case(lossless))
    })
}

const CAPITAL_SIGMA: char = '\u{3a3}';

/// Orders two strings exactly as their `to_lowercase()` forms would compare,
/// without allocating either: ASCII compares byte by byte, and everything but
/// a capital sigma (the one letter `str::to_lowercase` lowercases by context)
/// compares character by character.
pub fn cmp_ignore_case(a: &str, b: &str) -> Ordering {
    if a.is_ascii() && b.is_ascii() {
        return a
            .bytes()
            .map(|byte| byte.to_ascii_lowercase())
            .cmp(b.bytes().map(|byte| byte.to_ascii_lowercase()));
    }
    if a.contains(CAPITAL_SIGMA) || b.contains(CAPITAL_SIGMA) {
        return a.to_lowercase().cmp(&b.to_lowercase());
    }
    a.chars()
        .flat_map(char::to_lowercase)
        .cmp(b.chars().flat_map(char::to_lowercase))
}

thread_local! {
    static LOWERCASE_SCRATCH: RefCell<String> = const { RefCell::new(String::new()) };
}

/// Whether `haystack.to_lowercase()` contains `needle_lower`, which the caller
/// has already lowercased. Allocation-free for ASCII; other text is lowercased
/// into one reused buffer.
pub fn contains_ignore_case(haystack: &str, needle_lower: &str) -> bool {
    if needle_lower.is_empty() {
        return true;
    }
    if haystack.is_ascii() {
        let needle = needle_lower.as_bytes();
        return haystack.len() >= needle.len()
            && haystack.as_bytes().windows(needle.len()).any(|window| {
                window
                    .iter()
                    .zip(needle)
                    .all(|(byte, wanted)| byte.to_ascii_lowercase() == *wanted)
            });
    }
    if haystack.contains(CAPITAL_SIGMA) {
        return haystack.to_lowercase().contains(needle_lower);
    }
    LOWERCASE_SCRATCH.with(|scratch| {
        let mut scratch = scratch.borrow_mut();
        scratch.clear();
        scratch.extend(haystack.chars().flat_map(char::to_lowercase));
        scratch.contains(needle_lower)
    })
}

/// The search box text a page filters rows by, lowercased once per query
/// rather than once per row per keystroke. It follows the query it is handed,
/// so a page never filters by a stale needle.
#[derive(Default)]
pub struct SearchNeedle {
    source: RefCell<String>,
    lowered: RefCell<String>,
}

impl SearchNeedle {
    /// Whether any of `fields` contains `query`, ignoring case. An empty query
    /// matches everything.
    pub fn matches(&self, query: &str, fields: &[&str]) -> bool {
        if query.is_empty() {
            return true;
        }
        if *self.source.borrow() != query {
            *self.source.borrow_mut() = query.to_string();
            *self.lowered.borrow_mut() = query.to_lowercase();
        }
        let lowered = self.lowered.borrow();
        fields
            .iter()
            .any(|field| contains_ignore_case(field, &lowered))
    }
}

/// Digest of every field of a track that any library page renders, sorts or
/// filters on. Two rows with the same digest are interchangeable on screen.
pub fn track_digest(track: &Track) -> u64 {
    let mut hasher = DefaultHasher::new();
    track.rel_path.hash(&mut hasher);
    track.title.hash(&mut hasher);
    track.artist.hash(&mut hasher);
    track.album.hash(&mut hasher);
    track.loved.hash(&mut hasher);
    track.duration.to_bits().hash(&mut hasher);
    track.track_number.hash(&mut hasher);
    track.play_count.hash(&mut hasher);
    track.date_added.hash(&mut hasher);
    track.codec.hash(&mut hasher);
    track.bit_depth.hash(&mut hasher);
    track.sample_rate.hash(&mut hasher);
    track.last_played.hash(&mut hasher);
    track.revision.hash(&mut hasher);
    track.revised_at.hash(&mut hasher);
    hasher.finish()
}

fn album_digest(album: &Album) -> u64 {
    let mut hasher = DefaultHasher::new();
    album.title.hash(&mut hasher);
    album.artist.hash(&mut hasher);
    album.year.hash(&mut hasher);
    album.genre.hash(&mut hasher);
    hasher.finish()
}

fn album_recency_digest(album: &Album) -> u64 {
    let mut hasher = DefaultHasher::new();
    album.added_unix().hash(&mut hasher);
    album.last_played_unix().hash(&mut hasher);
    hasher.finish()
}

fn artist_digest(artist: &ArtistEntry) -> u64 {
    let mut hasher = DefaultHasher::new();
    artist.name.hash(&mut hasher);
    artist.album_count.hash(&mut hasher);
    artist.appearance_count.hash(&mut hasher);
    artist.track_count.hash(&mut hasher);
    artist.play_count.hash(&mut hasher);
    artist.last_played.hash(&mut hasher);
    hasher.finish()
}

fn fold_digests(digests: impl Iterator<Item = u64>) -> u64 {
    let mut hasher = DefaultHasher::new();
    for digest in digests {
        digest.hash(&mut hasher);
    }
    hasher.finish()
}

/// What changed between two builds of the library, as digests the pages
/// compare instead of walking and hashing the library themselves. Order
/// sensitive, so a reorder counts as a change.
pub struct LibrarySignature {
    pub track_rows: Vec<u64>,
    pub albums: u64,
    pub album_recency: u64,
    pub artists: u64,
}

impl LibrarySignature {
    pub fn of(library: &Library) -> Self {
        let track_rows: Vec<u64> = library.tracks.iter().map(track_digest).collect();
        Self {
            track_rows,
            albums: fold_digests(library.albums.iter().map(album_digest)),
            album_recency: fold_digests(library.albums.iter().map(album_recency_digest)),
            artists: fold_digests(library.artists.iter().map(artist_digest)),
        }
    }
}

type SignatureSlot = Option<(Weak<Library>, Rc<LibrarySignature>)>;

thread_local! {
    static LAST_SIGNATURE: RefCell<SignatureSlot> = const { RefCell::new(None) };
}

/// The signature of `library`, computed once per library build no matter how
/// many pages ask: the library is replaced wholesale, never mutated in place,
/// so the pointer names its contents.
pub fn library_signature(library: &Rc<Library>) -> Rc<LibrarySignature> {
    LAST_SIGNATURE.with(|slot| {
        if let Some((weak, signature)) = slot.borrow().as_ref() {
            if std::ptr::eq(weak.as_ptr(), Rc::as_ptr(library)) {
                return Rc::clone(signature);
            }
        }
        let signature = Rc::new(LibrarySignature::of(library));
        *slot.borrow_mut() = Some((Rc::downgrade(library), Rc::clone(&signature)));
        signature
    })
}

/// A weak note of which library a page last built from, so a reload that
/// carries the very same library can be told apart from a new one.
#[derive(Default)]
pub struct BuiltFrom(RefCell<Weak<Library>>);

impl BuiltFrom {
    pub fn is(&self, library: &Rc<Library>) -> bool {
        std::ptr::eq(self.0.borrow().as_ptr(), Rc::as_ptr(library))
    }

    pub fn set(&self, library: &Rc<Library>) {
        *self.0.borrow_mut() = Rc::downgrade(library);
    }
}

fn rediscover_candidates(album: &Album) -> RediscoverEntry {
    RediscoverEntry {
        id: album.key(),
        plays: album.tracks.iter().map(|track| track.play_count).sum(),
        last_played: album.last_played_unix(),
    }
}

/// The albums worth rediscovering, most neglected first.
pub fn rediscover_albums(albums: &[Album], now: i64) -> Vec<String> {
    let entries: Vec<RediscoverEntry> = albums.iter().map(rediscover_candidates).collect();
    rules::rediscover(&entries, now)
}

/// The tracks a Songs chip admits, by `rel_path`; `None` means every track.
/// Most Played is not decided here: it needs the scrobble table, so the page
/// asks the database and builds its own membership (see `most_played_ranking`).
pub fn songs_allowed(
    filter: LibraryFilter,
    tracks: &[Track],
    albums: &[Album],
    now: i64,
) -> Option<HashSet<String>> {
    match filter {
        LibraryFilter::All | LibraryFilter::MostPlayed => None,
        LibraryFilter::Favorites => Some(
            tracks
                .iter()
                .filter(|track| track.loved)
                .map(|track| track.rel_path.clone())
                .collect(),
        ),
        LibraryFilter::Lossless => Some(
            tracks
                .iter()
                .filter(|track| is_lossless(track))
                .map(|track| track.rel_path.clone())
                .collect(),
        ),
        LibraryFilter::RecentlyAdded => {
            let entries: Vec<AddedEntry> = tracks
                .iter()
                .map(|track| AddedEntry {
                    id: track.rel_path.clone(),
                    date_added: track.date_added,
                })
                .collect();
            Some(
                rules::recently_added(&entries, now, SONG_THRESHOLDS)
                    .into_iter()
                    .collect(),
            )
        }
        LibraryFilter::RecentlyPlayed => {
            let entries: Vec<PlayedEntry> = tracks
                .iter()
                .map(|track| PlayedEntry {
                    id: track.rel_path.clone(),
                    last_played: track.last_played,
                })
                .collect();
            Some(
                rules::recently_played(&entries, now, SONG_THRESHOLDS)
                    .into_iter()
                    .collect(),
            )
        }
        LibraryFilter::Rediscover => {
            let keys: HashSet<String> = rediscover_albums(albums, now).into_iter().collect();
            Some(
                albums
                    .iter()
                    .filter(|album| keys.contains(&album.key()))
                    .flat_map(|album| album.tracks.iter().map(|track| track.rel_path.clone()))
                    .collect(),
            )
        }
    }
}

/// The albums an Albums chip admits, by `Album::key`; `None` means every album.
pub fn albums_allowed(
    filter: LibraryFilter,
    albums: &[Album],
    now: i64,
) -> Option<HashSet<String>> {
    match filter {
        LibraryFilter::All | LibraryFilter::MostPlayed => None,
        LibraryFilter::Favorites => Some(
            albums
                .iter()
                .filter(|album| album.tracks.iter().any(|track| track.loved))
                .map(Album::key)
                .collect(),
        ),
        LibraryFilter::Lossless => Some(
            albums
                .iter()
                .filter(|album| album.tracks.first().is_some_and(is_lossless))
                .map(Album::key)
                .collect(),
        ),
        LibraryFilter::RecentlyAdded => {
            let entries: Vec<AddedEntry> = albums
                .iter()
                .map(|album| AddedEntry {
                    id: album.key(),
                    date_added: album.added_unix(),
                })
                .collect();
            Some(
                rules::recently_added(&entries, now, ALBUM_THRESHOLDS)
                    .into_iter()
                    .collect(),
            )
        }
        LibraryFilter::RecentlyPlayed => {
            let entries: Vec<PlayedEntry> = albums
                .iter()
                .map(|album| PlayedEntry {
                    id: album.key(),
                    last_played: album.last_played_unix(),
                })
                .collect();
            Some(
                rules::recently_played(&entries, now, ALBUM_THRESHOLDS)
                    .into_iter()
                    .collect(),
            )
        }
        LibraryFilter::Rediscover => Some(rediscover_albums(albums, now).into_iter().collect()),
    }
}

/// Plays inside a range for every track that has any, by `rel_path`, and the
/// order those tracks rank in (position 0 is the most played). `counts` is the
/// scrobble table grouped by song for the range.
pub fn most_played_ranking(
    tracks: &[Track],
    counts: &HashMap<String, i64>,
) -> (HashMap<String, i64>, HashMap<String, usize>) {
    let plays: HashMap<String, i64> = tracks
        .iter()
        .filter_map(|track| {
            let count = *counts.get(&crate::recap::track_key(&track.title, &track.artist))?;
            (count > 0).then(|| (track.rel_path.clone(), count))
        })
        .collect();
    let entries: Vec<rules::MostPlayedEntry> = tracks
        .iter()
        .filter_map(|track| {
            Some(rules::MostPlayedEntry {
                id: track.rel_path.clone(),
                plays: *plays.get(&track.rel_path)?,
                last_played: track.last_played,
                title: track.title.clone(),
            })
        })
        .collect();
    let rank = rules::most_played(&entries)
        .into_iter()
        .enumerate()
        .map(|(position, id)| (id, position))
        .collect();
    (plays, rank)
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_shared::library_filter::DAY;

    const NOW: i64 = 1_800_000_000;

    fn track(rel: &str, title: &str, artist: &str, album: &str) -> Track {
        Track {
            id: 0,
            rel_path: rel.to_string(),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            album_artist: None,
            track_number: 1,
            duration: 200.0,
            codec: Some("FLAC".to_string()),
            bit_depth: Some(16),
            sample_rate: Some(44_100),
            channels: Some(2),
            loved: false,
            play_count: 0,
            date_added: NOW - 400 * DAY,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    #[test]
    fn a_source_chip_admits_its_own_songs_only() {
        assert!(source_admits("", "Band/a.flac"));
        assert!(source_admits("", "remote://s1/abc"));
        assert!(source_admits(LOCAL_SOURCE, "Band/a.flac"));
        assert!(!source_admits(LOCAL_SOURCE, "remote://s1/abc"));
        assert!(source_admits("s1", "remote://s1/abc"));
        assert!(!source_admits("s1", "remote://s2/abc"));
        assert!(!source_admits("s1", "Band/a.flac"));
    }

    fn album(title: &str, artist: &str, tracks: Vec<Track>) -> Album {
        Album {
            title: title.to_string(),
            artist: artist.to_string(),
            year: None,
            genre: None,
            tracks,
        }
    }

    #[test]
    fn ids_round_trip_and_an_unknown_id_means_all() {
        for filter in LibraryFilter::SONGS {
            assert_eq!(LibraryFilter::from_id(filter.id()), filter);
        }
        assert_eq!(LibraryFilter::from_id("nonsense"), LibraryFilter::All);
        assert_eq!(range_from_id("7day"), Period::Week);
        assert_eq!(range_from_id("overall"), Period::AllTime);
        assert_eq!(range_from_id("nonsense"), DEFAULT_RANGE);
    }

    #[test]
    fn lossless_follows_the_apple_codec_set_without_regard_to_case() {
        let mut t = track("a", "A", "X", "AL");
        for codec in ["FLAC", "alac", "Wav", "AIFF"] {
            t.codec = Some(codec.to_string());
            assert!(is_lossless(&t), "{codec}");
        }
        for codec in ["MP3", "AAC", "OPUS"] {
            t.codec = Some(codec.to_string());
            assert!(!is_lossless(&t), "{codec}");
        }
        t.codec = None;
        assert!(!is_lossless(&t));
    }

    const SAMPLES: [&str; 12] = [
        "Abbey Road",
        "abbey road",
        "ÖDÖN",
        "ödön",
        "Straße",
        "STRASSE",
        "ΟΔΟΣ",
        "οδος",
        "İstanbul",
        "東京",
        "",
        "Zebra",
    ];

    #[test]
    fn case_blind_ordering_matches_comparing_the_lowercased_strings() {
        for a in SAMPLES {
            for b in SAMPLES {
                assert_eq!(
                    cmp_ignore_case(a, b),
                    a.to_lowercase().cmp(&b.to_lowercase()),
                    "{a:?} vs {b:?}"
                );
            }
        }
    }

    #[test]
    fn case_blind_search_matches_lowercasing_the_haystack() {
        let needles = ["abbey", "ödön", "ß", "ς", "σ", "οδος", "i̇stanbul", "東", "", "zz"];
        for haystack in SAMPLES {
            for needle in needles {
                assert_eq!(
                    contains_ignore_case(haystack, needle),
                    haystack.to_lowercase().contains(needle),
                    "{haystack:?} contains {needle:?}"
                );
            }
        }
    }

    #[test]
    fn a_search_needle_follows_the_query_it_is_given() {
        let needle = SearchNeedle::default();
        assert!(needle.matches("", &["anything"]));
        assert!(needle.matches("ROAD", &["Abbey Road", "x"]));
        assert!(!needle.matches("ROAD", &["Abbey", "Lane"]));
        assert!(needle.matches("lane", &["Abbey", "Penny Lane"]));
        assert!(!needle.matches("lane", &["Abbey Road"]));
    }

    #[test]
    fn a_library_signature_is_shared_per_build_and_follows_the_contents() {
        let mut loved = track("a.flac", "A", "X", "AL");
        loved.loved = true;
        let plain = track("a.flac", "A", "X", "AL");
        let build = |tracks: Vec<Track>| {
            Rc::new(Library {
                albums: vec![album("AL", "X", tracks.clone())],
                tracks,
                artists: Vec::new(),
                index: Default::default(),
            })
        };
        let first = build(vec![plain.clone()]);
        let same = library_signature(&first);
        assert!(Rc::ptr_eq(&same, &library_signature(&first)));
        let twin = build(vec![plain.clone()]);
        let twin_signature = library_signature(&twin);
        assert_eq!(same.track_rows, twin_signature.track_rows);
        assert_eq!(same.albums, twin_signature.albums);
        let hearted = library_signature(&build(vec![loved]));
        assert_ne!(same.track_rows, hearted.track_rows);
        assert_eq!(same.albums, hearted.albums);
    }

    #[test]
    fn built_from_tells_one_library_from_its_twin() {
        let library = Rc::new(Library::empty());
        let twin = Rc::new(Library::empty());
        let note = BuiltFrom::default();
        assert!(!note.is(&library));
        note.set(&library);
        assert!(note.is(&library));
        assert!(!note.is(&twin));
    }

    #[test]
    fn songs_chips_admit_the_right_tracks() {
        let mut loved = track("loved.flac", "Loved", "X", "AL");
        loved.loved = true;
        let mut lossy = track("lossy.mp3", "Lossy", "X", "AL");
        lossy.codec = Some("MP3".to_string());
        let tracks = vec![loved, lossy];
        let albums = vec![album("AL", "X", tracks.clone())];

        assert_eq!(
            songs_allowed(LibraryFilter::All, &tracks, &albums, NOW),
            None
        );
        assert_eq!(
            songs_allowed(LibraryFilter::MostPlayed, &tracks, &albums, NOW),
            None
        );
        let favorites =
            songs_allowed(LibraryFilter::Favorites, &tracks, &albums, NOW).expect("set");
        assert_eq!(favorites, HashSet::from(["loved.flac".to_string()]));
        let lossless = songs_allowed(LibraryFilter::Lossless, &tracks, &albums, NOW).expect("set");
        assert_eq!(lossless, HashSet::from(["loved.flac".to_string()]));
    }

    #[test]
    fn recently_added_takes_the_newest_when_too_few_are_recent() {
        let tracks: Vec<Track> = (0..60)
            .map(|k| {
                let mut t = track(&format!("{k}.flac"), &format!("T{k}"), "X", "AL");
                t.date_added = NOW - (100 + k) * DAY;
                t
            })
            .collect();
        let allowed = songs_allowed(LibraryFilter::RecentlyAdded, &tracks, &[], NOW).expect("set");
        assert_eq!(allowed.len(), 40, "the song fallback is the newest forty");
        assert!(allowed.contains("0.flac") && !allowed.contains("59.flac"));
    }

    #[test]
    fn rediscover_admits_every_track_of_a_neglected_album() {
        let mut loved_once = track("old-1.flac", "One", "X", "Old");
        loved_once.play_count = 6;
        loved_once.last_played = Some(NOW - 60 * DAY);
        let sibling = track("old-2.flac", "Two", "X", "Old");
        let mut fresh = track("new-1.flac", "New", "Y", "New");
        fresh.play_count = 9;
        fresh.last_played = Some(NOW - DAY);
        let albums = vec![
            album("Old", "X", vec![loved_once.clone(), sibling.clone()]),
            album("New", "Y", vec![fresh.clone()]),
        ];
        let tracks = vec![loved_once, sibling, fresh];
        let songs = songs_allowed(LibraryFilter::Rediscover, &tracks, &albums, NOW).expect("set");
        assert_eq!(
            songs,
            HashSet::from(["old-1.flac".to_string(), "old-2.flac".to_string()])
        );
        let albums_set = albums_allowed(LibraryFilter::Rediscover, &albums, NOW).expect("set");
        assert_eq!(albums_set, HashSet::from(["Old|X".to_string()]));
    }

    #[test]
    fn album_chips_read_the_album_as_a_whole() {
        let mut quiet = track("q.mp3", "Q", "X", "Quiet");
        quiet.codec = Some("MP3".to_string());
        let mut heart = track("h.flac", "H", "Y", "Heart");
        heart.loved = true;
        let albums = vec![
            album("Quiet", "X", vec![quiet]),
            album("Heart", "Y", vec![heart]),
        ];
        assert_eq!(
            albums_allowed(LibraryFilter::Favorites, &albums, NOW).expect("set"),
            HashSet::from(["Heart|Y".to_string()])
        );
        assert_eq!(
            albums_allowed(LibraryFilter::Lossless, &albums, NOW).expect("set"),
            HashSet::from(["Heart|Y".to_string()])
        );
        assert_eq!(albums_allowed(LibraryFilter::All, &albums, NOW), None);
    }

    #[test]
    fn most_played_ranks_by_range_plays_and_leaves_out_the_silent() {
        let mut a = track("a.flac", "Alpha", "X", "AL");
        a.last_played = Some(NOW - 5 * DAY);
        let mut b = track("b.flac", "Beta", "X", "AL");
        b.last_played = Some(NOW - DAY);
        let c = track("c.flac", "Gamma", "X", "AL");
        let tracks = vec![a, b, c];
        let counts = HashMap::from([
            (crate::recap::track_key("Alpha", "X"), 3),
            (crate::recap::track_key("Beta", "X"), 3),
            (crate::recap::track_key("Elsewhere", "Z"), 9),
        ]);
        let (plays, rank) = most_played_ranking(&tracks, &counts);
        assert_eq!(plays.get("a.flac"), Some(&3));
        assert_eq!(plays.get("c.flac"), None);
        assert_eq!(
            rank.get("b.flac"),
            Some(&0),
            "same plays, played more recently ranks first"
        );
        assert_eq!(rank.get("a.flac"), Some(&1));
        assert_eq!(rank.get("c.flac"), None);
    }
}
