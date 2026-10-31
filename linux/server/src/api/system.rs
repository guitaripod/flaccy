//! Identity and capability calls: license, extensions, the user and the folders.

use flaccy_shared::remote::subsonic_response::{Extension, MusicFolder};
use serde_json::json;

use super::{one, Call, Fields};
use crate::error::ApiError;
use crate::security::Role;

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

/// `getScanStatus`: whether a scan is running and how many songs the library holds so far.
pub(super) fn scan_status(call: &Call<'_>) -> Fields {
    let scan = call.state.0.scan.snapshot();
    one("scanStatus", json!({"scanning": scan.scanning, "count": scan.indexed}))
}

/// `getUser`: the calling user. Roles for features the server does not offer are false.
pub(super) fn user(call: &Call<'_>) -> Result<Fields, ApiError> {
    if let Some(asked) = call.params.get("username") {
        if !asked.eq_ignore_ascii_case(&call.username) {
            return Err(ApiError::not_found("User", asked));
        }
    }
    let role = call.principal.role;
    let writes = matches!(role, Role::Admin | Role::Member);
    Ok(one(
        "user",
        json!({
            "username": call.username,
            "email": "",
            "scrobblingEnabled": writes,
            "adminRole": false,
            "settingsRole": false,
            "downloadRole": true,
            "uploadRole": false,
            "playlistRole": writes,
            "coverArtRole": true,
            "commentRole": writes,
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
