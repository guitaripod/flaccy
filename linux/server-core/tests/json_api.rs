mod common;

use common::*;
use flaccy_server_core::json_api;
use flaccy_server_core::model::PlaylistDoc;
use flaccy_server_core::song::song_key;
use serde_json::{json, Value};

fn call(function: fn(&str) -> String, input: Value) -> Value {
    serde_json::from_str(&function(&input.to_string())).unwrap()
}

fn caller_json() -> Value {
    json!({ "user": "alice", "role": "member", "device": "phone" })
}

#[test]
fn between_answers_a_position() {
    let first = call(json_api::between, json!({ "a": null, "b": null }));
    assert_eq!(first, json!({ "pos": "V" }));
    let after = call(json_api::between, json!({ "a": "V", "b": null }));
    assert_eq!(after, json!({ "pos": "W" }));
}

#[test]
fn song_key_matches_the_core_function() {
    let answer = call(
        json_api::song_key,
        json!({ "artistKey": "artist", "titleKey": "title" }),
    );
    assert_eq!(answer["songKey"], json!(song_key("artist", "title")));
}

#[test]
fn suppressed_flags_come_back_in_input_order() {
    let events = json!([
        { "eventId": "a", "recorded": false, "titleKey": "t", "artistKey": "x" },
        { "eventId": "b", "recorded": true, "titleKey": "t", "artistKey": "x" },
    ]);
    assert_eq!(
        call(json_api::suppressed_flags, json!({ "events": events })),
        json!({ "flags": [true, false] })
    );
}

#[test]
fn next_stamp_steps_the_client_clock() {
    let answer = call(
        json_api::next_stamp,
        json!({ "last": 0, "offsetMs": 500, "nowMs": 1000 }),
    );
    assert_eq!(answer, json!({ "stamp": 1500_i64 << 16 }));
    let again = call(
        json_api::next_stamp,
        json!({ "last": 1500_i64 << 16, "offsetMs": 500, "nowMs": 1000 }),
    );
    assert_eq!(again, json!({ "stamp": (1500_i64 << 16) + 1 }));
}

#[test]
fn apply_playlist_creates_then_renames() {
    let create = mutation(
        1,
        "playlist.create",
        100,
        json!({ "id": "p1", "name": "Mix", "entries": [entry("a", 1)] }),
    );
    let created = call(
        json_api::apply_playlist,
        json!({ "doc": null, "mutation": create, "caller": caller_json() }),
    );
    assert_eq!(created["status"], "applied");
    assert_eq!(created["changed"].as_array().unwrap().len(), 2);
    let rename = mutation(
        2,
        "playlist.rename",
        200,
        json!({ "id": "p1", "name": "New" }),
    );
    let renamed = call(
        json_api::apply_playlist,
        json!({ "doc": created["doc"], "mutation": rename, "caller": caller_json() }),
    );
    assert_eq!(renamed["status"], "applied");
    assert_eq!(renamed["doc"]["playlist"]["name"], "New");
}

#[test]
fn apply_playlist_reports_invalid_codes_on_the_wire() {
    let rename = mutation(
        1,
        "playlist.rename",
        100,
        json!({ "id": "ghost", "name": "x" }),
    );
    let answer = call(
        json_api::apply_playlist,
        json!({ "doc": null, "mutation": rename, "caller": caller_json() }),
    );
    assert_eq!(answer["status"], "invalid");
    assert_eq!(answer["code"], "unknown_playlist");
}

#[test]
fn apply_scalar_sets_and_reports_a_noop_for_an_old_stamp() {
    let set = mutation(
        1,
        "scalar.set",
        200,
        json!({ "key": "pref/theme", "value": "dark" }),
    );
    let applied = call(
        json_api::apply_scalar,
        json!({ "scalar": null, "mutation": set, "caller": caller_json() }),
    );
    assert_eq!(applied["status"], "applied");
    assert_eq!(applied["scalar"]["value"], "dark");
    let older = mutation(
        2,
        "scalar.set",
        100,
        json!({ "key": "pref/theme", "value": "light" }),
    );
    let stale = call(
        json_api::apply_scalar,
        json!({ "scalar": applied["scalar"], "mutation": older, "caller": caller_json() }),
    );
    assert_eq!(stale["status"], "noop");
    assert_eq!(stale["scalar"]["value"], "dark");
}

#[test]
fn rebase_playlist_folds_pending_and_skips_failed_ones() {
    let base: PlaylistDoc = created("p1", vec![entry("a", 1)]).unwrap();
    let pending = json!([
        { "mutation": mutation(1, "playlist.rename", 200, json!({ "id": "p1", "name": "Pending" })), "failed": false },
        { "mutation": mutation(2, "entry.remove", 210, json!({ "id": "a" })), "failed": true },
    ]);
    let answer = call(
        json_api::rebase_playlist,
        json!({ "playlistId": "p1", "base": base, "caller": caller_json(), "pending": pending }),
    );
    assert_eq!(answer["doc"]["playlist"]["name"], "Pending");
    assert_eq!(answer["doc"]["entries"][0]["alive"], true);
}

#[test]
fn bad_input_answers_an_error_document() {
    let answer = call(json_api::between, json!({ "a": 3 }));
    assert!(answer["error"].is_string());
    let not_json: Value = serde_json::from_str(&json_api::apply_playlist("nope")).unwrap();
    assert!(not_json["error"].is_string());
    let wrong_kind = call(
        json_api::apply_playlist,
        json!({ "doc": null, "mutation": mutation(1, "love.set", 1, json!({})), "caller": caller_json() }),
    );
    assert!(wrong_kind["error"].is_string());
}

fn rebase_input(identity: Value, base: Value, pending: Value) -> Value {
    let mut input = json!({ "base": base, "caller": caller_json(), "pending": pending });
    input
        .as_object_mut()
        .unwrap()
        .extend(identity.as_object().unwrap().clone());
    input
}

fn pending(mutation: flaccy_server_core::wire::Mutation) -> Value {
    json!({ "mutation": mutation, "failed": false })
}

#[test]
fn rebase_love_folds_a_pending_love_over_the_base() {
    let key = song_key("artist", "title");
    let reference = json!({ "songKey": key, "title": "Title", "artist": "Artist" });
    let love = mutation(
        1,
        "love.set",
        300,
        json!({ "songKey": key, "ref": reference, "loved": true }),
    );
    let answer = call(
        json_api::rebase_love,
        rebase_input(
            json!({ "songKey": key }),
            Value::Null,
            json!([pending(love)]),
        ),
    );
    assert_eq!(answer["love"]["loved"], true);
    assert_eq!(answer["love"]["stamp"], 300);
    let unrelated = call(
        json_api::rebase_love,
        rebase_input(
            json!({ "songKey": song_key("other", "song") }),
            Value::Null,
            json!([]),
        ),
    );
    assert_eq!(unrelated, json!({ "love": null }));
}

#[test]
fn rebase_rating_folds_a_pending_rating_and_skips_failed_ones() {
    let key = song_key("artist", "title");
    let reference = json!({ "songKey": key, "title": "Title", "artist": "Artist" });
    let rate = |id: i64, stamp: i64, stars: u8, failed: bool| {
        let mutation = mutation(
            id,
            "rating.set",
            stamp,
            json!({ "songKey": key, "ref": reference, "rating": stars }),
        );
        json!({ "mutation": mutation, "failed": failed })
    };
    let answer = call(
        json_api::rebase_rating,
        rebase_input(
            json!({ "songKey": key }),
            Value::Null,
            json!([rate(1, 300, 4, false), rate(2, 400, 1, true)]),
        ),
    );
    assert_eq!(answer["rating"]["rating"], 4);
}

#[test]
fn rebase_scalar_folds_set_then_clear() {
    let set = mutation(
        1,
        "scalar.set",
        200,
        json!({ "key": "pref/theme", "value": "dark" }),
    );
    let clear = mutation(2, "scalar.clear", 300, json!({ "key": "pref/theme" }));
    let only_set = call(
        json_api::rebase_scalar,
        rebase_input(
            json!({ "key": "pref/theme" }),
            Value::Null,
            json!([pending(set.clone())]),
        ),
    );
    assert_eq!(only_set["scalar"]["value"], "dark");
    let cleared = call(
        json_api::rebase_scalar,
        rebase_input(
            json!({ "key": "pref/theme" }),
            Value::Null,
            json!([pending(set), pending(clear)]),
        ),
    );
    assert_eq!(cleared["scalar"]["deleted"], true);
}

#[test]
fn rebase_session_folds_only_the_callers_device() {
    let save = mutation(
        1,
        "session.save",
        200,
        json!({ "session": { "queue": [1, 2] } }),
    );
    let own = call(
        json_api::rebase_session,
        rebase_input(
            json!({ "device": "phone" }),
            Value::Null,
            json!([pending(save.clone())]),
        ),
    );
    assert_eq!(own["session"]["session"]["queue"], json!([1, 2]));
    let other = call(
        json_api::rebase_session,
        rebase_input(
            json!({ "device": "mac" }),
            Value::Null,
            json!([pending(save)]),
        ),
    );
    assert_eq!(other, json!({ "session": null }));
}

#[test]
fn rebase_functions_reject_malformed_input() {
    for function in [
        json_api::rebase_love,
        json_api::rebase_rating,
        json_api::rebase_scalar,
        json_api::rebase_session,
    ] {
        assert!(call(function, json!({ "pending": 3 }))["error"].is_string());
    }
}

#[test]
fn id_derivations_match_the_core_functions() {
    use flaccy_server_core::song::{
        entry_id, event_id_mig, event_id_rec, normalize_playlist_name, playlist_id,
    };
    let name = call(
        json_api::normalize_playlist_name,
        json!({ "name": "  Road   TRIP " }),
    );
    assert_eq!(name, json!({ "name": normalize_playlist_name("  Road   TRIP ") }));
    assert_eq!(name["name"], "road trip");
    let playlist = call(
        json_api::playlist_id,
        json!({ "name": "Road Trip", "occurrence": 1 }),
    );
    assert_eq!(playlist["playlistId"], json!(playlist_id("Road Trip", 1)));
    let entry = call(
        json_api::entry_id,
        json!({ "playlistId": "p", "songKey": "k", "occurrence": 2 }),
    );
    assert_eq!(entry["entryId"], json!(entry_id("p", "k", 2)));
    let rec = call(
        json_api::event_id_rec,
        json!({ "deviceId": "d", "instance": "i", "counter": 7 }),
    );
    assert_eq!(rec["eventId"], json!(event_id_rec("d", "i", 7)));
    let migrated = call(
        json_api::event_ids_mig,
        json!({ "plays": [{ "ts": 5, "titleKey": "t", "artistKey": "a" }, { "ts": 6, "titleKey": "t", "artistKey": "a" }] }),
    );
    assert_eq!(
        migrated,
        json!({ "eventIds": [event_id_mig(5, "t", "a"), event_id_mig(6, "t", "a")] })
    );
}

#[test]
fn song_keys_answers_in_input_order() {
    let answer = call(
        json_api::song_keys,
        json!({ "pairs": [{ "artistKey": "a", "titleKey": "b" }, { "artistKey": "c", "titleKey": "d" }] }),
    );
    assert_eq!(answer, json!({ "songKeys": [song_key("a", "b"), song_key("c", "d")] }));
}
