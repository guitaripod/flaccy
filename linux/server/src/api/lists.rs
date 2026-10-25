//! Lists: album lists, random songs, search and the starred collection.

use std::cmp::Reverse;

use flaccy_library::keys;
use rand::seq::{IndexedRandom, SliceRandom};
use serde_json::{json, Value};

use super::model::{album_value, song_value};
use super::{one, Call, Fields};
use crate::catalog::{Album, Catalog, Song};
use crate::error::ApiError;

const MAX_PAGE: usize = 500;
const DEFAULT_ALBUM_PAGE: usize = 10;
const DEFAULT_SEARCH_PAGE: usize = 20;

fn page_size(call: &Call<'_>, name: &str, default: usize) -> usize {
    call.params
        .int(name)
        .map(|size| size.clamp(0, MAX_PAGE as i64) as usize)
        .unwrap_or(default)
}

fn offset_of(call: &Call<'_>, name: &str) -> usize {
    call.params.int(name).map(|offset| offset.max(0) as usize).unwrap_or(0)
}

fn paged<T>(items: Vec<T>, offset: usize, size: usize) -> Vec<T> {
    items.into_iter().skip(offset).take(size).collect()
}

/// `getAlbumList2`: albums of one `type`, paged by `size` (at most 500) and `offset`.
pub(super) fn album_list(call: &Call<'_>) -> Result<Fields, ApiError> {
    let kind = call.require("type")?;
    let size = page_size(call, "size", DEFAULT_ALBUM_PAGE);
    let offset = offset_of(call, "offset");
    let catalog = call.state.catalog();
    let mut albums: Vec<&Album> = catalog.albums().iter().collect();
    match kind {
        "random" => albums.shuffle(&mut rand::rng()),
        "newest" => albums.sort_by_key(|album| Reverse(album.created)),
        "frequent" => {
            albums.retain(|album| catalog.album_play_count(album) > 0);
            albums.sort_by_key(|album| Reverse(catalog.album_play_count(album)));
        }
        "recent" => {
            albums.retain(|album| catalog.album_last_played(album).is_some());
            albums.sort_by_key(|album| Reverse(catalog.album_last_played(album)));
        }
        "alphabeticalByName" => albums.sort_by_key(|album| album.title.to_lowercase()),
        "alphabeticalByArtist" => {
            albums.sort_by_key(|album| (album.artist.to_lowercase(), album.title.to_lowercase()))
        }
        "starred" => albums.retain(|album| catalog.album_is_starred(album)),
        "byYear" => by_year(call, &mut albums)?,
        "byGenre" => {
            let genre = call.require("genre")?;
            albums.retain(|album| {
                album
                    .genre
                    .as_deref()
                    .is_some_and(|candidate| candidate.eq_ignore_ascii_case(genre))
            });
        }
        other => {
            return Err(ApiError::bad_parameter(
                call.method,
                "type",
                other,
                "use random, newest, frequent, recent, alphabeticalByName, alphabeticalByArtist, starred, byYear or byGenre",
            ))
        }
    }
    let listed: Vec<Value> = paged(albums, offset, size)
        .into_iter()
        .map(|album| album_value(&catalog, album))
        .collect();
    Ok(one("albumList2", albums_object(listed)))
}

fn albums_object(listed: Vec<Value>) -> Value {
    if listed.is_empty() {
        json!({})
    } else {
        json!({"album": listed})
    }
}

fn by_year(call: &Call<'_>, albums: &mut Vec<&Album>) -> Result<(), ApiError> {
    let from = call
        .params
        .int("fromYear")
        .ok_or_else(|| ApiError::missing_parameter(call.method, "fromYear"))?;
    let to = call
        .params
        .int("toYear")
        .ok_or_else(|| ApiError::missing_parameter(call.method, "toYear"))?;
    let (low, high) = (from.min(to), from.max(to));
    albums.retain(|album| album.year.is_some_and(|year| (low..=high).contains(&year)));
    albums.sort_by_key(|album| (album.year, album.title.to_lowercase()));
    if from > to {
        albums.reverse();
    }
    Ok(())
}

/// `getRandomSongs`: up to `size` (at most 500) songs, optionally of one genre and year range.
pub(super) fn random_songs(call: &Call<'_>) -> Fields {
    let size = page_size(call, "size", DEFAULT_ALBUM_PAGE);
    let genre = call.params.get("genre").filter(|genre| !genre.is_empty());
    let from = call.params.int("fromYear");
    let to = call.params.int("toYear");
    let catalog = call.state.catalog();
    let candidates: Vec<&Song> = catalog
        .songs_in_order()
        .filter(|song| {
            let album = catalog.album(&song.album_id);
            let genre_ok = genre.is_none_or(|wanted| {
                album
                    .and_then(|album| album.genre.as_deref())
                    .is_some_and(|actual| actual.eq_ignore_ascii_case(wanted))
            });
            let year = album.and_then(|album| album.year);
            let from_ok = from.is_none_or(|from| year.is_some_and(|year| year >= from));
            let to_ok = to.is_none_or(|to| year.is_some_and(|year| year <= to));
            genre_ok && from_ok && to_ok
        })
        .collect();
    let chosen: Vec<Value> = candidates
        .choose_multiple(&mut rand::rng(), size)
        .map(|song| song_value(&catalog, song))
        .collect();
    one("randomSongs", songs_object(chosen))
}

fn songs_object(listed: Vec<Value>) -> Value {
    if listed.is_empty() {
        json!({})
    } else {
        json!({"song": listed})
    }
}

fn search_terms(query: &str) -> Vec<String> {
    query
        .split_whitespace()
        .map(|word| keys::normalize(word.trim_matches(|c| c == '"' || c == '*')))
        .filter(|term| !term.is_empty())
        .collect()
}

fn matches_all(terms: &[String], haystack: &str) -> bool {
    let haystack = keys::normalize(haystack);
    terms.iter().all(|term| haystack.contains(term.as_str()))
}

/// `search3`: artists, albums and songs matching `query`; an empty query lists
/// everything. Each kind is paged by its own count and offset.
pub(super) fn search(call: &Call<'_>) -> Fields {
    let terms = search_terms(call.params.get("query").unwrap_or(""));
    let artist_page = (offset_of(call, "artistOffset"), page_size(call, "artistCount", DEFAULT_SEARCH_PAGE));
    let album_page = (offset_of(call, "albumOffset"), page_size(call, "albumCount", DEFAULT_SEARCH_PAGE));
    let song_page = (offset_of(call, "songOffset"), page_size(call, "songCount", DEFAULT_SEARCH_PAGE));
    let catalog = call.state.catalog();

    let artists: Vec<Value> = paged(
        catalog
            .artists()
            .iter()
            .filter(|artist| matches_all(&terms, &artist.name))
            .collect(),
        artist_page.0,
        artist_page.1,
    )
    .into_iter()
    .map(super::model::artist_entry_value)
    .collect();
    let albums: Vec<Value> = paged(
        catalog
            .albums()
            .iter()
            .filter(|album| matches_all(&terms, &format!("{} {}", album.title, album.artist)))
            .collect(),
        album_page.0,
        album_page.1,
    )
    .into_iter()
    .map(|album| album_value(&catalog, album))
    .collect();
    let songs: Vec<Value> = paged(
        catalog
            .songs_in_order()
            .filter(|song| matches_all(&terms, &format!("{} {} {}", song.row.title, song.row.artist, song.row.album)))
            .collect(),
        song_page.0,
        song_page.1,
    )
    .into_iter()
    .map(|song| song_value(&catalog, song))
    .collect();

    let mut result = serde_json::Map::new();
    if !artists.is_empty() {
        result.insert("artist".into(), Value::Array(artists));
    }
    if !albums.is_empty() {
        result.insert("album".into(), Value::Array(albums));
    }
    if !songs.is_empty() {
        result.insert("song".into(), Value::Array(songs));
    }
    one("searchResult3", Value::Object(result))
}

fn starred_songs(catalog: &Catalog) -> Vec<Value> {
    catalog
        .songs_in_order()
        .filter(|song| song.row.loved)
        .map(|song| song_value(catalog, song))
        .collect()
}

/// `getStarred2`: loved songs, and albums whose every song is loved.
pub(super) fn starred(call: &Call<'_>) -> Fields {
    let catalog = call.state.catalog();
    let mut result = serde_json::Map::new();
    let albums: Vec<Value> = catalog
        .albums()
        .iter()
        .filter(|album| catalog.album_is_starred(album))
        .map(|album| album_value(&catalog, album))
        .collect();
    if !albums.is_empty() {
        result.insert("album".into(), Value::Array(albums));
    }
    let songs = starred_songs(&catalog);
    if !songs.is_empty() {
        result.insert("song".into(), Value::Array(songs));
    }
    one("starred2", Value::Object(result))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_terms_drop_quotes_wildcards_and_punctuation() {
        assert_eq!(search_terms("\"Drill Band\"*"), vec!["drill", "band"]);
        assert!(search_terms("   ").is_empty());
        assert!(search_terms("").is_empty());
    }

    #[test]
    fn every_term_must_match_somewhere() {
        let terms = search_terms("drill rough");
        assert!(matches_all(&terms, "Rough Cuts by Drill Band"));
        assert!(!matches_all(&terms, "Drill Band"));
        assert!(matches_all(&[], "anything"));
    }

    #[test]
    fn paging_skips_then_takes() {
        assert_eq!(paged(vec![1, 2, 3, 4, 5], 1, 2), vec![2, 3]);
        assert_eq!(paged(vec![1, 2], 5, 2), Vec::<i32>::new());
    }
}
