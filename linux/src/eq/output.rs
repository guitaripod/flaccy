//! Follows the default audio sink so a profile can follow the headphones.
//!
//! A thread runs `pactl subscribe` (PipeWire's pulse server answers it too),
//! and on any sink or server event reads the default sink back and reports it
//! when it changed. Without `pactl` the equalizer simply never learns an
//! output, and the default profile applies.

use serde_json::Value;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OutputKind {
    Speaker,
    Headphones,
    Bluetooth,
    Usb,
    Display,
    Other,
}

/// Where Flaccy's sound is going: a stable identity to remember a profile
/// against, and a name and kind to show.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Output {
    pub id: String,
    pub name: String,
    pub kind: OutputKind,
}

/// How long events must stay quiet before the sink is read again, because one
/// volume drag raises a burst of them.
const SETTLE: Duration = Duration::from_millis(250);
/// How long to wait before subscribing again after the audio server went away.
const RESUBSCRIBE_DELAY: Duration = Duration::from_secs(3);

/// Starts the watcher thread. The first message is the output at launch, `None`
/// when none is known; later ones arrive only when the output changed.
pub fn watch() -> async_channel::Receiver<Option<Output>> {
    let (sender, receiver) = async_channel::unbounded();
    let spawned = std::thread::Builder::new()
        .name("flaccy-eq-output".into())
        .spawn(move || {
            let mut last: Option<Option<Output>> = None;
            let mut announce = |current: Option<Output>| -> bool {
                if last.as_ref() == Some(&current) {
                    return true;
                }
                last = Some(current.clone());
                sender.send_blocking(current).is_ok()
            };
            if !announce(read_default_output()) {
                return;
            }
            loop {
                let Some(events) = subscribe() else {
                    return;
                };
                while events.recv().is_ok() {
                    while events.recv_timeout(SETTLE).is_ok() {}
                    if !announce(read_default_output()) {
                        return;
                    }
                }
                std::thread::sleep(RESUBSCRIBE_DELAY);
                if !announce(read_default_output()) {
                    return;
                }
            }
        });
    if spawned.is_err() {
        crate::logger::warn("playback", "equalizer output watcher could not start");
    }
    receiver
}

/// Runs `pactl subscribe` and forwards each sink or server event line. `None`
/// when `pactl` is not installed.
fn subscribe() -> Option<mpsc::Receiver<()>> {
    let mut child = Command::new("pactl")
        .arg("subscribe")
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let stdout = child.stdout.take()?;
    let (sender, receiver) = mpsc::channel();
    std::thread::Builder::new()
        .name("flaccy-eq-pactl".into())
        .spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if is_output_event(&line) && sender.send(()).is_err() {
                    break;
                }
            }
            let _ = child.kill();
            let _ = child.wait();
        })
        .ok()?;
    Some(receiver)
}

/// Whether a `pactl subscribe` line can change which sink is the default or
/// how it presents itself.
fn is_output_event(line: &str) -> bool {
    line.contains(" on sink #") || line.contains(" on server")
}

fn pactl(arguments: &[&str]) -> Option<String> {
    let output = Command::new("pactl")
        .args(arguments)
        .env("LC_ALL", "C")
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .output()
        .ok()?;
    output
        .status
        .success()
        .then(|| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// The default sink as the equalizer sees it, or `None` when `pactl` is missing
/// or the server has no default.
pub fn read_default_output() -> Option<Output> {
    let default = pactl(&["get-default-sink"])?.trim().to_string();
    if default.is_empty() {
        return None;
    }
    let details = pactl(&["--format=json", "list", "sinks"])
        .and_then(|text| parse_sinks_json(&text, &default))
        .or_else(|| pactl(&["list", "sinks"]).and_then(|text| parse_sinks_text(&text, &default)));
    Some(details.unwrap_or_else(|| Output {
        kind: classify(&default, None, None, None),
        id: default.clone(),
        name: default,
    }))
}

/// The rate the sink called `id` runs at, as `pactl` reports it, or `None`
/// when `pactl` is missing or does not say. It runs a process, so call it off
/// the main thread.
pub fn sink_sample_rate(id: &str) -> Option<u32> {
    let text = pactl(&["--format=json", "list", "sinks"])?;
    sample_rate_from_sinks_json(&text, id)
}

fn sample_rate_from_sinks_json(text: &str, id: &str) -> Option<u32> {
    let sinks: Value = serde_json::from_str(text).ok()?;
    let specification = sinks
        .as_array()?
        .iter()
        .find(|sink| sink.get("name").and_then(Value::as_str) == Some(id))?
        .get("sample_specification")?
        .as_str()?;
    sample_rate_from_specification(specification)
}

/// The rate in a sample specification such as "s32le 2ch 48000Hz".
fn sample_rate_from_specification(specification: &str) -> Option<u32> {
    specification
        .split_whitespace()
        .find_map(|part| part.strip_suffix("Hz")?.parse().ok())
        .filter(|rate| *rate > 0)
}

fn parse_sinks_json(text: &str, default: &str) -> Option<Output> {
    let sinks: Value = serde_json::from_str(text).ok()?;
    let sink = sinks
        .as_array()?
        .iter()
        .find(|sink| sink.get("name").and_then(Value::as_str) == Some(default))?;
    let property = |key: &str| {
        sink.get("properties")
            .and_then(|properties| properties.get(key))
            .and_then(Value::as_str)
    };
    let description = sink
        .get("description")
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .unwrap_or(default);
    let active_port = sink.get("active_port").and_then(Value::as_str);
    Some(Output {
        id: default.to_string(),
        name: description.to_string(),
        kind: classify(default, property("device.bus"), property("device.form_factor"), active_port),
    })
}

fn parse_sinks_text(text: &str, default: &str) -> Option<Output> {
    let mut sections = text.split("\nSink #");
    let section = sections.find(|section| {
        section
            .lines()
            .any(|line| line.trim().strip_prefix("Name:").map(str::trim) == Some(default))
    })?;
    let value_after = |prefix: &str| {
        section
            .lines()
            .find_map(|line| line.trim().strip_prefix(prefix))
            .map(|rest| rest.trim().trim_matches('"').to_string())
    };
    let name = value_after("Description:").filter(|text| !text.is_empty());
    let bus = value_after("device.bus =");
    let form_factor = value_after("device.form_factor =");
    let port = value_after("Active Port:");
    Some(Output {
        id: default.to_string(),
        name: name.unwrap_or_else(|| default.to_string()),
        kind: classify(default, bus.as_deref(), form_factor.as_deref(), port.as_deref()),
    })
}

/// Picks the kind a sink is shown as. The bus decides first because a USB
/// headset is still a USB device; the form factor and the active port tell the
/// built-in speakers from the headphone jack.
pub fn classify(
    name: &str,
    bus: Option<&str>,
    form_factor: Option<&str>,
    active_port: Option<&str>,
) -> OutputKind {
    let lowered = name.to_lowercase();
    let bus = bus.map(str::to_lowercase);
    if bus.as_deref() == Some("bluetooth") || lowered.starts_with("bluez_") {
        return OutputKind::Bluetooth;
    }
    if bus.as_deref() == Some("usb") {
        return OutputKind::Usb;
    }
    if lowered.contains("hdmi") || lowered.contains("displayport") {
        return OutputKind::Display;
    }
    let form_factor = form_factor.map(str::to_lowercase);
    let port = active_port.map(str::to_lowercase);
    let is_headphones = matches!(form_factor.as_deref(), Some("headphone") | Some("headset"))
        || port
            .as_deref()
            .is_some_and(|port| port.contains("headphone") || port.contains("headset"));
    if is_headphones {
        OutputKind::Headphones
    } else if name.is_empty() {
        OutputKind::Other
    } else {
        OutputKind::Speaker
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_bus_beats_the_form_factor() {
        assert_eq!(
            classify("bluez_output.AA", Some("bluetooth"), Some("headset"), None),
            OutputKind::Bluetooth
        );
        assert_eq!(
            classify("alsa_output.usb-X", Some("usb"), Some("headphone"), None),
            OutputKind::Usb
        );
        assert_eq!(
            classify("alsa_output.pci.hdmi-stereo", Some("pci"), None, None),
            OutputKind::Display
        );
        assert_eq!(
            classify("alsa_output.pci.analog", Some("pci"), Some("headphone"), None),
            OutputKind::Headphones
        );
        assert_eq!(
            classify("alsa_output.pci.analog", None, None, Some("analog-output-headphones")),
            OutputKind::Headphones
        );
        assert_eq!(classify("alsa_output.pci.analog", None, None, None), OutputKind::Speaker);
    }

    #[test]
    fn json_listing_names_the_default_sink() {
        let text = r#"[
          {"name":"other","description":"Other","properties":{}},
          {"name":"alsa_output.usb-Focusrite","description":"Scarlett Solo","active_port":"analog-output",
           "properties":{"device.bus":"usb"}}
        ]"#;
        let output = parse_sinks_json(text, "alsa_output.usb-Focusrite").expect("found");
        assert_eq!(output.name, "Scarlett Solo");
        assert_eq!(output.kind, OutputKind::Usb);
        assert!(parse_sinks_json(text, "missing").is_none());
    }

    #[test]
    fn text_listing_is_the_fallback() {
        let text = "Sink #1\n\tName: first\n\tDescription: First\n\nSink #2\n\tName: bluez_output.X\n\tDescription: AirPods\n\tActive Port: headset-output\n\tProperties:\n\t\tdevice.bus = \"bluetooth\"\n\t\tdevice.form_factor = \"headset\"\n";
        let output = parse_sinks_text(text, "bluez_output.X").expect("found");
        assert_eq!(output.name, "AirPods");
        assert_eq!(output.kind, OutputKind::Bluetooth);
    }

    #[test]
    fn the_sample_rate_comes_from_the_named_sinks_specification() {
        let json = r#"[
            {"name": "hdmi", "sample_specification": "s16le 2ch 44100Hz"},
            {"name": "usb", "sample_specification": "s32le 2ch 96000Hz"},
            {"name": "odd", "sample_specification": "unknown"}
        ]"#;
        assert_eq!(sample_rate_from_sinks_json(json, "usb"), Some(96_000));
        assert_eq!(sample_rate_from_sinks_json(json, "hdmi"), Some(44_100));
        assert_eq!(sample_rate_from_sinks_json(json, "odd"), None);
        assert_eq!(sample_rate_from_sinks_json(json, "missing"), None);
        assert_eq!(sample_rate_from_specification("float32le 2ch 0Hz"), None);
    }

    #[test]
    fn only_sink_and_server_events_count() {
        assert!(is_output_event("Event 'change' on sink #3"));
        assert!(is_output_event("Event 'change' on server #-1"));
        assert!(!is_output_event("Event 'new' on sink-input #12"));
        assert!(!is_output_event("Event 'change' on source #4"));
    }
}
