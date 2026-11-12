//! Sharing on the local network, end to end over this machine's own local address: the link carries the pin,
//! a client with that pin enrolls, syncs and opens the live channel over TLS, a wrong pin and plain HTTP are refused,
//! and a typed address learns the key on first contact. Skipped on a machine with no local network address, and on a
//! Mac unless `FLACCY_LAN_TESTS=1`: the macOS application firewall lets a new unsigned binary accept the TCP connection
//! but never hands it the bytes, from this machine or any other, until someone allows it.

mod common;

use std::sync::mpsc;
use std::time::Duration;

use common::TempDir;
use flaccy_library::db::Db;
use flaccy_library::server_sync::live::{Live, LiveEvent};
use flaccy_library::server_sync::{ApiError, Backoff, Driver, ServerLink, SyncState, TokenStore, Transport};
use flaccy_server::embed::{EmbedConfig, EmbeddedServer};
use serde_json::Value;

const READY_WITHIN: Duration = Duration::from_secs(30);

fn config_in(dir: &TempDir) -> EmbedConfig {
    std::fs::create_dir_all(dir.file("music")).unwrap();
    EmbedConfig {
        music_folder: dir.file("music"),
        data_dir: dir.file("data"),
        name: "LAN Box".to_owned(),
        port: 0,
        ffmpeg: None,
        log_dir: dir.file("logs"),
        lan: true,
        lan_name: None,
    }
}

fn https_candidate(link: &ServerLink) -> String {
    link.candidates().into_iter().find(|url| url.starts_with("https://")).expect("a local network address in the link")
}

fn by_ip(url: &str, status: &Value) -> String {
    let port = url.rsplit(':').next().unwrap();
    let ip = status["addresses"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .filter_map(|address| address.parse::<std::net::SocketAddr>().ok())
        .map(|address| address.ip())
        .find(|ip| flaccy_shared::remote::local_network::is_bindable_local_network(*ip) && ip.is_ipv4())
        .expect("a local IPv4 address");
    format!("https://{ip}:{port}")
}

#[test]
fn a_device_on_this_network_enrolls_syncs_and_listens_over_pinned_tls() {
    if cfg!(target_os = "macos") && std::env::var("FLACCY_LAN_TESTS").as_deref() != Ok("1") {
        eprintln!("skipped on a Mac: set FLACCY_LAN_TESTS=1 once the firewall allows the test binary");
        return;
    }
    let dir = TempDir::new("lan");
    let handle = EmbeddedServer::start(config_in(&dir)).unwrap();
    handle.wait_until_running(READY_WITHIN).unwrap();
    let status: Value = serde_json::from_str(&handle.status_json()).unwrap();
    if status["localUrl"].is_null() {
        eprintln!("skipped: this machine has no local network address");
        handle.stop().unwrap();
        return;
    }
    let pin = status["pin"].as_str().unwrap().to_owned();
    assert_eq!(pin.len(), 43);

    let enrollment = handle.create_enrollment(None).unwrap();
    assert_eq!(enrollment.pin.as_deref(), Some(pin.as_str()));
    let link = ServerLink::parse(&enrollment.link).unwrap();
    assert_eq!(link.pin.as_deref(), Some(pin.as_str()));
    let local = by_ip(&https_candidate(&link), &status);

    let identity = Transport::probing(&local).pinned(Some(&pin)).hello().unwrap();
    assert_eq!(identity.server.name, "LAN Box");
    assert_eq!(Transport::probing(&local).pinned(Some("not-the-pin")).hello().unwrap_err(), ApiError::KeyChanged);
    let plain = local.replacen("https://", "http://", 1);
    assert!(matches!(Transport::probing(&plain).hello(), Err(ApiError::Offline(_))), "plain HTTP must not reach a local network listener");
    let typed = Transport::probing(&local).first_contact();
    typed.hello().unwrap();
    assert_eq!(typed.seen_pin().as_deref(), Some(pin.as_str()));

    let device = dir.file("device");
    std::fs::create_dir_all(&device).unwrap();
    let db = Db::open(&device.join("library.sqlite")).unwrap();
    let mut driver = Driver::new(TokenStore::new(device.join("sync-token")), None).with_backoff(Backoff::NONE);
    let only_local = ServerLink::new(&local, link.enroll.as_deref(), link.name.as_deref()).reaching(Some(&pin), None);
    driver.enroll(&db, &only_local, "LAN phone").unwrap();
    assert_eq!(driver.run_once(&db).state, SyncState::UpToDate);
    let target = driver.live_target(&db).unwrap();
    assert_eq!((target.url.as_str(), target.pin.as_deref()), (local.as_str(), Some(pin.as_str())));

    let (events, inbox) = mpsc::channel();
    let live = Live::start(&target.url, &target.token, target.pin.as_deref(), move |event| {
        let _ = events.send(event);
    })
    .unwrap();
    assert_eq!(inbox.recv_timeout(Duration::from_secs(10)).unwrap(), LiveEvent::Up);
    drop(live);
    handle.stop().unwrap();
}
