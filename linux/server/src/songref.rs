//! How a song is named to the sync state: the `SongRef` of a library song, and of
//! one the library no longer holds.

use flaccy_library::listen_history::album_listen_key;
use flaccy_library::server_sync::song_key_of;
use flaccy_server_core::model::SongRef;

use crate::catalog::Song;

const MILLIS_PER_SECOND: f64 = 1000.0;

/// The reference for a library song: its identity key, credits and length, with the fingerprint, MusicBrainz id and
/// path the library knows.
pub fn song_ref(song: &Song) -> SongRef {
    let row = &song.row;
    SongRef {
        song_key: song.song_key.clone(),
        title: row.title.clone(),
        artist: row.artist.clone(),
        album: row.album.clone(),
        duration_ms: (row.duration * MILLIS_PER_SECOND).round() as i64,
        fp: song.fingerprint.clone().filter(|text| !text.is_empty()),
        mbid: song.musicbrainz_id.clone().filter(|text| !text.is_empty()),
        album_key: album_key_of(&row.album),
        rel_path: Some(row.rel_path.clone()),
    }
}

/// The reference for a song known only by its credits, as a play of something the library does not hold.
pub fn credits_ref(title: &str, artist: &str, album: &str, rel_path: Option<&str>) -> SongRef {
    SongRef {
        song_key: song_key_of(title, artist),
        title: title.to_owned(),
        artist: artist.to_owned(),
        album: album.to_owned(),
        duration_ms: 0,
        fp: None,
        mbid: None,
        album_key: album_key_of(album),
        rel_path: rel_path.map(str::to_owned),
    }
}

/// The reference for a file the library no longer lists, named from its path: the title is the file name without
/// its track number, the album the folder, the artist the folder above.
pub fn path_ref(rel_path: &str) -> SongRef {
    let mut parts = rel_path.rsplit('/');
    let file = parts.next().unwrap_or(rel_path);
    let album = parts.next().unwrap_or("");
    let artist = parts.next().unwrap_or("");
    let stem = file.rsplit_once('.').map_or(file, |(stem, _)| stem);
    let title = stem.trim_start_matches(|c: char| c.is_ascii_digit() || c == '-' || c == '.' || c == ' ');
    let title = if title.is_empty() { stem } else { title };
    credits_ref(title, artist, album, Some(rel_path))
}

fn album_key_of(album: &str) -> Option<String> {
    Some(album_listen_key(album)).filter(|key| !key.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_names_a_title_an_album_and_an_artist() {
        let song = path_ref("Drill Band/Rough Cuts/02 Middle.flac");
        assert_eq!(song.title, "Middle");
        assert_eq!(song.album, "Rough Cuts");
        assert_eq!(song.artist, "Drill Band");
        assert_eq!(song.rel_path.as_deref(), Some("Drill Band/Rough Cuts/02 Middle.flac"));
        assert_eq!(song.song_key, song_key_of("Middle", "Drill Band"));
    }

    #[test]
    fn a_bare_file_name_still_makes_a_reference() {
        let song = path_ref("07.flac");
        assert_eq!(song.title, "07");
        assert_eq!(song.artist, "");
    }
}
