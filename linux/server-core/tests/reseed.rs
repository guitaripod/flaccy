mod common;

use common::*;
use flaccy_server_core::apply::{reseed_into_doc, Caller, Status};
use flaccy_server_core::model::{EntityKind, EntityValue};
use flaccy_server_core::mutation::{parse, Op};
use flaccy_server_core::wire::{ErrorCode, Role};
use serde_json::json;

fn entities_of(doc: &flaccy_server_core::model::PlaylistDoc) -> Vec<EntityValue> {
    let mut all = vec![EntityValue::Playlist(doc.playlist.clone())];
    all.extend(doc.entries.iter().cloned().map(EntityValue::Entry));
    all
}

fn reseed_op(entities: &[EntityValue]) -> Vec<EntityValue> {
    let wire: Vec<_> = entities.iter().map(EntityValue::to_entity).collect();
    match parsed("state.reseed", json!({ "entities": wire })) {
        Op::Reseed(decoded) => decoded,
        other => panic!("{other:?}"),
    }
}

#[test]
fn reseed_into_nothing_recreates_the_playlist_and_its_entries() {
    let source = created("p1", vec![entry("a", 1), entry("b", 2)]).unwrap();
    let entities = reseed_op(&entities_of(&source));
    let mut doc = None;
    let outcome = reseed_into_doc(&mut doc, "p1", &entities, &alice());
    assert_eq!(outcome.status, Status::Applied);
    assert_eq!(outcome.changed.len(), 3);
    assert_eq!(doc, Some(source));
}

#[test]
fn reseeding_the_same_state_again_is_a_noop() {
    let source = created("p1", vec![entry("a", 1)]).unwrap();
    let entities = reseed_op(&entities_of(&source));
    let mut doc = Some(source);
    assert_eq!(
        reseed_into_doc(&mut doc, "p1", &entities, &alice()).status,
        Status::Noop
    );
}

#[test]
fn reseed_keeps_the_newer_field_and_never_revives_a_removed_entry() {
    let mut older = created("p1", vec![entry("a", 1)]).unwrap();
    let mut newer = older.clone();
    newer.playlist.name = "Newer".into();
    newer.playlist.stamps.name = flaccy_server_core::stamp::Stamp(500);
    newer.entries[0].alive = false;
    newer.entries[0].stamps.alive = flaccy_server_core::stamp::Stamp(500);
    older.playlist.name = "Older".into();
    let mut doc = Some(newer.clone());
    reseed_into_doc(&mut doc, "p1", &reseed_op(&entities_of(&older)), &alice());
    let merged = doc.unwrap();
    assert_eq!(merged.playlist.name, "Newer");
    assert!(!merged.entries[0].alive);
    let mut from_old = Some(older.clone());
    reseed_into_doc(
        &mut from_old,
        "p1",
        &reseed_op(&entities_of(&newer)),
        &alice(),
    );
    let merged = from_old.unwrap();
    assert_eq!(merged.playlist.name, "Newer");
    assert!(!merged.entries[0].alive);
}

#[test]
fn reseed_of_a_stranger_or_a_guest_is_forbidden_and_leaves_the_doc_alone() {
    let source = created("p1", vec![entry("a", 1)]).unwrap();
    let entities = reseed_op(&entities_of(&source));
    let mut doc = None;
    let bob = Caller::member("bob", "laptop");
    assert_eq!(
        reseed_into_doc(&mut doc, "p1", &entities, &bob).status,
        Status::Invalid(ErrorCode::Forbidden)
    );
    let guest = Caller {
        user: "alice".into(),
        role: Role::Guest,
        device: "tv".into(),
    };
    assert_eq!(
        reseed_into_doc(&mut doc, "p1", &entities, &guest).status,
        Status::Invalid(ErrorCode::Forbidden)
    );
    assert_eq!(doc, None);
}

#[test]
fn entries_without_their_playlist_are_refused_whole() {
    let source = created("p1", vec![entry("a", 1)]).unwrap();
    let only_entries = reseed_op(&[EntityValue::Entry(source.entries[0].clone())]);
    let mut doc = None;
    let outcome = reseed_into_doc(&mut doc, "p1", &only_entries, &alice());
    assert_eq!(outcome.status, Status::Invalid(ErrorCode::UnknownPlaylist));
    assert_eq!(doc, None);
}

#[test]
fn reseed_only_touches_the_named_playlist() {
    let one = created("p1", vec![entry("a", 1)]).unwrap();
    let two = created("p2", vec![entry("b", 2)]).unwrap();
    let mut all = entities_of(&one);
    all.extend(entities_of(&two));
    let mut doc = None;
    let outcome = reseed_into_doc(&mut doc, "p2", &reseed_op(&all), &alice());
    assert_eq!(outcome.status, Status::Applied);
    assert_eq!(doc, Some(two));
    assert!(outcome.changed.iter().all(|c| c.kind != EntityKind::Love));
}

#[test]
fn reseed_arguments_are_validated_as_a_whole() {
    let bad = json!({ "entities": [{ "kind": "listen", "id": "x", "value": {} }] });
    let result = parse(&mutation(1, "state.reseed", 1, bad));
    assert_eq!(
        result,
        Err(flaccy_server_core::mutation::ParseError::Invalid(
            ErrorCode::BadArgs
        ))
    );
}
