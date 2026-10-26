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
