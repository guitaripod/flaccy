mod common;

use common::*;
use flaccy_server_core::apply::{
    apply_love, apply_rating, apply_scalar, apply_session, Caller, Status,
};
use flaccy_server_core::model::{EntityKind, Visibility, MAX_ENTRIES};
use flaccy_server_core::mutation::{parse, Op, ParseError};
use flaccy_server_core::position::{rebalance, MAX_POS_LEN};
use flaccy_server_core::stamp::Stamp;
use flaccy_server_core::wire::{ErrorCode, Role};
use serde_json::json;

fn id_args(id: &str) -> serde_json::Value {
    json!({ "id": id })
}

fn household_doc() -> Option<flaccy_server_core::model::PlaylistDoc> {
    let mut doc = created("p1", vec![entry("a", 1), entry("b", 2)]);
    let outcome = run_playlist(
        &mut doc,
        &alice(),
        110,
        "playlist.setVisibility",
        json!({ "id": "p1", "visibility": "household" }),
    );
    assert_eq!(outcome.status, Status::Applied);
    doc
}

fn bob() -> Caller {
    Caller::member("bob", "laptop")
}

fn with_role(role: Role) -> Caller {
    Caller {
        user: "carol".into(),
        role,
        device: "tv".into(),
    }
}

#[test]
fn create_makes_an_alive_private_playlist_owned_by_the_caller() {
    let doc = created("p1", vec![entry("a", 1), entry("b", 2), entry("c", 3)]).unwrap();
    assert_eq!(doc.playlist.owner, "alice");
    assert!(doc.playlist.alive);
    assert_eq!(doc.playlist.visibility, Visibility::Private);
    assert_eq!(doc.playlist.name, "Mix");
    assert_eq!(visible_ids(&doc), ["a", "b", "c"]);
}

#[test]
fn create_reports_the_playlist_and_each_entry_as_changed() {
    let mut doc = None;
    let outcome = run_playlist(
        &mut doc,
        &alice(),
        100,
        "playlist.create",
        json!({ "id": "p1", "name": "Mix", "entries": [entry("a", 1)] }),
    );
    let kinds: Vec<EntityKind> = outcome.changed.iter().map(|c| c.kind).collect();
    assert_eq!(kinds, [EntityKind::Playlist, EntityKind::PlaylistEntry]);
}

#[test]
fn create_twice_is_a_noop_and_a_stranger_cannot_take_the_id() {
    let mut doc = created("p1", vec![]);
    let again = run_playlist(
        &mut doc,
        &alice(),
        101,
        "playlist.create",
        json!({ "id": "p1", "name": "Other" }),
    );
    assert_eq!(again.status, Status::Noop);
    assert_eq!(doc.as_ref().unwrap().playlist.name, "Mix");
    let stolen = run_playlist(
        &mut doc,
        &bob(),
        102,
        "playlist.create",
        json!({ "id": "p1", "name": "Mine" }),
    );
    assert_eq!(stolen.status, Status::Invalid(ErrorCode::Forbidden));
}

#[test]
fn rename_is_last_writer_by_stamp_with_ties_to_the_later_apply() {
    let mut doc = created("p1", vec![]);
    let rename = |doc: &mut _, stamp, name: &str| {
        run_playlist(
            doc,
            &alice(),
            stamp,
            "playlist.rename",
            json!({ "id": "p1", "name": name }),
        )
    };
    assert_eq!(rename(&mut doc, 200, "New").status, Status::Applied);
    assert_eq!(rename(&mut doc, 150, "Old").status, Status::Noop);
    assert_eq!(rename(&mut doc, 200, "Tie").status, Status::Applied);
    assert_eq!(doc.unwrap().playlist.name, "Tie");
}

#[test]
fn a_dead_playlist_still_takes_field_writes_and_restore_reveals_them() {
    let mut doc = created("p1", vec![entry("a", 1)]);
    let delete = run_playlist(&mut doc, &alice(), 200, "playlist.delete", id_args("p1"));
    assert_eq!(delete.status, Status::Applied);
    let rename = run_playlist(
        &mut doc,
        &alice(),
        210,
        "playlist.rename",
        json!({ "id": "p1", "name": "Renamed" }),
    );
    assert_eq!(rename.status, Status::Applied);
    let insert = run_playlist(
        &mut doc,
        &alice(),
        220,
        "entry.insert",
        json!({ "id": "b", "playlist": "p1", "ref": song_json(2), "place": place("last", None) }),
    );
    assert_eq!(insert.status, Status::Applied);
    assert!(!doc.as_ref().unwrap().playlist.alive);
    let restore = run_playlist(&mut doc, &alice(), 230, "playlist.restore", id_args("p1"));
    assert_eq!(restore.status, Status::Applied);
    let doc = doc.unwrap();
    assert!(doc.playlist.alive);
    assert_eq!(doc.playlist.name, "Renamed");
    assert_eq!(visible_ids(&doc), ["a", "b"]);
}

#[test]
fn an_older_restore_does_not_undo_a_delete() {
    let mut doc = created("p1", vec![]);
    run_playlist(&mut doc, &alice(), 200, "playlist.delete", id_args("p1"));
    let restore = run_playlist(&mut doc, &alice(), 150, "playlist.restore", id_args("p1"));
    assert_eq!(restore.status, Status::Noop);
    assert!(!doc.unwrap().playlist.alive);
}

#[test]
fn cover_set_and_clear_follow_their_stamps() {
    let mut doc = created("p1", vec![]);
    let blob = "ab".repeat(32);
    let set = run_playlist(
        &mut doc,
        &alice(),
        200,
        "playlist.setCover",
        json!({ "id": "p1", "blob": blob }),
    );
    assert_eq!(set.status, Status::Applied);
    assert_eq!(
        doc.as_ref().unwrap().playlist.cover_blob.as_deref(),
        Some(blob.as_str())
    );
    let stale = run_playlist(
        &mut doc,
        &alice(),
        150,
        "playlist.clearCover",
        id_args("p1"),
    );
    assert_eq!(stale.status, Status::Noop);
    let clear = run_playlist(
        &mut doc,
        &alice(),
        300,
        "playlist.clearCover",
        id_args("p1"),
    );
    assert_eq!(clear.status, Status::Applied);
    assert_eq!(doc.unwrap().playlist.cover_blob, None);
}

#[test]
fn unknown_playlist_and_unknown_entry_are_invalid() {
    let mut none = None;
    let rename = run_playlist(
        &mut none,
        &alice(),
        1,
        "playlist.rename",
        json!({ "id": "nope", "name": "x" }),
    );
    assert_eq!(rename.status, Status::Invalid(ErrorCode::UnknownPlaylist));
    let insert = run_playlist(
        &mut none,
        &alice(),
        1,
        "entry.insert",
        json!({ "id": "e", "playlist": "nope", "ref": song_json(1), "place": place("first", None) }),
    );
    assert_eq!(insert.status, Status::Invalid(ErrorCode::UnknownPlaylist));
    let remove = run_playlist(&mut none, &alice(), 1, "entry.remove", id_args("e"));
    assert_eq!(remove.status, Status::Invalid(ErrorCode::UnknownAnchor));
}

#[test]
fn insert_resolves_first_last_after_and_before() {
    let mut doc = created("p1", vec![entry("a", 1), entry("c", 3)]);
    let mut insert = |id: &str, stamp, where_to| {
        let args = json!({ "id": id, "playlist": "p1", "ref": song_json(0), "place": where_to });
        run_playlist(&mut doc, &alice(), stamp, "entry.insert", args)
    };
    assert_eq!(
        insert("first", 200, place("first", None)).status,
        Status::Applied
    );
    assert_eq!(
        insert("last", 201, place("last", None)).status,
        Status::Applied
    );
    assert_eq!(
        insert("b", 202, place("after", Some("a"))).status,
        Status::Applied
    );
    assert_eq!(
        insert("b2", 203, place("before", Some("c"))).status,
        Status::Applied
    );
    assert_eq!(
        visible_ids(&doc.unwrap()),
        ["first", "a", "b", "b2", "c", "last"]
    );
}

#[test]
fn insert_with_an_unknown_anchor_is_invalid_and_changes_nothing() {
    let mut doc = created("p1", vec![entry("a", 1)]);
    let before = doc.clone();
    let args = json!({ "id": "x", "playlist": "p1", "ref": song_json(0), "place": place("after", Some("ghost")) });
    let outcome = run_playlist(&mut doc, &alice(), 200, "entry.insert", args);
    assert_eq!(outcome.status, Status::Invalid(ErrorCode::UnknownAnchor));
    assert_eq!(doc, before);
}

#[test]
fn a_dead_anchor_still_resolves_by_its_position() {
    let mut doc = created("p1", vec![entry("a", 1), entry("b", 2), entry("c", 3)]);
    run_playlist(&mut doc, &alice(), 200, "entry.remove", id_args("b"));
    let args = json!({ "id": "x", "playlist": "p1", "ref": song_json(0), "place": place("after", Some("b")) });
    let outcome = run_playlist(&mut doc, &alice(), 210, "entry.insert", args);
    assert_eq!(outcome.status, Status::Applied);
    assert_eq!(visible_ids(&doc.unwrap()), ["a", "x", "c"]);
}

#[test]
fn inserting_an_existing_entry_is_a_noop() {
    let mut doc = created("p1", vec![entry("a", 1)]);
    let args =
        json!({ "id": "a", "playlist": "p1", "ref": song_json(5), "place": place("last", None) });
    assert_eq!(
        run_playlist(&mut doc, &alice(), 200, "entry.insert", args).status,
        Status::Noop
    );
}

#[test]
fn insert_many_keeps_the_given_order_at_the_place() {
    let mut doc = created("p1", vec![entry("a", 1), entry("z", 9)]);
    let args = json!({ "playlist": "p1", "entries": [entry("x", 2), entry("y", 3), entry("w", 4)], "place": place("after", Some("a")) });
    let outcome = run_playlist(&mut doc, &alice(), 200, "entry.insertMany", args.clone());
    assert_eq!(outcome.status, Status::Applied);
    assert_eq!(
        visible_ids(doc.as_ref().unwrap()),
        ["a", "x", "y", "w", "z"]
    );
    assert_eq!(
        run_playlist(&mut doc, &alice(), 200, "entry.insertMany", args).status,
        Status::Noop
    );
}

#[test]
fn insert_many_at_first_and_last() {
    let mut doc = created("p1", vec![entry("m", 1)]);
    let front = json!({ "playlist": "p1", "entries": [entry("f1", 2), entry("f2", 3)], "place": place("first", None) });
    let back = json!({ "playlist": "p1", "entries": [entry("l1", 2), entry("l2", 3)], "place": place("last", None) });
    run_playlist(&mut doc, &alice(), 200, "entry.insertMany", front);
    run_playlist(&mut doc, &alice(), 201, "entry.insertMany", back);
    assert_eq!(visible_ids(&doc.unwrap()), ["f1", "f2", "m", "l1", "l2"]);
}

#[test]
fn move_places_an_entry_and_ignores_an_older_stamp() {
    let mut doc = created("p1", vec![entry("a", 1), entry("b", 2), entry("c", 3)]);
    let moved = run_playlist(
        &mut doc,
        &alice(),
        200,
        "entry.move",
        json!({ "id": "a", "place": place("last", None) }),
    );
    assert_eq!(moved.status, Status::Applied);
    assert_eq!(visible_ids(doc.as_ref().unwrap()), ["b", "c", "a"]);
    let stale = run_playlist(
        &mut doc,
        &alice(),
        150,
        "entry.move",
        json!({ "id": "a", "place": place("first", None) }),
    );
    assert_eq!(stale.status, Status::Noop);
    assert_eq!(visible_ids(doc.as_ref().unwrap()), ["b", "c", "a"]);
}

#[test]
fn moving_to_where_it_already_is_a_noop_and_to_an_unknown_anchor_is_invalid() {
    let mut doc = created("p1", vec![entry("a", 1), entry("b", 2)]);
    let same = run_playlist(
        &mut doc,
        &alice(),
        100,
        "entry.move",
        json!({ "id": "b", "place": place("after", Some("a")) }),
    );
    assert_eq!(same.status, Status::Noop);
    let ghost = run_playlist(
        &mut doc,
        &alice(),
        200,
        "entry.move",
        json!({ "id": "b", "place": place("before", Some("ghost")) }),
    );
    assert_eq!(ghost.status, Status::Invalid(ErrorCode::UnknownAnchor));
    let unknown = run_playlist(
        &mut doc,
        &alice(),
        200,
        "entry.move",
        json!({ "id": "ghost", "place": place("first", None) }),
    );
    assert_eq!(unknown.status, Status::Invalid(ErrorCode::UnknownAnchor));
}

#[test]
fn removal_is_sticky_even_against_an_older_stamp() {
    let mut doc = created("p1", vec![entry("a", 1)]);
    let early = run_playlist(&mut doc, &alice(), 50, "entry.remove", id_args("a"));
    assert_eq!(early.status, Status::Applied);
    assert!(!doc.as_ref().unwrap().entry("a").unwrap().alive);
    let again = run_playlist(&mut doc, &alice(), 50, "entry.remove", id_args("a"));
    assert_eq!(again.status, Status::Noop);
    let reinsert =
        json!({ "id": "a", "playlist": "p1", "ref": song_json(1), "place": place("last", None) });
    assert_eq!(
        run_playlist(&mut doc, &alice(), 900, "entry.insert", reinsert).status,
        Status::Noop
    );
    assert!(visible_ids(doc.as_ref().unwrap()).is_empty());
}

#[test]
fn a_dead_entry_still_takes_a_move() {
    let mut doc = created("p1", vec![entry("a", 1), entry("b", 2)]);
    run_playlist(&mut doc, &alice(), 150, "entry.remove", id_args("a"));
    let moved = run_playlist(
        &mut doc,
        &alice(),
        200,
        "entry.move",
        json!({ "id": "a", "place": place("last", None) }),
    );
    assert_eq!(moved.status, Status::Applied);
    let doc = doc.unwrap();
    assert!(doc.ordered().last().unwrap().id == "a");
    assert!(!doc.entry("a").unwrap().alive);
}

#[test]
fn growing_past_the_limit_rewrites_every_position() {
    let mut doc = created("p1", vec![entry("a", 1), entry("b", 2)]).unwrap();
    doc.entries[0].pos = format!("{}V", "0".repeat(63));
    doc.entries[1].pos = format!("{}z", "0".repeat(63));
    let mut doc = Some(doc);
    let mut last = None;
    for step in 0..40 {
        let args = json!({ "id": format!("n{step}"), "playlist": "p1", "ref": song_json(0), "place": place("after", Some("a")) });
        let outcome = run_playlist(&mut doc, &alice(), 200 + step, "entry.insert", args);
        if outcome.changed.len() > 1 {
            last = Some(outcome);
            break;
        }
    }
    let outcome = last.expect("a rewrite happened");
    let doc = doc.unwrap();
    assert_eq!(outcome.changed.len(), doc.entries.len());
    assert!(doc.entries.iter().all(|e| e.pos.len() <= MAX_POS_LEN));
    assert_eq!(doc.visible()[0].id, "a");
    assert_eq!(doc.visible().last().unwrap().id, "b");
}

#[test]
fn a_full_playlist_refuses_more_entries() {
    let mut doc = created("p1", vec![]).unwrap();
    for (index, pos) in rebalance(MAX_ENTRIES).into_iter().enumerate() {
        let id = format!("e{index}");
        doc.entries.push(flaccy_server_core::model::Entry::new(
            &id,
            "p1",
            song(0),
            pos,
            Stamp(1),
        ));
    }
    let mut doc = Some(doc);
    let args = json!({ "id": "extra", "playlist": "p1", "ref": song_json(0), "place": place("last", None) });
    let outcome = run_playlist(&mut doc, &alice(), 200, "entry.insert", args);
    assert_eq!(outcome.status, Status::Invalid(ErrorCode::TooLarge));
    assert_eq!(doc.unwrap().entries.len(), MAX_ENTRIES);
}

#[test]
fn removed_entries_do_not_count_against_the_limit() {
    let mut doc = created("p1", vec![]).unwrap();
    for (index, pos) in rebalance(MAX_ENTRIES).into_iter().enumerate() {
        let id = format!("e{index}");
        doc.entries.push(flaccy_server_core::model::Entry::new(
            &id,
            "p1",
            song(0),
            pos,
            Stamp(1),
        ));
    }
    let mut doc = Some(doc);
    run_playlist(&mut doc, &alice(), 200, "entry.remove", id_args("e0"));
    let args = json!({ "id": "extra", "playlist": "p1", "ref": song_json(0), "place": place("last", None) });
    assert_eq!(
        run_playlist(&mut doc, &alice(), 201, "entry.insert", args).status,
        Status::Applied
    );
}

#[test]
fn guests_and_pending_devices_write_nothing() {
    for role in [Role::Guest, Role::Pending] {
        let mut doc = created("p1", vec![]);
        let caller = with_role(role);
        let rename = run_playlist(
            &mut doc,
            &caller,
            200,
            "playlist.rename",
            json!({ "id": "p1", "name": "x" }),
        );
        assert_eq!(rename.status, Status::Invalid(ErrorCode::Forbidden));
        let mut fresh = None;
        let create = run_playlist(
            &mut fresh,
            &caller,
            200,
            "playlist.create",
            json!({ "id": "q", "name": "x" }),
        );
        assert_eq!(create.status, Status::Invalid(ErrorCode::Forbidden));
        let mut love = None;
        let args = parse(&mutation(
            1,
            "love.set",
            1,
            json!({ "songKey": song(1).song_key, "ref": song_json(1), "loved": true }),
        ))
        .unwrap();
        let Op::Love(args) = args else { panic!() };
        assert_eq!(
            apply_love(&mut love, &args, &caller, Stamp(5)).status,
            Status::Invalid(ErrorCode::Forbidden)
        );
    }
}

#[test]
fn a_member_cannot_touch_another_members_private_playlist() {
    let mut doc = created("p1", vec![entry("a", 1)]);
    let rename = run_playlist(
        &mut doc,
        &bob(),
        200,
        "playlist.rename",
        json!({ "id": "p1", "name": "x" }),
    );
    assert_eq!(rename.status, Status::Invalid(ErrorCode::Forbidden));
    let remove = run_playlist(&mut doc, &bob(), 200, "entry.remove", id_args("a"));
    assert_eq!(remove.status, Status::Invalid(ErrorCode::Forbidden));
}

#[test]
fn a_member_edits_name_and_entries_of_a_household_playlist_only() {
    let mut doc = household_doc();
    let rename = run_playlist(
        &mut doc,
        &bob(),
        200,
        "playlist.rename",
        json!({ "id": "p1", "name": "Ours" }),
    );
    assert_eq!(rename.status, Status::Applied);
    let args =
        json!({ "id": "c", "playlist": "p1", "ref": song_json(3), "place": place("last", None) });
    assert_eq!(
        run_playlist(&mut doc, &bob(), 201, "entry.insert", args).status,
        Status::Applied
    );
    assert_eq!(
        run_playlist(&mut doc, &bob(), 202, "entry.remove", id_args("a")).status,
        Status::Applied
    );
    for (name, args) in [
        ("playlist.delete", id_args("p1")),
        ("playlist.restore", id_args("p1")),
        (
            "playlist.setCover",
            json!({ "id": "p1", "blob": "ab".repeat(32) }),
        ),
        ("playlist.clearCover", id_args("p1")),
        (
            "playlist.setVisibility",
            json!({ "id": "p1", "visibility": "private" }),
        ),
    ] {
        let outcome = run_playlist(&mut doc, &bob(), 300, name, args);
        assert_eq!(
            outcome.status,
            Status::Invalid(ErrorCode::Forbidden),
            "{name}"
        );
    }
}

#[test]
fn an_admin_administers_household_playlists_but_not_private_ones() {
    let admin = Caller {
        user: "root".into(),
        role: Role::Admin,
        device: "pc".into(),
    };
    let mut shared = household_doc();
    let delete = run_playlist(&mut shared, &admin, 300, "playlist.delete", id_args("p1"));
    assert_eq!(delete.status, Status::Applied);
    let mut private = created("p2", vec![]);
    let denied = run_playlist(&mut private, &admin, 300, "playlist.delete", id_args("p2"));
    assert_eq!(denied.status, Status::Invalid(ErrorCode::Forbidden));
}

#[test]
fn love_rating_and_scalar_are_last_writer_and_dead_ones_still_accept_writes() {
    let key = song(1).song_key;
    let Op::Love(on) = parsed(
        "love.set",
        json!({ "songKey": key, "ref": song_json(1), "loved": true }),
    ) else {
        panic!()
    };
    let Op::Love(off) = parsed(
        "love.set",
        json!({ "songKey": key, "ref": song_json(1), "loved": false }),
    ) else {
        panic!()
    };
    let mut slot = None;
    assert_eq!(
        apply_love(&mut slot, &on, &alice(), Stamp(10)).status,
        Status::Applied
    );
    assert_eq!(
        apply_love(&mut slot, &off, &alice(), Stamp(20)).status,
        Status::Applied
    );
    assert_eq!(
        apply_love(&mut slot, &on, &alice(), Stamp(15)).status,
        Status::Noop
    );
    assert!(!slot.as_ref().unwrap().loved);
    assert_eq!(
        apply_love(&mut slot, &on, &alice(), Stamp(30)).status,
        Status::Applied
    );
    assert!(slot.unwrap().loved);

    let Op::Rating(rate) = parsed(
        "rating.set",
        json!({ "songKey": key, "ref": song_json(1), "rating": 4 }),
    ) else {
        panic!()
    };
    let mut rating = None;
    assert_eq!(
        apply_rating(&mut rating, &rate, &alice(), Stamp(10)).status,
        Status::Applied
    );
    assert_eq!(
        apply_rating(&mut rating, &rate, &alice(), Stamp(10)).status,
        Status::Noop
    );
    assert_eq!(rating.unwrap().rating, Some(4));
}

#[test]
fn scalar_clear_is_a_tombstone_that_blocks_an_older_set() {
    let Op::Scalar(set) = parsed(
        "scalar.set",
        json!({ "key": "pref/theme", "value": "dark" }),
    ) else {
        panic!()
    };
    let Op::Scalar(clear) = parsed("scalar.clear", json!({ "key": "pref/theme" })) else {
        panic!()
    };
    let mut slot = None;
    assert_eq!(
        apply_scalar(&mut slot, &clear, &alice(), Stamp(20)).status,
        Status::Applied
    );
    assert_eq!(
        apply_scalar(&mut slot, &set, &alice(), Stamp(10)).status,
        Status::Noop
    );
    assert!(slot.as_ref().unwrap().deleted);
    assert_eq!(
        apply_scalar(&mut slot, &set, &alice(), Stamp(30)).status,
        Status::Applied
    );
    assert!(!slot.unwrap().deleted);
}

#[test]
fn session_save_writes_the_callers_device() {
    let Op::Session(session) = parsed("session.save", json!({ "session": { "queue": [1, 2] } }))
    else {
        panic!()
    };
    let mut slot = None;
    let outcome = apply_session(&mut slot, &session, &alice(), Stamp(5));
    assert_eq!(outcome.status, Status::Applied);
    assert_eq!(outcome.changed[0].id, "phone");
    assert_eq!(slot.unwrap().device, "phone");
}

#[test]
fn scalar_keys_are_validated_by_prefix() {
    let key = song(1).song_key;
    let ok = |name: &str, args| assert!(parse(&mutation(1, name, 1, args)).is_ok(), "{name}");
    ok("scalar.set", json!({ "key": "pref/theme", "value": 1 }));
    ok("scalar.set", json!({ "key": "eq/preset", "value": [1] }));
    ok("scalar.set", json!({ "key": "want/x", "value": null }));
    ok(
        "scalar.set",
        json!({ "key": "lastfm/session", "value": "k" }),
    );
    ok("scalar.set", json!({ "key": "offline/a", "value": true }));
    ok(
        "scalar.set",
        json!({ "key": format!("lyr/{key}"), "value": 1500 }),
    );
    ok(
        "scalar.set",
        json!({ "key": format!("meta/{key}"), "value": { "a": 1 } }),
    );
    let bad = |args, code| {
        let result = parse(&mutation(1, "scalar.set", 1, args));
        assert_eq!(result, Err(ParseError::Invalid(code)));
    };
    bad(json!({ "key": "other/x", "value": 1 }), ErrorCode::BadKey);
    bad(json!({ "key": "nokey", "value": 1 }), ErrorCode::BadKey);
    bad(json!({ "key": "pref/", "value": 1 }), ErrorCode::BadKey);
    bad(json!({ "key": "lyr/short", "value": 1 }), ErrorCode::BadKey);
    bad(
        json!({ "key": format!("lyr/{key}"), "value": "text" }),
        ErrorCode::BadArgs,
    );
    bad(
        json!({ "key": format!("lyr/{key}"), "value": 1.5 }),
        ErrorCode::BadArgs,
    );
    bad(
        json!({ "key": format!("meta/{key}"), "value": [1] }),
        ErrorCode::BadArgs,
    );
    bad(
        json!({ "key": "pref/big", "value": "x".repeat(5_000) }),
        ErrorCode::TooLarge,
    );
    bad(
        json!({ "key": "eq/big", "value": "x".repeat(70_000) }),
        ErrorCode::TooLarge,
    );
}

#[test]
fn parse_reports_unsupported_and_bad_arguments() {
    assert_eq!(
        parse(&mutation(1, "album.merge", 1, json!({}))),
        Err(ParseError::Unsupported)
    );
    assert_eq!(
        parse(&mutation(1, "playlist.rename", 1, json!({ "id": "p" }))),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
    assert_eq!(
        parse(&mutation(
            1,
            "playlist.rename",
            1,
            json!({ "id": "", "name": "x" })
        )),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
    let dup = json!({ "id": "p", "name": "x", "entries": [entry("a", 1), entry("a", 2)] });
    assert_eq!(
        parse(&mutation(1, "playlist.create", 1, dup)),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
    let rating = json!({ "songKey": song(1).song_key, "ref": song_json(1), "rating": 6 });
    assert_eq!(
        parse(&mutation(1, "rating.set", 1, rating)),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
    let mismatch = json!({ "songKey": song(2).song_key, "ref": song_json(1), "loved": true });
    assert_eq!(
        parse(&mutation(1, "love.set", 1, mismatch)),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
    let huge = json!({ "session": { "blob": "x".repeat(70_000) } });
    assert_eq!(
        parse(&mutation(1, "session.save", 1, huge)),
        Err(ParseError::Invalid(ErrorCode::TooLarge))
    );
    assert_eq!(
        parse(&mutation(1, "session.save", 1, json!({ "session": 3 }))),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
    let place_missing =
        json!({ "id": "e", "playlist": "p", "ref": song_json(1), "place": { "kind": "after" } });
    assert_eq!(
        parse(&mutation(1, "entry.insert", 1, place_missing)),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
}

#[test]
fn parse_accepts_listen_record_and_device_rename() {
    let listen = json!({ "listens": [{ "eventId": "ab".repeat(12), "ts": 1790000000, "ref": song_json(1), "playedS": 200, "recorded": true }] });
    assert!(
        matches!(parse(&mutation(1, "listen.record", 1, listen)), Ok(Op::Listen(l)) if l.len() == 1)
    );
    let bad = json!({ "listens": [{ "eventId": "zz", "ts": 1, "ref": song_json(1), "playedS": 1, "recorded": true }] });
    assert_eq!(
        parse(&mutation(1, "listen.record", 1, bad)),
        Err(ParseError::Invalid(ErrorCode::BadArgs))
    );
    assert!(
        matches!(parse(&mutation(1, "device.rename", 1, json!({ "name": "Kitchen" }))), Ok(Op::DeviceRename(n)) if n == "Kitchen")
    );
}
