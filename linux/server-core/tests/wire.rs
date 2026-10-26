mod common;

use common::*;
use flaccy_server_core::digest::{arg_hash, canonical_json, state_digest};
use flaccy_server_core::model::{Entity, EntityKind, Place, SongRef, Visibility};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{
    Change, ErrorCode, Hello, Mutation, MutationResult, MutationStatus, PullResponse, PushRequest,
    PushResponse, Role,
};
use serde_json::{json, Value};

#[test]
fn a_mutation_parses_from_the_documented_json() {
    let text = r#"{"id": 7, "name": "playlist.rename", "stamp": 117440512000001, "args": {"id": "p", "name": "x"}}"#;
    let parsed: Mutation = serde_json::from_str(text).unwrap();
    assert_eq!(parsed.id, 7);
    assert_eq!(parsed.stamp, Stamp(117_440_512_000_001));
    assert_eq!(
        serde_json::to_value(&parsed).unwrap()["stamp"],
        json!(117_440_512_000_001_i64)
    );
}

#[test]
fn a_push_response_uses_camel_case_and_omits_an_absent_code() {
    let response = PushResponse {
        results: vec![
            MutationResult {
                id: 1,
                status: MutationStatus::Applied,
                code: None,
            },
            MutationResult {
                id: 2,
                status: MutationStatus::Invalid,
                code: Some(ErrorCode::UnknownAnchor),
            },
        ],
        server_time_ms: 1_790_000_000_000,
    };
    assert_eq!(
        serde_json::to_value(&response).unwrap(),
        json!({
            "results": [
                { "id": 1, "status": "applied" },
                { "id": 2, "status": "invalid", "code": "unknown_anchor" },
            ],
            "serverTimeMs": 1_790_000_000_000_i64,
        })
    );
}

#[test]
fn a_pull_response_matches_the_documented_shape() {
    let value = json!({
        "head": 9, "incarnation": "inc", "lastMutationId": 4, "more": false, "serverTimeMs": 5,
        "changes": [{ "seq": 9, "kind": "playlist_entry", "id": "e", "deleted": false, "value": { "id": "e" } }],
    });
    let parsed: PullResponse = serde_json::from_value(value.clone()).unwrap();
    assert_eq!(parsed.last_mutation_id, 4);
    assert_eq!(parsed.changes[0].kind, EntityKind::PlaylistEntry);
    assert_eq!(serde_json::to_value(&parsed).unwrap(), value);
}

#[test]
fn a_push_request_round_trips() {
    let request = PushRequest {
        device: "d".into(),
        instance: "i".into(),
        mutations: vec![mutation(1, "scalar.clear", 5, json!({ "key": "pref/a" }))],
    };
    let back: PushRequest =
        serde_json::from_value(serde_json::to_value(&request).unwrap()).unwrap();
    assert_eq!(back, request);
}

#[test]
fn hello_parses_with_and_without_a_caller() {
    let text = json!({
        "protocol": [1], "server": { "name": "arch", "version": "1.0.0", "schema": 1 },
        "features": ["sync", "live"], "mode": "easy", "serverTimeMs": 1_790_000_000_000_i64,
        "incarnation": "u", "caller": null,
    });
    let hello: Hello = serde_json::from_value(text.clone()).unwrap();
    assert!(hello.caller.is_none());
    let with_caller = json!({ "user": "u1", "role": "member", "device": null });
    let mut text = text;
    text["caller"] = with_caller;
    let hello: Hello = serde_json::from_value(text).unwrap();
    assert_eq!(hello.caller.unwrap().role, Role::Member);
}

#[test]
fn song_ref_fills_the_optional_fields() {
    let parsed: SongRef =
        serde_json::from_value(json!({ "songKey": "k", "title": "t", "artist": "a" })).unwrap();
    assert_eq!(parsed.album, "");
    assert_eq!(parsed.duration_ms, 0);
    assert_eq!(parsed.fp, None);
    let value = serde_json::to_value(&parsed).unwrap();
    for field in [
        "songKey",
        "title",
        "artist",
        "album",
        "durationMs",
        "fp",
        "mbid",
        "albumKey",
        "relPath",
    ] {
        assert!(value.get(field).is_some(), "{field}");
    }
}

#[test]
fn place_and_visibility_use_the_documented_spellings() {
    let after: Place = serde_json::from_value(json!({ "kind": "after", "id": "e" })).unwrap();
    assert_eq!(after, Place::After { id: "e".into() });
    assert_eq!(
        serde_json::to_value(Place::First).unwrap(),
        json!({ "kind": "first" })
    );
    assert_eq!(
        serde_json::to_value(Visibility::Household).unwrap(),
        json!("household")
    );
}

#[test]
fn entity_values_decode_and_validate() {
    let doc = created("p1", vec![entry("a", 1)]).unwrap();
    let playlist = Entity {
        kind: EntityKind::Playlist,
        id: "p1".into(),
        value: serde_json::to_value(&doc.playlist).unwrap(),
    };
    assert!(playlist.decode().is_ok());
    let wrong_id = Entity {
        id: "other".into(),
        ..playlist.clone()
    };
    assert_eq!(wrong_id.decode(), Err(ErrorCode::BadArgs));
    let listen = Entity {
        kind: EntityKind::Listen,
        id: "x".into(),
        value: Value::Null,
    };
    assert_eq!(listen.decode(), Err(ErrorCode::BadArgs));
    let mut bad_entry = serde_json::to_value(&doc.entries[0]).unwrap();
    bad_entry["pos"] = json!("V0");
    let entity = Entity {
        kind: EntityKind::PlaylistEntry,
        id: "a".into(),
        value: bad_entry,
    };
    assert_eq!(entity.decode(), Err(ErrorCode::BadArgs));
}

#[test]
fn canonical_json_sorts_keys_and_drops_whitespace() {
    let value = json!({ "b": [1, { "z": null, "a": "x\"y" }], "a": 1.5 });
    assert_eq!(
        canonical_json(&value),
        r#"{"a":1.5,"b":[1,{"a":"x\"y","z":null}]}"#
    );
}

#[test]
fn arg_hash_ignores_key_order_but_not_content_or_name() {
    let one = arg_hash("m", &json!({ "a": 1, "b": 2 }));
    assert_eq!(one, arg_hash("m", &json!({ "b": 2, "a": 1 })));
    assert_ne!(one, arg_hash("m", &json!({ "a": 1, "b": 3 })));
    assert_ne!(one, arg_hash("n", &json!({ "a": 1, "b": 2 })));
}

#[test]
fn state_digest_ignores_entity_order_and_sees_changes() {
    let doc = created("p1", vec![entry("a", 1), entry("b", 2)]).unwrap();
    let mut entities: Vec<Entity> = doc
        .entries
        .iter()
        .map(|e| Entity {
            kind: EntityKind::PlaylistEntry,
            id: e.id.clone(),
            value: serde_json::to_value(e).unwrap(),
        })
        .collect();
    let digest = state_digest(&entities);
    entities.reverse();
    assert_eq!(digest, state_digest(&entities));
    entities[0].value["pos"] = json!("zz");
    assert_ne!(digest, state_digest(&entities));
    assert_eq!(digest.len(), 64);
}

#[test]
fn change_round_trips() {
    let change = Change {
        seq: 3,
        kind: EntityKind::Scalar,
        id: "pref/a".into(),
        deleted: true,
        value: json!({ "key": "pref/a" }),
    };
    let back: Change = serde_json::from_value(serde_json::to_value(&change).unwrap()).unwrap();
    assert_eq!(back, change);
}
