//! An in-memory picture of the library, grouped the way the Flaccy clients
//! group it, with the ids the API hands out.
//!
//! It is built from `flaccy_library::library::load` after every scan. Play
//! counts, loved flags and ratings change between scans, so they are updated in
//! place here as well as in the database.

use std::collections::HashMap;
use std::path::Path;

use flaccy_library::db::Db;
use flaccy_library::hygiene;
use flaccy_library::library::{self, disc_sections, TrackRow};

use crate::ids;
use crate::store::{Store, TrackExtra};

/// One song: its library row plus what the API reports beyond it.
#[derive(Clone, Debug)]
pub struct Song {
    pub row: TrackRow,
    pub size: i64,
    pub fingerprint: Option<String>,
    pub musicbrainz_id: Option<String>,
    pub rating: Option<i64>,
    pub album_id: String,
    pub artist_id: String,
    pub disc: Option<i64>,
}

impl Song {
    /// The id the API uses for this song.
    pub fn id(&self) -> String {
        ids::song(self.row.id)
    }
}

/// One album as the library groups it, songs in play order.
#[derive(Clone, Debug)]
pub struct Album {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub artist_id: String,
    pub year: Option<i64>,
    pub genre: Option<String>,
    pub songs: Vec<i64>,
    pub created: i64,
    pub art_keys: Vec<(String, String)>,
}

/// One artist and the albums they are credited on or perform on.
#[derive(Clone, Debug)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub albums: Vec<String>,
}

/// The whole library in memory.
#[derive(Default)]
pub struct Catalog {
    songs: HashMap<i64, Song>,
    song_order: Vec<i64>,
    song_by_path: HashMap<String, i64>,
    albums: Vec<Album>,
    album_by_id: HashMap<String, usize>,
    artists: Vec<Artist>,
    artist_by_id: HashMap<String, usize>,
}

impl Catalog {
    /// Groups the library in `db`, adding the extras and ratings `store` holds.
    /// `root` is the music folder, used to size files the scan never measured.
    pub fn build(db: &Db, store: &Store, root: &Path) -> Catalog {
        let library = library::load(db, false);
        let extras = store.track_extras();
        let ratings = store.ratings();
        let mut catalog = Catalog::default();
        for album in &library.albums {
            let Some(first) = album.tracks.first() else {
                continue;
            };
            let album_id = ids::album(&first.album, first.credit());
            let artist_id = ids::artist(&album.artist);
            let discs = disc_numbers(&album.tracks);
            let mut song_ids = Vec::with_capacity(album.tracks.len());
            for track in &album.tracks {
                let extra = extras.get(&track.id).cloned().unwrap_or_default();
                let song = Song {
                    size: file_size(&extra, root, track),
                    fingerprint: extra.fingerprint,
                    musicbrainz_id: extra.musicbrainz_id,
                    rating: ratings.get(&track.rel_path).copied(),
                    album_id: album_id.clone(),
                    artist_id: ids::artist(&track.artist),
                    disc: discs.get(&track.rel_path).copied(),
                    row: track.clone(),
                };
                song_ids.push(track.id);
                catalog.song_order.push(track.id);
                catalog.song_by_path.insert(track.rel_path.clone(), track.id);
                catalog.songs.insert(track.id, song);
            }
            catalog.album_by_id.insert(album_id.clone(), catalog.albums.len());
            catalog.albums.push(Album {
                id: album_id,
                title: album.title.clone(),
                artist: album.artist.clone(),
                artist_id,
                year: album.year.as_deref().and_then(leading_year),
                genre: album.genre.clone().filter(|genre| !genre.is_empty()),
                songs: song_ids,
                created: album.added_unix(),
                art_keys: album.artwork_keys(),
            });
        }
        catalog.group_artists(&library);
        catalog
    }

    fn group_artists(&mut self, library: &library::Library) {
        let mut by_id: HashMap<String, Artist> = HashMap::new();
        let mut note = |name: &str, album_id: &str| {
            let id = ids::artist(name);
            let artist = by_id.entry(id.clone()).or_insert_with(|| Artist {
                id,
                name: hygiene::primary_artist(name),
                albums: Vec::new(),
            });
            if !artist.albums.iter().any(|existing| existing == album_id) {
                artist.albums.push(album_id.to_string());
            }
        };
        for (album, source) in self.albums.iter().zip(&library.albums) {
            note(&album.artist, &album.id);
            for track in &source.tracks {
                note(&track.artist, &album.id);
            }
        }
        let mut artists: Vec<Artist> = by_id.into_values().collect();
        artists.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()).then_with(|| a.id.cmp(&b.id)));
        self.artist_by_id = artists
            .iter()
            .enumerate()
            .map(|(index, artist)| (artist.id.clone(), index))
            .collect();
        self.artists = artists;
    }

    /// Copies play counts, last played times and loved flags from `rows`, and
    /// ratings from `ratings`, onto the songs they belong to.
    pub fn apply_dynamic(&mut self, rows: &[TrackRow], ratings: &HashMap<String, i64>) {
        for row in rows {
            if let Some(song) = self.songs.get_mut(&row.id) {
                song.row.loved = row.loved;
                song.row.play_count = row.play_count;
                song.row.last_played = row.last_played;
            }
        }
        for song in self.songs.values_mut() {
            song.rating = ratings.get(&song.row.rel_path).copied();
        }
    }

    /// Every song, in album order.
    pub fn songs_in_order(&self) -> impl Iterator<Item = &Song> {
        self.song_order.iter().filter_map(|id| self.songs.get(id))
    }

    /// How many songs the library holds.
    pub fn song_count(&self) -> usize {
        self.songs.len()
    }

    /// The song in track row `row_id`.
    pub fn song(&self, row_id: i64) -> Option<&Song> {
        self.songs.get(&row_id)
    }

    /// The song stored at `rel_path`.
    pub fn song_at_path(&self, rel_path: &str) -> Option<&Song> {
        self.song_by_path
            .get(rel_path)
            .and_then(|id| self.songs.get(id))
    }

    /// All albums, ordered by credit then title.
    pub fn albums(&self) -> &[Album] {
        &self.albums
    }

    /// The album with API id `id`.
    pub fn album(&self, id: &str) -> Option<&Album> {
        self.album_by_id.get(id).map(|&index| &self.albums[index])
    }

    /// All artists, ordered by name.
    pub fn artists(&self) -> &[Artist] {
        &self.artists
    }

    /// The artist with API id `id`.
    pub fn artist(&self, id: &str) -> Option<&Artist> {
        self.artist_by_id.get(id).map(|&index| &self.artists[index])
    }

    /// The songs of `album`, in play order.
    pub fn album_songs<'a>(&'a self, album: &'a Album) -> impl Iterator<Item = &'a Song> {
        album.songs.iter().filter_map(|id| self.songs.get(id))
    }

    /// Total plays across `album`.
    pub fn album_play_count(&self, album: &Album) -> i64 {
        self.album_songs(album).map(|song| song.row.play_count).sum()
    }

    /// When any song of `album` was last played.
    pub fn album_last_played(&self, album: &Album) -> Option<i64> {
        self.album_songs(album).filter_map(|song| song.row.last_played).max()
    }

    /// Whether every song of `album` is loved, which is what a starred album means here.
    pub fn album_is_starred(&self, album: &Album) -> bool {
        !album.songs.is_empty() && self.album_songs(album).all(|song| song.row.loved)
    }

    /// Total running time of `album` in seconds.
    pub fn album_duration(&self, album: &Album) -> f64 {
        self.album_songs(album).map(|song| song.row.duration).sum()
    }

    /// Marks the song loved or not.
    pub fn set_loved(&mut self, row_id: i64, loved: bool) {
        if let Some(song) = self.songs.get_mut(&row_id) {
            song.row.loved = loved;
        }
    }

    /// Counts one more play at `played_at` (Unix seconds).
    pub fn record_play(&mut self, row_id: i64, played_at: i64) {
        if let Some(song) = self.songs.get_mut(&row_id) {
            song.row.play_count += 1;
            song.row.last_played = Some(played_at);
        }
    }

    /// Sets or clears the song's rating.
    pub fn set_rating(&mut self, row_id: i64, rating: Option<i64>) {
        if let Some(song) = self.songs.get_mut(&row_id) {
            song.rating = rating;
        }
    }
}

fn file_size(extra: &TrackExtra, root: &Path, track: &TrackRow) -> i64 {
    extra
        .size
        .or_else(|| {
            std::fs::metadata(track.abs_path(root))
                .ok()
                .and_then(|metadata| i64::try_from(metadata.len()).ok())
        })
        .unwrap_or(0)
}

fn leading_year(text: &str) -> Option<i64> {
    let digits: String = text.trim().chars().take_while(char::is_ascii_digit).collect();
    if digits.len() == 4 {
        digits.parse().ok()
    } else {
        None
    }
}

/// Disc numbers by path for an album whose files carry disc or side markers,
/// numbering the sections in the order they play.
fn disc_numbers(tracks: &[TrackRow]) -> HashMap<String, i64> {
    let mut numbers = HashMap::new();
    if let Some(sections) = disc_sections(tracks) {
        for (index, section) in sections.iter().enumerate() {
            for track in &section.tracks {
                numbers.insert(track.rel_path.clone(), index as i64 + 1);
            }
        }
    }
    numbers
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_four_digit_year_counts() {
        assert_eq!(leading_year("1999"), Some(1999));
        assert_eq!(leading_year("2004-05-01"), Some(2004));
        assert_eq!(leading_year("99"), None);
        assert_eq!(leading_year(""), None);
    }
}
