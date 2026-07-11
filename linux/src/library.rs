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

pub fn load(db: &Db, group_album_editions: bool) -> Library {
    let tracks = db.fetch_all_tracks();
    let meta = db.album_meta();

    let mut grouped: HashMap<String, Vec<Track>> = HashMap::new();
    for track in &tracks {
        grouped
            .entry(format!("{}|{}", track.album, track.artist))
            .or_default()
            .push(track.clone());
    }

    let mut albums: Vec<Album> = grouped
        .into_values()
        .filter_map(|mut group| {
            let first = group.first()?.clone();
            group.sort_by(|a, b| {
                a.track_number
                    .cmp(&b.track_number)
                    .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
            });
            let (year, genre) = meta
                .get(&(first.album.clone(), first.artist.clone()))
                .cloned()
                .unwrap_or((None, None));
            Some(Album {
                title: first.album,
                artist: first.artist,
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

    let last_played = db.track_sort_keys();
    let mut artist_map: HashMap<String, (String, usize, usize, i64, Option<i64>)> = HashMap::new();
    for album in &albums {
        let primary = crate::hygiene::primary_artist(&album.artist);
        let entry = artist_map
            .entry(primary.to_lowercase())
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
