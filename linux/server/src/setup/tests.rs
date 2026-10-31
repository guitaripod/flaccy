use std::path::PathBuf;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use super::*;
use crate::runner::fake::FakeRunner;
use crate::terminal::ScriptedTerminal;

const TAILSCALE_JSON: &str = r#"{"Version":"1.78.1-t1-g2","BackendState":"Running","Self":{"HostName":"arch","DNSName":"arch.tail1234.ts.net.","TailscaleIPs":["100.91.211.44"]}}"#;

struct Sandbox {
    root: PathBuf,
}

impl Sandbox {
    fn new(label: &str) -> Self {
        let root = std::env::temp_dir().join(format!("flaccy-setup-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("music")).unwrap();
        Self { root }
    }

    fn environment<'a>(&self, runner: &'a FakeRunner, platform: Platform) -> SetupEnvironment<'a> {
        SetupEnvironment {
            config_path: self.root.join("config").join("flaccy-server").join("config.toml"),
            config_is_explicit: false,
            home: self.root.clone(),
            config_dir: self.root.join("config"),
            executable: PathBuf::from("/usr/bin/flaccy-server"),
            platform,
            user: "marcus".to_owned(),
            runner,
            ready_wait: Duration::from_millis(50),
            data_dir: Some(self.root.join("data")),
        }
    }

    fn args(&self, port: u16) -> SetupArgs {
        SetupArgs { yes: true, music: Some(self.root.join("music")), name: Some("marcus".to_owned()), port: Some(port) }
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn working_runner() -> FakeRunner {
    FakeRunner::default()
        .on("tailscale status --json", FakeRunner::ok(TAILSCALE_JSON))
        .on("systemctl", FakeRunner::ok(""))
        .on("loginctl show-user", FakeRunner::ok("Linger=no\n"))
        .on("loginctl enable-linger", FakeRunner::ok(""))
}

async fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap().port()
}

#[test]
fn numbers_group_by_thousands() {
    assert_eq!(grouped(0), "0");
    assert_eq!(grouped(612), "612");
    assert_eq!(grouped(7412), "7,412");
    assert_eq!(grouped(1_234_567), "1,234,567");
    assert_eq!(counted(1, "song", "songs"), "1 song");
    assert_eq!(counted(7412, "song", "songs"), "7,412 songs");
}

#[tokio::test]
async fn a_machine_without_tailscale_gets_the_documented_sentence_and_no_config() {
    let sandbox = Sandbox::new("notailscale");
    let runner = FakeRunner::default();
    let environment = sandbox.environment(&runner, Platform::Linux);
    let mut terminal = ScriptedTerminal::silent();
    let error = execute(&environment, &mut terminal, sandbox.args(4545)).await.unwrap_err();
    assert_eq!(
        error,
        "Tailscale isn't running on this machine. Flaccy Server reaches your devices through it. Install it from tailscale.com/download, sign in, then run this again."
    );
    assert!(!environment.config_path.exists());
}

#[tokio::test]
async fn a_taken_port_names_its_holder() {
    let sandbox = Sandbox::new("port");
    let held = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = held.local_addr().unwrap().port();
    let runner = working_runner().on("ss", FakeRunner::ok("LISTEN 0 1 127.0.0.1:1 0.0.0.0:* users:((\"navidrome\",pid=1,fd=3))"));
    let environment = sandbox.environment(&runner, Platform::Linux);
    let mut terminal = ScriptedTerminal::silent();
    let error = execute(&environment, &mut terminal, sandbox.args(port)).await.unwrap_err();
    assert_eq!(error, format!("Port {port} is in use by navidrome. Use --port, or stop that program."));
    assert!(!environment.config_path.exists());
}

#[tokio::test]
async fn a_missing_music_folder_stops_before_anything_is_written() {
    let sandbox = Sandbox::new("nofolder");
    let runner = working_runner();
    let environment = sandbox.environment(&runner, Platform::Linux);
    let mut terminal = ScriptedTerminal::silent();
    let mut args = sandbox.args(free_port().await);
    args.music = Some(sandbox.root.join("nowhere"));
    let error = execute(&environment, &mut terminal, args).await.unwrap_err();
    assert!(error.contains("There is no folder at") && error.contains("nowhere"), "{error}");
    assert!(!environment.config_path.exists());
}

#[tokio::test]
async fn a_first_run_follows_the_conversation_and_a_second_keeps_the_setup() {
    let sandbox = Sandbox::new("flow");
    let runner = working_runner();
    let environment = sandbox.environment(&runner, Platform::Linux);
    let port = free_port().await;
    let mut first = ScriptedTerminal::silent();
    execute(&environment, &mut first, sandbox.args(port)).await.unwrap();
    let out = first.output.clone();
    let expected_order = [
        "Flaccy Server ",
        "Where is your music? ",
        "  That folder has no music yet. Flaccy Server will pick files up as you add them.",
        "Tailscale: connected as arch (100.91.211.44).",
        "Your name on this server? marcus",
        &format!("Starting the server on port {port}... started, but not answering yet."),
        "Keeping it running after you log out... done (flaccy-server.service).",
        "Scan this with Flaccy on your iPhone, Mac or Linux:",
        "Or open this link on a device that has Flaccy:",
        &format!("  flaccy://server?url=http%3A%2F%2Farch%3A{port}&enroll="),
        "&name=arch",
        "The code works once and expires in 10 minutes. Make another with `flaccy-server enroll`.",
    ];
    let mut from = 0;
    for needle in expected_order {
        let at = out[from..].find(needle).unwrap_or_else(|| panic!("missing or out of order: {needle}\n{out}"));
        from += at;
    }
    let config = std::fs::read_to_string(&environment.config_path).unwrap();
    assert!(config.contains(&format!("port = {port}")) && config.contains("mode = \"easy\""), "{config}");
    let unit = sandbox.root.join("config/systemd/user/flaccy-server.service");
    assert!(std::fs::read_to_string(unit).unwrap().contains("ExecStart=/usr/bin/flaccy-server serve"));
    assert!(runner.calls.borrow().iter().any(|call| call == "loginctl enable-linger marcus"));

    let mut second = ScriptedTerminal::silent();
    execute(&environment, &mut second, sandbox.args(port)).await.unwrap();
    assert!(second.output.contains("stays as it is."), "{}", second.output);
    assert!(second.output.contains("Your name on this server: marcus"), "{}", second.output);
    assert!(second.output.contains("--music and --port are ignored"), "{}", second.output);
    assert_ne!(code_of(&out), code_of(&second.output));
    assert_eq!(std::fs::read_to_string(&environment.config_path).unwrap(), config);
}

fn code_of(output: &str) -> String {
    let after = output.split("&enroll=").nth(1).unwrap();
    after.split('&').next().unwrap().to_owned()
}

#[tokio::test]
async fn a_server_already_answering_is_left_running() {
    let sandbox = Sandbox::new("running");
    let runner = working_runner();
    let environment = sandbox.environment(&runner, Platform::Linux);
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut stream, _)) = listener.accept().await {
            let mut buffer = [0u8; 512];
            let _ = stream.read(&mut buffer).await;
            let body = r#"{"protocol":[1]}"#;
            let reply = format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
            let _ = stream.write_all(reply.as_bytes()).await;
        }
    });
    write_config(&environment.config_path, &sandbox.root.join("music"), port, environment.data_dir.as_deref()).unwrap();
    let mut terminal = ScriptedTerminal::silent();
    execute(&environment, &mut terminal, sandbox.args(port)).await.unwrap();
    assert!(terminal.output.contains(&format!("Starting the server on port {port}... already running.")), "{}", terminal.output);
    assert!(!runner.calls.borrow().iter().any(|call| call.starts_with("systemctl")));
}

#[tokio::test]
async fn a_system_without_a_service_manager_says_so_and_still_enrolls() {
    let sandbox = Sandbox::new("windows");
    let runner = working_runner();
    let environment = sandbox.environment(&runner, Platform::Other);
    let mut terminal = ScriptedTerminal::silent();
    execute(&environment, &mut terminal, sandbox.args(free_port().await)).await.unwrap();
    assert!(terminal.output.contains("Service install is not available on this system yet; run `flaccy-server serve`."), "{}", terminal.output);
    assert!(terminal.output.contains("flaccy://server?url="));
    assert!(!terminal.output.contains("Keeping it running"));
}

#[tokio::test]
async fn an_interactive_run_asks_the_questions_in_order() {
    let sandbox = Sandbox::new("asks");
    let runner = working_runner();
    let environment = sandbox.environment(&runner, Platform::Linux);
    let mut terminal = ScriptedTerminal::interactive(&[sandbox.root.join("music").to_str().unwrap(), "Marcus", "n"]);
    let args = SetupArgs { yes: false, music: None, name: None, port: Some(free_port().await) };
    execute(&environment, &mut terminal, args).await.unwrap();
    let out = &terminal.output;
    assert!(out.contains("Where is your music? [~/Music] "), "{out}");
    assert!(out.contains("Your name on this server? [marcus] "), "{out}");
    assert!(out.contains("Keep it running after you log out? [Y/n] "), "{out}");
    assert!(out.contains("Keeping it running after you log out... skipped."), "{out}");
}

#[test]
fn a_ready_server_says_where_the_music_shows_up_and_a_mac_adds_the_firewall_hint() {
    let sandbox = Sandbox::new("readiness");
    let config = Config {
        music_folder: sandbox.root.join("music"),
        address: "127.0.0.1".to_owned(),
        port: 4545,
        data_dir: Some(sandbox.root.join("data")),
        behind_proxy: false,
        mode: crate::config::Mode::Easy,
        lastfm: Default::default(),
        hosts: Vec::new(),
        backup_dir: None,
    };
    let mut mac = ScriptedTerminal::silent();
    report_readiness(&mut mac, &config, Platform::MacOs, true);
    assert!(mac.output.contains("ready.") && mac.output.contains("shows up in Flaccy as it is found"), "{}", mac.output);
    assert!(mac.output.contains("choose Allow"), "{}", mac.output);
    let mut linux = ScriptedTerminal::silent();
    report_readiness(&mut linux, &config, Platform::Linux, true);
    assert!(linux.output.contains("shows up in Flaccy as it is found") && !linux.output.contains("Allow"), "{}", linux.output);
    let mut waiting = ScriptedTerminal::silent();
    report_readiness(&mut waiting, &config, Platform::MacOs, false);
    assert!(waiting.output.contains("started, but not answering yet.") && !waiting.output.contains("Allow"), "{}", waiting.output);
}
