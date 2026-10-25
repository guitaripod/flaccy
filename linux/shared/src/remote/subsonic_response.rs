//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/SubsonicResponse.swift`.
//!
//! What an OpenSubsonic server answers. Only the envelope's `status` is
//! required; every other field is optional and unknown fields are ignored, so
//! a newer server keeps decoding. The `flaccy*` fields on a song are present
//! only when the server runs Flaccy's extension. Decode a body with
//! `serde_json::from_str::<Root>` and read `response`.

use serde::Deserialize;

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Root {
    #[serde(rename = "subsonic-response")]
    pub response: Envelope,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Envelope {
    pub status: String,
    pub version: Option<String>,
    #[serde(rename = "type")]
    pub server_type: Option<String>,
    pub server_version: Option<String>,
    pub open_subsonic: Option<bool>,
    pub error: Option<ErrorBody>,
    pub open_subsonic_extensions: Option<Vec<Extension>>,
    pub music_folders: Option<MusicFolders>,
    pub artists: Option<Artists>,
    pub album_list2: Option<AlbumList2>,
    pub album: Option<Album>,
    pub song: Option<Child>,
    pub search_result3: Option<SearchResult3>,
    pub playlists: Option<Playlists>,
}

impl Envelope {
    /// The failure the server reported, `None` when the status is not "failed".
    pub fn failure(&self) -> Option<SubsonicFailure> {
        if self.status != "failed" {
            return None;
        }
        let code = self
            .error
            .as_ref()
            .and_then(|error| error.code)
            .unwrap_or_default();
        Some(SubsonicFailure::from_code(code))
    }

    /// Whether the server lists the OpenSubsonic extension called `name`.
    pub fn supports(&self, name: &str) -> bool {
        self.open_subsonic_extensions
            .iter()
            .flatten()
            .any(|extension| extension.name.as_deref() == Some(name))
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SubsonicFailure {
    MissingParameter,
    IncompatibleVersion,
    WrongCredentials,
    TokenAuthUnsupported,
    AuthMechanismUnsupported,
    ConflictingAuth,
    InvalidApiKey,
    NotAuthorized,
    TrialExpired,
    NotFound,
    Other(i64),
}

impl SubsonicFailure {
    /// The failure a Subsonic error code names. Codes 20 and 30 are both
    /// version mismatches, one from each side.
    pub fn from_code(code: i64) -> Self {
        match code {
            10 => Self::MissingParameter,
            20 | 30 => Self::IncompatibleVersion,
            40 => Self::WrongCredentials,
            41 => Self::TokenAuthUnsupported,
            42 => Self::AuthMechanismUnsupported,
            43 => Self::ConflictingAuth,
            44 => Self::InvalidApiKey,
            50 => Self::NotAuthorized,
            60 => Self::TrialExpired,
            70 => Self::NotFound,
            other => Self::Other(other),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ErrorBody {
    pub code: Option<i64>,
    pub message: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Extension {
    pub name: Option<String>,
    pub versions: Option<Vec<i64>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MusicFolders {
    pub music_folder: Option<Vec<MusicFolder>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct MusicFolder {
    pub id: Option<i64>,
    pub name: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Artists {
    pub index: Option<Vec<ArtistIndex>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ArtistIndex {
    pub name: Option<String>,
    pub artist: Option<Vec<Artist>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Artist {
    pub id: Option<String>,
    pub name: Option<String>,
    pub album_count: Option<i64>,
    pub cover_art: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AlbumId3 {
    pub id: String,
    pub name: String,
    pub artist: Option<String>,
    pub artist_id: Option<String>,
    pub cover_art: Option<String>,
    pub song_count: Option<i64>,
    pub duration: Option<i64>,
    pub created: Option<String>,
    pub year: Option<i64>,
    pub genre: Option<String>,
    pub display_artist: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct AlbumList2 {
    pub album: Option<Vec<AlbumId3>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Album {
    #[serde(flatten)]
    pub info: AlbumId3,
    pub song: Option<Vec<Child>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Child {
    pub id: String,
    pub parent: Option<String>,
    pub title: String,
    pub album: Option<String>,
    pub artist: Option<String>,
    pub track: Option<i64>,
    pub disc_number: Option<i64>,
    pub year: Option<i64>,
    pub genre: Option<String>,
    pub cover_art: Option<String>,
    pub size: Option<i64>,
    pub content_type: Option<String>,
    pub suffix: Option<String>,
    pub duration: Option<i64>,
    pub bit_rate: Option<i64>,
    pub bit_depth: Option<i64>,
    pub sampling_rate: Option<i64>,
    pub channel_count: Option<i64>,
    pub path: Option<String>,
    pub album_id: Option<String>,
    pub artist_id: Option<String>,
    #[serde(rename = "type")]
    pub kind: Option<String>,
    pub created: Option<String>,
    pub music_brainz_id: Option<String>,
    pub display_artist: Option<String>,
    pub display_album_artist: Option<String>,
    pub flaccy_fingerprint: Option<String>,
    pub flaccy_revision: Option<i64>,
    pub flaccy_revised_at: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult3 {
    pub artist: Option<Vec<Artist>>,
    pub album: Option<Vec<AlbumId3>>,
    pub song: Option<Vec<Child>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Playlists {
    pub playlist: Option<Vec<Playlist>>,
}

#[derive(Clone, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Playlist {
    pub id: Option<String>,
    pub name: Option<String>,
    pub song_count: Option<i64>,
    pub duration: Option<i64>,
    pub created: Option<String>,
    pub changed: Option<String>,
    pub cover_art: Option<String>,
    pub owner: Option<String>,
    pub public: Option<bool>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(json: &str) -> Envelope {
        serde_json::from_str::<Root>(json).unwrap().response
    }

    #[test]
    fn ping_reports_the_navidrome_server() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/ping.json"
        ));
        assert_eq!(envelope.status, "ok");
        assert_eq!(envelope.server_type.as_deref(), Some("navidrome"));
        assert_eq!(
            envelope.server_version.as_deref(),
            Some("0.64.2 (10114574)")
        );
        assert_eq!(envelope.open_subsonic, Some(true));
        assert_eq!(envelope.failure(), None);
    }

    #[test]
    fn extensions_are_listed_with_their_versions() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/extensions.json"
        ));
        let lyrics = envelope
            .open_subsonic_extensions
            .as_ref()
            .unwrap()
            .iter()
            .find(|extension| extension.name.as_deref() == Some("songLyrics"))
            .unwrap();
        assert_eq!(lyrics.versions, Some(vec![1, 2]));
        assert!(envelope.supports("transcoding"));
        assert!(!envelope.supports("apiKeyAuthentication"));
    }

    #[test]
    fn music_folders_decode_their_numeric_id() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/musicFolders.json"
        ));
        let folder = &envelope.music_folders.unwrap().music_folder.unwrap()[0];
        assert_eq!(folder.id, Some(1));
        assert_eq!(folder.name.as_deref(), Some("Music Library"));
    }

    #[test]
    fn artists_are_grouped_by_index() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/artists.json"
        ));
        let index = &envelope.artists.unwrap().index.unwrap()[0];
        assert_eq!(index.name.as_deref(), Some("S"));
        assert_eq!(
            index.artist.as_ref().unwrap()[0].name.as_deref(),
            Some("Second Band")
        );
    }

    #[test]
    fn album_list_has_three_albums() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/albumList2.json"
        ));
        let albums = envelope.album_list2.unwrap().album.unwrap();
        assert_eq!(albums.len(), 3);
        assert_eq!(albums[0].name, "First Light");
    }

    #[test]
    fn album_carries_its_songs_in_track_order() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/album.json"
        ));
        let album = envelope.album.unwrap();
        assert_eq!(album.info.id, "3VJh1vLoeqzHRu7d7CGEO3");
        let songs = album.song.unwrap();
        let tracks: Vec<Option<i64>> = songs.iter().map(|song| song.track).collect();
        assert_eq!(tracks, vec![Some(1), Some(2), Some(3)]);
        assert_eq!(songs[0].title, "Opening");
    }

    #[test]
    fn song_decodes_its_audio_properties() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/song.json"
        ));
        let song = envelope.song.unwrap();
        assert_eq!(song.title, "Opening");
        assert_eq!(song.size, Some(313_276));
        assert_eq!(song.suffix.as_deref(), Some("flac"));
        assert_eq!(song.bit_depth, Some(16));
        assert_eq!(song.sampling_rate, Some(44_100));
        assert_eq!(song.channel_count, Some(2));
        assert_eq!(song.duration, Some(20));
        assert_eq!(song.flaccy_fingerprint, None);
        assert_eq!(song.flaccy_revision, None);
    }

    #[test]
    fn search_returns_six_songs() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/search3All.json"
        ));
        let songs = envelope.search_result3.unwrap().song.unwrap();
        assert_eq!(songs.len(), 6);
    }

    #[test]
    fn an_empty_playlist_list_decodes() {
        let envelope = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/playlists.json"
        ));
        assert!(envelope.playlists.unwrap().playlist.is_none());
    }

    #[test]
    fn wrong_credentials_and_missing_songs_map_to_their_failures() {
        let wrong = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/errorWrongCredentials.json"
        ));
        let missing = parse(include_str!(
            "../../../../Core/FlaccyCore/Tests/FlaccyCoreTests/Fixtures/Subsonic/errorNotFound.json"
        ));
        assert_eq!(wrong.failure(), Some(SubsonicFailure::WrongCredentials));
        assert_eq!(missing.failure(), Some(SubsonicFailure::NotFound));
    }

    #[test]
    fn error_codes_map_to_failures_and_unknown_codes_are_kept() {
        assert_eq!(
            SubsonicFailure::from_code(20),
            SubsonicFailure::IncompatibleVersion
        );
        assert_eq!(
            SubsonicFailure::from_code(30),
            SubsonicFailure::IncompatibleVersion
        );
        assert_eq!(
            SubsonicFailure::from_code(44),
            SubsonicFailure::InvalidApiKey
        );
        assert_eq!(
            SubsonicFailure::from_code(60),
            SubsonicFailure::TrialExpired
        );
        assert_eq!(
            SubsonicFailure::from_code(9999),
            SubsonicFailure::Other(9999)
        );
    }

    #[test]
    fn a_song_with_flaccy_extension_fields_decodes_them() {
        let envelope = parse(
            r#"{"subsonic-response":{"status":"ok","song":{"id":"x","title":"t","flaccyFingerprint":"flac:ab","flaccyRevision":3,"flaccyRevisedAt":"2026-10-25T14:00:00Z","unknownField":{"nested":true}}}}"#,
        );
        let song = envelope.song.unwrap();
        assert_eq!(song.flaccy_fingerprint.as_deref(), Some("flac:ab"));
        assert_eq!(song.flaccy_revision, Some(3));
        assert_eq!(
            song.flaccy_revised_at.as_deref(),
            Some("2026-10-25T14:00:00Z")
        );
    }

    #[test]
    fn a_body_without_a_status_is_rejected() {
        assert!(serde_json::from_str::<Root>(r#"{"subsonic-response":{}}"#).is_err());
    }
}
