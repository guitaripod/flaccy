//! What simulated users do: random mutations drawn from what they can see.

use super::rng::Rng;
use super::store::Store;
use crate::model::Entry;
use crate::song::song_key;
use serde_json::{json, Value};

const SONG_POOL: usize = 12;

fn song_key_of(index: usize) -> String {
    song_key(&format!("artist{index}"), &format!("title{index}"))
}

fn song_ref(index: usize) -> Value {
    json!({
        "songKey": song_key_of(index),
        "title": format!("Title {index}"),
        "artist": format!("Artist {index}"),
        "album": "Album",
        "durationMs": 180000,
        "fp": null,
        "mbid": null,
        "albumKey": null,
        "relPath": null,
    })
}

fn random_song(rng: &mut Rng) -> usize {
    rng.below(SONG_POOL)
}

fn new_entry(rng: &mut Rng) -> Value {
    let song = random_song(rng);
    json!({ "id": rng.id(), "ref": song_ref(song) })
}

fn place(rng: &mut Rng, order: &[&Entry]) -> Value {
    if order.is_empty() {
        return if rng.chance(50) {
            json!({ "kind": "first" })
        } else {
            json!({ "kind": "last" })
        };
    }
    let anchor = rng.pick(order).id.clone();
    match rng.below(100) {
        0..=24 => json!({ "kind": "first" }),
        25..=49 => json!({ "kind": "last" }),
        50..=84 => json!({ "kind": "after", "id": anchor }),
        85..=96 => json!({ "kind": "before", "id": anchor }),
        _ => json!({ "kind": "after", "id": rng.id() }),
    }
}

fn blob(rng: &mut Rng) -> String {
    format!("{}{}", rng.id(), rng.id())
}

fn scalar_key_and_value(rng: &mut Rng) -> (String, Value) {
    let song = random_song(rng);
    match rng.below(6) {
        0 => ("pref/theme".to_owned(), json!(rng.below(5))),
        1 => ("pref/volume".to_owned(), json!({ "level": rng.below(100) })),
        2 => (
            "eq/preset".to_owned(),
            json!(format!("preset{}", rng.below(4))),
        ),
        3 => ("want/album".to_owned(), json!([rng.below(9), rng.below(9)])),
        4 => (format!("lyr/{}", song_key_of(song)), json!(rng.below(5000))),
        _ => (
            format!("meta/{}", song_key_of(song)),
            json!({ "plays": rng.below(50) }),
        ),
    }
}

fn scalar_key(rng: &mut Rng) -> String {
    scalar_key_and_value(rng).0
}

fn invalid_mutation(rng: &mut Rng) -> (&'static str, Value) {
    match rng.below(4) {
        0 => (
            "entry.insert",
            json!({ "id": rng.id(), "playlist": rng.id(), "ref": song_ref(0), "place": { "kind": "last" } }),
        ),
        1 => ("scalar.set", json!({ "key": "bogus/key", "value": 1 })),
        2 => {
            let song = random_song(rng);
            (
                "rating.set",
                json!({ "songKey": song_key_of(song), "ref": song_ref(song), "rating": 9 }),
            )
        }
        _ => ("album.merge", json!({})),
    }
}

fn create(rng: &mut Rng) -> (&'static str, Value) {
    let count = rng.below(4);
    let entries: Vec<Value> = (0..count).map(|_| new_entry(rng)).collect();
    (
        "playlist.create",
        json!({ "id": rng.id(), "name": format!("Playlist {}", rng.below(1000)), "entries": entries }),
    )
}

fn entry_mutation(
    rng: &mut Rng,
    playlist: &str,
    order: &[&Entry],
    roll: usize,
) -> (&'static str, Value) {
    let song = random_song(rng);
    let where_to = place(rng, order);
    if roll < 40 || order.is_empty() {
        let args = json!({ "id": rng.id(), "playlist": playlist, "ref": song_ref(song), "place": where_to });
        return ("entry.insert", args);
    }
    if roll < 44 {
        let count = 1 + rng.below(4);
        let entries: Vec<Value> = (0..count).map(|_| new_entry(rng)).collect();
        return (
            "entry.insertMany",
            json!({ "playlist": playlist, "entries": entries, "place": where_to }),
        );
    }
    let target = rng.pick(order).id.clone();
    if roll < 54 {
        ("entry.move", json!({ "id": target, "place": where_to }))
    } else {
        ("entry.remove", json!({ "id": target }))
    }
}

fn playlist_mutation(rng: &mut Rng, playlist: &str, roll: usize) -> (&'static str, Value) {
    match roll {
        6..=11 => (
            "playlist.rename",
            json!({ "id": playlist, "name": format!("Renamed {}", rng.below(1000)) }),
        ),
        12..=13 => (
            "playlist.setCover",
            json!({ "id": playlist, "blob": blob(rng) }),
        ),
        14..=15 => ("playlist.clearCover", json!({ "id": playlist })),
        16..=18 => ("playlist.delete", json!({ "id": playlist })),
        19..=21 => ("playlist.restore", json!({ "id": playlist })),
        _ => {
            let visibility = if rng.chance(50) {
                "household"
            } else {
                "private"
            };
            (
                "playlist.setVisibility",
                json!({ "id": playlist, "visibility": visibility }),
            )
        }
    }
}

fn song_mutation(rng: &mut Rng, roll: usize) -> (&'static str, Value) {
    let song = random_song(rng);
    let key = song_key_of(song);
    match roll {
        60..=65 => (
            "love.set",
            json!({ "songKey": key, "ref": song_ref(song), "loved": rng.chance(60) }),
        ),
        66..=70 => {
            let rating = if rng.chance(20) {
                Value::Null
            } else {
                json!(1 + rng.below(5))
            };
            (
                "rating.set",
                json!({ "songKey": key, "ref": song_ref(song), "rating": rating }),
            )
        }
        71..=76 => {
            let (key, value) = scalar_key_and_value(rng);
            ("scalar.set", json!({ "key": key, "value": value }))
        }
        77..=79 => ("scalar.clear", json!({ "key": scalar_key(rng) })),
        _ => (
            "session.save",
            json!({ "session": { "queue": rng.below(20), "positionMs": rng.below(100000) } }),
        ),
    }
}

/// One random mutation a user could make looking at `visible`.
///
/// With `pressure` most of the work piles inserts at the front of one playlist,
/// which is what drives positions past the rewrite length.
pub fn random_mutation(rng: &mut Rng, visible: &Store, pressure: bool) -> (&'static str, Value) {
    let ids: Vec<String> = visible.playlists.keys().cloned().collect();
    let roll = rng.below(100);
    if ids.is_empty() || roll < 6 {
        return create(rng);
    }
    if pressure && rng.chance(45) {
        return pressure_insert(rng, visible, &ids[0]);
    }
    if roll >= 85 {
        return invalid_mutation(rng);
    }
    let playlist = rng.pick(&ids).clone();
    if (6..=24).contains(&roll) {
        return playlist_mutation(rng, &playlist, roll);
    }
    if roll >= 60 {
        return song_mutation(rng, roll);
    }
    let doc = visible.doc(&playlist);
    let order = doc.as_ref().map(|doc| doc.ordered()).unwrap_or_default();
    entry_mutation(rng, &playlist, &order, roll)
}

const PRESSURE_PLAYLIST: &str = "0-long";
const PRESSURE_USER: &str = "user";

fn long_position(last_digit: char) -> String {
    format!("{}{last_digit}", "0".repeat(63))
}

fn pressure_entry(id: &str, last_digit: char) -> Value {
    json!({
        "kind": "playlist_entry",
        "id": id,
        "value": {
            "id": id,
            "playlist": PRESSURE_PLAYLIST,
            "ref": song_ref(0),
            "pos": long_position(last_digit),
            "alive": true,
            "stamps": { "ref": 1, "pos": 1, "alive": 1 },
        },
    })
}

/// A `state.reseed` argument holding a playlist whose positions are already 64 characters long.
pub fn pressure_seed() -> Value {
    let playlist = json!({
        "kind": "playlist",
        "id": PRESSURE_PLAYLIST,
        "value": {
            "id": PRESSURE_PLAYLIST,
            "owner": PRESSURE_USER,
            "name": "Long",
            "coverBlob": null,
            "visibility": "private",
            "alive": true,
            "createdAt": 1,
            "stamps": { "name": 1, "cover": 1, "visibility": 1, "alive": 1 },
        },
    });
    json!({ "entities": [playlist, pressure_entry("0-e1", 'V'), pressure_entry("0-e2", 'z')] })
}

fn pressure_insert(rng: &mut Rng, visible: &Store, playlist: &str) -> (&'static str, Value) {
    let doc = visible.doc(playlist);
    let order = doc.as_ref().map(|doc| doc.ordered()).unwrap_or_default();
    let where_to = match order.first() {
        Some(first) => json!({ "kind": "after", "id": first.id }),
        None => json!({ "kind": "first" }),
    };
    let song = random_song(rng);
    let args =
        json!({ "id": rng.id(), "playlist": playlist, "ref": song_ref(song), "place": where_to });
    ("entry.insert", args)
}
