//! What the window's search box finds across the whole library: artists,
//! albums, songs and playlists, each ordered by how well its name answers the
//! query (the shared `library_search` rules), then by how much it is played.
//! The page that shows them is `ui::search`.

use crate::filters::cmp_ignore_case;
use crate::hygiene;
use crate::library::{Album, ArtistEntry, Library, Track};
use flaccy_shared::library_search::{Query, Rank};
use std::cmp::Reverse;

pub const ARTIST_LIMIT: usize = 8;
pub const ALBUM_LIMIT: usize = 12;
pub const SONG_LIMIT: usize = 50;
pub const PLAYLIST_LIMIT: usize = 8;

/// One kind of result: the best of what matched, how many matched in all, and
/// how well the first of them answers the query.
pub struct Found<T> {
    pub shown: Vec<T>,
    pub total: usize,
    pub best: Option<Rank>,
}

impl<T> Default for Found<T> {
    fn default() -> Self {
        Self {
            shown: Vec::new(),
            total: 0,
            best: None,
        }
    }
}

/// A playlist as the search knows it: its position among the cards it was
/// handed and its name.
pub struct PlaylistName<'a> {
    pub index: usize,
    pub name: &'a str,
}

#[derive(Default)]
pub struct Results {
    pub artists: Found<ArtistEntry>,
    pub albums: Found<Album>,
    pub songs: Found<Track>,
    /// Positions into the playlists the search was handed.
    pub playlists: Found<usize>,
}

/// The single result Enter opens.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TopHit {
    Artist,
    Album,
    Song,
    Playlist,
}

impl Results {
    pub fn is_empty(&self) -> bool {
        self.artists.total + self.albums.total + self.songs.total + self.playlists.total == 0
    }

    /// The kind whose first result answers the query best. A tie goes to the
    /// kind shown higher on the page.
    pub fn top_hit(&self) -> Option<TopHit> {
        [
            (self.artists.best, TopHit::Artist),
            (self.albums.best, TopHit::Album),
            (self.songs.best, TopHit::Song),
            (self.playlists.best, TopHit::Playlist),
        ]
        .into_iter()
        .filter_map(|(rank, hit)| rank.map(|rank| (rank, hit)))
        .min_by_key(|(rank, _)| *rank)
        .map(|(_, hit)| hit)
    }
}

/// Orders the rows a query finds: best rank first, then the most played, then
/// by name, and keeps the first `limit`.
fn ranked<'a, T>(
    rows: impl Iterator<Item = &'a T>,
    limit: usize,
    rank: impl Fn(&T) -> Option<Rank>,
    plays: impl Fn(&T) -> i64,
    name: impl Fn(&T) -> &str,
) -> (Vec<&'a T>, usize, Option<Rank>) {
    let mut found: Vec<(Rank, Reverse<i64>, &T)> = rows
        .filter_map(|row| rank(row).map(|rank| (rank, Reverse(plays(row)), row)))
        .collect();
    found.sort_by(|a, b| {
        a.0.cmp(&b.0)
            .then(a.1.cmp(&b.1))
            .then_with(|| cmp_ignore_case(name(a.2), name(b.2)))
    });
    let total = found.len();
    let best = found.first().map(|(rank, _, _)| *rank);
    let shown = found.into_iter().take(limit).map(|(_, _, row)| row).collect();
    (shown, total, best)
}

fn found<T: Clone>((shown, total, best): (Vec<&T>, usize, Option<Rank>)) -> Found<T> {
    Found {
        shown: shown.into_iter().cloned().collect(),
        total,
        best,
    }
}

pub fn artists(artists: &[ArtistEntry], query: &Query) -> Found<ArtistEntry> {
    found(ranked(
        artists.iter(),
        ARTIST_LIMIT,
        |artist| query.rank(&artist.name, &[]),
        |artist| artist.play_count,
        |artist| &artist.name,
    ))
}

pub fn albums(albums: &[Album], query: &Query) -> Found<Album> {
    found(ranked(
        albums.iter(),
        ALBUM_LIMIT,
        |album| query.rank(&album.title, &[&album.artist]),
        |album| album.tracks.iter().map(|track| track.play_count).sum(),
        |album| &album.title,
    ))
}

/// How well a song answers a query. A title that is the query, or begins with
/// it, comes first; past that a word somewhere in the title says no more than
/// the artist or the album matching, so those are one group and the most
/// played leads it.
fn song_rank(track: &Track, query: &Query) -> Option<Rank> {
    query
        .rank(&track.title, &[&track.artist, &track.album])
        .map(|rank| if rank > Rank::Prefix { Rank::Elsewhere } else { rank })
}

/// The songs a query finds. With Clean Library on, the copies of one song are
/// folded into the copy the Songs list would keep.
pub fn songs(tracks: &[Track], query: &Query, hide_duplicates: bool) -> Found<Track> {
    let (mut matched, _, _) = ranked(
        tracks.iter(),
        usize::MAX,
        |track| song_rank(track, query),
        |track| track.play_count,
        |track| &track.title,
    );
    if hide_duplicates {
        let hidden = hygiene::collapsing_duplicate_songs(
            matched.iter().copied(),
            &mut hygiene::SongKeyMemo::default(),
            |track| i32::from(track.loved) * 2 + i32::from(track.last_played.is_some()),
        )
        .hidden;
        matched.retain(|track| !hidden.contains(&track.rel_path));
    }
    let total = matched.len();
    let best = matched.first().and_then(|track| song_rank(track, query));
    Found {
        shown: matched.into_iter().take(SONG_LIMIT).cloned().collect(),
        total,
        best,
    }
}

pub fn playlists(names: &[PlaylistName], query: &Query) -> Found<usize> {
    let (shown, total, best) = ranked(
        names.iter(),
        PLAYLIST_LIMIT,
        |playlist| query.rank(playlist.name, &[]),
        |_| 0,
        |playlist| playlist.name,
    );
    Found {
        shown: shown.into_iter().map(|playlist| playlist.index).collect(),
        total,
        best,
    }
}

/// Everything `text` finds in the library and among `playlist_names`. A blank
/// query finds nothing.
pub fn find(
    library: &Library,
    playlist_names: &[PlaylistName],
    text: &str,
    hide_duplicates: bool,
) -> Results {
    let query = Query::new(text);
    if query.is_empty() {
        return Results::default();
    }
    Results {
        artists: artists(&library.artists, &query),
        albums: albums(&library.albums, &query),
        songs: songs(&library.tracks, &query, hide_duplicates),
        playlists: playlists(playlist_names, &query),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(title: &str, artist: &str, album: &str, plays: i64) -> Track {
        Track {
            id: 0,
            rel_path: format!("{artist}/{album}/{title}.flac"),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            album_artist: None,
            track_number: 1,
            duration: 200.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: plays,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    fn artist(name: &str, plays: i64) -> ArtistEntry {
        ArtistEntry {
            name: name.to_string(),
            album_count: 1,
            appearance_count: 0,
            track_count: 1,
            play_count: plays,
            last_played: None,
        }
    }

    fn album(title: &str, artist: &str, plays: i64) -> Album {
        Album {
            title: title.to_string(),
            artist: artist.to_string(),
            year: None,
            genre: None,
            tracks: vec![song("One", artist, title, plays)],
        }
    }

    fn titles(found: &Found<Track>) -> Vec<&str> {
        found.shown.iter().map(|track| track.title.as_str()).collect()
    }

    #[test]
    fn a_better_name_match_beats_more_plays() {
        let rows = [
            artist("Radio Dept.", 900),
            artist("Radiohead", 10),
            artist("TV on the Radio", 5000),
            artist("Radio", 1),
        ];
        let found = artists(&rows, &Query::new("radio"));
        let names: Vec<&str> = found.shown.iter().map(|artist| artist.name.as_str()).collect();
        assert_eq!(names, ["Radio", "Radio Dept.", "Radiohead", "TV on the Radio"]);
        assert_eq!(found.best, Some(Rank::Exact));
    }

    #[test]
    fn plays_then_names_order_equal_matches() {
        let rows = [artist("Low Roar", 3), artist("Low", 0), artist("Lower Dens", 3)];
        let found = artists(&rows, &Query::new("lo"));
        let names: Vec<&str> = found.shown.iter().map(|artist| artist.name.as_str()).collect();
        assert_eq!(names, ["Low Roar", "Lower Dens", "Low"]);
    }

    #[test]
    fn words_find_an_album_through_its_artist_in_any_order() {
        let rows = [
            album("Abbey Road", "The Beatles", 4),
            album("Revolver", "The Beatles", 9),
            album("Road to Ruin", "Ramones", 1),
        ];
        let found = albums(&rows, &Query::new("beatles abbey"));
        assert_eq!(found.total, 1);
        assert_eq!(found.shown[0].title, "Abbey Road");
        assert_eq!(found.best, Some(Rank::Prefix));
        let by_artist = albums(&rows, &Query::new("beatles"));
        let found_titles: Vec<&str> = by_artist.shown.iter().map(|album| album.title.as_str()).collect();
        assert_eq!(found_titles, ["Revolver", "Abbey Road"]);
        assert_eq!(by_artist.best, Some(Rank::Elsewhere));
    }

    #[test]
    fn songs_named_by_the_query_come_before_songs_on_a_matching_album() {
        let rows = [
            song("Come Together", "The Beatles", "Abbey Road", 50),
            song("Abbey Road Medley", "Tribute", "Covers", 0),
            song("Something", "The Beatles", "Abbey Road", 20),
        ];
        let found = songs(&rows, &Query::new("abbey road"), false);
        assert_eq!(titles(&found), ["Abbey Road Medley", "Come Together", "Something"]);
        assert_eq!(found.total, 3);
    }

    #[test]
    fn a_song_named_by_the_rest_of_the_query_beats_one_that_mentions_every_word() {
        let rows = [
            song("One [Live cover on Metallica]", "KoRn", "Live & Rare", 500),
            song("Spit Out the Bone", "Metallica", "Hardwired", 90),
            song("One", "Metallica", "...And Justice for All", 3),
            song("One (Live)", "Metallica", "S&M2", 1),
        ];
        let found = songs(&rows, &Query::new("metallica one"), false);
        assert_eq!(
            titles(&found),
            ["One", "One (Live)", "One [Live cover on Metallica]", "Spit Out the Bone"]
        );
    }

    #[test]
    fn past_a_title_that_starts_with_the_query_the_most_played_song_leads() {
        let rows = [
            song("Another Brick in the Wall [Cover on Pink Floyd]", "KoRn", "Live", 2),
            song("Comfortably Numb", "Pink Floyd", "The Wall", 80),
            song("Floyd the Barber", "Nirvana", "Bleach", 1),
        ];
        let found = songs(&rows, &Query::new("floyd"), false);
        assert_eq!(
            titles(&found),
            [
                "Floyd the Barber",
                "Comfortably Numb",
                "Another Brick in the Wall [Cover on Pink Floyd]"
            ]
        );
    }

    #[test]
    fn the_shown_songs_stop_at_the_limit_and_the_total_does_not() {
        let rows: Vec<Track> = (0..SONG_LIMIT + 7)
            .map(|index| song(&format!("Take {index}"), "Band", "Sessions", index as i64))
            .collect();
        let found = songs(&rows, &Query::new("take"), false);
        assert_eq!(found.shown.len(), SONG_LIMIT);
        assert_eq!(found.total, SONG_LIMIT + 7);
        assert_eq!(found.shown[0].title, format!("Take {}", SONG_LIMIT + 6));
    }

    #[test]
    fn clean_library_keeps_one_copy_of_a_song() {
        let mut second = song("Karma Police", "Radiohead", "OK Computer", 0);
        second.rel_path = "copy/Karma Police.flac".to_string();
        let rows = [song("Karma Police", "Radiohead", "OK Computer", 3), second];
        assert_eq!(songs(&rows, &Query::new("karma"), true).total, 1);
        assert_eq!(songs(&rows, &Query::new("karma"), false).total, 2);
    }

    #[test]
    fn enter_opens_the_kind_that_answers_best() {
        let names = ["Bjork Mix", "Morning"];
        let listed: Vec<PlaylistName> = names
            .iter()
            .enumerate()
            .map(|(index, name)| PlaylistName { index, name })
            .collect();
        let query = Query::new("bjork");
        let results = Results {
            artists: artists(&[artist("Björk", 1)], &query),
            albums: albums(&[album("Debut", "Björk", 1)], &query),
            songs: songs(&[song("Bjork Interlude", "Someone", "Tape", 99)], &query, false),
            playlists: playlists(&listed, &query),
        };
        assert_eq!(results.top_hit(), Some(TopHit::Artist));
        assert_eq!(results.playlists.shown, [0]);
        let query = Query::new("debut");
        let results = Results {
            artists: artists(&[artist("Björk", 1)], &query),
            albums: albums(&[album("Debut", "Björk", 1)], &query),
            ..Results::default()
        };
        assert_eq!(results.top_hit(), Some(TopHit::Album));
        assert!(Results::default().top_hit().is_none());
        assert!(Results::default().is_empty());
    }
}
