use super::client::{ClientModel, PullContext};
use super::server::{ServerError, ServerModel};
use super::world::{run_seed, Stats};
use crate::apply::Caller;
use crate::model::EntityKind;
use crate::stamp::Stamp;
use crate::wire::{ErrorCode, Mutation, MutationStatus, PushRequest};
use serde_json::{json, Value};

const NOW: i64 = 1_790_000_000_000;

fn run_range(seeds: std::ops::Range<u64>) -> Stats {
    let mut total = Stats::default();
    for seed in seeds {
        match run_seed(seed) {
            Ok(stats) => total.absorb(&stats),
            Err(message) => panic!("{message}"),
        }
    }
    total
}

fn caller() -> Caller {
    Caller::member("user", "phone")
}

fn mutation(id: i64, name: &str, args: Value) -> Mutation {
    Mutation {
        id,
        name: name.to_owned(),
        stamp: Stamp::from_wall_ms(NOW - 1_000 + id),
        args,
    }
}

fn request(instance: &str, mutations: Vec<Mutation>) -> PushRequest {
    PushRequest {
        device: "phone".to_owned(),
        instance: instance.to_owned(),
        mutations,
    }
}

fn rename(id: i64, name: &str) -> Mutation {
    mutation(
        id,
        "scalar.set",
        json!({ "key": "pref/name", "value": name }),
    )
}

#[test]
fn a_retry_answers_the_stored_status_and_a_changed_retry_conflicts() {
    let mut server = ServerModel::new("inc".to_owned());
    let first = request("i1", vec![rename(1, "a"), rename(2, "b")]);
    let answered = server.push(&caller(), &first, NOW).unwrap();
    assert!(answered
        .results
        .iter()
        .all(|r| r.status == MutationStatus::Applied));
    let again = server.push(&caller(), &first, NOW + 5).unwrap();
    assert_eq!(again.results, answered.results);
    assert_eq!(server.head(), 2);
    let changed = request("i1", vec![rename(2, "different")]);
    assert_eq!(
        server.push(&caller(), &changed, NOW),
        Err(ServerError::InstanceConflict)
    );
}

#[test]
fn a_gap_applies_nothing_and_a_new_instance_starts_at_one() {
    let mut server = ServerModel::new("inc".to_owned());
    server
        .push(&caller(), &request("i1", vec![rename(1, "a")]), NOW)
        .unwrap();
    let skipping = request("i1", vec![rename(2, "b"), rename(4, "d")]);
    assert_eq!(
        server.push(&caller(), &skipping, NOW),
        Err(ServerError::MutationGap { have: 1 })
    );
    assert_eq!(server.head(), 1);
    assert_eq!(
        server.push(&caller(), &request("i2", vec![rename(2, "x")]), NOW),
        Err(ServerError::MutationGap { have: 0 })
    );
    assert!(server
        .push(&caller(), &request("i2", vec![rename(1, "x")]), NOW)
        .is_ok());
}

#[test]
fn every_mutation_consumes_its_id_whatever_the_verdict() {
    let mut server = ServerModel::new("inc".to_owned());
    let mixed = request(
        "i1",
        vec![
            mutation(1, "no.such", json!({})),
            mutation(2, "scalar.set", json!({ "key": "bogus/x", "value": 1 })),
            rename(3, "a"),
            Mutation {
                id: 4,
                ..rename(3, "a")
            },
        ],
    );
    let answer = server.push(&caller(), &mixed, NOW).unwrap();
    let statuses: Vec<_> = answer.results.iter().map(|r| (r.status, r.code)).collect();
    assert_eq!(
        statuses,
        [
            (MutationStatus::Unsupported, None),
            (MutationStatus::Invalid, Some(ErrorCode::BadKey)),
            (MutationStatus::Applied, None),
            (MutationStatus::Noop, None),
        ]
    );
    assert!(server.check_dense_ids().is_ok());
}

#[test]
fn pull_pages_in_sequence_order_and_reports_the_instance_progress() {
    let mut server = ServerModel::new("inc".to_owned());
    let writes = (1..=5)
        .map(|id| {
            mutation(
                id,
                "scalar.set",
                json!({ "key": format!("pref/k{id}"), "value": id }),
            )
        })
        .collect();
    server.push(&caller(), &request("i1", writes), NOW).unwrap();
    let page = server.pull("phone", "i1", 0, 2, NOW).unwrap();
    assert_eq!((page.head, page.more, page.last_mutation_id), (5, true, 5));
    assert_eq!(
        page.changes.iter().map(|c| c.seq).collect::<Vec<_>>(),
        [1, 2]
    );
    let rest = server.pull("phone", "i1", 2, 10, NOW).unwrap();
    assert!(!rest.more);
    assert_eq!(
        rest.changes.iter().map(|c| c.seq).collect::<Vec<_>>(),
        [3, 4, 5]
    );
    assert_eq!(
        server
            .pull("phone", "other", 0, 1, NOW)
            .unwrap()
            .last_mutation_id,
        0
    );
    assert!(server
        .pull("phone", "i1", 5, 10, NOW)
        .unwrap()
        .changes
        .is_empty());
}

#[test]
fn a_changed_entity_moves_to_the_front_of_the_log_and_a_cookie_ahead_is_refused() {
    let mut server = ServerModel::new("inc".to_owned());
    server
        .push(
            &caller(),
            &request(
                "i1",
                vec![
                    rename(1, "a"),
                    mutation(2, "scalar.set", json!({ "key": "pref/other", "value": 1 })),
                    rename(3, "b"),
                ],
            ),
            NOW,
        )
        .unwrap();
    let all = server.pull("phone", "i1", 0, 10, NOW).unwrap();
    let ids: Vec<_> = all
        .changes
        .iter()
        .map(|c| (c.kind, c.id.as_str()))
        .collect();
    assert_eq!(
        ids,
        [
            (EntityKind::Scalar, "pref/other"),
            (EntityKind::Scalar, "pref/name")
        ]
    );
    assert_eq!(
        server.pull("phone", "i1", 4, 10, NOW),
        Err(ServerError::CookieAhead)
    );
}

#[test]
fn a_clock_far_behind_the_server_refuses_writes() {
    let mut server = ServerModel::new("inc".to_owned());
    server
        .push(&caller(), &request("i1", vec![rename(1, "a")]), NOW)
        .unwrap();
    let late = request("i1", vec![rename(2, "b")]);
    assert_eq!(
        server.push(&caller(), &late, NOW - 3_700_000),
        Err(ServerError::ClockBehind)
    );
}

#[test]
fn restore_rolls_state_back_under_a_new_incarnation() {
    let mut server = ServerModel::new("inc".to_owned());
    server
        .push(&caller(), &request("i1", vec![rename(1, "a")]), NOW)
        .unwrap();
    let backup = server.snapshot();
    server
        .push(&caller(), &request("i1", vec![rename(2, "b")]), NOW)
        .unwrap();
    server.restore(backup, "new".to_owned());
    assert_eq!(server.head(), 1);
    assert_eq!(server.incarnation, "new");
    assert_eq!(
        server
            .pull("phone", "i1", 0, 10, NOW)
            .unwrap()
            .last_mutation_id,
        1
    );
}

fn client() -> ClientModel {
    ClientModel::new("phone", "user", "i1".to_owned(), "inc".to_owned())
}

fn context(client: &ClientModel) -> PullContext {
    PullContext {
        instance: client.durable.instance.clone(),
        since: client.durable.cursor,
    }
}

#[test]
fn a_pending_write_is_visible_at_once_and_retired_only_by_a_pull_after_its_ack() {
    let mut server = ServerModel::new("inc".to_owned());
    let mut client = client();
    client.record("scalar.set", json!({ "key": "pref/a", "value": 1 }), NOW);
    assert!(client.visible().scalars.contains_key("pref/a"));
    let answer = server
        .push(&caller(), &client.push_request().unwrap(), NOW)
        .unwrap();
    let pull = server.pull("phone", "i1", 0, 10, NOW).unwrap();
    client.on_pull_response(&context(&client), &pull, NOW, "spare".to_owned());
    assert_eq!(client.durable.pending.len(), 1);
    client.on_push_response("i1", &answer, NOW);
    assert!(client.push_request().is_none());
    let pull = server
        .pull("phone", "i1", client.durable.cursor, 10, NOW)
        .unwrap();
    client.on_pull_response(&context(&client), &pull, NOW, "spare".to_owned());
    assert!(client.durable.pending.is_empty());
    assert!(client.durable.base.scalars.contains_key("pref/a"));
}

#[test]
fn a_refused_write_is_marked_failed_and_disappears_from_the_visible_state() {
    let mut server = ServerModel::new("inc".to_owned());
    let mut client = client();
    client.record(
        "playlist.rename",
        json!({ "id": "ghost", "name": "x" }),
        NOW,
    );
    client.record("scalar.set", json!({ "key": "pref/a", "value": 1 }), NOW);
    let answer = server
        .push(&caller(), &client.push_request().unwrap(), NOW)
        .unwrap();
    client.on_push_response("i1", &answer, NOW);
    assert!(client.durable.pending[0].failed);
    assert!(!client.durable.pending[1].failed);
    assert!(client.visible().playlists.is_empty());
}

#[test]
fn a_stale_pull_answer_is_ignored() {
    let mut server = ServerModel::new("inc".to_owned());
    let mut client = client();
    server
        .push(&caller(), &request("other", vec![rename(1, "a")]), NOW)
        .unwrap();
    let stale = PullContext {
        instance: "i1".to_owned(),
        since: 99,
    };
    let pull = server.pull("phone", "i1", 0, 10, NOW).unwrap();
    client.on_pull_response(&stale, &pull, NOW, "spare".to_owned());
    assert_eq!(client.durable.cursor, 0);
    assert!(client.durable.base.scalars.is_empty());
}

#[test]
fn a_new_incarnation_reseeds_the_server_and_renumbers_the_pending_writes() {
    let mut server = ServerModel::new("inc".to_owned());
    let mut client = client();
    client.record("scalar.set", json!({ "key": "pref/a", "value": 1 }), NOW);
    let answer = server
        .push(&caller(), &client.push_request().unwrap(), NOW)
        .unwrap();
    client.on_push_response("i1", &answer, NOW);
    let pull = server.pull("phone", "i1", 0, 10, NOW).unwrap();
    client.on_pull_response(&context(&client), &pull, NOW, "spare".to_owned());
    client.record("scalar.set", json!({ "key": "pref/b", "value": 2 }), NOW);

    let mut restored = ServerModel::new("replacement".to_owned());
    let pull = restored.pull("phone", "i1", 0, 10, NOW).unwrap();
    client.on_pull_response(&context(&client), &pull, NOW, "i2".to_owned());
    assert_eq!(client.durable.instance, "i2");
    let names: Vec<_> = client
        .durable
        .pending
        .iter()
        .map(|p| (p.mutation.id, p.mutation.name.as_str()))
        .collect();
    assert_eq!(names, [(1, "state.reseed"), (2, "scalar.set")]);
    let answer = restored
        .push(&caller(), &client.push_request().unwrap(), NOW)
        .unwrap();
    assert!(answer
        .results
        .iter()
        .all(|r| r.status == MutationStatus::Applied));
    assert!(
        restored.store.scalars.contains_key("pref/a")
            && restored.store.scalars.contains_key("pref/b")
    );
}

#[test]
fn an_instance_conflict_moves_the_pending_writes_to_a_new_instance() {
    let mut client = client();
    client.record("scalar.set", json!({ "key": "pref/a", "value": 1 }), NOW);
    client.record("scalar.set", json!({ "key": "pref/b", "value": 2 }), NOW);
    client.on_push_error("i1", &ServerError::InstanceConflict, "i2".to_owned());
    assert_eq!(client.durable.instance, "i2");
    let ids: Vec<_> = client
        .durable
        .pending
        .iter()
        .map(|p| p.mutation.id)
        .collect();
    assert_eq!(ids, [1, 2]);
    assert_eq!(client.push_request().unwrap().instance, "i2");
}

#[test]
fn sim_quick() {
    let total = run_range(0..300);
    assert!(total.restores > 0, "{total:?}");
    assert!(total.resets > 0, "{total:?}");
    assert!(
        total.lost_messages > 0 && total.duplicated_messages > 0,
        "{total:?}"
    );
    assert!(
        total.reinstalls > 0 && total.stale_restores > 0,
        "{total:?}"
    );
    assert!(total.rotations > 0, "{total:?}");
}

#[test]
#[ignore]
fn sim_long() {
    let seeds = std::env::var("SIM_SEEDS")
        .ok()
        .and_then(|text| text.parse::<u64>().ok())
        .unwrap_or(20_000);
    let total = run_range(1_000_000..1_000_000 + seeds);
    assert!(total.rebalances > 0, "{total:?}");
    assert!(total.rotations > 0, "{total:?}");
}
