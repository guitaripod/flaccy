//! Browsing: artist indexes, one artist, one album, one song and lyrics.

use std::collections::BTreeMap;

use flaccy_library::keys;
use flaccy_shared::lyrics::{parse_lrc, LineKind};
use serde_json::{json, Value};

use super::model::{album_value, album_with_songs_value, artist_entry_value, song_value};
use super::{one, Call, Fields};
use crate::catalog::{Artist, Catalog};
use crate::error::ApiError;
use crate::ids::{self, Entity};

const IGNORED_ARTICLES: &str = "The";

fn sort_name(name: &str) -> String {
    let lowered = name.trim().to_lowercase();
    lowered
        .strip_prefix("the ")
        .map(str::to_string)
        .unwrap_or(lowered)
}

fn index_letter(name: &str) -> String {
    keys::normalize(&sort_name(name))
        .chars()
        .next()
        .filter(|letter| letter.is_alphabetic())
        .map(|letter| letter.to_uppercase().collect())
        .unwrap_or_else(|| "#".to_string())
}

fn index_groups(catalog: &Catalog) -> Vec<Value> {
    let mut groups: BTreeMap<String, Vec<&Artist>> = BTreeMap::new();
    for artist in catalog.artists() {
        groups.entry(index_letter(&artist.name)).or_default().push(artist);
    }
    groups
        .into_iter()
        .map(|(letter, mut artists)| {
            artists.sort_by_key(|artist| sort_name(&artist.name));
            json!({
                "name": letter,
                "artist": artists.into_iter().map(artist_entry_value).collect::<Vec<_>>()
            })
        })
        .collect()
}

/// `getIndexes`: artists grouped by first letter.
pub(super) fn indexes(call: &Call<'_>) -> Fields {
    let catalog = call.state.catalog();
    one(
        "indexes",
        json!({
            "ignoredArticles": IGNORED_ARTICLES,
            "lastModified": 0,
            "index": index_groups(&catalog)
        }),
    )
}

/// `getArtists`: artists grouped by first letter, ignoring "The ".
pub(super) fn artists(call: &Call<'_>) -> Fields {
    let catalog = call.state.catalog();
    one(
        "artists",
        json!({"ignoredArticles": IGNORED_ARTICLES, "index": index_groups(&catalog)}),
    )
}

/// `getArtist`: one artist and the albums they are on.
pub(super) fn artist(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("id")?;
    let catalog = call.state.catalog();
    let artist = catalog
        .artist(id)
        .ok_or_else(|| ApiError::not_found("Artist", id))?;
    let mut value = artist_entry_value(artist);
    let albums: Vec<Value> = artist
        .albums
        .iter()
        .filter_map(|album_id| catalog.album(album_id))
        .map(|album| album_value(&catalog, &call.view, album))
        .collect();
    if let Value::Object(object) = &mut value {
        object.insert("album".into(), Value::Array(albums));
    }
    Ok(one("artist", value))
}

/// `getAlbum`: one album with its songs in play order.
pub(super) fn album(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("id")?;
    let catalog = call.state.catalog();
    let album = catalog
        .album(id)
        .ok_or_else(|| ApiError::not_found("Album", id))?;
    Ok(one("album", album_with_songs_value(&catalog, &call.view, album)))
}

/// `getSong`: one song.
pub(super) fn song(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("id")?;
    let catalog = call.state.catalog();
    let song = match ids::parse(id) {
        Some(Entity::Song(row_id)) => catalog.song(row_id),
        _ => None,
    }
    .ok_or_else(|| ApiError::not_found("Song", id))?;
    Ok(one("song", song_value(&catalog, &call.view, song)))
}

/// `getLyricsBySongId`: the lyrics the library holds, synced lines when there are any.
pub(super) fn lyrics(call: &Call<'_>) -> Result<Fields, ApiError> {
    let id = call.require("id")?;
    let (title, artist) = {
        let catalog = call.state.catalog();
        let song = match ids::parse(id) {
            Some(Entity::Song(row_id)) => catalog.song(row_id),
            _ => None,
        }
        .ok_or_else(|| ApiError::not_found("Song", id))?;
        (song.row.title.clone(), song.row.artist.clone())
    };
    let stored = call.state.db().fetch_lyrics(&title, &artist);
    let mut structured = Vec::new();
    if let Some(row) = stored.filter(|row| !row.instrumental) {
        let synced_lines = row.synced.as_deref().map(|text| synced_lines(text, row.offset_ms));
        if let Some(lines) = synced_lines.filter(|lines| !lines.is_empty()) {
            structured.push(structured_lyrics(&title, &artist, true, lines));
        } else if let Some(plain) = row.plain.as_deref().filter(|text| !text.trim().is_empty()) {
            let lines = plain.lines().map(|line| json!({"value": line})).collect();
            structured.push(structured_lyrics(&title, &artist, false, lines));
        }
    }
    let list = if structured.is_empty() {
        json!({})
    } else {
        json!({"structuredLyrics": structured})
    };
    Ok(one("lyricsList", list))
}

fn synced_lines(lrc: &str, offset_ms: i64) -> Vec<Value> {
    parse_lrc(lrc)
        .lines
        .iter()
        .filter(|line| line.kind == LineKind::Text)
        .map(|line| {
            let start = ((line.start * 1000.0).round() as i64 + offset_ms).max(0);
            json!({"start": start, "value": line.text})
        })
        .collect()
}

fn structured_lyrics(title: &str, artist: &str, synced: bool, lines: Vec<Value>) -> Value {
    json!({
        "displayArtist": artist,
        "displayTitle": title,
        "lang": "xxx",
        "synced": synced,
        "line": lines
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn articles_and_symbols_group_the_way_a_listener_files_them() {
        assert_eq!(index_letter("The Beatles"), "B");
        assert_eq!(index_letter("Édith Piaf"), "E");
        assert_eq!(index_letter("2Pac"), "#");
        assert_eq!(index_letter("!!!"), "#");
        assert_eq!(index_letter("the"), "T");
    }

    #[test]
    fn synced_lines_carry_milliseconds_and_the_listeners_offset() {
        let lines = synced_lines("[00:01.50]one\n[00:03.00]two", 250);
        assert_eq!(lines[0], json!({"start": 1750, "value": "one"}));
        assert_eq!(lines[1]["start"], 3250);
    }
}
