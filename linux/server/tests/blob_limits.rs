//! Cover pictures: what an upload may declare, how much a user may store, and who may name a blob as a cover.

mod common;

use flaccy_server::security::Role;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use common::http::{Device, Harness, Reply};
use common::images::{bomb_jpeg, bomb_png, padded_to, png};

fn hash_of(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|byte| format!("{byte:02x}")).collect()
}

async fn upload(harness: &Harness, device: &Device, bytes: &[u8], mime: &str) -> Reply {
    let path = format!("/flaccy/v1/blobs/{}", hash_of(bytes));
    harness.call("PUT", &path, Some(&device.token), &[("Content-Type", mime)], bytes).await
}

fn status_of(reply: &Reply, index: usize) -> String {
    let result = &reply.json()["results"][index];
    match result["code"].as_str() {
        Some(code) => format!("{}:{code}", result["status"].as_str().unwrap()),
        None => result["status"].as_str().unwrap().to_owned(),
    }
}

fn reseed_playlist(id: &str, owner: &str, cover: &str) -> Value {
    let entity = json!({
        "kind": "playlist",
        "id": id,
        "value": {
            "id": id, "owner": owner, "name": "Restored", "coverBlob": cover, "visibility": "private", "alive": true, "createdAt": 1,
            "stamps": { "name": 5, "cover": 5, "visibility": 5, "alive": 5 }
        }
    });
    json!({ "entities": [entity] })
}

#[tokio::test(flavor = "multi_thread")]
async fn a_picture_whose_header_declares_a_decompression_bomb_is_refused_with_413() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bomb = bomb_png(12_000, 12_000);
    assert!(bomb.len() < 200);
    let refused = upload(&harness, &alice, &bomb, "image/png").await;
    assert_eq!((refused.status, refused.code()), (413, "too_large".to_owned()), "{}", String::from_utf8_lossy(&refused.body));
    let message = refused.json()["error"]["message"].as_str().unwrap().to_owned();
    assert!(message.contains("16 megapixels") && message.contains("8192"), "{message}");
    let tall = upload(&harness, &alice, &bomb_png(100, 8_193), "image/png").await;
    assert_eq!(tall.status, 413);
    let jpeg = upload(&harness, &alice, &bomb_jpeg(20_000, 20_000), "image/jpeg").await;
    assert_eq!(jpeg.status, 413, "{}", String::from_utf8_lossy(&jpeg.body));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_picture_inside_the_limits_is_stored_and_an_unreadable_header_is_not() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    assert_eq!(upload(&harness, &alice, &bomb_png(4_000, 4_000), "image/png").await.status, 201);
    assert_eq!(upload(&harness, &alice, &bomb_png(8_192, 1_953), "image/png").await.status, 201);
    assert_eq!(upload(&harness, &alice, &bomb_png(4_001, 4_000), "image/png").await.status, 413);
    let signature_only = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3];
    assert_eq!(upload(&harness, &alice, &signature_only, "image/png").await.status, 400);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_user_may_keep_fifty_megabytes_of_blobs_and_others_are_unaffected() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let size = flaccy_server::sync::MAX_BLOB_BYTES;
    let blob = |number: u8| padded_to(png(4, 4), size, number);
    let mut stored = 0;
    for number in 0..40u8 {
        let reply = upload(&harness, &alice, &blob(number), "image/png").await;
        if reply.status == 413 {
            assert_eq!(reply.code(), "too_large");
            assert!(reply.json()["error"]["message"].as_str().unwrap().contains("50 MB"));
            break;
        }
        assert_eq!(reply.status, 201);
        stored += size;
    }
    assert!(stored > 40_000_000 && stored <= 50_000_000, "alice stored {stored} bytes");
    assert_eq!(upload(&harness, &bob, &blob(200), "image/png").await.status, 201);
    assert_eq!(upload(&harness, &alice, &blob(0), "image/png").await.status, 200);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_cover_must_name_a_blob_the_caller_uploaded() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let cover = png(8, 8);
    let hash = hash_of(&cover);
    assert_eq!(upload(&harness, &alice, &cover, "image/png").await.status, 201);
    let made = harness.push(&bob, 1, vec![("playlist.create", json!({ "id": "bobs", "name": "Bob's" }))]).await;
    assert_eq!(status_of(&made, 0), "applied");
    let foreign = harness.push(&bob, 2, vec![("playlist.setCover", json!({ "id": "bobs", "blob": hash }))]).await;
    assert_eq!(status_of(&foreign, 0), "invalid:bad_args");
    let missing = harness.push(&bob, 3, vec![("playlist.setCover", json!({ "id": "bobs", "blob": "ab".repeat(32) }))]).await;
    assert_eq!(status_of(&missing, 0), "invalid:bad_args");
    harness.push(&alice, 1, vec![("playlist.create", json!({ "id": "alices", "name": "Alice's" }))]).await;
    let own = harness.push(&alice, 2, vec![("playlist.setCover", json!({ "id": "alices", "blob": hash }))]).await;
    assert_eq!(status_of(&own, 0), "applied");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_reseeded_cover_must_name_a_blob_the_caller_uploaded() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let cover = png(8, 8);
    assert_eq!(upload(&harness, &alice, &cover, "image/png").await.status, 201);
    let foreign = harness.push(&bob, 1, vec![("state.reseed", reseed_playlist("bobs", &bob.user, &hash_of(&cover)))]).await;
    assert_eq!(status_of(&foreign, 0), "invalid:bad_args");
    let own = harness.push(&alice, 1, vec![("state.reseed", reseed_playlist("alices", &alice.user, &hash_of(&cover)))]).await;
    assert_eq!(status_of(&own, 0), "applied");
    harness.stop().await;
}
