//! The playlist paths that must stay cheap on a large playlist, and the caps that keep it from growing without bound.

mod common;

use common::*;
use flaccy_server_core::apply::{clamp_reseed, Status};
use flaccy_server_core::model::{
    EntityValue, Entry, Place, Playlist, PlaylistDoc, PlaylistStamps, Visibility, MAX_ENTRIES, MAX_TOTAL_ENTRIES,
};
use flaccy_server_core::model::Entity;
use flaccy_server_core::mutation::{chunk_reseed, parse, ParseError, MAX_RESEED_ENTITIES};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::ErrorCode;
use serde_json::{json, Value};

fn playlist(id: &str) -> Playlist {
    Playlist {
        id: id.to_owned(),
        owner: "alice".to_owned(),
        name: id.to_owned(),
        cover_blob: None,
        visibility: Visibility::Private,
        alive: true,
        created_at: 1,
        stamps: PlaylistStamps::all(Stamp(1)),
    }
}

fn doc_with_positions(positions: &[(&str, &str)]) -> PlaylistDoc {
    let mut doc = PlaylistDoc::new(playlist("p"));
    for (id, pos) in positions {
        doc.entries.push(Entry::new(id, "p", song(0), (*pos).to_owned(), Stamp(1)));
    }
    doc
}

fn sorted_ids(doc: &PlaylistDoc, skip: Option<&str>) -> Vec<String> {
    doc.ordered().iter().map(|entry| entry.id.clone()).filter(|id| Some(id.as_str()) != skip).collect()
}

fn neighbour_ids(doc: &PlaylistDoc, place: &Place, skip: Option<&str>) -> (Option<String>, Option<String>) {
    let (before, after) = doc.neighbours(place, skip).unwrap();
    (before.map(|entry| entry.id.clone()), after.map(|entry| entry.id.clone()))
}

fn expected_neighbours(order: &[String], place: &Place) -> (Option<String>, Option<String>) {
    match place {
        Place::First => (None, order.first().cloned()),
        Place::Last => (order.last().cloned(), None),
        Place::After { id } => {
            let at = order.iter().position(|candidate| candidate == id).unwrap();
            (Some(order[at].clone()), order.get(at + 1).cloned())
        }
        Place::Before { id } => {
            let at = order.iter().position(|candidate| candidate == id).unwrap();
            (at.checked_sub(1).map(|before| order[before].clone()), Some(order[at].clone()))
        }
    }
}

#[test]
fn neighbours_agree_with_a_sorted_walk_including_equal_keys_and_a_skipped_entry() {
    let doc = doc_with_positions(&[("d", "5"), ("a", "5"), ("c", "V"), ("b", "5"), ("e", "A1"), ("f", "z"), ("g", "V")]);
    for skip in [None, Some("a"), Some("c"), Some("f")] {
        let order = sorted_ids(&doc, skip);
        let mut places = vec![Place::First, Place::Last];
        for id in &order {
            places.push(Place::After { id: id.clone() });
            places.push(Place::Before { id: id.clone() });
        }
        for place in places {
            assert_eq!(neighbour_ids(&doc, &place, skip), expected_neighbours(&order, &place), "{place:?} skipping {skip:?}");
        }
    }
    assert!(doc.neighbours(&Place::After { id: "nobody".into() }, None).is_err());
    assert!(doc.neighbours(&Place::After { id: "a".into() }, Some("a")).is_err());
}

fn keys(doc: &Option<PlaylistDoc>) -> Vec<(String, String)> {
    doc.as_ref().unwrap().ordered().iter().map(|entry| (entry.id.clone(), entry.pos.clone())).collect()
}

fn insert_one_by_one(mut doc: Option<PlaylistDoc>, place: &Value, ids: &[String]) -> Option<PlaylistDoc> {
    let mut place = place.clone();
    for (index, id) in ids.iter().enumerate() {
        let args = json!({ "id": id, "playlist": "p", "ref": song_json(index), "place": place });
        assert_eq!(run_playlist(&mut doc, &alice(), 50, "entry.insert", args).status, Status::Applied);
        place = json!({ "kind": "after", "id": id });
    }
    doc
}

fn insert_many_at_once(mut doc: Option<PlaylistDoc>, place: &Value, ids: &[String]) -> Option<PlaylistDoc> {
    let entries: Vec<Value> = ids.iter().enumerate().map(|(index, id)| entry(id, index)).collect();
    let args = json!({ "playlist": "p", "entries": entries, "place": place });
    assert_eq!(run_playlist(&mut doc, &alice(), 50, "entry.insertMany", args).status, Status::Applied);
    doc
}

#[test]
fn insert_many_gives_every_entry_the_key_an_insert_after_the_previous_one_would() {
    let ids: Vec<String> = (0..60).map(|index| format!("n{index}")).collect();
    let base = created("p", (0..25).map(|index| entry(&format!("e{index}"), index)).collect());
    for place in [json!({ "kind": "first" }), json!({ "kind": "last" }), json!({ "kind": "after", "id": "e7" }), json!({ "kind": "before", "id": "e7" })] {
        let together = insert_many_at_once(base.clone(), &place, &ids);
        let one_by_one = insert_one_by_one(base.clone(), &place, &ids);
        assert_eq!(keys(&together), keys(&one_by_one), "{place}");
    }
}

#[test]
fn insert_many_keeps_the_requested_order_between_equal_keys_left_by_a_reseed() {
    let base = Some(doc_with_positions(&[("a", "V"), ("b", "V"), ("c", "W")]));
    let ids: Vec<String> = (0..12).map(|index| format!("n{index}")).collect();
    let place = json!({ "kind": "after", "id": "a" });
    let together = insert_many_at_once(base.clone(), &place, &ids);
    let one_by_one = insert_one_by_one(base, &place, &ids);
    assert_eq!(keys(&together), keys(&one_by_one));
}

fn alive_total(doc: &PlaylistDoc) -> (usize, usize) {
    (doc.entries.iter().filter(|entry| entry.alive).count(), doc.entries.len())
}

fn crowded(alive: usize, dead: usize) -> Option<PlaylistDoc> {
    let mut doc = PlaylistDoc::new(playlist("p"));
    for index in 0..alive + dead {
        let mut entry = Entry::new(&format!("x{index}"), "p", song(0), format!("M{index:06}1"), Stamp(1));
        entry.alive = index < alive;
        doc.entries.push(entry);
    }
    assert_eq!(alive_total(&doc), (alive, alive + dead));
    Some(doc)
}

#[test]
fn a_playlist_takes_no_entry_past_twenty_thousand_alive_or_forty_thousand_in_all() {
    let many = |count: usize| json!({ "playlist": "p", "entries": (0..count).map(|index| entry(&format!("n{index}"), index)).collect::<Vec<_>>(), "place": { "kind": "last" } });
    let mut alive_full = crowded(MAX_ENTRIES - 5, 0);
    assert_eq!(run_playlist(&mut alive_full, &alice(), 50, "entry.insertMany", many(6)).status, Status::Invalid(ErrorCode::TooLarge));
    assert_eq!(run_playlist(&mut alive_full, &alice(), 50, "entry.insertMany", many(5)).status, Status::Applied);

    let mut graveyard = crowded(10, MAX_TOTAL_ENTRIES - 15);
    assert_eq!(run_playlist(&mut graveyard, &alice(), 50, "entry.insertMany", many(6)).status, Status::Invalid(ErrorCode::TooLarge));
    assert_eq!(alive_total(graveyard.as_ref().unwrap()).1, MAX_TOTAL_ENTRIES - 5);
    assert_eq!(run_playlist(&mut graveyard, &alice(), 50, "entry.insertMany", many(5)).status, Status::Applied);
    let one = json!({ "id": "straw", "playlist": "p", "ref": song_json(1), "place": { "kind": "last" } });
    assert_eq!(run_playlist(&mut graveyard, &alice(), 50, "entry.insert", one).status, Status::Invalid(ErrorCode::TooLarge));
}

fn love(index: usize) -> Value {
    let key = song_json(index)["songKey"].clone();
    json!({ "kind": "love", "id": key, "value": { "songKey": key, "ref": song_json(index), "loved": true, "stamp": 3 } })
}

fn parse_reseed(entities: Vec<Value>) -> Result<(), ParseError> {
    parse(&mutation(1, "state.reseed", 1, json!({ "entities": entities }))).map(|_| ())
}

#[test]
fn a_reseed_is_bounded_in_entities_and_bytes() {
    assert_eq!(parse_reseed((0..MAX_RESEED_ENTITIES).map(love).collect()), Ok(()));
    assert_eq!(parse_reseed((0..=MAX_RESEED_ENTITIES).map(love).collect()), Err(ParseError::Invalid(ErrorCode::TooLarge)));
    let heavy = |index: usize| json!({ "kind": "scalar", "id": format!("eq/k{index}"), "value": { "key": format!("eq/k{index}"), "value": "x".repeat(50_000), "deleted": false, "stamp": 3 } });
    assert_eq!(parse_reseed((0..9).map(heavy).collect()), Err(ParseError::Invalid(ErrorCode::TooLarge)));
    assert_eq!(parse_reseed((0..7).map(heavy).collect()), Ok(()));
}

#[test]
fn clamping_lowers_every_stamp_of_every_kind_and_leaves_lower_ones_alone() {
    let ceiling = Stamp(1_000);
    let high = Stamp(i64::MAX);
    let mut playlist = playlist("p");
    playlist.stamps = PlaylistStamps { name: high, cover: Stamp(5), visibility: high, alive: high };
    let mut entry = Entry::new("e", "p", song(0), "V".into(), high);
    entry.stamps.pos = Stamp(9);
    let entities = vec![EntityValue::Playlist(playlist), EntityValue::Entry(entry)];
    let clamped = clamp_reseed(&entities, ceiling);
    let EntityValue::Playlist(playlist) = &clamped[0] else { panic!("playlist first") };
    assert_eq!((playlist.stamps.name, playlist.stamps.cover, playlist.stamps.visibility, playlist.stamps.alive), (ceiling, Stamp(5), ceiling, ceiling));
    let EntityValue::Entry(entry) = &clamped[1] else { panic!("entry second") };
    assert_eq!((entry.stamps.song, entry.stamps.pos, entry.stamps.alive), (ceiling, Stamp(9), ceiling));
}

fn as_entities(values: Vec<Value>) -> Vec<Entity> {
    values.into_iter().map(|value| serde_json::from_value(value).unwrap()).collect()
}

#[test]
fn a_large_base_is_chunked_into_reseeds_the_server_accepts_in_order() {
    let chunks = chunk_reseed(as_entities((0..2_500).map(love).collect()));
    let sizes: Vec<usize> = chunks.iter().map(Vec::len).collect();
    assert_eq!(sizes, [1_000, 1_000, 500]);
    let ids: Vec<String> = chunks.iter().flatten().map(|entity| entity.id.clone()).collect();
    let expected: Vec<String> = (0..2_500).map(|index| song_json(index)["songKey"].as_str().unwrap().to_owned()).collect();
    assert_eq!(ids, expected);

    let heavy = |index: usize| json!({ "kind": "scalar", "id": format!("eq/k{index}"), "value": { "key": format!("eq/k{index}"), "value": "x".repeat(50_000), "deleted": false, "stamp": 3 } });
    let chunks = chunk_reseed(as_entities((0..20).map(heavy).collect()));
    assert!(chunks.len() > 1);
    for chunk in chunks {
        let args = json!({ "entities": chunk });
        assert!(parse(&mutation(1, "state.reseed", 1, args)).is_ok());
    }
    assert!(chunk_reseed(Vec::new()).is_empty());
}
