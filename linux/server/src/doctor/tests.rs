use std::time::Duration;

use super::*;
use crate::runner::fake::FakeRunner;
use crate::runner::RunError;
use crate::security::{Role, Store as SecurityStore};
use crate::tailscale::Tailnet;
use crate::terminal::ScriptedTerminal;

const NOW_MS: i64 = 1_790_000_000_000;

struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    fn new(label: &str) -> Self {
        let root = std::env::temp_dir().join(format!("flaccy-doctor-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("data")).unwrap();
        Self { root }
    }

    fn config(&self, extra: &str) -> Config {
        let text = format!("music_folder = \"{0}\"\ndata_dir = \"{0}/data\"\n{extra}", self.root.display());
        toml::from_str(&text).unwrap()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn environment(runner: &dyn Runner) -> DoctorEnvironment<'_> {
    DoctorEnvironment { config_path: PathBuf::from("/x/config.toml"), runner, platform: Platform::Linux, ffmpeg: "ffmpeg".to_owned(), now_ms: NOW_MS }
}

fn tailnet() -> Tailnet {
    Tailnet {
        version: "1.78.1".to_owned(),
        name: "arch".to_owned(),
        dns_name: "arch.tail1234.ts.net".to_owned(),
        addresses: vec!["100.91.211.44".parse().unwrap()],
    }
}

fn write_state(path: &Path, hlc: Option<i64>) {
    let connection = Connection::open(path).unwrap();
    connection.execute_batch("CREATE TABLE server_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)").unwrap();
    if let Some(hlc) = hlc {
        connection.execute("INSERT INTO server_meta VALUES ('server_hlc', ?1)", [hlc.to_string()]).unwrap();
    }
}

#[test]
fn tailscale_lines_cover_the_three_states() {
    let up = tailscale_check(&Tailscale::Running(tailnet()));
    assert_eq!(up.line(), "✓ Tailscale: connected as arch (100.91.211.44), version 1.78.1");
    let missing = tailscale_check(&Tailscale::NotInstalled);
    assert!(missing.failed() && missing.line().starts_with("✗ Tailscale: is not installed. Install it from tailscale.com/download"));
    let down = tailscale_check(&Tailscale::NotRunning("its state is Stopped".to_owned()));
    assert!(down.failed() && down.line().contains("its state is Stopped") && down.line().contains("tailscale up"));
}

#[test]
fn a_clock_over_an_hour_behind_the_stored_changes_fails() {
    let sandbox = Sandbox::new("clock");
    let config = sandbox.config("");
    assert!(!clock_check(&config, NOW_MS).failed(), "no state yet");
    let ahead_two_hours = (NOW_MS + 2 * 60 * 60 * 1000) << 16;
    write_state(&config.state_path(), Some(ahead_two_hours));
    let behind = clock_check(&config, NOW_MS);
    assert!(behind.failed() && behind.line().contains("2 hours behind") && behind.line().contains("timedatectl"), "{}", behind.line());
    std::fs::remove_file(config.state_path()).unwrap();
    write_state(&config.state_path(), Some((NOW_MS + 30 * 60 * 1000) << 16));
    assert!(!clock_check(&config, NOW_MS).failed());
}

#[test]
fn network_drives_fail_and_sd_cards_only_warn() {
    let data = Path::new("/mnt/media/flaccy");
    let network = medium_check(data, &Medium::Network("nfs4".to_owned()));
    assert!(network.failed() && network.line().contains("network drive (nfs4)"));
    let card = medium_check(data, &Medium::SdCard);
    assert!(!card.failed() && card.line().starts_with("! Disk:") && card.line().contains("SD card"));
    assert_eq!(medium_check(data, &Medium::Local).line(), "✓ Disk: /mnt/media/flaccy is on a local disk");
}

#[test]
fn little_free_space_fails_and_plenty_passes() {
    let sandbox = Sandbox::new("space");
    let config = sandbox.config("");
    let low = FakeRunner::default().on("df", FakeRunner::ok("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 99 512000 99% /\n"));
    let checks = disk_checks(&config, &low);
    assert_eq!(checks[1].name, "Disk space");
    assert!(checks[1].failed() && checks[1].line().contains("0.5 GB"), "{}", checks[1].line());
    let roomy = FakeRunner::default().on("df", FakeRunner::ok("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/x 100 99 41943040 5% /\n"));
    assert_eq!(disk_checks(&config, &roomy)[1].line(), "✓ Disk space: 40.0 GB free");
}

#[test]
fn ffmpeg_present_or_missing() {
    let present = FakeRunner::default().on("ffmpeg -version", FakeRunner::ok("ffmpeg version 7.1 Copyright\nbuilt with gcc\n"));
    assert_eq!(ffmpeg_check(&environment(&present)).line(), "✓ ffmpeg: ffmpeg version 7.1 Copyright");
    let absent = FakeRunner::default().on("ffmpeg", Err(RunError::NotFound));
    let check = ffmpeg_check(&environment(&absent));
    assert!(check.failed() && check.line().contains("apt install ffmpeg"));
}

#[test]
fn integrity_is_checked_on_both_databases() {
    let sandbox = Sandbox::new("integrity");
    let config = sandbox.config("");
    assert!(database_check(&config).line().starts_with("! Database:"), "nothing exists yet");
    write_state(&config.state_path(), None);
    write_state(&config.security_path(), None);
    assert!(database_check(&config).line().starts_with("✓ Database:"));
    std::fs::write(config.security_path(), vec![7u8; 8192]).unwrap();
    let broken = database_check(&config);
    assert!(broken.failed() && broken.line().contains("security.sqlite:") && broken.line().contains("flaccy-server restore"), "{}", broken.line());
}

#[test]
fn backups_are_fresh_stale_missing_or_off() {
    let sandbox = Sandbox::new("backups");
    let config = sandbox.config(&format!("backup_dir = \"{}/backups\"\n", sandbox.root.display()));
    let dir = config.backup_dir().unwrap();
    assert_eq!(backup_check(&config, NOW_MS).line(), "! Backups: no backups yet");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("notes.txt"), "x").unwrap();
    assert_eq!(backup_check(&config, NOW_MS).line(), "! Backups: no backups yet", "foreign files are ignored");
    let file = std::fs::File::create(dir.join("state-20261020-033000.sqlite")).unwrap();
    let modified = SystemTime::UNIX_EPOCH + Duration::from_millis((NOW_MS - 3 * 60 * 60 * 1000) as u64);
    file.set_modified(modified).unwrap();
    assert_eq!(backup_check(&config, NOW_MS).line(), "✓ Backups: newest is 3 hours old");
    file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_millis((NOW_MS - 9 * 24 * 60 * 60 * 1000) as u64)).unwrap();
    let stale = backup_check(&config, NOW_MS);
    assert!(stale.failed() && stale.line().contains("9 days old") && stale.line().contains("flaccy-server backup"), "{}", stale.line());
    let off = sandbox.config("backup_dir = \"\"\n");
    assert!(backup_check(&off, NOW_MS).line().contains("switched off"));
}

#[tokio::test]
async fn devices_list_platform_and_last_seen() {
    let sandbox = Sandbox::new("devices");
    let config = sandbox.config("");
    assert!(devices_check(&config, NOW_MS).line().starts_with("! Devices: none enrolled yet"));
    let store = SecurityStore::open(&config.security_path()).await.unwrap();
    let owner = store.create_user("marcus", Role::Admin).await.unwrap();
    store.create_device(&owner.id, "iPhone Air", "ios").await.unwrap();
    store.close().await.unwrap();
    let check = devices_check(&config, NOW_MS);
    assert_eq!(check.line(), "✓ Devices: 1 enrolled");
    assert_eq!(check.details, vec!["iPhone Air (ios, marcus): never seen".to_owned()]);
}

#[tokio::test]
async fn bind_fails_without_a_tailnet_address_and_names_a_down_server() {
    let sandbox = Sandbox::new("bind");
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let config = sandbox.config(&format!("port = {port}\n"));
    let runner = FakeRunner::default();
    let environment = environment(&runner);
    let nothing = bind_check(&config, &environment, vec!["192.168.1.5".parse().unwrap()]).await;
    assert!(nothing.failed() && nothing.line().contains("no Tailscale address"), "{}", nothing.line());
    let down = bind_check(&config, &environment, vec!["100.91.211.44".parse().unwrap()]).await;
    assert!(down.failed() && down.line().contains(&format!("not answering on port {port}")) && down.line().contains("systemctl --user start"), "{}", down.line());
}

#[tokio::test]
async fn the_report_prints_every_line_and_flags_a_failure() {
    let sandbox = Sandbox::new("report");
    let config = sandbox.config("backup_dir = \"\"\n");
    let runner = FakeRunner::default();
    let mut terminal = ScriptedTerminal::silent();
    let failed = report(&config, &environment(&runner), &mut terminal).await;
    assert!(failed, "Tailscale is missing in this fake world");
    let lines: Vec<&str> = terminal.output.lines().collect();
    let order = ["Tailscale", "Bind", "Clock", "Disk", "Disk space", "ffmpeg", "Database", "Backups", "Devices"];
    let found: Vec<&str> = lines.iter().filter(|line| !line.starts_with(' ')).map(|line| line[line.find(' ').unwrap() + 1..].split(':').next().unwrap()).collect();
    assert_eq!(found, order, "{}", terminal.output);
}
