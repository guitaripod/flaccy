use crate::app::AppCore;
use crate::events::AppEvent;
use crate::library::Track;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

const BASE_URL: &str = "https://flaccy-api.midgarcorp.cc/v1/samples";
const SAMPLE_DIR: &str = "Flaccy Samples";

enum SampleEvent {
    Manifest(Vec<String>),
    Progress(String),
    Landed,
    Done(usize),
    Failed(String),
}

/// One download, from the tap to the last file joining the queue. The album
/// starts playing as soon as its first file is in the library and the rest
/// are appended as they land — the same behavior as the Apple clients'
/// `SampleMusicService`, because the sample exists to be heard.
struct Session {
    order: RefCell<Vec<String>>,
    started_playback: Cell<bool>,
    rescan_wanted: Cell<bool>,
    finished: Cell<bool>,
}

/// Downloads the free CC0 sample album from flaccy-api into the library root
/// (empty-library onboarding), rescanning after every file so playback can
/// begin before the whole album is down.
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

    let session = Rc::new(Session {
        order: RefCell::new(Vec::new()),
        started_playback: Cell::new(false),
        rescan_wanted: Cell::new(false),
        finished: Cell::new(false),
    });
    follow_library(core, &session);

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
                SampleEvent::Manifest(order) => {
                    *session.order.borrow_mut() = order;
                }
                SampleEvent::Progress(text) => {
                    core.hub.emit(&AppEvent::SampleDownload {
                        text,
                        done: false,
                        failed: false,
                    });
                }
                SampleEvent::Landed => request_rescan(&core, &session),
                SampleEvent::Done(count) => {
                    core.sample_in_flight.set(false);
                    session.finished.set(true);
                    core.hub.emit(&AppEvent::SampleDownload {
                        text: format!("Sample album added ({count} tracks)"),
                        done: true,
                        failed: false,
                    });
                    break;
                }
                SampleEvent::Failed(message) => {
                    core.sample_in_flight.set(false);
                    session.finished.set(true);
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

/// A file that lands while a scan is already running would be missed by it,
/// and `rescan` ignores a call made mid-scan, so the request is remembered and
/// replayed when that scan finishes.
fn request_rescan(core: &Rc<AppCore>, session: &Session) {
    if core.scanning.get() {
        session.rescan_wanted.set(true);
    } else {
        core.rescan();
    }
}

/// Watches reloads for the album's arrivals, and lets go once the download is
/// over and every file it fetched is in the library.
fn follow_library(core: &Rc<AppCore>, session: &Rc<Session>) {
    let weak = Rc::downgrade(core);
    let session = Rc::clone(session);
    core.hub.subscribe(move |event| {
        let Some(core) = weak.upgrade() else {
            return false;
        };
        match event {
            AppEvent::ScanFinished { .. } => {
                if session.rescan_wanted.replace(false) {
                    core.rescan();
                }
                true
            }
            AppEvent::LibraryReloaded => {
                let order = session.order.borrow().clone();
                let tracks = sample_tracks(&core, &order);
                on_arrivals(&core, &session, tracks.clone());
                !(session.finished.get() && tracks.len() >= order.len())
            }
            AppEvent::SampleDownload { failed: true, .. } => false,
            _ => true,
        }
    });
}

/// Starts the album on its first arrival unless something else is already
/// playing, then appends later arrivals only while the queue is still the
/// sample album, so someone who has moved on to their own music never finds
/// Bach tacked onto it.
fn on_arrivals(core: &Rc<AppCore>, session: &Session, tracks: Vec<Track>) {
    if tracks.is_empty() {
        return;
    }
    if !session.started_playback.replace(true) {
        if !core.player.is_playing() {
            crate::logger::info("samples", "playing the sample album as it arrives");
            core.play_tracks(tracks, 0);
        }
        return;
    }
    let snapshot = core.player.queue_snapshot();
    if snapshot.queue.is_empty() || !snapshot.queue.iter().all(|t| is_sample(&t.rel_path)) {
        return;
    }
    let missing: Vec<Track> = tracks
        .into_iter()
        .filter(|t| !snapshot.queue.iter().any(|q| q.rel_path == t.rel_path))
        .collect();
    if !missing.is_empty() {
        crate::logger::info(
            "samples",
            &format!(
                "queued {} more sample tracks as they arrived",
                missing.len()
            ),
        );
    }
    core.player.append_tracks(missing);
}

fn is_sample(rel_path: &str) -> bool {
    Path::new(rel_path).parent() == Some(Path::new(SAMPLE_DIR))
}

/// The album's files present in the library, in album order rather than the
/// order they were downloaded in.
fn sample_tracks(core: &AppCore, order: &[String]) -> Vec<Track> {
    let position = |track: &Track| {
        let name = Path::new(&track.rel_path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or_default();
        order
            .iter()
            .position(|file| sanitize(file) == name)
            .unwrap_or(usize::MAX)
    };
    let mut tracks: Vec<Track> = core
        .library
        .borrow()
        .tracks
        .iter()
        .filter(|t| is_sample(&t.rel_path))
        .cloned()
        .collect();
    tracks.sort_by_key(position);
    tracks
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
    let _ = tx.send_blocking(SampleEvent::Manifest(manifest.clone()));
    let target_dir = root.join(SAMPLE_DIR);
    if let Err(err) = std::fs::create_dir_all(&target_dir) {
        let _ = tx.send_blocking(SampleEvent::Failed(format!("mkdir failed: {err}")));
        return;
    }
    let plan = smallest_first(&manifest);
    let total_bytes = plan.iter().map(|(_, bytes)| bytes).sum::<u64>().max(1);
    let mut landed_bytes = 0_u64;
    for (file, bytes) in plan {
        let destination = target_dir.join(sanitize(&file));
        if !destination.exists() {
            let baseline = landed_bytes;
            let report = |received: u64| {
                let _ = tx.send_blocking(SampleEvent::Progress(progress_line(
                    baseline + received,
                    total_bytes,
                )));
            };
            if let Err(message) = download_file(&file, &destination, report) {
                let _ = tx.send_blocking(SampleEvent::Failed(message));
                return;
            }
        }
        landed_bytes += bytes;
        let _ = tx.send_blocking(SampleEvent::Progress(progress_line(
            landed_bytes,
            total_bytes,
        )));
        let _ = tx.send_blocking(SampleEvent::Landed);
    }
    let _ = tx.send_blocking(SampleEvent::Done(total));
}

fn progress_line(received: u64, total: u64) -> String {
    let percent = (received.min(total) * 100) / total.max(1);
    format!("Downloading sample album… {percent}%")
}

/// Smallest file first, so the first sound comes after about 20 MB rather
/// than the Aria's 80. The Worker answers HEAD without a length and ignores
/// Range, so each size is read off a GET's headers and the body is dropped
/// unread; a file whose size cannot be read goes last.
fn smallest_first(manifest: &[String]) -> Vec<(String, u64)> {
    let mut sized: Vec<(String, u64)> = manifest
        .iter()
        .map(|file| (file.clone(), content_length(file).unwrap_or(0)))
        .collect();
    sized.sort_by_key(|(_, bytes)| if *bytes == 0 { u64::MAX } else { *bytes });
    sized
}

fn content_length(file: &str) -> Option<u64> {
    let response = agent().get(&format!("{BASE_URL}/{file}")).call().ok()?;
    response.header("Content-Length")?.parse().ok()
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

/// Streams the file to a `.part` beside its destination, reporting the bytes
/// received about once a percent, and only then gives it its real name.
fn download_file(file: &str, destination: &PathBuf, report: impl Fn(u64)) -> Result<(), String> {
    const LIMIT: u64 = 500 * 1024 * 1024;
    let url = format!("{BASE_URL}/{file}");
    let response = agent().get(&url).call().map_err(|e| format!("{e}"))?;
    let expected = response
        .header("Content-Length")
        .and_then(|v| v.parse::<u64>().ok())
        .unwrap_or(0);
    let step = (expected / 100).max(256 * 1024);
    let temp = destination.with_extension("part");
    let mut out = std::fs::File::create(&temp).map_err(|e| format!("{e}"))?;
    let mut reader = response.into_reader().take(LIMIT);
    let mut buffer = vec![0_u8; 64 * 1024];
    let mut received = 0_u64;
    let mut reported = 0_u64;
    loop {
        let read = reader.read(&mut buffer).map_err(|e| format!("{e}"))?;
        if read == 0 {
            break;
        }
        out.write_all(&buffer[..read]).map_err(|e| format!("{e}"))?;
        received += read as u64;
        if received - reported >= step {
            reported = received;
            report(received);
        }
    }
    out.flush().map_err(|e| format!("{e}"))?;
    drop(out);
    if received == 0 {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("empty file {file}"));
    }
    std::fs::rename(&temp, destination).map_err(|e| format!("{e}"))?;
    crate::logger::info("samples", &format!("downloaded {file} ({received} bytes)"));
    Ok(())
}

fn sanitize(file: &str) -> String {
    file.rsplit('/').next().unwrap_or(file).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_line_rounds_down_and_never_passes_one_hundred() {
        assert_eq!(progress_line(0, 200), "Downloading sample album… 0%");
        assert_eq!(progress_line(199, 200), "Downloading sample album… 99%");
        assert_eq!(progress_line(500, 200), "Downloading sample album… 100%");
    }

    #[test]
    fn only_files_directly_in_the_sample_folder_count_as_samples() {
        assert!(is_sample("Flaccy Samples/goldberg-01-aria.flac"));
        assert!(!is_sample("Bach/Flaccy Samples/goldberg-01-aria.flac"));
        assert!(!is_sample("goldberg-01-aria.flac"));
    }
}
