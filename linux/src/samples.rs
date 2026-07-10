use crate::app::AppCore;
use crate::events::AppEvent;
use gtk::glib;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

const BASE_URL: &str = "https://flaccy-api.midgarcorp.cc/v1/samples";

enum SampleEvent {
    Progress(String),
    Done(usize),
    Failed(String),
}

/// Downloads the free CC0 sample album from flaccy-api into the library root
/// (empty-library onboarding), then triggers a rescan.
pub fn download(core: &Rc<AppCore>) {
    if core.sample_in_flight.get() {
        return;
    }
    core.sample_in_flight.set(true);
    core.hub.emit(&AppEvent::SampleDownload {
        text: "Fetching sample album…".to_string(),
        done: false,
        failed: false,
    });

    let root = core.music_root();
    let (tx, rx) = async_channel::unbounded::<SampleEvent>();
    std::thread::Builder::new()
        .name("flaccy-samples".into())
        .spawn(move || run_download(&root, tx))
        .ok();

    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        while let Ok(event) = rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            match event {
                SampleEvent::Progress(text) => {
                    core.hub.emit(&AppEvent::SampleDownload {
                        text,
                        done: false,
                        failed: false,
                    });
                }
                SampleEvent::Done(count) => {
                    core.sample_in_flight.set(false);
                    core.hub.emit(&AppEvent::SampleDownload {
                        text: format!("Sample album added ({count} tracks)"),
                        done: true,
                        failed: false,
                    });
                    core.rescan();
                    break;
                }
                SampleEvent::Failed(message) => {
                    core.sample_in_flight.set(false);
                    crate::logger::error("samples", &format!("sample download failed: {message}"));
                    core.hub.emit(&AppEvent::SampleDownload {
                        text: "Sample download failed. Check your connection.".to_string(),
                        done: true,
                        failed: true,
                    });
                    break;
                }
            }
        }
    });
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(300))
        .user_agent("flaccy/1.0 (https://github.com/guitaripod/flaccy)")
        .build()
}

fn run_download(root: &Path, tx: async_channel::Sender<SampleEvent>) {
    let manifest = match fetch_manifest() {
        Ok(manifest) => manifest,
        Err(message) => {
            let _ = tx.send_blocking(SampleEvent::Failed(message));
            return;
        }
    };
    let total = manifest.len();
    if total == 0 {
        let _ = tx.send_blocking(SampleEvent::Failed("empty manifest".to_string()));
        return;
    }
    let target_dir = root.join("Flaccy Samples");
    if let Err(err) = std::fs::create_dir_all(&target_dir) {
        let _ = tx.send_blocking(SampleEvent::Failed(format!("mkdir failed: {err}")));
        return;
    }
    for (index, file) in manifest.iter().enumerate() {
        let destination = target_dir.join(sanitize(file));
        if destination.exists() {
            continue;
        }
        let _ = tx.send_blocking(SampleEvent::Progress(format!(
            "Downloading {} of {total}…",
            index + 1
        )));
        if let Err(message) = download_file(file, &destination) {
            let _ = tx.send_blocking(SampleEvent::Failed(message));
            return;
        }
    }
    let _ = tx.send_blocking(SampleEvent::Progress("Adding to library…".to_string()));
    let _ = tx.send_blocking(SampleEvent::Done(total));
}

fn fetch_manifest() -> Result<Vec<String>, String> {
    let response = agent().get(BASE_URL).call().map_err(|e| format!("{e}"))?;
    let text = response.into_string().map_err(|e| format!("{e}"))?;
    let json: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("{e}"))?;
    let tracks = json["tracks"]
        .as_array()
        .ok_or_else(|| "manifest missing tracks".to_string())?;
    Ok(tracks
        .iter()
        .filter_map(|t| t["file"].as_str().map(String::from))
        .collect())
}

fn download_file(file: &str, destination: &PathBuf) -> Result<(), String> {
    let url = format!("{BASE_URL}/{file}");
    let response = agent().get(&url).call().map_err(|e| format!("{e}"))?;
    let mut data = Vec::new();
    response
        .into_reader()
        .take(500 * 1024 * 1024)
        .read_to_end(&mut data)
        .map_err(|e| format!("{e}"))?;
    if data.is_empty() {
        return Err(format!("empty file {file}"));
    }
    let temp = destination.with_extension("part");
    std::fs::write(&temp, &data).map_err(|e| format!("{e}"))?;
    std::fs::rename(&temp, destination).map_err(|e| format!("{e}"))?;
    crate::logger::info(
        "samples",
        &format!("downloaded {file} ({} bytes)", data.len()),
    );
    Ok(())
}

fn sanitize(file: &str) -> String {
    file.rsplit('/').next().unwrap_or(file).to_string()
}
