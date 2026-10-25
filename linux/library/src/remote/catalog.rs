//! A server's song as the library stores it: the fields of a library row plus
//! what is needed to fetch the audio and the cover again.

use crate::remote::{decode_segment, encode_segment};
use flaccy_shared::remote::catalog_diff::CatalogSong;
use flaccy_shared::remote::remote_path;
use flaccy_shared::remote::subsonic_response::Child;

/// One song of one server, ready to become or refresh a library row.
#[derive(Clone, Debug, PartialEq)]
pub struct RemoteSong {
    pub server: String,
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub track_number: i32,
    pub duration: f64,
    pub codec: Option<String>,
    pub bit_depth: Option<i32>,
    pub sample_rate: Option<i32>,
    pub channels: Option<i32>,
    pub suffix: String,
    pub size: i64,
    pub cover_art: Option<String>,
    pub album_id: Option<String>,
    pub disc: Option<i32>,
    pub fingerprint: Option<String>,
    pub added_unix: Option<i64>,
    pub starred: bool,
    pub play_count: i64,
    pub played_unix: Option<i64>,
}

impl RemoteSong {
    /// Reads a server's `Child` into a row, filling what the server left out the
    /// way a folder scan does for a file without tags.
    pub fn from_child(server: &str, child: &Child) -> Self {
        let suffix = child
            .suffix
            .as_deref()
            .map(str::to_lowercase)
            .filter(|suffix| !suffix.is_empty())
            .unwrap_or_else(|| "bin".to_string());
        let text = |value: &Option<String>| {
            value
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        };
        Self {
            server: server.to_string(),
            id: child.id.clone(),
            title: child.title.trim().to_string(),
            artist: text(&child.artist)
                .or_else(|| text(&child.display_artist))
                .unwrap_or_else(|| "Unknown Artist".to_string()),
            album: text(&child.album).unwrap_or_else(|| "Unknown Album".to_string()),
            album_artist: text(&child.display_album_artist),
            track_number: child.track.unwrap_or(0).clamp(0, i32::MAX as i64) as i32,
            duration: child.duration.unwrap_or(0).max(0) as f64,
            codec: codec_for_suffix(&suffix),
            bit_depth: child.bit_depth.filter(|bits| *bits > 0).map(|bits| bits as i32),
            sample_rate: child
                .sampling_rate
                .filter(|rate| *rate > 0)
                .map(|rate| rate as i32),
            channels: child
                .channel_count
                .filter(|channels| *channels > 0)
                .map(|channels| channels as i32),
            suffix,
            size: child.size.unwrap_or(0).max(0),
            cover_art: text(&child.cover_art),
            album_id: text(&child.album_id),
            disc: child.disc_number.filter(|disc| *disc > 0).map(|disc| disc as i32),
            fingerprint: text(&child.flaccy_fingerprint),
            added_unix: child
                .created
                .as_deref()
                .and_then(|created| chrono::DateTime::parse_from_rfc3339(created).ok())
                .map(|created| created.timestamp()),
            starred: text(&child.starred).is_some(),
            play_count: child.play_count.unwrap_or(0).max(0),
            played_unix: child.played.as_deref().and_then(unix_from_iso),
        }
    }

    /// The `fileURL` the library stores this song under.
    pub fn rel_path(&self) -> String {
        remote_path::encode(&self.server, &self.id)
    }

    /// The song as `catalog_diff` compares it.
    pub fn catalog_song(&self) -> CatalogSong {
        CatalogSong {
            id: self.id.clone(),
            size: self.size,
            duration: self.duration,
            title: self.title.clone(),
            artist: self.artist.clone(),
            album: self.album.clone(),
            track: Some(i64::from(self.track_number)).filter(|track| *track > 0),
            fingerprint: self.fingerprint.clone(),
        }
    }
}

/// The Unix second an ISO 8601 timestamp names, `None` when it does not parse.
fn unix_from_iso(text: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(text.trim())
        .ok()
        .map(|time| time.timestamp())
}

/// The badge codec for a file suffix, as the folder scan names it.
fn codec_for_suffix(suffix: &str) -> Option<String> {
    let codec = match suffix {
        "flac" => "FLAC",
        "mp3" => "MP3",
        "m4a" | "mp4" | "aac" => "AAC",
        "ogg" | "oga" => "OGG",
        "opus" => "OPUS",
        "wav" => "WAV",
        "aiff" | "aif" => "AIFF",
        _ => return None,
    };
    Some(codec.to_string())
}

/// The file name a song's bytes are cached under: its id, made safe for a file
/// system, and its suffix.
pub fn cache_file_name(song: &str, suffix: &str) -> String {
    format!("{}.{suffix}", encode_segment(song))
}

/// The song id a [`cache_file_name`] was made from.
pub fn song_from_cache_file_name(name: &str) -> Option<String> {
    let stem = name.rsplit_once('.')?.0;
    decode_segment(stem)
}

/// The media type a song's suffix is served as.
pub fn content_type(suffix: &str) -> &'static str {
    match suffix {
        "flac" => "audio/flac",
        "mp3" => "audio/mpeg",
        "m4a" | "mp4" | "aac" => "audio/mp4",
        "ogg" | "oga" => "audio/ogg",
        "opus" => "audio/opus",
        "wav" => "audio/wav",
        "aiff" | "aif" => "audio/aiff",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn child(json: &str) -> Child {
        serde_json::from_str(json).unwrap()
    }

    #[test]
    fn a_child_becomes_a_row_with_the_scan_s_fallbacks() {
        let song = RemoteSong::from_child(
            "s1",
            &child(r#"{"id":"abc","title":" Opening ","suffix":"FLAC","size":1000,"duration":20,"track":1,"bitDepth":16,"samplingRate":44100,"channelCount":2,"created":"2026-10-25T14:48:14.043618202+02:00"}"#),
        );
        assert_eq!(song.title, "Opening");
        assert_eq!(song.artist, "Unknown Artist");
        assert_eq!(song.album, "Unknown Album");
        assert_eq!(song.codec.as_deref(), Some("FLAC"));
        assert_eq!(song.suffix, "flac");
        assert_eq!(song.bit_depth, Some(16));
        assert_eq!(song.rel_path(), "remote://s1/abc");
        assert_eq!(song.added_unix, Some(1_792_932_494));
    }

    #[test]
    fn a_child_carries_its_love_and_play_state() {
        let song = RemoteSong::from_child(
            "s1",
            &child(r#"{"id":"a","title":"T","starred":"2026-10-24T09:30:00Z","playCount":4,"played":"2026-10-25T14:00:00Z"}"#),
        );
        assert!(song.starred);
        assert_eq!(song.play_count, 4);
        assert_eq!(song.played_unix, Some(1_792_936_800));
    }

    #[test]
    fn a_blank_star_and_an_unparseable_play_time_are_ignored() {
        let song = RemoteSong::from_child(
            "s1",
            &child(r#"{"id":"a","title":"T","starred":"  ","playCount":-2,"played":"yesterday"}"#),
        );
        assert!(!song.starred);
        assert_eq!(song.play_count, 0);
        assert_eq!(song.played_unix, None);
    }

    #[test]
    fn the_catalog_view_leaves_out_a_zero_track_number() {
        let song = RemoteSong::from_child("s1", &child(r#"{"id":"a","title":"T","duration":3}"#));
        assert_eq!(song.catalog_song().track, None);
        assert_eq!(song.suffix, "bin");
    }

    #[test]
    fn cache_file_names_round_trip_odd_ids() {
        let name = cache_file_name("a/b c", "flac");
        assert!(!name.contains('/'));
        assert_eq!(song_from_cache_file_name(&name).as_deref(), Some("a/b c"));
    }
}
