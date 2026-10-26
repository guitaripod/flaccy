mod common;

use common::*;
use flaccy_server_core::apply::{apply_love, apply_playlist, apply_rating, apply_scalar, Status};
use flaccy_server_core::model::{Love, PlaylistDoc, Rating, Scalar};
use flaccy_server_core::mutation::{parse, Op};
use flaccy_server_core::rebase::{fold_playlist, PendingMutation};
use flaccy_server_core::stamp::Stamp;
use proptest::prelude::*;
use serde_json::json;
use std::collections::BTreeMap;

type Choice = (u8, u16, u16, bool);

fn choices() -> impl Strategy<Value = Vec<Choice>> {
    proptest::collection::vec(
        (any::<u8>(), any::<u16>(), any::<u16>(), any::<bool>()),
        1..40,
    )
}

fn apply_script(doc: &mut Option<PlaylistDoc>, script: &[flaccy_server_core::wire::Mutation]) {
    for mutation in script {
        if let Ok(Op::Playlist(op)) = parse(mutation) {
            apply_playlist(doc, &op, &alice(), mutation.stamp);
        }
    }
}

proptest! {
    #[test]
    fn a_playlist_mutation_applied_twice_is_a_noop_the_second_time(choices in choices()) {
        let mut doc = created("p1", vec![entry("seed", 1)]);
        for mutation in playlist_script(&choices, "p1", 1_000) {
            let Ok(Op::Playlist(op)) = parse(&mutation) else { continue };
            let first = apply_playlist(&mut doc, &op, &alice(), mutation.stamp);
            let after_first = doc.clone();
            let second = apply_playlist(&mut doc, &op, &alice(), mutation.stamp);
            match first.status {
                Status::Invalid(code) => prop_assert_eq!(second.status, Status::Invalid(code)),
                _ => prop_assert_eq!(second.status, Status::Noop),
            }
            prop_assert_eq!(&doc, &after_first);
        }
    }

    #[test]
    fn invalid_playlist_mutations_leave_the_document_untouched(choices in choices()) {
        let mut doc = created("p1", vec![entry("seed", 1)]);
        for mutation in playlist_script(&choices, "p1", 1_000) {
            let Ok(Op::Playlist(op)) = parse(&mutation) else { continue };
            let before = doc.clone();
            let outcome = apply_playlist(&mut doc, &op, &alice(), mutation.stamp);
            if matches!(outcome.status, Status::Invalid(_)) {
                prop_assert_eq!(&doc, &before);
            }
        }
    }

    #[test]
    fn folding_pending_on_a_base_equals_the_server_applying_them(
        choices in choices(),
        failed in proptest::collection::vec(any::<bool>(), 40),
    ) {
        let base = created("p1", vec![entry("seed", 1), entry("seed2", 2)]);
        let script = playlist_script(&choices, "p1", 1_000);
        let pending: Vec<PendingMutation> = script
            .iter()
            .zip(failed.iter())
            .map(|(mutation, &failed)| PendingMutation { mutation: mutation.clone(), failed })
            .collect();
        let live: Vec<_> = pending.iter().filter(|p| !p.failed).map(|p| p.mutation.clone()).collect();
        let mut server = base.clone();
        apply_script(&mut server, &live);
        let folded = fold_playlist("p1", base.as_ref(), &alice(), &pending);
        prop_assert_eq!(folded, server);
    }

    #[test]
    fn folding_from_nothing_includes_the_pending_create(choices in choices()) {
        let create = mutation(0, "playlist.create", 900, json!({ "id": "p1", "name": "Mix", "entries": [entry("seed", 1)] }));
        let mut script = vec![create];
        script.extend(playlist_script(&choices, "p1", 1_000));
        let pending: Vec<PendingMutation> = script.iter().map(|m| PendingMutation { mutation: m.clone(), failed: false }).collect();
        let mut server = None;
        apply_script(&mut server, &script);
        prop_assert!(server.is_some());
        prop_assert_eq!(fold_playlist("p1", None, &alice(), &pending), server);
    }

    #[test]
    fn stamped_single_entity_writes_converge_in_any_order(
        writes in proptest::collection::vec((0u8..3, 0usize..3, 0u8..6, any::<bool>()), 1..40),
        keys in proptest::collection::vec(any::<u32>(), 40),
    ) {
        let mutations: Vec<_> = writes
            .iter()
            .enumerate()
            .map(|(index, &(kind, song_index, value, flag))| single_write(index, kind, song_index, value, flag))
            .collect();
        let mut shuffled: Vec<usize> = (0..mutations.len()).collect();
        shuffled.sort_by_key(|&index| keys[index]);
        let in_stamp_order = singles_after(&mutations, &(0..mutations.len()).collect::<Vec<_>>());
        let reversed: Vec<usize> = (0..mutations.len()).rev().collect();
        prop_assert_eq!(&in_stamp_order, &singles_after(&mutations, &shuffled));
        prop_assert_eq!(&in_stamp_order, &singles_after(&mutations, &reversed));
    }
}

#[derive(Debug, PartialEq, Default)]
struct Singles {
    loves: BTreeMap<String, Love>,
    ratings: BTreeMap<String, Rating>,
    scalars: BTreeMap<String, Scalar>,
}

fn single_write(
    index: usize,
    kind: u8,
    song_index: usize,
    value: u8,
    flag: bool,
) -> flaccy_server_core::wire::Mutation {
    let stamp = (index as i64 + 1) * 10;
    let key = song(song_index).song_key;
    let (name, args) = match (kind, flag) {
        (0, _) => (
            "love.set",
            json!({ "songKey": key, "ref": song_json(song_index), "loved": value.is_multiple_of(2) }),
        ),
        (1, _) => (
            "rating.set",
            json!({ "songKey": key, "ref": song_json(song_index), "rating": if value == 0 { json!(null) } else { json!(value) } }),
        ),
        (_, true) => (
            "scalar.clear",
            json!({ "key": format!("pref/k{song_index}") }),
        ),
        (_, false) => (
            "scalar.set",
            json!({ "key": format!("pref/k{song_index}"), "value": value }),
        ),
    };
    mutation(index as i64 + 1, name, stamp, args)
}

fn singles_after(mutations: &[flaccy_server_core::wire::Mutation], order: &[usize]) -> Singles {
    let mut state = Singles::default();
    for &index in order {
        let mutation = &mutations[index];
        let stamp = Stamp(mutation.stamp.0);
        match parse(mutation).unwrap() {
            Op::Love(args) => {
                let mut slot = state.loves.remove(&args.song_key);
                apply_love(&mut slot, &args, &alice(), stamp);
                state.loves.extend(slot.map(|v| (args.song_key.clone(), v)));
            }
            Op::Rating(args) => {
                let mut slot = state.ratings.remove(&args.song_key);
                apply_rating(&mut slot, &args, &alice(), stamp);
                state
                    .ratings
                    .extend(slot.map(|v| (args.song_key.clone(), v)));
            }
            Op::Scalar(op) => {
                let mut slot = state.scalars.remove(op.key());
                apply_scalar(&mut slot, &op, &alice(), stamp);
                state.scalars.extend(slot.map(|v| (op.key().to_owned(), v)));
            }
            other => panic!("unexpected {other:?}"),
        }
    }
    state
}
