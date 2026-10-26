//! The live channel end to end: pokes, presence, commands, limits, revocation and shutdown.

mod common;

use std::time::{Duration, Instant};

use common::http::{Device, Harness};
use flaccy_server::native::LiveTiming;
use flaccy_server::security::Role;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

const SOON: Duration = Duration::from_millis(200);
const PATIENT: Duration = Duration::from_secs(5);
const QUIET: Duration = Duration::from_millis(300);

fn request(harness: &Harness, token: Option<&str>, origin: Option<&str>) -> tokio_tungstenite::tungstenite::handshake::client::Request {
    let mut request = format!("ws://{}/flaccy/v1/live", harness.address).into_client_request().unwrap();
    if let Some(token) = token {
        request.headers_mut().insert("Authorization", format!("Bearer {token}").parse().unwrap());
    }
    if let Some(origin) = origin {
        request.headers_mut().insert("Origin", origin.parse().unwrap());
    }
    request
}

async fn connect(harness: &Harness, device: &Device) -> Socket {
    let (socket, response) = tokio_tungstenite::connect_async(request(harness, Some(&device.token), None)).await.unwrap();
    assert_eq!(response.status().as_u16(), 101);
    socket
}

async fn refused_status(harness: &Harness, token: Option<&str>, origin: Option<&str>) -> u16 {
    match tokio_tungstenite::connect_async(request(harness, token, origin)).await {
        Err(tokio_tungstenite::tungstenite::Error::Http(response)) => response.status().as_u16(),
        other => panic!("expected an HTTP refusal, got {:?}", other.map(|_| ())),
    }
}

async fn next_json(socket: &mut Socket, within: Duration) -> Option<Value> {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        match tokio::time::timeout_at(deadline, socket.next()).await {
            Ok(Some(Ok(Message::Text(text)))) => return serde_json::from_str(text.as_str()).ok(),
            Ok(Some(Ok(Message::Ping(_) | Message::Pong(_)))) => continue,
            _ => return None,
        }
    }
}

async fn close_code(socket: &mut Socket, within: Duration) -> Option<CloseCode> {
    let deadline = tokio::time::Instant::now() + within;
    loop {
        match tokio::time::timeout_at(deadline, socket.next()).await {
            Ok(Some(Ok(Message::Close(frame)))) => return frame.map(|frame| frame.code),
            Ok(Some(Ok(_))) => continue,
            _ => return None,
        }
    }
}

async fn send_json(socket: &mut Socket, frame: Value) {
    socket.send(Message::Text(frame.to_string().into())).await.unwrap();
}

async fn two_devices_of_one_user(harness: &Harness) -> (Device, Device) {
    let first = harness.enroll("alice", Role::Member).await;
    let second = harness.enroll("alice", Role::Member).await;
    (first, second)
}

async fn wait_for_connections(harness: &Harness, expected: usize) {
    let deadline = Instant::now() + PATIENT;
    while harness.state.0.live.connection_count() != expected && Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(harness.state.0.live.connection_count(), expected);
}

fn love(index: usize) -> (&'static str, Value) {
    ("love.set", json!({ "songKey": common::song(index)["songKey"], "ref": common::song(index), "loved": true }))
}

#[tokio::test(flavor = "multi_thread")]
async fn a_push_from_one_device_pokes_the_other_within_200_ms() {
    let harness = Harness::start().await;
    let (phone, laptop) = two_devices_of_one_user(&harness).await;
    let mut listening = connect(&harness, &laptop).await;
    let started = Instant::now();
    let pushed = harness.push(&phone, 1, vec![love(1)]).await;
    assert_eq!(pushed.status, 200);
    let poke = next_json(&mut listening, PATIENT).await.expect("a poke");
    assert!(started.elapsed() < SOON, "the poke took {:?}", started.elapsed());
    assert_eq!(poke["t"], "poke");
    assert!(poke["head"].as_i64().unwrap() >= 1);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn pokes_stay_inside_the_users_scope_but_household_reaches_everyone() {
    let harness = Harness::start().await;
    let alice = harness.enroll("alice", Role::Member).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let mut bobs = connect(&harness, &bob).await;
    harness.push(&alice, 1, vec![love(1)]).await;
    assert!(next_json(&mut bobs, QUIET).await.is_none(), "a private change must not poke another user");
    let shared = json!({ "id": "family", "name": "Family", "entries": [] });
    harness.push(&alice, 2, vec![("playlist.create", shared), ("playlist.setVisibility", json!({ "id": "family", "visibility": "household" }))]).await;
    let poke = next_json(&mut bobs, PATIENT).await.expect("household changes poke everyone");
    assert_eq!(poke["t"], "poke");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn presence_is_stamped_by_the_server_relayed_and_replayed() {
    let harness = Harness::start().await;
    let (phone, laptop) = two_devices_of_one_user(&harness).await;
    let mut phone_socket = connect(&harness, &phone).await;
    let frame = json!({ "t": "presence", "device": "someone-else", "state": "playing", "ref": { "songKey": "k" }, "positionMs": 1234 });
    send_json(&mut phone_socket, frame).await;
    tokio::time::sleep(QUIET).await;
    let mut laptop_socket = connect(&harness, &laptop).await;
    let replayed = next_json(&mut laptop_socket, PATIENT).await.expect("replayed presence");
    assert_eq!(replayed["t"], "presence");
    assert_eq!(replayed["device"], phone.id.as_str(), "the server overwrites `device` from the token");
    assert_eq!((replayed["state"].as_str(), replayed["positionMs"].as_i64()), (Some("playing"), Some(1234)));
    assert!(replayed["at"].as_i64().unwrap() > 0);
    send_json(&mut phone_socket, json!({ "t": "presence", "state": "paused", "ref": null, "positionMs": 2000 })).await;
    let live = next_json(&mut laptop_socket, PATIENT).await.expect("live presence");
    assert_eq!((live["state"].as_str(), live["device"].as_str()), (Some("paused"), Some(phone.id.as_str())));
    assert!(next_json(&mut phone_socket, QUIET).await.is_none(), "a device does not hear itself");
    drop(phone_socket);
    let gone = next_json(&mut laptop_socket, PATIENT).await.expect("offline presence");
    assert_eq!((gone["state"].as_str(), gone["device"].as_str()), (Some("offline"), Some(phone.id.as_str())));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_command_reaches_the_target_with_a_fresh_id_and_the_server_s_clock() {
    let harness = Harness::start().await;
    let (phone, laptop) = two_devices_of_one_user(&harness).await;
    let mut phone_socket = connect(&harness, &phone).await;
    let mut laptop_socket = connect(&harness, &laptop).await;
    let command = json!({ "t": "command", "to": laptop.id, "name": "pause", "args": { "fade": true }, "from": "forged", "id": "forged" });
    send_json(&mut phone_socket, command.clone()).await;
    let first = next_json(&mut laptop_socket, PATIENT).await.expect("the command");
    send_json(&mut phone_socket, command).await;
    let second = next_json(&mut laptop_socket, PATIENT).await.expect("the second command");
    assert_eq!((first["t"].as_str(), first["name"].as_str(), first["from"].as_str()), (Some("command"), Some("pause"), Some(phone.id.as_str())));
    assert_eq!(first["args"], json!({ "fade": true }));
    assert_ne!(first["id"], second["id"]);
    assert_ne!(first["id"], "forged");
    let skew = (first["sentAt"].as_i64().unwrap() - harness.state.0.sync.now_ms()).abs();
    assert!(skew < 5_000, "sentAt is the server's clock, {skew} ms off");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_command_to_an_offline_or_foreign_device_is_an_error_and_never_queued() {
    let harness = Harness::start().await;
    let (phone, laptop) = two_devices_of_one_user(&harness).await;
    let bob = harness.enroll("bob", Role::Member).await;
    let mut phone_socket = connect(&harness, &phone).await;
    let mut bobs_socket = connect(&harness, &bob).await;
    for target in [laptop.id.as_str(), bob.id.as_str(), "nobody"] {
        send_json(&mut phone_socket, json!({ "t": "command", "to": target, "name": "play", "args": {} })).await;
        let error = next_json(&mut phone_socket, PATIENT).await.expect("an error frame");
        assert_eq!((error["t"].as_str(), error["code"].as_str()), (Some("error"), Some("target_offline")), "{target}");
    }
    assert!(next_json(&mut bobs_socket, QUIET).await.is_none(), "another user's device never hears the command");
    let mut laptop_socket = connect(&harness, &laptop).await;
    assert!(next_json(&mut laptop_socket, QUIET).await.is_none(), "an offline command is not delivered later");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn more_than_five_commands_a_second_are_rate_limited() {
    let harness = Harness::start().await;
    let phone = harness.enroll("alice", Role::Member).await;
    let mut socket = connect(&harness, &phone).await;
    for _ in 0..7 {
        send_json(&mut socket, json!({ "t": "command", "to": "nobody", "name": "play", "args": {} })).await;
    }
    let mut codes = Vec::new();
    while let Some(frame) = next_json(&mut socket, PATIENT).await {
        codes.push(frame["code"].as_str().unwrap().to_owned());
        if codes.len() == 7 {
            break;
        }
    }
    assert_eq!(&codes[..5], ["target_offline"; 5]);
    assert_eq!(&codes[5..], ["rate_limited"; 2]);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_frame_over_64_kib_closes_the_socket() {
    let harness = Harness::start().await;
    let phone = harness.enroll("alice", Role::Member).await;
    let mut socket = connect(&harness, &phone).await;
    let padding = "x".repeat(70 * 1024);
    send_json(&mut socket, json!({ "t": "presence", "state": "playing", "ref": padding })).await;
    assert_eq!(close_code(&mut socket, PATIENT).await, Some(CloseCode::Size));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_revoked_token_closes_the_socket_at_the_next_check_and_on_the_next_command() {
    let harness = Harness::start().await;
    harness.state.0.live.set_timing(LiveTiming { revalidate: Duration::from_millis(100), ..LiveTiming::default() });
    let (phone, laptop) = two_devices_of_one_user(&harness).await;
    let mut phone_socket = connect(&harness, &phone).await;
    harness.revoke(&phone.id).await;
    assert_eq!(close_code(&mut phone_socket, PATIENT).await, Some(CloseCode::Policy));

    harness.state.0.live.set_timing(LiveTiming::default());
    let mut laptop_socket = connect(&harness, &laptop).await;
    let mut other = connect(&harness, &harness.enroll("alice", Role::Member).await).await;
    harness.revoke(&laptop.id).await;
    send_json(&mut laptop_socket, json!({ "t": "command", "to": "anyone", "name": "play", "args": {} })).await;
    assert_eq!(close_code(&mut laptop_socket, PATIENT).await, Some(CloseCode::Policy));
    assert!(next_json(&mut other, QUIET).await.is_none());
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn revoking_a_device_over_http_closes_its_sockets_at_once() {
    let harness = Harness::start().await;
    let (phone, laptop) = two_devices_of_one_user(&harness).await;
    let mut phone_socket = connect(&harness, &phone).await;
    let reply = harness.call("DELETE", &format!("/flaccy/v1/devices/{}", phone.id), Some(&laptop.token), &[], &[]).await;
    assert_eq!(reply.status, 200);
    assert_eq!(close_code(&mut phone_socket, SOON * 5).await, Some(CloseCode::Policy));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn only_an_approved_device_without_an_origin_may_upgrade() {
    let harness = Harness::start().await;
    let phone = harness.enroll("alice", Role::Member).await;
    let pending = harness.enroll("newcomer", Role::Pending).await;
    assert_eq!(refused_status(&harness, None, None).await, 401);
    assert_eq!(refused_status(&harness, Some("not-a-token"), None).await, 401);
    assert_eq!(refused_status(&harness, Some(&pending.token), None).await, 403);
    assert_eq!(refused_status(&harness, Some(&phone.token), Some("https://evil.example")).await, 403);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_silent_connection_is_closed_and_a_listening_one_is_pinged_and_kept() {
    let harness = Harness::start().await;
    harness
        .state
        .0
        .live
        .set_timing(LiveTiming { ping: Duration::from_millis(100), silence: Duration::from_millis(500), ..LiveTiming::default() });
    let (phone, laptop) = two_devices_of_one_user(&harness).await;
    let mut deaf = connect(&harness, &phone).await;
    let mut listening = connect(&harness, &laptop).await;
    let mut pings = 0;
    let deadline = tokio::time::Instant::now() + Duration::from_millis(1500);
    while let Ok(Some(Ok(message))) = tokio::time::timeout_at(deadline, listening.next()).await {
        pings += usize::from(matches!(message, Message::Ping(_)));
    }
    assert!(pings >= 5, "only {pings} pings in 1.5 s");
    assert_eq!(harness.state.0.live.connection_count(), 1, "the socket that never answered was closed, the other kept");
    assert!(deaf.next().await.is_some());
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn a_graceful_shutdown_says_going_away() {
    let harness = Harness::start().await;
    let phone = harness.enroll("alice", Role::Member).await;
    let mut socket = connect(&harness, &phone).await;
    harness.state.0.live.shutdown();
    assert_eq!(close_code(&mut socket, PATIENT).await, Some(CloseCode::Away));
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn fifty_simultaneous_connections_all_get_the_poke_and_the_server_stays_healthy() {
    let harness = Harness::start().await;
    let owner = harness.user("crowd", Role::Member).await;
    let mut devices = Vec::new();
    for index in 0..50 {
        let (id, token) = harness.state.0.security.create_device(&owner, &format!("device {index}"), "linux").await.unwrap();
        devices.push(Device { id: id.to_string(), token, user: owner.to_string(), instance: format!("instance-{index}") });
    }
    let mut sockets = Vec::new();
    for device in &devices {
        sockets.push(connect(&harness, device).await);
    }
    wait_for_connections(&harness, 50).await;
    send_json(&mut sockets[0], json!({ "t": "presence", "state": "playing", "ref": null, "positionMs": 0 })).await;
    let pushed = harness.push(&devices[0], 1, vec![love(1)]).await;
    assert_eq!(pushed.status, 200);
    for (index, socket) in sockets.iter_mut().enumerate() {
        let mut saw_poke = false;
        let mut saw_presence = index == 0;
        while !(saw_poke && saw_presence) {
            let frame = next_json(socket, PATIENT).await.unwrap_or_else(|| panic!("device {index} missed a frame"));
            saw_poke |= frame["t"] == "poke";
            saw_presence |= frame["t"] == "presence";
        }
    }
    let hello = harness.get("/flaccy/v1/hello", None).await;
    assert_eq!(hello.status, 200);
    drop(sockets);
    wait_for_connections(&harness, 0).await;
    harness.stop().await;
}
