//! The Host policy end to end, on the OpenSubsonic API and the native API alike.

mod common;

use common::http::{send, Harness};

const ANSWERED_HOSTS: [&str; 9] = [
    "arch:4545",
    "arch.tail1234.ts.net:4545",
    "100.64.0.1:4545",
    "[fd7a:115c:a1e0::6b01:d32d]:4545",
    "nas.local",
    "nas.local:4545",
    "192.168.1.5:4545",
    "localhost",
    "ARCH.TAIL1234.TS.NET",
];

const REFUSED_HOSTS: [&str; 5] = [
    "evil.example.com",
    "100.64.0.1.evil.com",
    "evil.example.com:4545",
    "localhost.evil.com",
    "music.example.org",
];

async fn status_of(harness: &Harness, path: &str, host: &str) -> (u16, String) {
    let reply = send(harness.address, "GET", path, &[("Host", host)], &[]).await;
    let code = if reply.status == 403 { reply.code() } else { String::new() };
    (reply.status, code)
}

#[tokio::test(flavor = "multi_thread")]
async fn magic_dns_lan_and_ip_hosts_reach_both_apis() {
    let harness = Harness::start().await;
    for host in ANSWERED_HOSTS {
        let (hello, _) = status_of(&harness, "/flaccy/v1/hello", host).await;
        assert_eq!(hello, 200, "native API refused {host}");
        let (rest, code) = status_of(&harness, "/rest/ping.view", host).await;
        assert_ne!(rest, 403, "/rest refused {host} ({code})");
    }
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn rebinding_names_are_refused_on_both_apis() {
    let harness = Harness::start().await;
    for host in REFUSED_HOSTS {
        for path in ["/flaccy/v1/hello", "/rest/ping.view"] {
            let (status, code) = status_of(&harness, path, host).await;
            assert_eq!((status, code.as_str()), (403, "browser_refused"), "{path} with {host}");
        }
    }
    harness.stop().await;
}
