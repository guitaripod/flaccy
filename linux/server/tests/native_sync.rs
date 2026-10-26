//! The sync routes over real HTTP: push, pull, scopes, the listen ledger and the guards around them.

mod common;

use std::time::Duration;

use flaccy_server::security::Role;
use serde_json::{json, Value};

use common::http::{Device, Harness};
use common::song;

fn statuses(reply: &common::http::Reply) -> Vec<String> {
    reply.json()["results"]
        .as_array()
        .unwrap()
        .iter()
        .map(|result| match result["code"].as_str() {
            Some(code) => format!("{}:{code}", result["status"].as_str().unwrap()),
            None => result["status"].as_str().unwrap().to_owned(),
        })
        .collect()
}

fn kinds(pull: &Value) -> Vec<String> {
    pull["changes"].as_array().unwrap().iter().map(|change| change["kind"].as_str().unwrap().to_owned()).collect()
}

fn change<'a>(pull: &'a Value, kind: &str, id: &str) -> &'a Value {
    pull["changes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|change| change["kind"] == kind && change["id"] == id)
        .unwrap_or_else(|| panic!("no {kind} {id} in {pull}"))
}

fn love(index: usize, loved: bool) -> Value {
    json!({ "songKey": song(index)["songKey"], "ref": song(index), "loved": loved })
}

#[tokio::test(flavor = "multi_thread")]
async fn a_playlist_a_love_and_a_scalar_push_and_pull_back() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let push = harness
        .push(
            &alice,
            1,
            vec![
                ("playlist.create", json!({ "id": "mix", "name": "Mix", "entries": [{ "id": "e1", "ref": song(0) }] })),
                ("entry.insert", json!({ "id": "e2", "playlist": "mix", "ref": song(1), "place": { "kind": "after", "id": "e1" } })),
                ("love.set", love(2, true)),
                ("scalar.set", json!({ "key": "pref/theme", "value": "dark" })),
            ],
        )
        .await;
    assert_eq!(push.status, 200, "{}", String::from_utf8_lossy(&push.body));
    assert_eq!(statuses(&push), ["applied", "applied", "applied", "applied"]);
    assert!(push.json()["serverTimeMs"].is_i64());

    let pull = harness.pull(&alice, 0).await.json();
    assert_eq!(pull["lastMutationId"], 4);
    assert_eq!(pull["more"], false);
    assert_eq!(pull["head"], 5);
    assert_eq!(kinds(&pull), ["playlist", "playlist_entry", "playlist_entry", "love", "scalar"]);
    assert_eq!(change(&pull, "playlist", "mix")["value"]["name"], "Mix");
    assert_eq!(change(&pull, "playlist", "mix")["value"]["owner"], alice.user.as_str());
    assert!(change(&pull, "playlist_entry", "e1")["value"]["pos"].as_str().unwrap() < change(&pull, "playlist_entry", "e2")["value"]["pos"].as_str().unwrap());
    assert_eq!(change(&pull, "scalar", "pref/theme")["value"]["value"], "dark");
    assert!(harness.pull(&alice, 5).await.json()["changes"].as_array().unwrap().is_empty());

    harness.push(&alice, 5, vec![("love.set", love(2, false)), ("scalar.clear", json!({ "key": "pref/theme" })), ("entry.remove", json!({ "id": "e1" }))]).await;
    let later = harness.pull(&alice, 5).await.json();
    assert_eq!(later["changes"].as_array().unwrap().len(), 3);
    for (kind, id) in [("love", song(2)["songKey"].as_str().unwrap().to_owned()), ("scalar", "pref/theme".to_owned()), ("playlist_entry", "e1".to_owned())] {
        assert_eq!(change(&later, kind, &id)["deleted"], true, "{kind}");
    }
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn retries_answer_from_the_record_and_gaps_and_conflicts_apply_nothing() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let create = vec![("playlist.create", json!({ "id": "mix", "name": "Mix" })), ("love.set", love(0, true))];
    let first = harness.push(&alice, 1, create.clone()).await;
    let head = harness.pull(&alice, 0).await.json()["head"].clone();
    let retry = harness.push(&alice, 1, create).await;
    assert_eq!(retry.json()["results"], first.json()["results"]);
    assert_eq!(harness.pull(&alice, 0).await.json()["head"], head, "a retry changes nothing");

    let gap = harness.push(&alice, 4, vec![("love.set", love(1, true))]).await;
    assert_eq!((gap.status, gap.code()), (409, "mutation_gap".to_owned()));
    assert_eq!(gap.json()["error"]["have"], 2);

    let conflict = harness.push(&alice, 1, vec![("playlist.create", json!({ "id": "other", "name": "Other" })), ("love.set", love(0, true))]).await;
    assert_eq!((conflict.status, conflict.code()), (409, "instance_conflict".to_owned()));
    let mixed = harness.push(&alice, 2, vec![("love.set", love(0, true)), ("love.set", love(5, true))]).await;
    assert_eq!(mixed.status, 200);
    assert_eq!(statuses(&mixed), ["applied", "applied"]);
    let after = harness.push(&alice, 3, vec![("love.set", love(7, true))]).await;
    assert_eq!(after.code(), "instance_conflict", "id 3 was used by a different love");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_new_instance_starts_again_at_one() {
    let harness = Harness::start().await;
    let mut alice = harness.enroll("alice", Role::Member).await;
    assert_eq!(harness.push(&alice, 1, vec![("love.set", love(0, true))]).await.status, 200);
    alice.instance = "another-install".to_owned();
    assert_eq!(harness.push(&alice, 1, vec![("love.set", love(1, true))]).await.status, 200);
    assert_eq!(harness.pull(&alice, 0).await.json()["lastMutationId"], 1);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_incarnation_header_and_a_cursor_ahead_of_the_server_are_conflicts() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let current = harness.state.0.sync.incarnation();
    let stale = [("Flaccy-Incarnation", "00000000-0000-7000-8000-000000000000")];
    let body = json!({ "device": alice.id, "instance": alice.instance, "mutations": [] });
    let push = harness.post_json("/flaccy/v1/sync/push", Some(&alice.token), &stale, &body).await;
    assert_eq!((push.status, push.code()), (409, "incarnation_changed".to_owned()));
    assert_eq!(push.json()["error"]["incarnation"], current.as_str());
    let pull = harness.call("GET", "/flaccy/v1/sync/pull", Some(&alice.token), &stale, &[]).await;
    assert_eq!((pull.status, pull.code()), (409, "incarnation_changed".to_owned()));
    let matching = [("Flaccy-Incarnation", current.as_str())];
    assert_eq!(harness.post_json("/flaccy/v1/sync/push", Some(&alice.token), &matching, &body).await.status, 200);
    assert_eq!(harness.call("GET", "/flaccy/v1/sync/pull", Some(&alice.token), &matching, &[]).await.status, 200);
    let ahead = harness.pull(&alice, 999_999).await;
    assert_eq!((ahead.status, ahead.code()), (409, "cookie_ahead".to_owned()));
    assert_eq!(ahead.json()["error"]["incarnation"], current.as_str());
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn push_checks_the_device_and_the_batch_size() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let impostor = Device { id: bob.id.clone(), token: alice.token.clone(), user: alice.user.clone(), instance: "x".to_owned() };
    let mismatch = harness.push(&impostor, 1, vec![("love.set", love(0, true))]).await;
    assert_eq!((mismatch.status, mismatch.code()), (403, "forbidden".to_owned()));
    let many: Vec<(&str, Value)> = (0..501).map(|index| ("scalar.set", json!({ "key": format!("pref/k{index}"), "value": 1 }))).collect();
    let too_many = harness.push(&alice, 1, many).await;
    assert_eq!((too_many.status, too_many.code()), (413, "too_large".to_owned()));
    let empty_instance = Device { id: alice.id.clone(), token: alice.token.clone(), user: alice.user.clone(), instance: String::new() };
    assert_eq!(harness.push(&empty_instance, 1, vec![]).await.status, 400);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn private_playlists_stay_private_and_household_ones_are_shared() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    harness
        .push(&alice, 1, vec![("playlist.create", json!({ "id": "shared", "name": "Road trip", "entries": [{ "id": "e1", "ref": song(0) }, { "id": "e2", "ref": song(1) }] }))])
        .await;
    assert!(harness.pull(&bob, 0).await.json()["changes"].as_array().unwrap().is_empty());
    let private_write = harness.push(&bob, 1, vec![("entry.insert", json!({ "id": "x", "playlist": "shared", "ref": song(2), "place": { "kind": "last" } }))]).await;
    assert_eq!(statuses(&private_write), ["invalid:forbidden"]);

    harness.push(&alice, 2, vec![("playlist.setVisibility", json!({ "id": "shared", "visibility": "household" }))]).await;
    let seen = harness.pull(&bob, 0).await.json();
    assert_eq!(kinds(&seen), ["playlist", "playlist_entry", "playlist_entry"]);
    assert_eq!(change(&seen, "playlist", "shared")["value"]["name"], "Road trip");
    let bob_head = seen["head"].as_i64().unwrap();

    let edits = harness
        .push(
            &bob,
            2,
            vec![
                ("playlist.rename", json!({ "id": "shared", "name": "Bob's road trip" })),
                ("entry.insert", json!({ "id": "e3", "playlist": "shared", "ref": song(2), "place": { "kind": "after", "id": "e2" } })),
                ("playlist.delete", json!({ "id": "shared" })),
                ("playlist.setVisibility", json!({ "id": "shared", "visibility": "private" })),
            ],
        )
        .await;
    assert_eq!(statuses(&edits), ["applied", "applied", "invalid:forbidden", "invalid:forbidden"]);
    let alice_view = harness.pull(&alice, 0).await.json();
    assert_eq!(change(&alice_view, "playlist", "shared")["value"]["name"], "Bob's road trip");
    assert_eq!(change(&alice_view, "playlist_entry", "e3")["deleted"], false);

    harness.push(&alice, 3, vec![("playlist.setVisibility", json!({ "id": "shared", "visibility": "private" }))]).await;
    let retracted = harness.pull(&bob, bob_head).await.json();
    let playlist = change(&retracted, "playlist", "shared");
    assert_eq!(playlist["deleted"], true);
    assert_eq!(playlist["value"]["name"], "");
    let entry = change(&retracted, "playlist_entry", "e1");
    assert_eq!(entry["deleted"], true);
    assert_ne!(entry["value"]["ref"]["songKey"], song(0)["songKey"]);
    let entity = harness.get("/flaccy/v1/sync/entity?kind=playlist&id=shared", Some(&bob.token)).await;
    assert_eq!(entity.status, 404);
    let own = harness.get("/flaccy/v1/sync/entity?kind=playlist&id=shared", Some(&alice.token)).await;
    assert_eq!(own.status, 200);
    assert_eq!(own.json()["value"]["name"], "Bob's road trip");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_entry_id_belongs_to_one_playlist_only() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let push = harness
        .push(
            &alice,
            1,
            vec![
                ("playlist.create", json!({ "id": "a", "name": "A", "entries": [{ "id": "e1", "ref": song(0) }] })),
                ("playlist.create", json!({ "id": "b", "name": "B" })),
                ("entry.insert", json!({ "id": "e1", "playlist": "b", "ref": song(1), "place": { "kind": "last" } })),
                ("entry.insert", json!({ "id": "e1", "playlist": "a", "ref": song(1), "place": { "kind": "last" } })),
                ("playlist.create", json!({ "id": "c", "name": "C", "entries": [{ "id": "e1", "ref": song(2) }] })),
            ],
        )
        .await;
    assert_eq!(statuses(&push), ["applied", "applied", "invalid:bad_args", "noop", "invalid:bad_args"]);
    let pull = harness.pull(&alice, 0).await.json();
    assert_eq!(change(&pull, "playlist_entry", "e1")["value"]["playlist"], "a");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn guests_read_but_write_nothing_and_pending_devices_do_nothing() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let guest = harness.enroll("visitor", Role::Guest).await;
    let pending = harness.enroll("newcomer", Role::Pending).await;
    harness.push(&alice, 1, vec![("playlist.create", json!({ "id": "mix", "name": "Mix" })), ("playlist.setVisibility", json!({ "id": "mix", "visibility": "household" }))]).await;

    let write = harness.push(&guest, 1, vec![("love.set", love(0, true)), ("playlist.rename", json!({ "id": "mix", "name": "Hacked" })), ("listen.record", json!({ "listens": [] })), ("device.rename", json!({ "name": "x" }))]).await;
    assert_eq!(write.status, 200);
    assert_eq!(statuses(&write), ["invalid:forbidden"; 4]);
    let read = harness.pull(&guest, 0).await.json();
    assert_eq!(change(&read, "playlist", "mix")["value"]["name"], "Mix");

    for reply in [harness.pull(&pending, 0).await, harness.push(&pending, 1, vec![("love.set", love(0, true))]).await, harness.get("/flaccy/v1/listens", Some(&pending.token)).await] {
        assert_eq!((reply.status, reply.code()), (403, "forbidden".to_owned()));
    }
    assert_eq!(harness.get("/flaccy/v1/me", Some(&pending.token)).await.status, 200);
    harness.stop().await;
}

fn listen(event: &str, ts: i64, title: &str, artist: &str, recorded: bool) -> Value {
    let key = flaccy_server_core::song::song_key(&format!("{artist}-key"), &format!("{title}-key"));
    json!({ "eventId": event.repeat(24), "ts": ts, "ref": { "songKey": key, "title": title, "artist": artist }, "playedS": 200, "recorded": recorded })
}

fn listens_of(reply: &common::http::Reply) -> Vec<Value> {
    reply.json()["listens"].as_array().unwrap().clone()
}

#[tokio::test(flavor = "multi_thread")]
async fn listens_run_the_ledger_and_flipped_ones_come_back_by_sequence() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let ts = 1_700_000_000;
    let first = harness.push(&alice, 1, vec![("listen.record", json!({ "listens": [listen("a", ts, "Song", "Band", false)] }))]).await;
    assert_eq!(statuses(&first), ["applied"]);
    let before = harness.get(&format!("/flaccy/v1/listens?before={}", ts + 1), Some(&alice.token)).await;
    let rows = listens_of(&before);
    assert_eq!((rows.len(), rows[0]["suppressed"].clone()), (1, json!(false)));
    let cursor = rows[0]["seq"].as_i64().unwrap();

    let second = harness
        .push(&alice, 2, vec![("listen.record", json!({ "listens": [listen("b", ts, "Song", "Band", true), listen("c", ts, "Other Song", "Band", false), listen("d", ts + 60, "Later", "Else", false)] }))])
        .await;
    assert_eq!(statuses(&second), ["applied"]);
    let after = listens_of(&harness.get(&format!("/flaccy/v1/listens?after={cursor}"), Some(&alice.token)).await);
    let summary: Vec<(String, bool)> = after.iter().map(|row| (row["eventId"].as_str().unwrap()[..1].to_owned(), row["suppressed"].as_bool().unwrap())).collect();
    assert_eq!(summary, [("a".into(), true), ("b".into(), false), ("c".into(), true), ("d".into(), false)]);
    assert!(after.windows(2).all(|pair| pair[0]["seq"].as_i64() < pair[1]["seq"].as_i64()));

    let repeat = harness.push(&alice, 3, vec![("listen.record", json!({ "listens": [listen("a", ts, "Song", "Band", false), listen("b", ts, "Song", "Band", true)] }))]).await;
    assert_eq!(statuses(&repeat), ["noop"]);

    let newest_first = listens_of(&harness.get("/flaccy/v1/listens?before=2000000000&limit=2", Some(&alice.token)).await);
    assert_eq!(newest_first.iter().map(|row| row["eventId"].as_str().unwrap()[..1].to_owned()).collect::<Vec<_>>(), ["d", "c"]);
    let page = harness.get("/flaccy/v1/listens?before=2000000000&limit=2", Some(&alice.token)).await.json();
    assert_eq!(page["more"], true);
    assert!(listens_of(&harness.get("/flaccy/v1/listens", Some(&bob.token)).await).is_empty());
    assert_eq!(harness.get("/flaccy/v1/listens?before=1&after=1", Some(&alice.token)).await.status, 400);

    let stream = harness.call("GET", "/flaccy/v1/listens?before=2000000000", Some(&alice.token), &[("Accept", "application/x-ndjson")], &[]).await;
    assert_eq!(stream.header("content-type"), Some("application/x-ndjson"));
    let lines: Vec<Value> = String::from_utf8_lossy(&stream.body).lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 4);
    assert!(lines.iter().all(|line| line["seq"].is_i64() && line["eventId"].is_string()));
    assert_eq!(stream.header("flaccy-more"), Some("false"));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_entity_route_returns_one_entity_and_refuses_what_is_not_yours() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    harness.push(&alice, 1, vec![("playlist.create", json!({ "id": "mix", "name": "Mix" })), ("love.set", love(0, true))]).await;
    let found = harness.get("/flaccy/v1/sync/entity?kind=playlist&id=mix", Some(&alice.token)).await.json();
    assert_eq!((found["kind"].clone(), found["value"]["name"].clone(), found["deleted"].clone()), (json!("playlist"), json!("Mix"), json!(false)));
    assert!(found["seq"].as_i64().unwrap() >= 1 && found["serverTimeMs"].is_i64());
    let key = song(0)["songKey"].as_str().unwrap().to_owned();
    assert_eq!(harness.get(&format!("/flaccy/v1/sync/entity?kind=love&id={key}"), Some(&alice.token)).await.status, 200);
    assert_eq!(harness.get(&format!("/flaccy/v1/sync/entity?kind=love&id={key}"), Some(&bob.token)).await.status, 404);
    assert_eq!(harness.get("/flaccy/v1/sync/entity?kind=playlist&id=mix", Some(&bob.token)).await.status, 404);
    assert_eq!(harness.get("/flaccy/v1/sync/entity?kind=nonsense&id=mix", Some(&alice.token)).await.status, 400);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reseed_is_all_or_nothing() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let playlist = |id: &str, owner: &str| json!({ "kind": "playlist", "id": id, "value": { "id": id, "owner": owner, "name": "Restored", "coverBlob": null, "visibility": "private", "alive": true, "createdAt": 1, "stamps": { "name": 5, "cover": 5, "visibility": 5, "alive": 5 } } });
    let entry = json!({ "kind": "playlist_entry", "id": "re1", "value": { "id": "re1", "playlist": "restored", "ref": song(0), "pos": "V", "alive": true, "stamps": { "ref": 5, "pos": 5, "alive": 5 } } });
    let refused = harness.push(&alice, 1, vec![("state.reseed", json!({ "entities": [playlist("restored", &alice.user), entry.clone(), playlist("stolen", &bob.user)] }))]).await;
    assert_eq!(statuses(&refused), ["invalid:forbidden"]);
    assert!(harness.pull(&alice, 0).await.json()["changes"].as_array().unwrap().is_empty());
    let accepted = harness.push(&alice, 2, vec![("state.reseed", json!({ "entities": [playlist("restored", &alice.user), entry] }))]).await;
    assert_eq!(statuses(&accepted), ["applied"]);
    let pull = harness.pull(&alice, 0).await.json();
    assert_eq!(kinds(&pull), ["playlist", "playlist_entry"]);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn naming_a_device_by_mutation_reaches_the_device_list() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let push = harness.push(&alice, 1, vec![("device.rename", json!({ "name": "Kitchen" })), ("device.rename", json!({ "name": "  " }))]).await;
    assert_eq!(statuses(&push), ["applied", "invalid:bad_args"]);
    for _ in 0..40 {
        let devices = harness.get("/flaccy/v1/devices", Some(&alice.token)).await.json();
        if devices["devices"][0]["name"] == "Kitchen" {
            harness.stop().await;
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the device kept its name");
}

#[tokio::test(flavor = "multi_thread")]
async fn commits_poke_the_scope_they_changed() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let mut pokes = harness.state.0.sync.subscribe();
    harness.push(&alice, 1, vec![("playlist.create", json!({ "id": "mix", "name": "Mix" })), ("playlist.setVisibility", json!({ "id": "mix", "visibility": "household" }))]).await;
    let mut seen = Vec::new();
    while let Ok(poke) = tokio::time::timeout(Duration::from_millis(500), pokes.recv()).await {
        seen.push(poke.unwrap());
        if seen.len() == 2 {
            break;
        }
    }
    assert_eq!(seen[0].scope, alice.user);
    assert_eq!(seen[1].scope, "household");
    assert!(seen[1].head > seen[0].head);
    harness.push(&alice, 3, vec![("love.set", love(0, true))]).await;
    let third = tokio::time::timeout(Duration::from_millis(500), pokes.recv()).await.unwrap().unwrap();
    assert_eq!(third.scope, alice.user);
    harness.push(&alice, 4, vec![("scalar.set", json!({ "key": "bogus/key", "value": 1 }))]).await;
    assert!(tokio::time::timeout(Duration::from_millis(200), pokes.recv()).await.is_err(), "a refused mutation must not poke");
    harness.stop().await;
}
