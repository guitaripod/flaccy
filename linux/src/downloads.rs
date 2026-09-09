use crate::app::AppCore;
use crate::db::{Db, DownloadRow};
use crate::events::AppEvent;
use gtk::glib;
use lofty::config::WriteOptions;
use lofty::file::TaggedFileExt;
use lofty::picture::{MimeType, Picture, PictureType};
use lofty::prelude::*;
use lofty::tag::Tag;
use std::cell::{Cell, RefCell};
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::sync::atomic::{AtomicI64, AtomicU32, Ordering};
use std::sync::Arc;

pub const STATUS_QUEUED: &str = "queued";
pub const STATUS_FETCHING: &str = "fetching";
pub const STATUS_DOWNLOADING: &str = "downloading";
pub const STATUS_DONE: &str = "done";
pub const STATUS_FAILED: &str = "failed";
pub const STATUS_CANCELLED: &str = "cancelled";

pub const KIND_LINK: &str = "link";
pub const KIND_TRACK: &str = "track";

const MAX_PLAYLIST_ITEMS: usize = 500;
const LIBRARY_SUBDIR: &str = "YouTube";

pub struct DownloadHandle {
    tx: RefCell<Option<async_channel::Sender<()>>>,
    current: Arc<CurrentJob>,
    rescan_pending: Cell<bool>,
}

/// Identifies the row and OS process the worker is currently running, so the
/// main thread can deliver a cancel to a live yt-dlp instead of only flagging
/// the database row.
struct CurrentJob {
    id: AtomicI64,
    pid: AtomicU32,
}

impl CurrentJob {
    fn set(&self, id: i64, pid: u32) {
        self.id.store(id, Ordering::SeqCst);
        self.pid.store(pid, Ordering::SeqCst);
    }

    fn clear(&self) {
        self.id.store(-1, Ordering::SeqCst);
        self.pid.store(0, Ordering::SeqCst);
    }

    fn pid_for(&self, id: i64) -> Option<u32> {
        if self.id.load(Ordering::SeqCst) != id {
            return None;
        }
        match self.pid.load(Ordering::SeqCst) {
            0 => None,
            pid => Some(pid),
        }
    }
}

impl DownloadHandle {
    pub fn new() -> Self {
        Self {
            tx: RefCell::new(None),
            current: Arc::new(CurrentJob {
                id: AtomicI64::new(-1),
                pid: AtomicU32::new(0),
            }),
            rescan_pending: Cell::new(false),
        }
    }

    fn wake(&self) {
        if let Some(tx) = self.tx.borrow().as_ref() {
            let _ = tx.send_blocking(());
        }
    }
}

pub struct ToolStatus {
    pub yt_dlp_version: Option<String>,
    pub ffmpeg: bool,
}

impl ToolStatus {
    pub fn ready(&self) -> bool {
        self.yt_dlp_version.is_some() && self.ffmpeg
    }
}

enum WorkerEvent {
    Changed,
    Progress {
        id: i64,
        fraction: f64,
    },
    Finished {
        title: String,
        artist: String,
        album: String,
    },
    Toast(String),
    Repaired(usize),
}

pub fn start(core: &Rc<AppCore>) {
    core.db.reset_interrupted_downloads();
    let (wake_tx, wake_rx) = async_channel::unbounded::<()>();
    let (event_tx, event_rx) = async_channel::unbounded::<WorkerEvent>();
    *core.downloads.tx.borrow_mut() = Some(wake_tx);

    let db_path = core.db_path.clone();
    let root = core.music_root();
    let current = Arc::clone(&core.downloads.current);
    std::thread::Builder::new()
        .name("flaccy-download".into())
        .spawn(move || worker(&db_path, &root, event_tx, wake_rx, current))
        .ok();

    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        while let Ok(event) = event_rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            match event {
                WorkerEvent::Changed => core.hub.emit(&AppEvent::DownloadsChanged),
                WorkerEvent::Progress { id, fraction } => {
                    core.hub.emit(&AppEvent::DownloadProgress { id, fraction });
                }
                WorkerEvent::Finished {
                    title,
                    artist,
                    album,
                } => {
                    core.hub.emit(&AppEvent::DownloadsChanged);
                    core.toast(&format!("Added {title} — {artist}"));
                    if core.scanning.get() {
                        core.downloads.rescan_pending.set(true);
                    } else {
                        core.rescan();
                    }
                    if !album.is_empty() && !artist.is_empty() {
                        crate::enrichment::request_album(&core, &album, &artist);
                    }
                }
                WorkerEvent::Toast(message) => core.toast(&message),
                WorkerEvent::Repaired(count) => {
                    core.hub.emit(&AppEvent::DownloadsChanged);
                    core.toast(&repair_summary(count));
                    if core.scanning.get() {
                        core.downloads.rescan_pending.set(true);
                    } else {
                        core.rescan();
                    }
                }
            }
        }
    });

    let weak = Rc::downgrade(core);
    core.hub.subscribe(move |event| {
        let Some(core) = weak.upgrade() else {
            return false;
        };
        if let AppEvent::ScanFinished { .. } = event {
            if core.downloads.rescan_pending.replace(false) {
                core.rescan();
            }
        }
        true
    });

    if core.db.active_download_count() > 0 {
        core.downloads.wake();
    }
}

pub fn enqueue(core: &Rc<AppCore>, raw: &str) {
    let Some(url) = normalize_url(raw) else {
        core.toast("That doesn't look like a link");
        return;
    };
    if core.db.has_active_download_url(&url) {
        core.toast("Already in the download queue");
        return;
    }
    match core.db.insert_download(&url) {
        Ok(_) => {
            crate::logger::info("downloads", &format!("queued {url}"));
            core.hub.emit(&AppEvent::DownloadsChanged);
            core.downloads.wake();
        }
        Err(err) => {
            crate::logger::error("downloads", &format!("enqueue failed: {err}"));
            core.toast("Could not add the download");
        }
    }
}

pub fn cancel(core: &Rc<AppCore>, id: i64) {
    core.db.set_download_status(id, STATUS_CANCELLED, None);
    if let Some(pid) = core.downloads.current.pid_for(id) {
        let _ = Command::new("kill").arg(pid.to_string()).status();
    }
    crate::logger::info("downloads", &format!("cancelled download {id}"));
    core.hub.emit(&AppEvent::DownloadsChanged);
}

pub fn retry(core: &Rc<AppCore>, id: i64) {
    core.db.requeue_download(id);
    core.hub.emit(&AppEvent::DownloadsChanged);
    core.downloads.wake();
}

pub fn remove(core: &Rc<AppCore>, id: i64) {
    core.db.delete_download(id);
    core.hub.emit(&AppEvent::DownloadsChanged);
}

pub fn clear_finished(core: &Rc<AppCore>) {
    core.db.clear_finished_downloads();
    core.hub.emit(&AppEvent::DownloadsChanged);
}

pub fn looks_like_url(text: &str) -> bool {
    normalize_url(text).is_some()
}

fn normalize_url(raw: &str) -> Option<String> {
    let text = raw.trim();
    if text.is_empty() || text.chars().any(char::is_whitespace) {
        return None;
    }
    if text.starts_with("http://") || text.starts_with("https://") {
        return Some(text.to_string());
    }
    let host = text.split('/').next().unwrap_or_default();
    if host.contains('.') && !host.starts_with('.') && !host.ends_with('.') {
        return Some(format!("https://{text}"));
    }
    None
}

pub fn resolve_tool(name: &str) -> Option<PathBuf> {
    if let Some(paths) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&paths) {
            let candidate = dir.join(name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    let fallbacks = [
        dirs::home_dir().map(|h| h.join(".local/bin").join(name)),
        Some(PathBuf::from("/usr/local/bin").join(name)),
        Some(PathBuf::from("/usr/bin").join(name)),
    ];
    fallbacks.into_iter().flatten().find(|p| p.is_file())
}

pub fn check_tools() -> ToolStatus {
    let yt_dlp_version = resolve_tool("yt-dlp").and_then(|path| {
        Command::new(path)
            .arg("--version")
            .output()
            .ok()
            .filter(|out| out.status.success())
            .map(|out| String::from_utf8_lossy(&out.stdout).trim().to_string())
            .filter(|v| !v.is_empty())
    });
    let ffmpeg = resolve_tool("ffmpeg").is_some();
    ToolStatus {
        yt_dlp_version,
        ffmpeg,
    }
}

fn worker(
    db_path: &Path,
    root: &Path,
    tx: async_channel::Sender<WorkerEvent>,
    rx: async_channel::Receiver<()>,
    current: Arc<CurrentJob>,
) {
    let Ok(db) = Db::open(db_path) else { return };
    repair_unplayable(&db, &tx);
    while rx.recv_blocking().is_ok() {
        while rx.try_recv().is_ok() {}
        let mut just_downloaded = false;
        while let Some(row) = db.next_queued_download() {
            if just_downloaded {
                std::thread::sleep(std::time::Duration::from_millis(1500));
            }
            if row.kind == KIND_LINK {
                probe(&db, &row, &tx, &current);
                just_downloaded = false;
            } else {
                download(&db, root, &row, &tx, &current);
                just_downloaded = true;
            }
        }
    }
}

fn probe(
    db: &Db,
    row: &DownloadRow,
    tx: &async_channel::Sender<WorkerEvent>,
    current: &CurrentJob,
) {
    if !db.claim_download(row.id, STATUS_FETCHING) {
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    }
    let _ = tx.send_blocking(WorkerEvent::Changed);
    let Some(yt_dlp) = resolve_tool("yt-dlp") else {
        db.set_download_status(row.id, STATUS_FAILED, Some("yt-dlp is not installed"));
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    };

    let mut command = Command::new(yt_dlp);
    command
        .args([
            "--flat-playlist",
            "-J",
            "--no-warnings",
            "--socket-timeout",
            "15",
        ])
        .arg(&row.url)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null());
    let (output, stderr) = match run_captured(command, row.id, current) {
        Ok(pair) => pair,
        Err(message) => {
            fail_unless_cancelled(db, row.id, &message);
            let _ = tx.send_blocking(WorkerEvent::Changed);
            return;
        }
    };
    if db.download_status(row.id).as_deref() == Some(STATUS_CANCELLED) {
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    }
    let Ok(json) = serde_json::from_str::<serde_json::Value>(&output) else {
        db.set_download_status(row.id, STATUS_FAILED, Some(&friendly_error(&stderr)));
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    };

    if json["_type"].as_str() == Some("playlist") {
        let playlist_title = json["title"].as_str().unwrap_or_default().to_string();
        let entries: Vec<&serde_json::Value> = json["entries"]
            .as_array()
            .map(|list| {
                list.iter()
                    .filter(|e| e["url"].as_str().is_some())
                    .collect()
            })
            .unwrap_or_default();
        if entries.is_empty() {
            db.set_download_status(
                row.id,
                STATUS_FAILED,
                Some("Nothing to download at this link"),
            );
            let _ = tx.send_blocking(WorkerEvent::Changed);
            return;
        }
        let total = entries.len();
        let queued: Vec<(String, String, String, i64)> = entries
            .iter()
            .take(MAX_PLAYLIST_ITEMS)
            .enumerate()
            .map(|(index, entry)| {
                let artist = entry["channel"]
                    .as_str()
                    .or_else(|| entry["uploader"].as_str())
                    .unwrap_or_default();
                (
                    entry["url"].as_str().unwrap_or_default().to_string(),
                    entry["title"].as_str().unwrap_or("Untitled").to_string(),
                    artist.to_string(),
                    (index + 1) as i64,
                )
            })
            .collect();
        if let Err(err) = db.expand_playlist(row.id, &queued, &playlist_title) {
            crate::logger::error("downloads", &format!("playlist expand failed: {err}"));
            db.set_download_status(row.id, STATUS_FAILED, Some("Could not queue playlist"));
            let _ = tx.send_blocking(WorkerEvent::Changed);
            return;
        }
        crate::logger::info(
            "downloads",
            &format!("expanded playlist '{playlist_title}': {total} items"),
        );
        if total > MAX_PLAYLIST_ITEMS {
            let _ = tx.send_blocking(WorkerEvent::Toast(format!(
                "Queued the first {MAX_PLAYLIST_ITEMS} of {total} items"
            )));
        }
    } else {
        let title = json["title"].as_str().unwrap_or("Untitled");
        let artist = json["artist"]
            .as_str()
            .or_else(|| json["channel"].as_str())
            .or_else(|| json["uploader"].as_str())
            .unwrap_or_default();
        db.set_download_meta(row.id, KIND_TRACK, title, artist);
        db.set_download_status(row.id, STATUS_QUEUED, None);
    }
    let _ = tx.send_blocking(WorkerEvent::Changed);
}

fn download(
    db: &Db,
    root: &Path,
    row: &DownloadRow,
    tx: &async_channel::Sender<WorkerEvent>,
    current: &CurrentJob,
) {
    if !db.claim_download(row.id, STATUS_DOWNLOADING) {
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    }
    let _ = tx.send_blocking(WorkerEvent::Changed);
    let Some(yt_dlp) = resolve_tool("yt-dlp") else {
        db.set_download_status(row.id, STATUS_FAILED, Some("yt-dlp is not installed"));
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    };

    let home = root.join(LIBRARY_SUBDIR);
    let temp = dirs::cache_dir()
        .unwrap_or_default()
        .join("flaccy/downloads");
    let _ = std::fs::create_dir_all(&home);
    let _ = std::fs::create_dir_all(&temp);

    let mut command = Command::new(yt_dlp);
    command
        .args(["-f", "bestaudio/best", "-x", "--audio-format", "best", "--audio-quality", "0"])
        .args(["-S", "acodec:opus"])
        .args(["--embed-metadata", "--write-thumbnail", "--convert-thumbnails", "jpg"])
        .args(["--no-playlist", "--no-overwrites", "--newline", "--no-warnings"])
        .args(["--socket-timeout", "15", "--retries", "3"])
        .args(["--progress-template", "download:FLACCYPROG %(progress._percent_str)s"])
        .args(["--print", "after_move:FLACCYFILE %(filepath)s", "--no-quiet"])
        .arg("--paths")
        .arg(format!("home:{}", home.display()))
        .arg("--paths")
        .arg(format!("temp:{}", temp.display()))
        .args([
            "-o",
            "%(artist,creator,channel,uploader|Unknown Artist)s/%(album,track,title)s/%(track,title)s [%(id)s].%(ext)s",
        ]);
    if let Some(ffmpeg) = resolve_tool("ffmpeg") {
        command.arg("--ffmpeg-location").arg(ffmpeg);
    }
    command
        .arg(&row.url)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null());

    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(err) => {
            db.set_download_status(
                row.id,
                STATUS_FAILED,
                Some(&format!("could not start yt-dlp: {err}")),
            );
            let _ = tx.send_blocking(WorkerEvent::Changed);
            return;
        }
    };
    current.set(row.id, child.id());
    if db.download_status(row.id).as_deref() == Some(STATUS_CANCELLED) {
        let _ = Command::new("kill").arg(child.id().to_string()).status();
    }

    let stderr_handle = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut text = String::new();
            let _ = pipe.read_to_string(&mut text);
            text
        })
    });

    let mut file_path: Option<PathBuf> = None;
    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let Some(percent) = line.strip_prefix("FLACCYPROG ") {
                if let Ok(value) = percent.trim().trim_end_matches('%').parse::<f64>() {
                    let _ = tx.send_blocking(WorkerEvent::Progress {
                        id: row.id,
                        fraction: (value / 100.0).clamp(0.0, 1.0),
                    });
                }
            } else if let Some(path) = line.strip_prefix("FLACCYFILE ") {
                file_path = Some(PathBuf::from(path.trim()));
            }
        }
    }

    let status = child.wait();
    current.clear();
    let stderr = stderr_handle
        .and_then(|handle| handle.join().ok())
        .unwrap_or_default();

    if db.download_status(row.id).as_deref() == Some(STATUS_CANCELLED) {
        crate::logger::info(
            "downloads",
            &format!("download {} cancelled mid-flight", row.id),
        );
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    }
    let succeeded = status.map(|s| s.success()).unwrap_or(false);
    if !succeeded {
        let message = friendly_error(&stderr);
        crate::logger::error(
            "downloads",
            &format!("download {} failed: {message}", row.id),
        );
        db.set_download_status(row.id, STATUS_FAILED, Some(&message));
        let _ = tx.send_blocking(WorkerEvent::Changed);
        return;
    }

    match file_path.map(|path| ensure_playable(&path)) {
        Some(path) => {
            let (title, artist, album) = finalize_tags(&path, row);
            db.set_download_file(row.id, &path.to_string_lossy());
            db.set_download_meta(row.id, KIND_TRACK, &title, &artist);
            db.set_download_status(row.id, STATUS_DONE, None);
            crate::logger::info(
                "downloads",
                &format!("downloaded '{title} — {artist}' to {}", path.display()),
            );
            let _ = tx.send_blocking(WorkerEvent::Finished {
                title,
                artist,
                album,
            });
        }
        None => {
            db.set_download_status(row.id, STATUS_DONE, Some("Already in your library"));
            crate::logger::info(
                "downloads",
                &format!("download {} already present, skipped", row.id),
            );
            let _ = tx.send_blocking(WorkerEvent::Changed);
        }
    }
}

/// Runs a captured child while registering its pid for cancellation; returns
/// (stdout, stderr).
fn run_captured(
    mut command: Command,
    id: i64,
    current: &CurrentJob,
) -> Result<(String, String), String> {
    let mut child = command
        .spawn()
        .map_err(|err| format!("could not start yt-dlp: {err}"))?;
    current.set(id, child.id());
    let stderr_handle = child.stderr.take().map(|mut pipe| {
        std::thread::spawn(move || {
            let mut text = String::new();
            let _ = pipe.read_to_string(&mut text);
            text
        })
    });
    let mut stdout = String::new();
    if let Some(mut pipe) = child.stdout.take() {
        let _ = pipe.read_to_string(&mut stdout);
    }
    let status = child.wait();
    current.clear();
    let stderr = stderr_handle
        .and_then(|handle| handle.join().ok())
        .unwrap_or_default();
    match status {
        Ok(status) if status.success() => Ok((stdout, stderr)),
        _ => Err(friendly_error(&stderr)),
    }
}

fn fail_unless_cancelled(db: &Db, id: i64, message: &str) {
    if db.download_status(id).as_deref() != Some(STATUS_CANCELLED) {
        db.set_download_status(id, STATUS_FAILED, Some(message));
    }
}

const PROBE_TIMEOUT: gst::ClockTime = gst::ClockTime::from_seconds(20);
const CONVERT_SUFFIX: &str = "flaccy-convert.flac";

/// Re-checks finished downloads that are still sitting in a codec this machine
/// turned out not to be able to decode, so a file that was already fetched
/// before this pipeline learned to convert starts playing without the user
/// hunting down a GStreamer plugin.
fn repair_unplayable(db: &Db, tx: &async_channel::Sender<WorkerEvent>) {
    let mut repaired = 0usize;
    for (id, file) in db.unchecked_download_files() {
        let path = PathBuf::from(&file);
        if !path.is_file() {
            continue;
        }
        if is_flac(&path) || is_decodable(&path) {
            db.mark_download_codec_checked(id);
            continue;
        }
        let Some(converted) = transcode_to_flac(&path) else {
            continue;
        };
        db.set_download_file(id, &converted.to_string_lossy());
        repaired += 1;
    }
    if repaired > 0 {
        let _ = tx.send_blocking(WorkerEvent::Repaired(repaired));
    }
}

/// The sentence shown once a launch has rescued files that were already on disk.
fn repair_summary(count: usize) -> String {
    if count == 1 {
        "Converted 1 download to FLAC so it plays here".to_string()
    } else {
        format!("Converted {count} downloads to FLAC so they play here")
    }
}

/// Guarantees the file handed to the library is one this machine can actually
/// play: a site can serve perfectly valid AAC that needs gst-libav, which the
/// base runtime deps don't pull in, and the failure would only surface as a
/// missing-codec toast the first time the user pressed play.
fn ensure_playable(path: &Path) -> PathBuf {
    if is_flac(path) || is_decodable(path) {
        return path.to_path_buf();
    }
    crate::logger::warn(
        "downloads",
        &format!(
            "no local decoder for {}; converting to FLAC",
            path.display()
        ),
    );
    transcode_to_flac(path).unwrap_or_else(|| path.to_path_buf())
}

fn is_flac(path: &Path) -> bool {
    path.extension()
        .map(|ext| ext.eq_ignore_ascii_case("flac"))
        .unwrap_or(false)
}

/// Asks the local GStreamer to preroll the file with everything decoded, which
/// is the only check that sees a missing decoder before the user does. A probe
/// that cannot even be set up answers "decodable" so a broken probe never
/// triggers a pointless re-encode.
fn is_decodable(path: &Path) -> bool {
    use gst::prelude::*;
    if gst::init().is_err() {
        return true;
    }
    let Ok(uri) = glib::filename_to_uri(path, None) else {
        return true;
    };
    let Ok(source) = gst::ElementFactory::make("uridecodebin")
        .property("uri", uri.as_str())
        .build()
    else {
        return true;
    };
    let pipeline = gst::Pipeline::new();
    if pipeline.add(&source).is_err() {
        return true;
    }

    let audio_pads = Arc::new(AtomicU32::new(0));
    let weak_pipeline = pipeline.downgrade();
    let seen = Arc::clone(&audio_pads);
    source.connect_pad_added(move |_, pad| {
        let Some(pipeline) = weak_pipeline.upgrade() else {
            return;
        };
        let is_audio = pad
            .current_caps()
            .and_then(|caps| caps.structure(0).map(|s| s.name().starts_with("audio/")))
            .unwrap_or(false);
        let Ok(sink) = gst::ElementFactory::make("fakesink")
            .property("sync", false)
            .build()
        else {
            return;
        };
        if pipeline.add(&sink).is_err() || sink.sync_state_with_parent().is_err() {
            return;
        }
        let Some(target) = sink.static_pad("sink") else {
            return;
        };
        if pad.link(&target).is_ok() && is_audio {
            seen.fetch_add(1, Ordering::SeqCst);
        }
    });

    let decodable = preroll(&pipeline) && audio_pads.load(Ordering::SeqCst) > 0;
    let _ = pipeline.set_state(gst::State::Null);
    decodable
}

/// Drives the probe pipeline to PAUSED and reports whether it got there.
fn preroll(pipeline: &gst::Pipeline) -> bool {
    use gst::prelude::*;
    if pipeline.set_state(gst::State::Paused).is_err() {
        return false;
    }
    let Some(bus) = pipeline.bus() else {
        return false;
    };
    let Some(message) = bus.timed_pop_filtered(
        Some(PROBE_TIMEOUT),
        &[
            gst::MessageType::AsyncDone,
            gst::MessageType::Error,
            gst::MessageType::Eos,
        ],
    ) else {
        return false;
    };
    match message.view() {
        gst::MessageView::AsyncDone(_) => true,
        gst::MessageView::Error(err) => {
            crate::logger::info("downloads", &format!("probe rejected file: {}", err.error()));
            false
        }
        _ => false,
    }
}

/// Re-encodes to FLAC, which every install that can run Flaccy at all can
/// decode. The source is already lossy, so FLAC is what keeps the decoded
/// signal intact — a second lossy pass would not. Cover art is carried across
/// by hand because ffmpeg does not turn an MP4 cover atom into a Vorbis
/// picture block.
fn transcode_to_flac(path: &Path) -> Option<PathBuf> {
    let ffmpeg = resolve_tool("ffmpeg")?;
    let target = unique_flac_path(path);
    let scratch = path.with_extension(CONVERT_SUFFIX);
    let _ = std::fs::remove_file(&scratch);

    let output = Command::new(ffmpeg)
        .args(["-nostdin", "-v", "error", "-y", "-i"])
        .arg(path)
        .args([
            "-map",
            "0:a:0",
            "-map_metadata",
            "0",
            "-c:a",
            "flac",
            "-compression_level",
            "8",
        ])
        .arg(&scratch)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output();
    let succeeded = match &output {
        Ok(output) => output.status.success(),
        Err(_) => false,
    };
    if !succeeded || !scratch.is_file() {
        let detail = output
            .map(|out| String::from_utf8_lossy(&out.stderr).trim().to_string())
            .unwrap_or_else(|err| err.to_string());
        crate::logger::error(
            "downloads",
            &format!("could not convert {} to FLAC: {detail}", path.display()),
        );
        let _ = std::fs::remove_file(&scratch);
        return None;
    }

    carry_pictures(path, &scratch);
    if std::fs::remove_file(path).is_err() || std::fs::rename(&scratch, &target).is_err() {
        crate::logger::error(
            "downloads",
            &format!("could not replace {} with its FLAC", path.display()),
        );
        let _ = std::fs::remove_file(&scratch);
        return None;
    }
    crate::logger::info(
        "downloads",
        &format!("converted {} to {}", path.display(), target.display()),
    );
    Some(target)
}

/// The .flac name next to the original, stepped aside if something already
/// owns it so a conversion never overwrites another track.
fn unique_flac_path(path: &Path) -> PathBuf {
    let target = path.with_extension("flac");
    if !target.exists() {
        return target;
    }
    let stem = path
        .file_stem()
        .map(|stem| stem.to_string_lossy().to_string())
        .unwrap_or_else(|| "track".to_string());
    let parent = path.parent().unwrap_or(Path::new("."));
    for index in 2..1000 {
        let candidate = parent.join(format!("{stem} {index}.flac"));
        if !candidate.exists() {
            return candidate;
        }
    }
    target
}

/// Copies embedded cover art from the original file onto the converted one.
fn carry_pictures(source: &Path, target: &Path) {
    let pictures: Vec<Picture> = lofty::probe::Probe::open(source)
        .ok()
        .and_then(|probe| probe.read().ok())
        .and_then(|tagged| tagged.primary_tag().or_else(|| tagged.first_tag()).cloned())
        .map(|tag| tag.pictures().to_vec())
        .unwrap_or_default();
    if pictures.is_empty() {
        return;
    }
    let Some(tagged) = lofty::probe::Probe::open(target)
        .ok()
        .and_then(|probe| probe.read().ok())
    else {
        return;
    };
    let tag_type = tagged.primary_tag_type();
    let mut tag = tagged
        .primary_tag()
        .or_else(|| tagged.first_tag())
        .cloned()
        .unwrap_or_else(|| Tag::new(tag_type));
    if !tag.pictures().is_empty() {
        return;
    }
    for picture in pictures {
        tag.push_picture(picture);
    }
    if let Err(err) = tag.save_to_path(target, WriteOptions::default()) {
        crate::logger::warn(
            "downloads",
            &format!("cover carry failed for {}: {err}", target.display()),
        );
    }
}

/// Fills tag gaps yt-dlp leaves on plain videos (album, artist, track number)
/// and embeds the written thumbnail as front cover art — lofty writes Vorbis
/// picture blocks natively, so no mutagen dependency is needed. Returns the
/// final (title, artist, album).
fn finalize_tags(path: &Path, row: &DownloadRow) -> (String, String, String) {
    let fallback_title = row.title.clone().unwrap_or_else(|| "Untitled".to_string());
    let fallback_artist = row.artist.clone().filter(|a| !a.is_empty());

    let Some(tagged) = lofty::probe::Probe::open(path)
        .ok()
        .and_then(|probe| probe.read().ok())
    else {
        return (
            fallback_title,
            fallback_artist.unwrap_or_else(|| "Unknown Artist".to_string()),
            String::new(),
        );
    };
    let tag_type = tagged.primary_tag_type();
    let mut tag = tagged
        .primary_tag()
        .or_else(|| tagged.first_tag())
        .cloned()
        .unwrap_or_else(|| Tag::new(tag_type));

    let artist = non_empty(tag.artist().as_deref())
        .or(fallback_artist)
        .unwrap_or_else(|| "Unknown Artist".to_string());
    tag.set_artist(artist.clone());
    let title = clean_video_title(
        &non_empty(tag.title().as_deref()).unwrap_or(fallback_title),
        &artist,
    );
    tag.set_title(title.clone());
    let album = non_empty(tag.album().as_deref())
        .or_else(|| row.playlist_title.clone().filter(|t| !t.is_empty()))
        .unwrap_or_else(|| title.clone());
    tag.set_album(album.clone());
    if tag.track().unwrap_or(0) == 0 {
        if let Some(index) = row.playlist_index.filter(|i| *i > 0) {
            tag.set_track(index as u32);
        }
    }

    let thumbnail = path.with_extension("jpg");
    if tag.pictures().is_empty() {
        if let Ok(data) = std::fs::read(&thumbnail) {
            tag.push_picture(Picture::new_unchecked(
                PictureType::CoverFront,
                Some(MimeType::Jpeg),
                None,
                data,
            ));
        }
    }
    if let Err(err) = tag.save_to_path(path, WriteOptions::default()) {
        crate::logger::warn(
            "downloads",
            &format!("tag write failed for {}: {err}", path.display()),
        );
    }
    let _ = std::fs::remove_file(&thumbnail);
    (title, artist, album)
}

fn non_empty(text: Option<&str>) -> Option<String> {
    text.map(str::trim)
        .filter(|t| !t.is_empty())
        .map(String::from)
}

/// Strips YouTube video-title noise a music library doesn't want: a leading
/// "<artist> - " credit (only when it matches the artist tag) and trailing
/// bracketed qualifiers like "(Official Audio)" or "[4K Remaster]". Meaningful
/// qualifiers ("(Live)", "(Acoustic)", "(Remix)") are kept.
fn clean_video_title(title: &str, artist: &str) -> String {
    let mut result = title.trim().to_string();
    if !artist.is_empty() {
        for separator in [" - ", " – ", " — ", ": "] {
            let prefix = format!("{artist}{separator}");
            if result.len() > prefix.len()
                && result.is_char_boundary(prefix.len())
                && result[..prefix.len()].eq_ignore_ascii_case(&prefix)
            {
                result = result[prefix.len()..].trim().to_string();
                break;
            }
        }
    }
    result = remove_noise_groups(&result);
    let cleaned = result
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_end_matches(['-', '–', '—', '|'])
        .trim()
        .to_string();
    if cleaned.is_empty() {
        title.trim().to_string()
    } else {
        cleaned
    }
}

/// Removes every (...) / [...] group whose content is a noise qualifier,
/// wherever it appears in the title.
fn remove_noise_groups(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open_index) = rest.find(['(', '[']) {
        let open = rest[open_index..].chars().next().unwrap_or('(');
        let close = if open == '(' { ')' } else { ']' };
        let Some(close_offset) = rest[open_index..].find(close) else {
            break;
        };
        let close_index = open_index + close_offset;
        let content = rest[open_index + open.len_utf8()..close_index].to_lowercase();
        if is_noise_qualifier(&content) {
            result.push_str(&rest[..open_index]);
        } else {
            result.push_str(&rest[..close_index + close.len_utf8()]);
        }
        rest = &rest[close_index + close.len_utf8()..];
    }
    result.push_str(rest);
    result
}

fn is_noise_qualifier(content: &str) -> bool {
    if matches!(
        content,
        "audio" | "video" | "hd" | "hq" | "4k" | "mv" | "m/v" | "official"
    ) {
        return true;
    }
    [
        "official",
        "lyric",
        "lyrics",
        "visuali",
        "remaster",
        "music video",
        "out now",
        "premiere",
    ]
    .iter()
    .any(|noise| content.contains(noise))
}

pub fn friendly_error(stderr: &str) -> String {
    let raw = stderr
        .lines()
        .rev()
        .find_map(|line| line.trim().strip_prefix("ERROR: "))
        .map(strip_extractor_prefix)
        .unwrap_or_else(|| "Download failed".to_string());
    if raw.contains("Sign in to confirm")
        || raw.contains("not a bot")
        || raw.contains("HTTP Error 403")
    {
        return "YouTube blocked the request — updating yt-dlp usually fixes this".to_string();
    }
    if raw.contains("Unsupported URL") {
        return "This link isn't supported".to_string();
    }
    let mut message: String = raw.chars().take(200).collect();
    if message.len() < raw.len() {
        message.push('…');
    }
    message
}

/// Turns "[youtube] dQw4w9WgXcQ: Video unavailable" into "Video unavailable".
fn strip_extractor_prefix(line: &str) -> String {
    if !line.starts_with('[') {
        return line.to_string();
    }
    line.split_once("] ")
        .and_then(|(_, rest)| rest.split_once(": "))
        .map(|(_, message)| message.to_string())
        .unwrap_or_else(|| line.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_urls() {
        assert_eq!(
            normalize_url("  https://youtu.be/abc  ").as_deref(),
            Some("https://youtu.be/abc")
        );
        assert_eq!(
            normalize_url("music.youtube.com/watch?v=abc").as_deref(),
            Some("https://music.youtube.com/watch?v=abc")
        );
        assert_eq!(normalize_url("not a url"), None);
        assert_eq!(normalize_url(""), None);
        assert_eq!(normalize_url("plaintext"), None);
    }

    #[test]
    fn friendly_error_maps_bot_check() {
        let stderr = "WARNING: x\nERROR: Sign in to confirm you're not a bot.";
        assert_eq!(
            friendly_error(stderr),
            "YouTube blocked the request — updating yt-dlp usually fixes this"
        );
    }

    #[test]
    fn friendly_error_falls_back_to_last_error_line() {
        assert_eq!(
            friendly_error("ERROR: Video unavailable"),
            "Video unavailable"
        );
        assert_eq!(
            friendly_error("ERROR: [youtube] 00000000000: Video unavailable"),
            "Video unavailable"
        );
        assert_eq!(friendly_error(""), "Download failed");
    }

    #[test]
    fn unique_flac_path_steps_aside_from_an_existing_file() {
        let dir = std::env::temp_dir().join(format!(
            "flaccy-unique-{}",
            std::process::id() as u64 + 1_000_000
        ));
        let _ = std::fs::create_dir_all(&dir);
        let source = dir.join("Song [abc].m4a");
        assert_eq!(unique_flac_path(&source), dir.join("Song [abc].flac"));
        std::fs::write(dir.join("Song [abc].flac"), b"x").unwrap();
        assert_eq!(unique_flac_path(&source), dir.join("Song [abc] 2.flac"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The whole point of the conversion: a file whose codec this machine has no
    /// decoder for must come back as one it does, tags and all.
    #[test]
    fn converts_an_undecodable_file_into_a_playable_flac() {
        let Some(ffmpeg) = resolve_tool("ffmpeg") else {
            return;
        };
        let dir = std::env::temp_dir().join("flaccy-transcode-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let source = dir.join("Tone [xyz].m4a");
        let built = Command::new(&ffmpeg)
            .args([
                "-nostdin", "-v", "error", "-y", "-f", "lavfi", "-i",
                "sine=frequency=440:duration=1", "-c:a", "aac",
            ])
            .arg(&source)
            .status()
            .map(|status| status.success())
            .unwrap_or(false);
        if !built {
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        if is_decodable(&source) {
            let _ = std::fs::remove_dir_all(&dir);
            return;
        }
        let converted = ensure_playable(&source);
        assert_eq!(converted, dir.join("Tone [xyz].flac"));
        assert!(!source.exists());
        assert!(is_decodable(&converted));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cleans_video_titles() {
        assert_eq!(
            clean_video_title(
                "Rick Astley - Beautiful Life (Official Video) [4K Remaster]",
                "Rick Astley"
            ),
            "Beautiful Life"
        );
        assert_eq!(
            clean_video_title("Rick Astley - Shivers (Official Audio)", "Rick Astley"),
            "Shivers"
        );
        assert_eq!(
            clean_video_title("She Makes Me", "Rick Astley"),
            "She Makes Me"
        );
        assert_eq!(
            clean_video_title("Daft Punk - Something About Us (Live)", "Daft Punk"),
            "Something About Us (Live)"
        );
        assert_eq!(
            clean_video_title("Song Title (Acoustic Version)", "Artist"),
            "Song Title (Acoustic Version)"
        );
        assert_eq!(
            clean_video_title("Other Band - Their Song", "Rick Astley"),
            "Other Band - Their Song"
        );
        assert_eq!(
            clean_video_title("(Official Video)", "Artist"),
            "(Official Video)"
        );
        assert_eq!(
            clean_video_title(
                "Daft Punk - Instant Crush (Official Video) ft. Julian Casablancas",
                "Daft Punk"
            ),
            "Instant Crush ft. Julian Casablancas"
        );
    }
}
