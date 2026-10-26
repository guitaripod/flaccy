use flaccy_server_core::song::song_key as core_song_key;
use flaccy_server_core_ffi::*;
use serde_json::{json, Value};

fn parsed(answer: Result<String, ServerCoreFfiError>) -> Value {
    serde_json::from_str(&answer.expect("the core answered an error")).unwrap()
}

fn message(answer: Result<String, ServerCoreFfiError>) -> String {
    match answer.expect_err("the core answered a document") {
        ServerCoreFfiError::Message(message) => message,
    }
}

fn caller() -> Value {
    json!({ "user": "alice", "role": "member", "device": "phone" })
}

#[test]
fn version_is_the_crate_version() {
    assert_eq!(version(), env!("CARGO_PKG_VERSION"));
}

#[test]
fn song_key_matches_the_core() {
    let input = json!({ "artistKey": "radiohead", "titleKey": "karma police" });
    let answer = parsed(song_key(input.to_string()));
    assert_eq!(
        answer["songKey"],
        json!(core_song_key("radiohead", "karma police"))
    );
}

#[test]
fn between_answers_the_protocol_examples() {
    let first = parsed(between(json!({ "a": null, "b": null }).to_string()));
    assert_eq!(first, json!({ "pos": "V" }));
    let after = parsed(between(json!({ "a": "V", "b": null }).to_string()));
    assert_eq!(after, json!({ "pos": "W" }));
}

#[test]
fn next_stamp_packs_the_aligned_clock() {
    let answer = parsed(next_stamp(
        json!({ "last": 0, "offsetMs": 500, "nowMs": 1000 }).to_string(),
    ));
    assert_eq!(answer, json!({ "stamp": 1500_i64 << 16 }));
}

#[test]
fn suppressed_flags_follow_input_order() {
    let events = json!([
        { "eventId": "a", "recorded": false, "titleKey": "t", "artistKey": "x" },
        { "eventId": "b", "recorded": true, "titleKey": "t", "artistKey": "x" },
    ]);
    let answer = parsed(suppressed_flags(json!({ "events": events }).to_string()));
    assert_eq!(answer, json!({ "flags": [true, false] }));
}

#[test]
fn apply_playlist_and_scalar_answer_documents() {
    let create = json!({ "id": 1, "name": "playlist.create", "stamp": 100, "args": { "id": "p1", "name": "Mix" } });
    let created = parsed(apply_playlist(
        json!({ "doc": null, "mutation": create, "caller": caller() }).to_string(),
    ));
    assert_eq!(created["status"], "applied");
    assert_eq!(created["doc"]["playlist"]["name"], "Mix");
    let set = json!({ "id": 2, "name": "scalar.set", "stamp": 200, "args": { "key": "pref/theme", "value": "dark" } });
    let stored = parsed(apply_scalar(
        json!({ "scalar": null, "mutation": set, "caller": caller() }).to_string(),
    ));
    assert_eq!(stored["scalar"]["value"], "dark");
}

#[test]
fn rebase_functions_fold_pending_mutations() {
    let key = core_song_key("artist", "title");
    let reference = json!({ "songKey": key, "title": "Title", "artist": "Artist" });
    let love = json!({ "id": 1, "name": "love.set", "stamp": 300, "args": { "songKey": key, "ref": reference, "loved": true } });
    let pending = json!([{ "mutation": love, "failed": false }]);
    let folded = parsed(rebase_love(
        json!({ "songKey": key, "base": null, "caller": caller(), "pending": pending }).to_string(),
    ));
    assert_eq!(folded["love"]["loved"], true);
    let session = json!({ "id": 2, "name": "session.save", "stamp": 400, "args": { "session": { "queue": [] } } });
    let saved = parsed(rebase_session(
        json!({ "device": "phone", "base": null, "caller": caller(), "pending": [{ "mutation": session }] }).to_string(),
    ));
    assert_eq!(saved["session"]["stamp"], 400);
}

#[test]
fn a_core_error_document_becomes_the_error() {
    assert!(message(between(json!({ "a": 3 }).to_string())).contains("invalid type"));
    assert!(!message(apply_playlist("nope".to_owned())).is_empty());
    let key = core_song_key("artist", "title");
    let reference = json!({ "songKey": key, "title": "Title", "artist": "Artist" });
    let love = json!({ "id": 1, "name": "love.set", "stamp": 1, "args": { "songKey": key, "ref": reference, "loved": true } });
    let wrong_kind =
        apply_playlist(json!({ "doc": null, "mutation": love, "caller": caller() }).to_string());
    assert_eq!(message(wrong_kind), "not a playlist mutation");
}

#[test]
fn every_export_reports_malformed_input_as_an_error() {
    let exports: [fn(String) -> Result<String, ServerCoreFfiError>; 11] = [
        apply_playlist,
        apply_scalar,
        rebase_playlist,
        rebase_love,
        rebase_rating,
        rebase_scalar,
        rebase_session,
        between,
        song_key,
        suppressed_flags,
        next_stamp,
    ];
    for export in exports {
        assert!(export("[]".to_owned()).is_err());
    }
}
