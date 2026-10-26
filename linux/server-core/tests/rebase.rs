mod common;

use common::*;
use flaccy_server_core::model::{Love, Scalar, SessionDoc};
use flaccy_server_core::rebase::{
    fold_love, fold_playlist, fold_rating, fold_scalar, fold_session, PendingMutation,
};
use flaccy_server_core::stamp::Stamp;
use serde_json::json;

fn pending(mutation: flaccy_server_core::wire::Mutation, failed: bool) -> PendingMutation {
    PendingMutation { mutation, failed }
}

#[test]
fn a_pending_insert_shows_at_its_place_before_the_server_confirms() {
    let base = created("p1", vec![entry("a", 1), entry("c", 3)]);
    let args = json!({ "id": "b", "playlist": "p1", "ref": song_json(2), "place": place("after", Some("a")) });
    let pending = [pending(mutation(1, "entry.insert", 500, args), false)];
    let folded = fold_playlist("p1", base.as_ref(), &alice(), &pending).unwrap();
    assert_eq!(visible_ids(&folded), ["a", "b", "c"]);
}

#[test]
fn pending_mutations_apply_in_order_and_failed_ones_are_skipped() {
    let base = created("p1", vec![entry("a", 1), entry("b", 2)]);
    let pending = [
        pending(mutation(1, "entry.remove", 500, json!({ "id": "a" })), true),
        pending(
            mutation(
                2,
                "playlist.rename",
                510,
                json!({ "id": "p1", "name": "One" }),
            ),
            false,
        ),
        pending(
            mutation(
                3,
                "playlist.rename",
                520,
                json!({ "id": "p1", "name": "Two" }),
            ),
            false,
        ),
        pending(
            mutation(4, "entry.remove", 530, json!({ "id": "b" })),
            false,
        ),
    ];
    let folded = fold_playlist("p1", base.as_ref(), &alice(), &pending).unwrap();
    assert_eq!(folded.playlist.name, "Two");
    assert_eq!(visible_ids(&folded), ["a"]);
}

#[test]
fn mutations_for_other_playlists_are_ignored() {
    let base = created("p1", vec![entry("a", 1)]);
    let pending = [pending(
        mutation(
            1,
            "playlist.rename",
            500,
            json!({ "id": "other", "name": "x" }),
        ),
        false,
    )];
    let folded = fold_playlist("p1", base.as_ref(), &alice(), &pending);
    assert_eq!(folded, base);
}

#[test]
fn a_pending_create_is_visible_before_any_pull() {
    let create = mutation(
        1,
        "playlist.create",
        500,
        json!({ "id": "p9", "name": "New", "entries": [entry("a", 1)] }),
    );
    let folded = fold_playlist("p9", None, &alice(), &[pending(create, false)]).unwrap();
    assert_eq!(folded.playlist.name, "New");
    assert_eq!(visible_ids(&folded), ["a"]);
}

#[test]
fn a_local_write_older_than_the_base_loses_just_as_on_the_server() {
    let base = created("p1", vec![]);
    let pending = [pending(
        mutation(
            1,
            "playlist.rename",
            50,
            json!({ "id": "p1", "name": "Old" }),
        ),
        false,
    )];
    let folded = fold_playlist("p1", base.as_ref(), &alice(), &pending).unwrap();
    assert_eq!(folded.playlist.name, "Mix");
}

#[test]
fn love_rating_scalar_and_session_fold_over_their_base() {
    let key = song(1).song_key;
    let love = fold_love(
        &key,
        None,
        &alice(),
        &[pending(
            mutation(
                1,
                "love.set",
                10,
                json!({ "songKey": key, "ref": song_json(1), "loved": true }),
            ),
            false,
        )],
    );
    assert!(love.unwrap().loved);

    let base_love = Love {
        song_key: key.clone(),
        song: song(1),
        loved: true,
        stamp: Stamp(100),
    };
    let kept = fold_love(
        &key,
        Some(&base_love),
        &alice(),
        &[pending(
            mutation(
                1,
                "love.set",
                10,
                json!({ "songKey": key, "ref": song_json(1), "loved": false }),
            ),
            false,
        )],
    );
    assert_eq!(kept, Some(base_love));

    let rating = fold_rating(
        &key,
        None,
        &alice(),
        &[pending(
            mutation(
                1,
                "rating.set",
                10,
                json!({ "songKey": key, "ref": song_json(1), "rating": 5 }),
            ),
            false,
        )],
    );
    assert_eq!(rating.unwrap().rating, Some(5));

    let base_scalar = Scalar {
        key: "pref/a".into(),
        value: json!(1),
        deleted: false,
        stamp: Stamp(5),
    };
    let cleared = fold_scalar(
        "pref/a",
        Some(&base_scalar),
        &alice(),
        &[pending(
            mutation(1, "scalar.clear", 10, json!({ "key": "pref/a" })),
            false,
        )],
    );
    assert!(cleared.unwrap().deleted);

    let own = fold_session(
        "phone",
        None,
        &alice(),
        &[pending(
            mutation(1, "session.save", 10, json!({ "session": { "q": 1 } })),
            false,
        )],
    );
    assert_eq!(own.unwrap().session, json!({ "q": 1 }));
    let other: Option<SessionDoc> = fold_session(
        "tv",
        None,
        &alice(),
        &[pending(
            mutation(1, "session.save", 10, json!({ "session": { "q": 1 } })),
            false,
        )],
    );
    assert_eq!(other, None);
}

#[test]
fn failed_single_entity_mutations_are_skipped() {
    let key = song(1).song_key;
    let love = fold_love(
        &key,
        None,
        &alice(),
        &[pending(
            mutation(
                1,
                "love.set",
                10,
                json!({ "songKey": key, "ref": song_json(1), "loved": true }),
            ),
            true,
        )],
    );
    assert_eq!(love, None);
}
