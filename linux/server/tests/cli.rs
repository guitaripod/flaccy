//! The administration commands, run as the real binary against the data folder of a running server.

mod common;

use serde_json::{json, Value};
use tokio::process::Command;

use common::http::Harness;

struct Cli {
    config: std::path::PathBuf,
}

struct Ran {
    ok: bool,
    out: String,
    err: String,
}

impl Cli {
    fn new(harness: &Harness) -> Self {
        let config = harness.dir.file("config.toml");
        let text = format!(
            "music_folder = \"{}\"\ndata_dir = \"{}\"\nport = 4549\n",
            harness.dir.file("music").display(),
            harness.dir.file("data").display()
        );
        std::fs::write(&config, text).unwrap();
        Self { config }
    }

    async fn run(&self, args: &[&str]) -> Ran {
        let output = Command::new(env!("CARGO_BIN_EXE_flaccy-server"))
            .arg("--config")
            .arg(&self.config)
            .args(args)
            .output()
            .await
            .unwrap();
        Ran {
            ok: output.status.success(),
            out: String::from_utf8_lossy(&output.stdout).into_owned(),
            err: String::from_utf8_lossy(&output.stderr).into_owned(),
        }
    }

    async fn json(&self, args: &[&str]) -> Value {
        let ran = self.run(args).await;
        assert!(ran.ok, "{args:?} failed: {}", ran.err);
        serde_json::from_str(&ran.out).unwrap_or_else(|error| panic!("{args:?} printed no JSON ({error}): {}", ran.out))
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn enroll_prints_a_link_and_a_code_a_device_can_redeem() {
    let harness = Harness::start().await;
    let cli = Cli::new(&harness);
    let made = cli.json(&["enroll", "--user", "alice", "--url", "http://box.tail1234.ts.net:4545", "--json"]).await;
    assert_eq!(made["user"], "alice");
    assert_eq!(made["url"], "http://box.tail1234.ts.net:4545");
    let code = made["code"].as_str().unwrap();
    assert_eq!(code.len(), 26);
    let link = made["link"].as_str().unwrap();
    assert!(link.starts_with("flaccy://server?url=http%3A%2F%2Fbox.tail1234.ts.net%3A4545&enroll="), "{link}");
    assert!(link.contains(code) && link.contains("&name="), "{link}");
    assert!(made["expiresAt"].as_str().unwrap().ends_with('Z'));

    let reply = harness.post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": code, "name": "Laptop", "platform": "linux" })).await;
    assert_eq!(reply.status, 201);
    assert_eq!(reply.json()["user"]["role"], "admin", "the first enrollment creates the first admin");

    let text = cli.run(&["enroll", "--user", "alice"]).await;
    assert!(text.ok, "{}", text.err);
    assert!(text.out.contains("flaccy://server?url=") && text.out.contains("valid until"), "{}", text.out);
    assert!(text.out.contains('▀') || text.out.contains('█') || text.out.contains('▄'), "a QR code is drawn");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn enroll_refuses_an_unknown_user_once_users_exist_and_a_bad_ttl() {
    let harness = Harness::start().await;
    let cli = Cli::new(&harness);
    assert!(cli.run(&["enroll", "--user", "alice", "--json"]).await.ok);
    let unknown = cli.run(&["enroll", "--user", "stranger", "--json"]).await;
    assert!(!unknown.ok && unknown.err.contains("user add stranger"), "{}", unknown.err);
    let bad = cli.run(&["enroll", "--user", "alice", "--ttl", "soon"]).await;
    assert!(!bad.ok && bad.err.contains("--ttl"), "{}", bad.err);
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn users_devices_audit_and_status_work_from_the_command_line() {
    let harness = Harness::start().await;
    let cli = Cli::new(&harness);
    let code = cli.json(&["enroll", "--user", "alice", "--json"]).await["code"].as_str().unwrap().to_owned();
    let enrolled = harness.post_json("/flaccy/v1/devices", None, &[], &json!({ "enroll": code, "name": "Laptop", "platform": "linux" })).await.json();
    let token = enrolled["token"].as_str().unwrap().to_owned();
    let device = enrolled["device"].as_str().unwrap().to_owned();

    assert!(cli.run(&["user", "add", "bob", "--role", "member"]).await.ok);
    assert!(!cli.run(&["user", "add", "bob"]).await.ok, "names are unique");
    assert!(!cli.run(&["user", "add", "carol", "--role", "chief"]).await.ok);
    assert!(cli.run(&["user", "role", "bob", "guest"]).await.ok);
    let users = cli.run(&["user", "list"]).await.out;
    assert!(users.contains("alice") && users.contains("admin") && users.contains("bob") && users.contains("guest"), "{users}");
    assert!(!cli.run(&["user", "role", "alice", "member"]).await.ok, "the last admin cannot be demoted");

    let devices = cli.run(&["device", "list", "--user", "alice"]).await.out;
    assert!(devices.contains(&device) && devices.contains("Laptop") && devices.contains("linux"), "{devices}");
    assert_eq!(harness.get("/flaccy/v1/me", Some(&token)).await.status, 200);
    assert!(cli.run(&["device", "revoke", &device]).await.ok);
    assert_eq!(harness.get("/flaccy/v1/me", Some(&token)).await.status, 401);
    assert!(cli.run(&["device", "list"]).await.out.contains("revoked"));
    assert!(!cli.run(&["device", "revoke", "missing"]).await.ok);

    let audit = cli.run(&["audit", "verify"]).await;
    assert!(audit.ok && audit.out.contains("intact"), "{}{}", audit.out, audit.err);

    let status = cli.json(&["status", "--json"]).await;
    assert_eq!(status["sync"]["users"], 2);
    assert_eq!(status["sync"]["devices"], 0);
    assert_eq!(status["sync"]["revokedDevices"], 1);
    assert_eq!(status["sync"]["head"], 0);
    assert!(status["sync"]["databaseBytes"]["state"].as_u64().unwrap() > 0);
    assert!(status["library"]["songs"].is_u64());
    let text = cli.run(&["status"]).await.out;
    assert!(text.contains("Sync:") && text.contains("Databases:") && text.contains("Library:"), "{text}");
    harness.stop().await;
}

#[tokio::test(flavor = "multi_thread")]
async fn household_mode_is_refused_when_the_configuration_loads() {
    let harness = Harness::start().await;
    let cli = Cli::new(&harness);
    let text = std::fs::read_to_string(&cli.config).unwrap();
    std::fs::write(&cli.config, format!("{text}mode = \"household\"\n")).unwrap();
    let ran = cli.run(&["status"]).await;
    assert!(!ran.ok);
    assert!(ran.err.contains("Household mode is not available in this release; remove `mode` or set it to \"easy\"."), "{}", ran.err);
    harness.stop().await;
}
