//! The native API over real HTTP: identity, enrollment, authentication, the browser guard and blobs.

mod common;

use flaccy_server::credentials::{self, Credentials};
use flaccy_server::security::Role;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use common::http::{send, Harness};

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn png(extra: usize) -> Vec<u8> {
    let mut bytes = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    bytes.extend(std::iter::repeat_n(7u8, extra));
    bytes
}

#[tokio::test(flavor = "multi_thread")]
async fn hello_answers_without_a_token_and_lists_only_what_exists() {
    let harness = Harness::start().await;
    let reply = harness.get("/flaccy/v1/hello", None).await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.header("flaccy-protocol"), Some("1"));
    let body = reply.json();
    assert_eq!(body["protocol"], json!([1]));
    assert_eq!(body["features"], json!(["sync", "live"]));
    assert_eq!(body["mode"], "easy");
    assert_eq!(body["caller"], Value::Null);
    assert_eq!(body["server"]["schema"], flaccy_server::sync::CURRENT_VERSION);
    assert!(body["serverTimeMs"].as_i64().unwrap() > 1_700_000_000_000);
    assert_eq!(body["incarnation"].as_str().unwrap(), harness.state.0.sync.incarnation());
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn hello_echoes_the_caller_for_a_valid_token_only() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Admin).await;
    let known = harness.get("/flaccy/v1/hello", Some(&alice.token)).await.json();
    assert_eq!(known["caller"]["user"], alice.user.as_str());
    assert_eq!(known["caller"]["role"], "admin");
    assert_eq!(known["caller"]["device"], alice.id.as_str());
    let unknown = harness.get("/flaccy/v1/hello", Some("not-a-token")).await.json();
    assert_eq!(unknown["caller"], Value::Null);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_enrollment_code_works_once_and_every_failure_looks_the_same() {
    let harness = Harness::start().await;
    let user = harness.user("alice", Role::Member).await;
    let code = harness.enroll_code(&user).await;
    let enroll = |code: String| {
        let harness = &harness;
        async move {
            harness
                .post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": code, "name": "iPhone", "platform": "ios", "instance": "i1" }))
                .await
        }
    };
    let first = enroll(code.clone()).await;
    assert_eq!(first.status, 201);
    let body = first.json();
    assert_eq!(body["user"]["name"], "alice");
    assert_eq!(body["user"]["role"], "member");
    assert_eq!(body["token"].as_str().unwrap().len(), 43);
    assert!(body["incarnation"].is_string() && body["serverTimeMs"].is_i64());
    let used = enroll(code).await;
    let wrong = enroll("0".repeat(26)).await;
    let short_lived = harness.state.0.security.create_enrollment(&user, std::time::Duration::from_millis(50)).await.unwrap();
    tokio::time::sleep(std::time::Duration::from_millis(120)).await;
    let expired = enroll(short_lived).await;
    for refused in [&used, &wrong, &expired] {
        assert_eq!(refused.status, 401);
        assert_eq!(refused.code(), "enroll_invalid");
        assert_eq!(refused.body, used.body, "wrong, used and expired must answer identically");
    }
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn five_wrong_codes_lock_enrollment_with_a_retry_after() {
    let harness = Harness::start().await;
    for _ in 0..5 {
        let reply = harness.post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": "WRONGCODE", "name": "x" })).await;
        assert_eq!(reply.status, 401);
    }
    let locked = harness.post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": "WRONGCODE", "name": "x" })).await;
    assert_eq!(locked.status, 429);
    assert_eq!(locked.code(), "rate_limited");
    assert!(locked.header("retry-after").unwrap().parse::<u64>().unwrap() >= 1);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn an_enrollment_with_a_bad_name_keeps_the_code() {
    let harness = Harness::start().await;
    let user = harness.user("alice", Role::Member).await;
    let code = harness.enroll_code(&user).await;
    let bad = harness.post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": code, "name": "  " })).await;
    assert_eq!(bad.status, 400);
    let good = harness.post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": code, "name": "Phone" })).await;
    assert_eq!(good.status, 201);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn calls_without_a_valid_token_are_unauthorized() {
    let harness = Harness::start().await;
    for path in ["/flaccy/v1/me", "/flaccy/v1/devices", "/flaccy/v1/sync/pull", "/flaccy/v1/listens"] {
        let reply = harness.get(path, None).await;
        assert_eq!((reply.status, reply.code()), (401, "unauthorized".to_owned()), "{path}");
        let reply = harness.get(path, Some("0123456789")).await;
        assert_eq!((reply.status, reply.code()), (401, "unauthorized".to_owned()), "{path}");
    }
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn ten_unknown_tokens_lock_the_address_even_for_a_good_one() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    for _ in 0..10 {
        assert_eq!(harness.get("/flaccy/v1/me", Some("guess")).await.status, 401);
    }
    let locked = harness.get("/flaccy/v1/me", Some(&alice.token)).await;
    assert_eq!(locked.status, 429);
    assert_eq!(locked.code(), "rate_limited");
    assert!(locked.header("retry-after").is_some());
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_revoked_device_is_rejected_on_its_next_call() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    assert_eq!(harness.get("/flaccy/v1/me", Some(&alice.token)).await.status, 200);
    let revoke = harness.call("DELETE", &format!("/flaccy/v1/devices/{}", alice.id), Some(&alice.token), &[], &[]).await;
    assert_eq!(revoke.status, 200);
    assert_eq!(revoke.json()["revoked"], true);
    let after = harness.get("/flaccy/v1/me", Some(&alice.token)).await;
    assert_eq!((after.status, after.code()), (401, "unauthorized".to_owned()));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn devices_are_listed_renamed_and_revoked_by_their_owner_or_an_admin() {
    let harness = Harness::start().await;
    let root = harness.enroll("root", Role::Admin).await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let own = harness.get("/flaccy/v1/devices", Some(&alice.token)).await.json();
    assert_eq!(own["devices"].as_array().unwrap().len(), 1);
    assert_eq!(own["devices"][0]["current"], true);
    let everyone = harness.get("/flaccy/v1/devices", Some(&root.token)).await.json();
    assert_eq!(everyone["devices"].as_array().unwrap().len(), 3);
    let path = format!("/flaccy/v1/devices/{}", alice.id);
    let rename = |token: &str, name: &str| {
        let body = json!({ "name": name }).to_string();
        let path = path.clone();
        let token = token.to_owned();
        let harness = &harness;
        async move { harness.call("PATCH", &path, Some(&token), &[("Content-Type", "application/json")], body.as_bytes()).await }
    };
    assert_eq!(rename(&bob.token, "stolen").await.status, 403);
    assert_eq!(rename(&alice.token, "Alice iPad").await.status, 200);
    assert_eq!(rename(&root.token, "Renamed by admin").await.status, 200);
    let me = harness.get("/flaccy/v1/me", Some(&alice.token)).await.json();
    assert_eq!(me["devices"][0]["name"], "Renamed by admin");
    assert_eq!(me["role"], "member");
    assert_eq!(harness.call("DELETE", &path, Some(&bob.token), &[], &[]).await.status, 403);
    assert_eq!(harness.call("DELETE", "/flaccy/v1/devices/missing", Some(&root.token), &[], &[]).await.status, 404);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn browsers_and_foreign_hosts_are_refused_before_anything_else() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bearer = format!("Bearer {}", alice.token);
    let origin = send(harness.address, "GET", "/flaccy/v1/hello", &[("Origin", "http://evil.example")], &[]).await;
    assert_eq!((origin.status, origin.code()), (403, "browser_refused".to_owned()));
    let cross = send(harness.address, "GET", "/flaccy/v1/me", &[("Sec-Fetch-Site", "cross-site"), ("Authorization", &bearer)], &[]).await;
    assert_eq!((cross.status, cross.code()), (403, "browser_refused".to_owned()));
    let host = send(harness.address, "GET", "/flaccy/v1/hello", &[("Host", "evil.example")], &[]).await;
    assert_eq!((host.status, host.code()), (403, "browser_refused".to_owned()));
    let preflight = send(harness.address, "OPTIONS", "/flaccy/v1/sync/push", &[("Origin", "http://evil.example"), ("Access-Control-Request-Method", "POST")], &[]).await;
    assert_eq!(preflight.status, 403);
    assert!(preflight.header("access-control-allow-origin").is_none());
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn unknown_routes_and_methods_answer_in_the_error_shape() {
    let harness = Harness::start().await;
    let missing = harness.get("/flaccy/v1/nothing", None).await;
    assert_eq!((missing.status, missing.code()), (404, "not_found".to_owned()));
    assert!(missing.json()["error"]["message"].is_string());
    let wrong = harness.call("DELETE", "/flaccy/v1/hello", None, &[], &[]).await;
    assert_eq!((wrong.status, wrong.code()), (405, "method_not_allowed".to_owned()));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_large_body_and_malformed_json_are_refused_in_the_error_shape() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let huge = vec![b' '; 1024 * 1024 + 10];
    let too_large = harness.call("POST", "/flaccy/v1/sync/push", Some(&alice.token), &[("Content-Type", "application/json")], &huge).await;
    assert_eq!((too_large.status, too_large.code()), (413, "too_large".to_owned()));
    let broken = harness.call("POST", "/flaccy/v1/sync/push", Some(&alice.token), &[("Content-Type", "application/json")], b"{not json").await;
    assert_eq!((broken.status, broken.code()), (400, "bad_request".to_owned()));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn blobs_are_stored_by_hash_and_read_back() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bytes = png(100);
    let hash = hex(&Sha256::digest(&bytes));
    let put = harness.call("PUT", &format!("/flaccy/v1/blobs/{hash}"), Some(&alice.token), &[("Content-Type", "image/png")], &bytes).await;
    assert_eq!(put.status, 201);
    let again = harness.call("PUT", &format!("/flaccy/v1/blobs/{hash}"), Some(&alice.token), &[("Content-Type", "image/png")], &bytes).await;
    assert_eq!(again.status, 200);
    let got = harness.get(&format!("/flaccy/v1/blobs/{hash}"), Some(&alice.token)).await;
    assert_eq!((got.status, got.body.clone()), (200, bytes.clone()));
    assert_eq!(got.header("content-type"), Some("image/png"));
    assert_eq!(harness.get(&format!("/flaccy/v1/blobs/{}", "0".repeat(64)), Some(&alice.token)).await.status, 404);
    let wrong_hash = harness.call("PUT", &format!("/flaccy/v1/blobs/{}", "ab".repeat(32)), Some(&alice.token), &[("Content-Type", "image/png")], &bytes).await;
    assert_eq!((wrong_hash.status, wrong_hash.code()), (400, "bad_request".to_owned()));
    let wrong_type = harness.call("PUT", &format!("/flaccy/v1/blobs/{hash}"), Some(&alice.token), &[("Content-Type", "text/html")], &bytes).await;
    assert_eq!(wrong_type.status, 400);
    let not_an_image = harness.call("PUT", &format!("/flaccy/v1/blobs/{hash}"), Some(&alice.token), &[("Content-Type", "image/jpeg")], &bytes).await;
    assert_eq!(not_an_image.status, 400);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_blob_over_two_mebibytes_is_too_large_and_guests_cannot_store() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let guest = harness.enroll("guest", Role::Guest).await;
    let big = png(2 * 1024 * 1024 + 100);
    let hash = hex(&Sha256::digest(&big));
    let refused = harness.call("PUT", &format!("/flaccy/v1/blobs/{hash}"), Some(&alice.token), &[("Content-Type", "image/png")], &big).await;
    assert_eq!((refused.status, refused.code()), (413, "too_large".to_owned()));
    let small = png(10);
    let small_hash = hex(&Sha256::digest(&small));
    let guest_put = harness.call("PUT", &format!("/flaccy/v1/blobs/{small_hash}"), Some(&guest.token), &[("Content-Type", "image/png")], &small).await;
    assert_eq!((guest_put.status, guest_put.code()), (403, "forbidden".to_owned()));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn responses_compress_when_the_client_accepts_it() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let entries: Vec<Value> = (0..200).map(|index| json!({ "id": format!("e{index}"), "ref": common::song(index) })).collect();
    harness.push(&alice, 1, vec![("playlist.create", json!({ "id": "mix", "name": "Mix", "entries": entries }))]).await;
    let plain = harness.pull(&alice, 0).await;
    assert!(plain.header("content-encoding").is_none());
    let compressed = harness
        .call("GET", "/flaccy/v1/sync/pull?since=0", Some(&alice.token), &[("Accept-Encoding", "gzip")], &[])
        .await;
    assert_eq!(compressed.header("content-encoding"), Some("gzip"));
    assert!(compressed.body.len() < plain.body.len() / 3);
    assert_eq!(&compressed.body[..2], &[0x1f, 0x8b]);
    let brotli = harness.call("GET", "/flaccy/v1/sync/pull?since=0", Some(&alice.token), &[("Accept-Encoding", "br")], &[]).await;
    assert_eq!(brotli.header("content-encoding"), Some("br"));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn the_opensubsonic_api_still_answers_and_its_keys_became_the_owner_s() {
    let harness = Harness::start_with(|config| {
        std::fs::create_dir_all(config.data_dir()).unwrap();
        let mut account = Credentials { username: "legacy".to_owned(), password: "sesame-seed".to_owned(), keys: Vec::new() };
        account.add_key("phone", "2026-10-25T12:00:00Z").unwrap();
        credentials::save(&config.credentials_path(), &account).unwrap();
    })
    .await;
    let reply = send(harness.address, "GET", "/rest/ping.view?u=legacy&p=sesame-seed&v=1.16.1&c=test&f=json", &[], &[]).await;
    assert_eq!(reply.status, 200);
    assert_eq!(reply.json()["subsonic-response"]["status"], "ok");
    let owner = harness.state.0.security.find_user_by_name("legacy").await.unwrap().unwrap();
    assert_eq!(owner.role, Role::Admin);
    assert_eq!(harness.state.0.security.list_api_keys(Some(&owner.id)).await.unwrap().len(), 1);
    harness.stop().await;
}
