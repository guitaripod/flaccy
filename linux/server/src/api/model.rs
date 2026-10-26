//! The JSON shapes the endpoints answer with, built on the models the Flaccy
//! clients decode with so the two cannot drift apart.

use chrono::{DateTime, SecondsFormat, Utc};
use flaccy_shared::remote::subsonic_response::{AlbumId3, Artist as ArtistEntry, Child};
use serde::Serialize;
use serde_json::Value;

use super::userview::UserView;
use crate::catalog::{Album, Artist, Catalog, Song};

/// A song with the fields beyond the shared `Child`.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SongOut {
    #[serde(flatten)]
    child: Child,
    is_dir: bool,
    media_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    played: Option<String>,
    play_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    starred: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    user_rating: Option<i64>,
}

/// An album with the fields beyond the shared `AlbumId3`.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AlbumOut {
    #[serde(flatten)]
    info: AlbumId3,
    play_count: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    played: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    starred: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    song: Option<Vec<SongOut>>,
}

/// Unix seconds as the ISO 8601 UTC text Subsonic uses.
pub fn iso(seconds: i64) -> String {
    DateTime::<Utc>::from_timestamp(seconds, 0)
        .unwrap_or_default()
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// Unix milliseconds as ISO 8601 UTC text.
pub fn iso_ms(milliseconds: i64) -> String {
    DateTime::<Utc>::from_timestamp_millis(milliseconds)
        .unwrap_or_default()
        .to_rfc3339_opts(SecondsFormat::Secs, true)
}

/// The lowercase extension of a path.
pub fn suffix_of(rel_path: &str) -> String {
    rel_path
        .rsplit_once('.')
        .map(|(_, suffix)| suffix.to_ascii_lowercase())
        .unwrap_or_default()
}

/// The media type a file with this suffix is streamed as.
pub fn content_type_of(suffix: &str) -> &'static str {
    match suffix {
        "flac" => "audio/flac",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" => "audio/mp4",
        "ogg" => "audio/ogg",
        "opus" => "audio/ogg",
        "wav" => "audio/x-wav",
        "aiff" | "aif" => "audio/aiff",
        _ => "application/octet-stream",
    }
}

fn song_child(catalog: &Catalog, song: &Song) -> Child {
    let row = &song.row;
    let suffix = suffix_of(&row.rel_path);
    let album = catalog.album(&song.album_id);
    let bit_rate = (row.duration > 0.0 && song.size > 0)
        .then(|| ((song.size as f64 * 8.0) / row.duration / 1000.0).round() as i64);
    Child {
        id: song.id(),
        parent: Some(song.album_id.clone()),
        title: row.title.clone(),
        album: Some(row.album.clone()),
        artist: Some(row.artist.clone()),
        track: (row.track_number > 0).then_some(i64::from(row.track_number)),
        disc_number: song.disc,
        year: album.and_then(|album| album.year),
        genre: album.and_then(|album| album.genre.clone()),
        cover_art: Some(if row.album.is_empty() {
            song.id()
        } else {
            song.album_id.clone()
        }),
        size: (song.size > 0).then_some(song.size),
        content_type: Some(content_type_of(&suffix).to_string()),
        suffix: Some(suffix),
        duration: Some(row.duration.round() as i64),
        bit_rate,
        bit_depth: row.bit_depth.map(i64::from),
        sampling_rate: row.sample_rate.map(i64::from),
        channel_count: row.channels.map(i64::from),
        path: Some(row.rel_path.clone()),
        album_id: Some(song.album_id.clone()),
        artist_id: Some(song.artist_id.clone()),
        kind: Some("music".to_string()),
        created: Some(iso(row.date_added)),
        music_brainz_id: song.musicbrainz_id.clone().filter(|id| !id.is_empty()),
        display_artist: Some(row.artist.clone()),
        display_album_artist: album.map(|album| album.artist.clone()),
        flaccy_fingerprint: song.fingerprint.clone(),
        flaccy_revision: Some(row.revision),
        flaccy_revised_at: row.revised_at.map(iso_ms),
        starred: None,
        play_count: None,
        played: None,
    }
}

fn song_out(catalog: &Catalog, view: &UserView, song: &Song) -> SongOut {
    let key = &song.song_key;
    SongOut {
        child: song_child(catalog, song),
        is_dir: false,
        media_type: "song",
        played: view.last_played(key).map(iso),
        play_count: view.play_count(key),
        starred: view.starred_at(key).map(iso_ms),
        user_rating: view.rating(key),
    }
}

/// Total plays across `album`.
pub fn album_play_count(catalog: &Catalog, view: &UserView, album: &Album) -> i64 {
    catalog.album_songs(album).map(|song| view.play_count(&song.song_key)).sum()
}

/// When any song of `album` was last played, in Unix seconds.
pub fn album_last_played(catalog: &Catalog, view: &UserView, album: &Album) -> Option<i64> {
    catalog.album_songs(album).filter_map(|song| view.last_played(&song.song_key)).max()
}

/// Whether every song of `album` is starred, which is what a starred album means here.
pub fn album_is_starred(catalog: &Catalog, view: &UserView, album: &Album) -> bool {
    !album.songs.is_empty() && catalog.album_songs(album).all(|song| view.starred_at(&song.song_key).is_some())
}

fn album_id3(catalog: &Catalog, album: &Album) -> AlbumId3 {
    AlbumId3 {
        id: album.id.clone(),
        name: album.title.clone(),
        artist: Some(album.artist.clone()),
        artist_id: Some(album.artist_id.clone()),
        cover_art: Some(album.id.clone()),
        song_count: Some(album.songs.len() as i64),
        duration: Some(catalog.album_duration(album).round() as i64),
        created: Some(iso(album.created)),
        year: album.year,
        genre: album.genre.clone(),
        display_artist: Some(album.artist.clone()),
    }
}

fn album_out(catalog: &Catalog, view: &UserView, album: &Album, with_songs: bool) -> AlbumOut {
    AlbumOut {
        info: album_id3(catalog, album),
        play_count: album_play_count(catalog, view, album),
        played: album_last_played(catalog, view, album).map(iso),
        starred: album_is_starred(catalog, view, album).then(|| iso(album.created)),
        song: with_songs.then(|| {
            catalog
                .album_songs(album)
                .map(|song| song_out(catalog, view, song))
                .collect()
        }),
    }
}

fn value<T: Serialize>(item: &T) -> Value {
    serde_json::to_value(item).unwrap_or(Value::Null)
}

/// A song as JSON.
pub fn song_value(catalog: &Catalog, view: &UserView, song: &Song) -> Value {
    value(&song_out(catalog, view, song))
}

/// An album without its songs as JSON.
pub fn album_value(catalog: &Catalog, view: &UserView, album: &Album) -> Value {
    value(&album_out(catalog, view, album, false))
}

/// An album with its songs in play order as JSON.
pub fn album_with_songs_value(catalog: &Catalog, view: &UserView, album: &Album) -> Value {
    value(&album_out(catalog, view, album, true))
}

/// An artist as a list entry as JSON.
pub fn artist_entry_value(artist: &Artist) -> Value {
    value(&ArtistEntry {
        id: Some(artist.id.clone()),
        name: Some(artist.name.clone()),
        album_count: Some(artist.albums.len() as i64),
        cover_art: Some(artist.id.clone()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timestamps_are_iso_8601_in_utc() {
        assert_eq!(iso(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso_ms(86_400_000), "1970-01-02T00:00:00Z");
    }

    #[test]
    fn suffixes_map_to_media_types() {
        assert_eq!(suffix_of("A/b.FLAC"), "flac");
        assert_eq!(content_type_of("flac"), "audio/flac");
        assert_eq!(content_type_of("wav"), "audio/x-wav");
        assert_eq!(content_type_of("xyz"), "application/octet-stream");
    }
}
