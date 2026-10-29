use std::path::PathBuf;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use flaccy_server_embed_ffi::{embed_enroll, embed_start, embed_status, embed_stop, embed_version};
use serde_json::{json, Value};

static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("flaccy-embed-ffi-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(path.join("music")).unwrap();
        Self(path)
    }

    fn config(&self) -> String {
        json!({
            "musicFolder": self.0.join("music"),
            "dataDir": self.0.join("data"),
            "logDir": self.0.join("logs"),
            "name": "Ffi Test",
            "port": 0,
        })
        .to_string()
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn status() -> Value {
    serde_json::from_str(&embed_status().unwrap()).unwrap()
}

fn wait_for_state(wanted: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let now = status();
        if now["state"] == wanted {
            return now;
        }
        assert!(Instant::now() < deadline, "never reached {wanted}: {now}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn the_server_starts_enrolls_reports_and_stops_idempotently() {
    let _serial = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new();
    assert_eq!(status()["state"], "stopped");
    assert!(embed_enroll(String::new()).unwrap_err().to_string().contains("not running"));
    embed_stop().unwrap();

    let first: Value = serde_json::from_str(&embed_start(scratch.config()).unwrap()).unwrap();
    assert!(["starting", "running"].contains(&first["state"].as_str().unwrap()), "{first}");
    let running = wait_for_state("running");
    assert!(!running["addresses"].as_array().unwrap().is_empty());
    assert_eq!(running["deviceCount"], 0);
    assert_eq!(running["songCount"], 0);

    let again: Value = serde_json::from_str(&embed_start(scratch.config()).unwrap()).unwrap();
    assert_eq!(again["state"], "running", "starting twice answers the running server");

    let enrollment: Value = serde_json::from_str(&embed_enroll(String::new()).unwrap()).unwrap();
    assert_eq!(enrollment["user"], "owner");
    assert!(enrollment["link"].as_str().unwrap().starts_with("flaccy://server?url=http"));
    assert!(enrollment["code"].as_str().unwrap().len() >= 20);
    assert!(enrollment["expiresAt"].as_str().unwrap().ends_with('Z'));
    assert!(embed_enroll("nobody".to_owned()).unwrap_err().to_string().contains("no user called 'nobody'"));

    embed_stop().unwrap();
    embed_stop().unwrap();
    assert_eq!(status()["state"], "stopped");
    assert!(!embed_version().is_empty());
}

#[test]
fn a_bad_config_and_a_missing_folder_fail_with_a_sentence() {
    let _serial = ONE_AT_A_TIME.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let scratch = Scratch::new();
    let error = embed_start("{".to_owned()).unwrap_err().to_string();
    assert!(error.contains("not valid"), "{error}");
    let missing = json!({ "musicFolder": scratch.0.join("nope"), "dataDir": scratch.0.join("d"), "logDir": scratch.0.join("l") });
    let error = embed_start(missing.to_string()).unwrap_err().to_string();
    assert!(error.contains("Choose the folder again"), "{error}");
    let after = status();
    assert_eq!(after["state"], "error");
    assert!(after["lastError"].as_str().unwrap().contains("Choose the folder again"));
    embed_stop().unwrap();
    assert_eq!(status()["state"], "stopped");
}
