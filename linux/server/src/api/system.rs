//! Identity and capability calls: license, extensions, the user and the folders.

use flaccy_shared::remote::subsonic_response::{Extension, MusicFolder};
use serde_json::json;

use super::{one, Call, Fields};
use crate::error::ApiError;

const EXTENSIONS: [(&str, i64); 4] = [
    ("apiKeyAuthentication", 1),
    ("formPost", 1),
    ("songLyrics", 1),
    ("flaccyVersions", 1),
];

/// `getLicense`: always valid, there is nothing to buy.
pub(super) fn license() -> Fields {
    one(
        "license",
        json!({"valid": true, "email": "", "licenseExpires": "2099-12-31T00:00:00Z"}),
    )
}

/// `getOpenSubsonicExtensions`: what this server supports beyond Subsonic 1.16.1.
pub(super) fn extensions() -> Fields {
    let listed: Vec<Extension> = EXTENSIONS
        .iter()
        .map(|(name, version)| Extension {
            name: Some((*name).to_string()),
            versions: Some(vec![*version]),
        })
        .collect();
    one(
        "openSubsonicExtensions",
        serde_json::to_value(listed).unwrap_or_default(),
    )
}

/// `getUser`: the one account. Roles for features the server does not offer are false.
pub(super) fn user(call: &Call<'_>) -> Result<Fields, ApiError> {
    if let Some(asked) = call.params.get("username") {
        if !asked.eq_ignore_ascii_case(&call.username) {
            return Err(ApiError::not_found("User", asked));
        }
    }
    Ok(one(
        "user",
        json!({
            "username": call.username,
            "email": "",
            "scrobblingEnabled": true,
            "adminRole": false,
            "settingsRole": false,
            "downloadRole": true,
            "uploadRole": false,
            "playlistRole": true,
            "coverArtRole": true,
            "commentRole": true,
            "podcastRole": false,
            "streamRole": true,
            "jukeboxRole": false,
            "shareRole": false,
            "videoConversionRole": false,
            "folder": [1]
        }),
    ))
}

/// `getMusicFolders`: the single music folder, id 1.
pub(super) fn music_folders() -> Fields {
    one(
        "musicFolders",
        json!({"musicFolder": [MusicFolder {id: Some(1), name: Some("Music".to_string())}]}),
    )
}
