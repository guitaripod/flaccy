//! Keeping the server running without a terminal: a systemd user unit on Linux, a launchd agent on macOS.

use std::path::{Path, PathBuf};

use crate::runner::{RunError, Runner};

/// The unit's file name, and what `setup` calls the service.
pub const UNIT_NAME: &str = "flaccy-server.service";
/// The launchd label and the plist's base name.
pub const LAUNCHD_LABEL: &str = "cc.midgarcorp.flaccy-server";
/// What a platform without a service manager is told.
pub const UNSUPPORTED_MESSAGE: &str = "Service install is not available on this system yet; run `flaccy-server serve`";

const LAUNCHD_PATH: &str = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";

/// The operating systems with a service manager this module can drive.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Platform {
    /// systemd user units.
    Linux,
    /// launchd agents.
    MacOs,
    /// Nothing to install into.
    Other,
}

impl Platform {
    /// The platform this binary runs on.
    pub fn current() -> Self {
        match std::env::consts::OS {
            "linux" => Self::Linux,
            "macos" => Self::MacOs,
            _ => Self::Other,
        }
    }
}

/// What to run: this program, `serve`, and a configuration file when it is not the default one.
#[derive(Clone, Debug)]
pub struct ServiceSpec {
    /// The `flaccy-server` binary.
    pub executable: PathBuf,
    /// The configuration file, passed as `--config` unless `None`.
    pub config: Option<PathBuf>,
    /// Where the log of a launchd agent goes.
    pub log: PathBuf,
}

/// Where the files go and who the current user is.
#[derive(Clone, Debug)]
pub struct ServiceHome {
    /// `~/.config`, where `systemd/user` lives.
    pub config_dir: PathBuf,
    /// The home folder, where `Library/LaunchAgents` lives.
    pub home: PathBuf,
}

/// What was installed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Installed {
    /// The service's name for the person: `flaccy-server.service` or the launchd label.
    pub name: String,
    /// The unit or plist file.
    pub file: PathBuf,
}

/// Why the service could not be installed or started.
#[derive(Debug, PartialEq, Eq)]
pub enum ServiceError {
    /// This system has no service manager to install into.
    Unsupported(String),
    /// The service manager refused a step.
    Manager(String),
}

impl std::fmt::Display for ServiceError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unsupported(message) | Self::Manager(message) => formatter.write_str(message),
        }
    }
}

fn quote_exec(argument: &str) -> String {
    if argument.chars().any(|c| c.is_whitespace() || matches!(c, '"' | '\\' | '$' | '%')) {
        format!("\"{}\"", argument.replace('\\', "\\\\").replace('"', "\\\"").replace('$', "$$").replace('%', "%%"))
    } else {
        argument.to_owned()
    }
}

fn arguments(spec: &ServiceSpec) -> Vec<String> {
    let mut list = vec![spec.executable.display().to_string()];
    if let Some(config) = &spec.config {
        list.push("--config".to_owned());
        list.push(config.display().to_string());
    }
    list.push("serve".to_owned());
    list
}

/// The systemd user unit.
pub fn unit_file(spec: &ServiceSpec) -> String {
    let command: Vec<String> = arguments(spec).iter().map(|argument| quote_exec(argument)).collect();
    format!(
        "[Unit]\nDescription=Flaccy Server\nAfter=network-online.target tailscaled.service\nWants=network-online.target\n\n[Service]\nExecStart={}\nRestart=on-failure\nRestartSec=5\nLimitNOFILE=65536\nNoNewPrivileges=yes\n\n[Install]\nWantedBy=default.target\n",
        command.join(" ")
    )
}

fn xml_escape(text: &str) -> String {
    text.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The launchd agent.
pub fn plist_file(spec: &ServiceSpec) -> String {
    let program: String = arguments(spec).iter().map(|argument| format!("        <string>{}</string>\n", xml_escape(argument))).collect();
    let log = xml_escape(&spec.log.display().to_string());
    format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n    <key>Label</key>\n    <string>{LAUNCHD_LABEL}</string>\n    <key>ProgramArguments</key>\n    <array>\n{program}    </array>\n    <key>EnvironmentVariables</key>\n    <dict>\n        <key>PATH</key>\n        <string>{LAUNCHD_PATH}</string>\n    </dict>\n    <key>RunAtLoad</key>\n    <true/>\n    <key>KeepAlive</key>\n    <true/>\n    <key>StandardOutPath</key>\n    <string>{log}</string>\n    <key>StandardErrorPath</key>\n    <string>{log}</string>\n</dict>\n</plist>\n"
    )
}

/// Writes `content` unless the file already holds it; true when it replaced an older file.
fn write_changed(path: &Path, content: &str) -> Result<bool, ServiceError> {
    let existing = std::fs::read_to_string(path).ok();
    if existing.as_deref() == Some(content) {
        return Ok(false);
    }
    let write = || -> std::io::Result<()> {
        std::fs::create_dir_all(path.parent().unwrap_or(Path::new(".")))?;
        std::fs::write(path, content)
    };
    write().map_err(|error| ServiceError::Manager(format!("Could not write {}: {error}. Make the folder writable, or run `flaccy-server serve` yourself.", path.display())))?;
    Ok(existing.is_some())
}

fn step(runner: &dyn Runner, program: &str, args: &[&str]) -> Result<(), ServiceError> {
    let shown = format!("{program} {}", args.join(" "));
    match runner.run(program, args) {
        Ok(output) if output.success => Ok(()),
        Ok(output) => {
            let reason = output.stderr.lines().next().unwrap_or("it failed").trim().to_owned();
            Err(ServiceError::Manager(format!("`{shown}` failed: {reason}. Run `flaccy-server serve` yourself, or fix that and run setup again.")))
        }
        Err(RunError::NotFound) => Err(ServiceError::Unsupported(format!("{program} is not installed, so the server cannot be kept running for you; run `flaccy-server serve`"))),
        Err(RunError::Failed(reason)) => Err(ServiceError::Manager(format!("`{shown}` did not run: {reason}."))),
    }
}

/// Writes the unit, enables it and starts it; restarts it when it replaced an older unit that was running.
pub fn install_systemd(runner: &dyn Runner, home: &ServiceHome, spec: &ServiceSpec) -> Result<Installed, ServiceError> {
    let file = home.config_dir.join("systemd").join("user").join(UNIT_NAME);
    let replaced = write_changed(&file, &unit_file(spec))?;
    step(runner, "systemctl", &["--user", "daemon-reload"])?;
    step(runner, "systemctl", &["--user", "enable", "--now", UNIT_NAME])?;
    if replaced {
        step(runner, "systemctl", &["--user", "restart", UNIT_NAME])?;
    }
    Ok(Installed { name: UNIT_NAME.to_owned(), file })
}

/// Writes the agent and starts it.
pub fn install_launchd(runner: &dyn Runner, home: &ServiceHome, spec: &ServiceSpec) -> Result<Installed, ServiceError> {
    let file = home.home.join("Library").join("LaunchAgents").join(format!("{LAUNCHD_LABEL}.plist"));
    write_changed(&file, &plist_file(spec))?;
    let uid = runner
        .run("id", &["-u"])
        .ok()
        .map(|output| output.stdout.trim().to_owned())
        .filter(|uid| !uid.is_empty() && uid.bytes().all(|b| b.is_ascii_digit()))
        .ok_or_else(|| ServiceError::Manager("Could not find your user id with `id -u`; run `flaccy-server serve` yourself.".to_owned()))?;
    let domain = format!("gui/{uid}");
    let target = format!("{domain}/{LAUNCHD_LABEL}");
    let _ = runner.run("launchctl", &["bootout", &target]);
    step(runner, "launchctl", &["bootstrap", &domain, &file.display().to_string()])?;
    step(runner, "launchctl", &["kickstart", "-k", &target])?;
    Ok(Installed { name: LAUNCHD_LABEL.to_owned(), file })
}

/// Installs and starts the service for `platform`.
pub fn install(platform: Platform, runner: &dyn Runner, home: &ServiceHome, spec: &ServiceSpec) -> Result<Installed, ServiceError> {
    match platform {
        Platform::Linux => install_systemd(runner, home, spec),
        Platform::MacOs => install_launchd(runner, home, spec),
        Platform::Other => Err(ServiceError::Unsupported(UNSUPPORTED_MESSAGE.to_owned())),
    }
}

/// Whether `loginctl` says this user's services outlive their login.
pub fn linger_enabled(runner: &dyn Runner, user: &str) -> bool {
    runner
        .run("loginctl", &["show-user", user, "--property=Linger"])
        .ok()
        .is_some_and(|output| output.stdout.trim() == "Linger=yes")
}

/// Lets the user's services run after they log out.
pub fn enable_linger(runner: &dyn Runner, user: &str) -> Result<(), ServiceError> {
    step(runner, "loginctl", &["enable-linger", user])
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runner::fake::FakeRunner;

    fn spec(config: Option<&str>) -> ServiceSpec {
        ServiceSpec {
            executable: PathBuf::from("/home/me/.cargo/bin/flaccy-server"),
            config: config.map(PathBuf::from),
            log: PathBuf::from("/home/me/Library/Logs/flaccy-server.log"),
        }
    }

    fn home(root: &Path) -> ServiceHome {
        ServiceHome { config_dir: root.join(".config"), home: root.to_path_buf() }
    }

    fn scratch(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("flaccy-service-{label}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        path
    }

    #[test]
    fn the_unit_runs_serve_and_quotes_awkward_paths() {
        let plain = unit_file(&spec(None));
        assert!(plain.contains("ExecStart=/home/me/.cargo/bin/flaccy-server serve\n"));
        assert!(plain.contains("WantedBy=default.target") && plain.contains("Restart=on-failure"));
        let custom = unit_file(&spec(Some("/home/me/My Music/config.toml")));
        assert!(custom.contains("ExecStart=/home/me/.cargo/bin/flaccy-server --config \"/home/me/My Music/config.toml\" serve\n"));
    }

    #[test]
    fn the_plist_escapes_and_keeps_the_server_alive() {
        let plist = plist_file(&spec(Some("/Users/me/a&b/config.toml")));
        assert!(plist.contains("<string>cc.midgarcorp.flaccy-server</string>"));
        assert!(plist.contains("<string>/Users/me/a&amp;b/config.toml</string>"));
        assert!(plist.contains("<key>KeepAlive</key>\n    <true/>") && plist.contains("/opt/homebrew/bin"));
    }

    #[test]
    fn systemd_install_writes_the_unit_then_enables_and_restarts_only_a_replaced_unit() {
        let root = scratch("systemd");
        let runner = FakeRunner::default().on("systemctl", FakeRunner::ok(""));
        let installed = install(Platform::Linux, &runner, &home(&root), &spec(None)).unwrap();
        assert_eq!(installed.name, "flaccy-server.service");
        assert!(installed.file.ends_with(".config/systemd/user/flaccy-server.service"));
        assert_eq!(std::fs::read_to_string(&installed.file).unwrap(), unit_file(&spec(None)));
        assert_eq!(
            runner.calls.borrow().as_slice(),
            ["systemctl --user daemon-reload", "systemctl --user enable --now flaccy-server.service"]
        );
        let again = FakeRunner::default().on("systemctl", FakeRunner::ok(""));
        install(Platform::Linux, &again, &home(&root), &spec(None)).unwrap();
        assert!(!again.calls.borrow().iter().any(|call| call.contains("restart")));
        let moved = FakeRunner::default().on("systemctl", FakeRunner::ok(""));
        install(Platform::Linux, &moved, &home(&root), &spec(Some("/elsewhere/config.toml"))).unwrap();
        assert_eq!(moved.calls.borrow().last().unwrap(), "systemctl --user restart flaccy-server.service");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_missing_or_broken_systemctl_is_reported_with_the_way_out() {
        let root = scratch("nosystemd");
        let missing = install(Platform::Linux, &FakeRunner::default(), &home(&root), &spec(None)).unwrap_err();
        assert!(matches!(&missing, ServiceError::Unsupported(text) if text.contains("flaccy-server serve")));
        let broken = FakeRunner::default().on("systemctl", FakeRunner::fails("Failed to connect to bus: No medium found\n"));
        let error = install(Platform::Linux, &broken, &home(&root), &spec(None)).unwrap_err();
        assert!(matches!(&error, ServiceError::Manager(text) if text.contains("Failed to connect to bus")));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn launchd_install_boots_out_bootstraps_and_kickstarts() {
        let root = scratch("launchd");
        let runner = FakeRunner::default().on("id -u", FakeRunner::ok("501\n")).on("launchctl", FakeRunner::ok(""));
        let installed = install(Platform::MacOs, &runner, &home(&root), &spec(None)).unwrap();
        assert!(installed.file.ends_with("Library/LaunchAgents/cc.midgarcorp.flaccy-server.plist"));
        let calls = runner.calls.borrow();
        assert_eq!(calls[1], "launchctl bootout gui/501/cc.midgarcorp.flaccy-server");
        assert!(calls[2].starts_with("launchctl bootstrap gui/501 ") && calls[2].ends_with(".plist"));
        assert_eq!(calls[3], "launchctl kickstart -k gui/501/cc.midgarcorp.flaccy-server");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn other_systems_get_the_documented_sentence() {
        let error = install(Platform::Other, &FakeRunner::default(), &home(Path::new("/x")), &spec(None)).unwrap_err();
        assert_eq!(error.to_string(), "Service install is not available on this system yet; run `flaccy-server serve`");
    }

    #[test]
    fn linger_is_read_from_loginctl_and_enabled_when_missing() {
        let on = FakeRunner::default().on("loginctl show-user", FakeRunner::ok("Linger=yes\n"));
        let off = FakeRunner::default().on("loginctl show-user", FakeRunner::ok("Linger=no\n")).on("loginctl enable-linger", FakeRunner::ok(""));
        assert!(linger_enabled(&on, "me"));
        assert!(!linger_enabled(&off, "me"));
        enable_linger(&off, "me").unwrap();
        assert_eq!(off.calls.borrow().last().unwrap(), "loginctl enable-linger me");
    }
}
