//! Audio and pictures: `stream`, `download` and `getCoverArt`.

use std::path::{Path, PathBuf};

use axum::body::Body;
use axum::http::request::Parts;
use axum::http::{header, HeaderMap, HeaderName, HeaderValue, Method, Request, StatusCode};
use axum::response::Response;
use chrono::{DateTime, Utc};
use tower::ServiceExt;
use tower_http::services::ServeFile;

use super::model::suffix_of;
use super::{Call, Outcome};
use crate::cover;
use crate::error::ApiError;
use crate::ids::{self, Entity};
use crate::transcode::{self, Target};

const LOSSY_SUFFIXES: [&str; 4] = ["mp3", "m4a", "ogg", "opus"];

struct Source {
    path: PathBuf,
    suffix: String,
    kbps: Option<i64>,
}

fn find_source(call: &Call<'_>) -> Result<Source, ApiError> {
    let id = call.require("id")?;
    let catalog = call.state.catalog();
    let song = match ids::parse(id) {
        Some(Entity::Song(row_id)) => catalog.song(row_id),
        _ => None,
    }
    .ok_or_else(|| ApiError::not_found("Song", id))?;
    let kbps = (song.row.duration > 0.0 && song.size > 0)
        .then(|| ((song.size as f64 * 8.0) / song.row.duration / 1000.0).round() as i64);
    Ok(Source {
        path: song.row.abs_path(call.state.music_root()),
        suffix: suffix_of(&song.row.rel_path),
        kbps,
    })
}

async fn require_file(path: &Path, id: &str) -> Result<(), ApiError> {
    match tokio::fs::metadata(path).await {
        Ok(metadata) if metadata.is_file() => Ok(()),
        _ => Err(ApiError::new(
            70,
            format!(
                "The file for song '{id}' is no longer at {}; it was moved or deleted after the last scan. The folder watcher rescans within seconds, or run `flaccy-server scan`, then refresh your client",
                path.display()
            ),
        )),
    }
}

/// `stream`: the original file with range support, or an ffmpeg conversion
/// when `format` is not `raw` or `maxBitRate` asks for less. A lossy file that
/// already fits under `maxBitRate`, with no `format` asked, is sent as it is.
pub(super) async fn stream(call: &Call<'_>, parts: &Parts) -> Result<Outcome, ApiError> {
    let source = find_source(call)?;
    require_file(&source.path, call.params.get("id").unwrap_or_default()).await?;
    let max_bit_rate = call.params.int("maxBitRate").filter(|kbps| *kbps > 0);
    let format = call
        .params
        .get("format")
        .filter(|format| !format.is_empty() && !format.eq_ignore_ascii_case("raw"));
    let target = match (format, max_bit_rate) {
        (Some(format), _) => Some(Target::parse(format).ok_or_else(|| {
            ApiError::bad_parameter(call.method, "format", format, "use raw, mp3, opus, aac or mp4")
        })?),
        (None, Some(limit)) if !already_fits(&source, limit) => Some(Target::Mp3),
        (None, _) => None,
    };
    let response = match target {
        Some(target) => {
            transcode::stream(
                &call.state.0.ffmpeg,
                &source.path,
                target,
                max_bit_rate,
                call.params.int("timeOffset"),
                parts.method == Method::HEAD,
            )
            .await?
        }
        None => serve_file(&source.path, parts, None).await,
    };
    Ok(Outcome::Raw(response))
}

fn already_fits(source: &Source, limit: i64) -> bool {
    LOSSY_SUFFIXES.contains(&source.suffix.as_str()) && source.kbps.is_some_and(|kbps| kbps <= limit)
}

/// `download`: the original file as an attachment, always raw.
pub(super) async fn download(call: &Call<'_>, parts: &Parts) -> Result<Outcome, ApiError> {
    let source = find_source(call)?;
    require_file(&source.path, call.params.get("id").unwrap_or_default()).await?;
    let name = source
        .path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "song".to_string());
    Ok(Outcome::Raw(serve_file(&source.path, parts, Some(&name)).await))
}

async fn serve_file(path: &Path, parts: &Parts, attachment: Option<&str>) -> Response {
    let method = if parts.method == Method::HEAD { Method::HEAD } else { Method::GET };
    let mut request = Request::new(Body::empty());
    *request.method_mut() = method;
    *request.headers_mut() = forwarded_headers(&parts.headers, path).await;
    let served = ServeFile::new(path)
        .oneshot(request)
        .await
        .unwrap_or_else(|never| match never {});
    let (head, body) = served.into_parts();
    let mut response = Response::from_parts(head, Body::new(body));
    if let Some(name) = attachment {
        if let Ok(value) = HeaderValue::from_str(&content_disposition(name)) {
            response.headers_mut().insert(header::CONTENT_DISPOSITION, value);
        }
    }
    response
}

/// The request headers a file response honors. `ServeFile` does not know
/// `If-Range`, so it is applied here: a `Range` is kept only when the
/// `If-Range` date is exactly the file's `Last-Modified`.
async fn forwarded_headers(original: &HeaderMap, path: &Path) -> HeaderMap {
    let mut headers = HeaderMap::new();
    for name in [header::RANGE, header::IF_MODIFIED_SINCE, header::IF_UNMODIFIED_SINCE] {
        if let Some(value) = original.get(&name) {
            headers.insert(name, value.clone());
        }
    }
    if let Some(condition) = original.get(HeaderName::from_static("if-range")) {
        let current = last_modified(path).await;
        let fresh = condition
            .to_str()
            .ok()
            .zip(current)
            .is_some_and(|(sent, current)| sent.trim() == current);
        if !fresh {
            headers.remove(header::RANGE);
        }
    }
    headers
}

async fn last_modified(path: &Path) -> Option<String> {
    let modified = tokio::fs::metadata(path).await.ok()?.modified().ok()?;
    Some(DateTime::<Utc>::from(modified).format("%a, %d %b %Y %H:%M:%S GMT").to_string())
}

fn content_disposition(name: &str) -> String {
    let ascii: String = name
        .chars()
        .map(|c| if c.is_ascii() && c != '"' && c != '\\' && !c.is_control() { c } else { '_' })
        .collect();
    let encoded: String = name
        .bytes()
        .map(|byte| {
            if byte.is_ascii_alphanumeric() || b"-._~".contains(&byte) {
                (byte as char).to_string()
            } else {
                format!("%{byte:02X}")
            }
        })
        .collect();
    format!("attachment; filename=\"{ascii}\"; filename*=UTF-8''{encoded}")
}

/// `getCoverArt`: the stored cover of an album, else a picture embedded in one
/// of its files, optionally resized to fit `size` pixels.
pub(super) fn cover_art(call: &Call<'_>) -> Result<Outcome, ApiError> {
    let id = call.require("id")?;
    let size = call.params.int("size").filter(|size| *size > 0).map(|size| size.min(4096) as u32);
    let found = find_cover(call, id)?;
    let (bytes, kind) = match size {
        Some(size) => cover::resized(&call.state.0.config.covers_dir(), id, size, &found),
        None => {
            let kind = cover::content_type(&found);
            (found, kind)
        }
    };
    let mut response = Response::new(Body::from(bytes));
    *response.status_mut() = StatusCode::OK;
    response
        .headers_mut()
        .insert(header::CONTENT_TYPE, HeaderValue::from_static(kind));
    response.headers_mut().insert(
        header::CACHE_CONTROL,
        HeaderValue::from_static("private, max-age=3600"),
    );
    Ok(Outcome::Raw(response))
}

fn find_cover(call: &Call<'_>, id: &str) -> Result<Vec<u8>, ApiError> {
    let missing = || {
        ApiError::new(
            70,
            format!("No cover picture exists for '{id}': neither the library nor the files of its album carry one. Add a cover to the album's files and the next scan will serve it"),
        )
    };
    let root = call.state.music_root();
    let (art_keys, paths) = {
        let catalog = call.state.catalog();
        match ids::parse(id) {
            Some(Entity::Playlist(row_id)) => {
                return call.state.db().playlist_cover(row_id).ok_or_else(missing)
            }
            Some(Entity::Song(row_id)) => {
                let song = catalog.song(row_id).ok_or_else(|| ApiError::not_found("Song", id))?;
                match catalog.album(&song.album_id) {
                    Some(album) => (album.art_keys.clone(), vec![song.row.abs_path(root)]),
                    None => (Vec::new(), vec![song.row.abs_path(root)]),
                }
            }
            Some(Entity::Album(_)) => {
                let album = catalog.album(id).ok_or_else(|| ApiError::not_found("Album", id))?;
                let paths = catalog.album_songs(album).map(|song| song.row.abs_path(root)).collect();
                (album.art_keys.clone(), paths)
            }
            Some(Entity::Artist(_)) => {
                let artist = catalog.artist(id).ok_or_else(|| ApiError::not_found("Artist", id))?;
                let album = artist
                    .albums
                    .first()
                    .and_then(|album_id| catalog.album(album_id))
                    .ok_or_else(missing)?;
                let paths = catalog.album_songs(album).map(|song| song.row.abs_path(root)).collect();
                (album.art_keys.clone(), paths)
            }
            None => return Err(ApiError::not_found("Cover", id)),
        }
    };
    let stored = {
        let db = call.state.db();
        art_keys
            .iter()
            .find_map(|(title, artist)| db.fetch_album_artwork(title, artist))
    };
    stored
        .or_else(|| paths.iter().find_map(|path| cover::embedded_picture(path)))
        .ok_or_else(missing)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_attachment_name_keeps_unicode_in_the_extended_field() {
        let header = content_disposition("Bjork \"Hyperballad\" é.flac");
        assert!(header.contains("filename=\"Bjork _Hyperballad_ _.flac\""));
        assert!(header.contains("filename*=UTF-8''Bjork%20%22Hyperballad%22%20%C3%A9.flac"));
    }
}
