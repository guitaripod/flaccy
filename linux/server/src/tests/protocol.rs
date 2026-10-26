//! Envelope formats and the authentication paths.

use std::net::SocketAddr;

use axum::body::Body;
use axum::extract::ConnectInfo;
use axum::http::{Request, StatusCode};
use md5::{Digest, Md5};

use super::{TestServer, PASSWORD, USER};
use crate::ids;

fn token_for(salt: &str) -> String {
    let mut hasher = Md5::new();
    hasher.update(format!("{PASSWORD}{salt}").as_bytes());
    ids::hex(&hasher.finalize())
}

#[tokio::test]
async fn ping_without_f_answers_xml_with_the_subsonic_root() {
    let server = TestServer::new().await;
    let reply = server.get(&format!("/rest/ping?{}", TestServer::login())).await;
    assert_eq!(reply.status, StatusCode::OK);
    assert!(reply.header("content-type").starts_with("application/xml"));
    let xml = reply.text();
    assert!(xml.starts_with("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"));
    assert!(xml.contains("<subsonic-response xmlns=\"http://subsonic.org/restapi\""));
    assert!(xml.contains("status=\"ok\"") && xml.contains("version=\"1.16.1\""));
    assert!(xml.contains("openSubsonic=\"true\""));
}

#[tokio::test]
async fn get_album_without_f_answers_one_song_element_per_track_in_xml() {
    let server = TestServer::new().await;
    server.standard_library();
    let album = server.album_id("Rough Cuts").await;
    let reply = server
        .get(&format!("/rest/getAlbum?{}&id={album}", TestServer::login()))
        .await;
    let xml = reply.text();
    assert!(reply.header("content-type").starts_with("application/xml"));
    assert!(xml.contains("status=\"ok\""));
    assert_eq!(xml.matches("<album ").count(), 1);
    assert_eq!(xml.matches("<song ").count(), 3);
    assert!(xml.contains("name=\"Rough Cuts\"") && xml.contains("songCount=\"3\""));
    assert!(xml.contains("isDir=\"false\"") && xml.contains("flaccyRevision=\"1\""));
}

#[tokio::test]
async fn an_error_is_a_200_with_an_error_element_in_xml() {
    let server = TestServer::new().await;
    let reply = server.get("/rest/ping").await;
    assert_eq!(reply.status, StatusCode::OK);
    let xml = reply.text();
    assert!(xml.contains("status=\"failed\"") && xml.contains("<error code=\"10\""));
}

#[tokio::test]
async fn the_view_suffix_and_form_posts_work() {
    let server = TestServer::new().await;
    let reply = server.get(&format!("/rest/ping.view?{}&f=json", TestServer::login())).await;
    assert!(reply.text().contains("\"status\":\"ok\""));
    let posted = server
        .post_form("ping.view", &format!("u={USER}&p={PASSWORD}&f=json"))
        .await;
    assert_eq!(posted.status, StatusCode::OK);
    assert!(posted.text().contains("\"status\":\"ok\""));
}

#[tokio::test]
async fn every_auth_path_logs_in_and_each_failure_has_its_code() {
    let server = TestServer::new().await;
    let salt = "c19b2d";
    let token = token_for(salt);
    let encoded = ids::hex(PASSWORD.as_bytes());
    let key = &server.api_key;
    let accepted = [
        format!("u={USER}&p={PASSWORD}"),
        format!("u={USER}&p=enc:{encoded}"),
        format!("u={USER}&t={token}&s={salt}"),
        format!("apiKey={key}"),
    ];
    for query in accepted {
        let reply = server.get(&format!("/rest/ping?f=json&{query}")).await;
        assert!(reply.text().contains("\"status\":\"ok\""), "{query}: {}", reply.text());
    }
    let refused = [
        ("", 10),
        (&format!("u={USER}"), 10),
        (&format!("u={USER}&p=wrong"), 40),
        (&format!("u={USER}&t=00&s=1"), 40),
        ("u=nobody&p=sesame-seed", 40),
        ("apiKey=not-a-key", 44),
        (&format!("apiKey={key}&u={USER}"), 43),
    ];
    for (query, code) in refused {
        let reply = server.get(&format!("/rest/ping?f=json&{query}")).await;
        assert_eq!(reply.status, StatusCode::OK);
        let answer: serde_json::Value = serde_json::from_slice(&reply.body).unwrap();
        assert_eq!(answer["subsonic-response"]["status"], "failed", "{query}");
        assert_eq!(answer["subsonic-response"]["error"]["code"], code, "{query}");
    }
}

fn from_peer(uri: &str, peer: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .extension(ConnectInfo(peer.parse::<SocketAddr>().unwrap()))
        .body(Body::empty())
        .unwrap()
}

#[tokio::test]
async fn ten_failed_logins_lock_one_address_out_and_leave_the_others_working() {
    let server = TestServer::new().await;
    let wrong = format!("/rest/ping?f=json&u={USER}&p=wrong");
    let right = format!("/rest/ping?f=json&u={USER}&p={PASSWORD}");
    let attacker = "203.0.113.9:5000";
    for _ in 0..10 {
        let reply = server.send(from_peer(&wrong, attacker)).await;
        assert!(reply.text().contains("\"code\":40"), "{}", reply.text());
        assert!(!reply.text().contains("Too many"), "{}", reply.text());
    }
    let refused = server.send(from_peer(&right, attacker)).await;
    assert_eq!(refused.status, StatusCode::OK);
    assert!(refused.text().contains("\"code\":40"), "{}", refused.text());
    assert!(
        refused.text().contains("Too many failed logins from 203.0.113.9. Wait 10 minutes, then check the username and password or API key saved in your app."),
        "{}",
        refused.text()
    );
    let other = server.send(from_peer(&right, "198.51.100.4:5000")).await;
    assert!(other.text().contains("\"status\":\"ok\""), "{}", other.text());
}

#[tokio::test]
async fn a_revoked_key_is_refused_at_once() {
    let server = TestServer::new().await;
    let path = server.state.0.config.credentials_path();
    let mut account = crate::credentials::load(&path).unwrap().unwrap();
    assert!(account.revoke_key("phone"));
    std::thread::sleep(std::time::Duration::from_millis(20));
    crate::credentials::save(&path, &account).unwrap();
    let reply = server
        .get(&format!("/rest/ping?f=json&apiKey={}", server.api_key))
        .await;
    assert!(reply.text().contains("\"code\":44"), "{}", reply.text());
}

#[tokio::test]
async fn unknown_methods_say_they_are_not_implemented() {
    let server = TestServer::new().await;
    let answer = server.json("getPodcasts", "").await;
    assert_eq!(answer.error_code(), 0);
    let message = answer.envelope.error.unwrap().message.unwrap();
    assert!(message.contains("not implemented by flaccy-server"), "{message}");
}

#[tokio::test]
async fn identity_calls_describe_the_server() {
    let server = TestServer::new().await;
    server.standard_library();
    let ping = server.json("ping", "").await;
    assert_eq!(ping.envelope.server_type.as_deref(), Some("flaccy-server"));
    assert_eq!(ping.envelope.open_subsonic, Some(true));
    assert_eq!(server.json("getLicense", "").await.raw["license"]["valid"], true);

    let extensions = server.json("getOpenSubsonicExtensions", "").await;
    for name in ["apiKeyAuthentication", "formPost", "songLyrics", "flaccyVersions"] {
        assert!(extensions.envelope.supports(name), "{name}");
    }
    assert!(!extensions.envelope.supports("transcoding"));

    let folders = server.json("getMusicFolders", "").await;
    assert_eq!(folders.envelope.music_folders.unwrap().music_folder.unwrap()[0].id, Some(1));

    let user = server.json("getUser", &format!("username={USER}")).await;
    assert_eq!(user.raw["user"]["username"], USER);
    assert_eq!(user.raw["user"]["streamRole"], true);
    assert_eq!(user.raw["user"]["adminRole"], false);
    assert_eq!(server.json("getUser", "username=other").await.error_code(), 70);
}
