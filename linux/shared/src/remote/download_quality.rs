//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Remote/RemoteDownloadQuality.swift`.
//!
//! The form a song on a server is downloaded in: the original file, or AAC at
//! the bit rate AirPods Pro receive over Bluetooth (256 kbps), or half that for
//! the most songs per gigabyte.

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DownloadQuality {
    Original,
    Aac256,
    Aac128,
}

pub const DEFAULT_QUALITY: DownloadQuality = DownloadQuality::Aac256;

/// The server type a Flaccy Server reports in `ping`.
pub const FLACCY_SERVER_TYPE: &str = "flaccy-server";

impl DownloadQuality {
    pub const ALL: [DownloadQuality; 3] = [DownloadQuality::Original, DownloadQuality::Aac256, DownloadQuality::Aac128];

    /// The quality a stored name stands for, the default for a name this version does not know.
    pub fn from_stored_name(name: Option<&str>) -> DownloadQuality {
        match name {
            Some("original") => DownloadQuality::Original,
            Some("aac256") => DownloadQuality::Aac256,
            Some("aac128") => DownloadQuality::Aac128,
            _ => DEFAULT_QUALITY,
        }
    }

    pub fn stored_name(self) -> &'static str {
        match self {
            DownloadQuality::Original => "original",
            DownloadQuality::Aac256 => "aac256",
            DownloadQuality::Aac128 => "aac128",
        }
    }

    pub fn kbps(self) -> Option<u32> {
        match self {
            DownloadQuality::Original => None,
            DownloadQuality::Aac256 => Some(256),
            DownloadQuality::Aac128 => Some(128),
        }
    }

    /// The `stream` parameters that ask a server for this quality, `None` for
    /// the original file. A Flaccy Server sends a whole m4a, whose edit list
    /// keeps songs gapless; other servers are asked for `aac`.
    pub fn stream_parameters(self, server_type: Option<&str>) -> Option<Vec<(&'static str, String)>> {
        let kbps = self.kbps()?;
        let format = if server_type == Some(FLACCY_SERVER_TYPE) { "mp4" } else { "aac" };
        Some(vec![("format", format.to_string()), ("maxBitRate", kbps.to_string())])
    }
}

/// The suffix a converted download is stored under, from the response's media
/// type, or `None` when the server sent something other than AAC.
pub fn converted_suffix(content_type: Option<&str>) -> Option<&'static str> {
    let kind = content_type
        .unwrap_or_default()
        .split(';')
        .next()
        .unwrap_or_default()
        .trim()
        .to_ascii_lowercase();
    match kind.as_str() {
        "audio/mp4" | "audio/m4a" | "audio/x-m4a" => Some("m4a"),
        "audio/aac" | "audio/aacp" | "audio/x-aac" => Some("aac"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_is_aac_at_256() {
        assert_eq!(DEFAULT_QUALITY, DownloadQuality::Aac256);
        assert_eq!(DownloadQuality::from_stored_name(None), DownloadQuality::Aac256);
        assert_eq!(DownloadQuality::from_stored_name(Some("flac")), DownloadQuality::Aac256);
        assert_eq!(DownloadQuality::from_stored_name(Some("original")), DownloadQuality::Original);
        assert_eq!(DownloadQuality::from_stored_name(Some("aac128")), DownloadQuality::Aac128);
        for quality in DownloadQuality::ALL {
            assert_eq!(DownloadQuality::from_stored_name(Some(quality.stored_name())), quality);
        }
    }

    #[test]
    fn the_original_asks_for_no_conversion() {
        assert_eq!(DownloadQuality::Original.stream_parameters(Some("flaccy-server")), None);
        assert_eq!(DownloadQuality::Original.kbps(), None);
    }

    #[test]
    fn a_flaccy_server_is_asked_for_a_whole_m4a() {
        let parameters = DownloadQuality::Aac256.stream_parameters(Some("flaccy-server")).unwrap();
        assert_eq!(parameters, vec![("format", "mp4".to_string()), ("maxBitRate", "256".to_string())]);
    }

    #[test]
    fn other_servers_are_asked_for_aac() {
        for kind in [Some("navidrome"), Some("gonic"), None] {
            let parameters = DownloadQuality::Aac128.stream_parameters(kind).unwrap();
            assert_eq!(parameters, vec![("format", "aac".to_string()), ("maxBitRate", "128".to_string())]);
        }
    }

    #[test]
    fn the_suffix_follows_the_media_type() {
        assert_eq!(converted_suffix(Some("audio/mp4")), Some("m4a"));
        assert_eq!(converted_suffix(Some("audio/x-m4a")), Some("m4a"));
        assert_eq!(converted_suffix(Some("Audio/AAC; charset=binary")), Some("aac"));
        assert_eq!(converted_suffix(Some("audio/flac")), None);
        assert_eq!(converted_suffix(Some("audio/mpeg")), None);
        assert_eq!(converted_suffix(None), None);
    }
}
