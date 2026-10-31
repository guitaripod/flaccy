pub mod align;
pub mod llm;
pub mod playback;
pub mod score;
pub mod search;
pub mod stream;
pub mod sync;
mod worker;

use crate::app::AppCore;
use crate::events::AppEvent;
use gtk::glib;
use playback::{StageState, VideoStage};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use worker::{Request, Response};

/// How often the video is measured against the audio clock. Fast enough that a
/// gap is closed before it reads as lip-sync error, slow enough to cost
/// nothing. The loop only runs while a video is on screen and playing.
const SYNC_INTERVAL: Duration = Duration::from_millis(200);

/// Quality ceilings offered in Preferences, smallest first.
pub const QUALITY_HEIGHTS: [i32; 4] = [360, 480, 720, 1080];

/// What the lens says when yt-dlp is missing: what failed and how to fix it.
pub const YT_DLP_MISSING: &str =
    "yt-dlp isn't installed — install it with your package manager to find music videos";

/// A YouTube search result, before anything has decided what it is.
#[derive(Clone)]
pub struct Candidate {
    pub id: String,
    pub title: String,
    pub channel: String,
    pub duration: f64,
    pub view_count: Option<u64>,
    pub live_now: bool,
}

impl Candidate {
    /// A video known only by its id, for a stream served from memory where
    /// the match it belongs to already carries the rest.
    pub fn bare(id: &str) -> Self {
        Self {
            id: id.to_string(),
            title: String::new(),
            channel: String::new(),
            duration: 0.0,
            view_count: None,
            live_now: false,
        }
    }
}

pub use flaccy_library::music_video::VideoMatch;

/// What the search is doing while the lens waits, so a slow step names
/// itself instead of hiding behind one spinner.
#[derive(Clone, PartialEq, Debug)]
pub enum Phase {
    Searching,
    /// A local model is breaking a tie between close results.
    Judging(String),
    /// The match is decided; its stream is being resolved.
    Loading,
}

#[derive(Clone)]
pub enum VideoState {
    Off,
    Searching(Phase),
    Ready(VideoMatch),
    Missing(String),
    Failed(String),
}

impl VideoState {
    pub fn matched(&self) -> Option<&VideoMatch> {
        match self {
            VideoState::Ready(found) => Some(found),
            _ => None,
        }
    }
}

#[derive(Clone)]
pub struct Settings {
    pub max_height: i32,
    pub use_llm: bool,
    pub model: String,
    pub align: bool,
}

pub struct MusicVideoHandle {
    tx: RefCell<Option<async_channel::Sender<Request>>>,
    /// The newest request's number, shared with the worker so it can drop a
    /// search the listener has already skipped past.
    latest: Arc<AtomicU64>,
    stage: RefCell<Option<Rc<VideoStage>>>,
    state: RefCell<VideoState>,
    seq: Cell<u64>,
    enabled: Cell<bool>,
    visible: Cell<bool>,
    fullscreen: Cell<bool>,
    drift: Cell<Option<f64>>,
    catching_up: Cell<bool>,
    exhausted: Cell<bool>,
    candidates: RefCell<Vec<Candidate>>,
    candidates_seq: Cell<u64>,
    stream: RefCell<Option<stream::Stream>>,
    sink_ready: Cell<bool>,
    /// Guards the one automatic retry a failed stream is allowed, so a video
    /// that simply cannot play reports that instead of reloading forever.
    recovering: Cell<bool>,
    sync_loop: RefCell<Option<glib::SourceId>>,
}

impl MusicVideoHandle {
    pub fn new() -> Self {
        Self {
            tx: RefCell::new(None),
            latest: Arc::new(AtomicU64::new(0)),
            stage: RefCell::new(None),
            state: RefCell::new(VideoState::Off),
            seq: Cell::new(0),
            enabled: Cell::new(false),
            visible: Cell::new(false),
            fullscreen: Cell::new(false),
            drift: Cell::new(None),
            catching_up: Cell::new(false),
            exhausted: Cell::new(false),
            candidates: RefCell::new(Vec::new()),
            candidates_seq: Cell::new(0),
            stream: RefCell::new(None),
            sink_ready: Cell::new(false),
            recovering: Cell::new(false),
            sync_loop: RefCell::new(None),
        }
    }

    pub fn state(&self) -> VideoState {
        self.state.borrow().clone()
    }

    pub fn drift(&self) -> Option<f64> {
        self.drift.get()
    }

    pub fn candidates(&self) -> Vec<Candidate> {
        self.candidates.borrow().clone()
    }

    /// The height actually being streamed, which can sit below the configured
    /// ceiling when the upload has no format that tall.
    pub fn stream_height(&self) -> Option<i32> {
        self.stream
            .borrow()
            .as_ref()
            .map(|stream| stream.height)
            .filter(|height| *height > 0)
    }

    pub fn stream_codec(&self) -> Option<stream::Codec> {
        self.stream
            .borrow()
            .as_ref()
            .and_then(|stream| stream.codec)
    }

    /// True once the song has outlasted the video it was matched to.
    pub fn exhausted(&self) -> bool {
        self.exhausted.get()
    }

    pub fn stage_state(&self) -> StageState {
        self.stage
            .borrow()
            .as_ref()
            .map(|stage| stage.state())
            .unwrap_or(StageState::Idle)
    }

    /// Whether any surface — the lens or the full-screen window — shows the
    /// video.
    pub fn is_showing(&self) -> bool {
        self.visible.get() || self.fullscreen.get()
    }

    /// Where the picture is in the video's own timeline, for opening the
    /// same moment on YouTube.
    pub fn video_position(&self) -> Option<f64> {
        self.stage
            .borrow()
            .as_ref()
            .and_then(|stage| stage.position())
    }

    /// The paintable every video surface draws, created on first use so a
    /// session that never opens the video lens never builds a pipeline.
    pub fn paintable(&self) -> Option<gtk::gdk::Paintable> {
        self.stage
            .borrow()
            .as_ref()
            .map(|stage| stage.paintable.clone())
    }
}

/// Whether this build can show video at all. Checked once so the UI can
/// explain itself instead of failing silently.
pub fn available() -> bool {
    gst::ElementFactory::find("playbin3").is_some()
}

pub fn start(core: &Rc<AppCore>) {
    let (request_tx, response_rx) = worker::spawn(
        core.db_path.clone(),
        core.music_root(),
        Arc::clone(&core.music_video.latest),
    );
    *core.music_video.tx.borrow_mut() = Some(request_tx);

    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        while let Ok(response) = response_rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            apply_response(&core, response);
        }
    });

    wire_transport(core);
    std::thread::Builder::new()
        .name("flaccy-buffer-sweep".into())
        .spawn(sweep_download_buffers)
        .ok();
}

/// The download buffer that makes the video seekable is a temporary file
/// GStreamer removes when the pipeline stops — unless the app was killed
/// first, in which case it is left behind. Anything older than a day cannot
/// belong to this session, so it goes.
fn sweep_download_buffers() {
    let Some(cache) = dirs::cache_dir() else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(&cache) else {
        return;
    };
    let cutoff = std::time::Duration::from_secs(24 * 60 * 60);
    let mut removed = 0usize;
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !is_download_buffer(name) {
            continue;
        }
        let Ok(meta) = entry.metadata() else { continue };
        let stale = meta.is_file()
            && meta
                .modified()
                .map(|modified| modified.elapsed().map(|age| age > cutoff).unwrap_or(false))
                .unwrap_or(false);
        if stale && std::fs::remove_file(entry.path()).is_ok() {
            removed += 1;
        }
    }
    if removed > 0 {
        crate::logger::info(
            "musicvideo",
            &format!("cleared {removed} stale video download buffers"),
        );
    }
}

/// GStreamer names the buffer after the program plus six random characters
/// (`flaccy-MLNVX3`); anything else in the cache folder is left alone.
fn is_download_buffer(name: &str) -> bool {
    name.strip_prefix("flaccy-").is_some_and(|suffix| {
        suffix.len() == 6 && suffix.chars().all(|c| c.is_ascii_alphanumeric())
    })
}

/// Mirrors the audio transport onto the video stage and re-resolves whenever
/// the song changes.
fn wire_transport(core: &Rc<AppCore>) {
    let weak = Rc::downgrade(core);
    core.hub.subscribe(move |event| {
        let Some(core) = weak.upgrade() else {
            return false;
        };
        if !core.music_video.enabled.get() {
            return true;
        }
        match event {
            AppEvent::TrackChanged(_) => {
                core.music_video.drift.set(None);
                core.music_video.exhausted.set(false);
                if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                    stage.unload();
                }
                *core.music_video.stream.borrow_mut() = None;
                request_resolve(&core, false);
            }
            AppEvent::PlayingChanged(playing) => {
                if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                    stage.set_playing(*playing && core.music_video.is_showing());
                }
                refresh_sync_loop(&core);
            }
            AppEvent::Seeked(position) => {
                if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                    stage.resync(*position);
                }
            }
            _ => {}
        }
        true
    });
}

/// Runs the sync loop exactly while it has work: music video mode on, a
/// surface showing it, and the audio playing. Otherwise it is removed, so an
/// idle Flaccy has no timer waking it.
fn refresh_sync_loop(core: &Rc<AppCore>) {
    let wanted =
        core.music_video.enabled.get() && core.music_video.is_showing() && core.player.is_playing();
    let running = core.music_video.sync_loop.borrow().is_some();
    if wanted == running {
        return;
    }
    if !wanted {
        if let Some(source) = core.music_video.sync_loop.borrow_mut().take() {
            source.remove();
        }
        return;
    }
    let weak = Rc::downgrade(core);
    let source = glib::timeout_add_local(SYNC_INTERVAL, move || {
        let Some(core) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        sync_tick(&core);
        glib::ControlFlow::Continue
    });
    *core.music_video.sync_loop.borrow_mut() = Some(source);
}

fn sync_tick(core: &Rc<AppCore>) {
    let Some(stage) = core.music_video.stage.borrow().clone() else {
        return;
    };
    let Some(position) = core.player.position() else {
        return;
    };
    let drift = stage.follow(position);
    core.music_video.drift.set(drift);
    let catching_up = drift.is_some_and(|drift| drift.abs() >= sync::HARD_SEEK);
    let exhausted = stage.exhausted(position);
    let changed = core.music_video.catching_up.replace(catching_up) != catching_up
        || core.music_video.exhausted.replace(exhausted) != exhausted;
    if changed {
        core.hub.emit(&AppEvent::MusicVideoChanged);
    }
}

/// Turns music video mode on or off. Turning it on resolves a video for
/// whatever is playing; turning it off tears the pipeline down so nothing is
/// streamed in the background.
pub fn set_enabled(core: &Rc<AppCore>, enabled: bool) {
    if core.music_video.enabled.replace(enabled) == enabled {
        return;
    }
    core.config.borrow_mut().music_video_mode = enabled;
    crate::config::save(&core.config.borrow());
    if enabled {
        request_resolve(core, false);
    } else {
        next_seq(core);
        if let Some(stage) = core.music_video.stage.borrow().as_ref() {
            stage.unload();
        }
        *core.music_video.stream.borrow_mut() = None;
        core.music_video.drift.set(None);
        core.music_video.exhausted.set(false);
        publish(core, VideoState::Off);
    }
    refresh_sync_loop(core);
}

/// Whether the lens is actually on screen. Off screen the pipeline is parked
/// rather than torn down, so returning to the lens is instant.
pub fn set_visible(core: &Rc<AppCore>, visible: bool) {
    core.music_video.visible.set(visible);
    apply_showing(core);
}

/// Whether the full-screen window is open. It counts as a surface of its own,
/// so a main window the compositor considers hidden behind it doesn't park
/// the picture it is showing.
pub fn set_fullscreen(core: &Rc<AppCore>, open: bool) {
    core.music_video.fullscreen.set(open);
    apply_showing(core);
}

fn apply_showing(core: &Rc<AppCore>) {
    refresh_sync_loop(core);
    core.hub.emit(&AppEvent::MusicVideoChanged);
    let stage = core.music_video.stage.borrow().clone();
    let Some(stage) = stage else { return };
    if !core.music_video.is_showing() {
        stage.set_playing(false);
        return;
    }
    let stream = core.music_video.stream.borrow().clone();
    match stream {
        Some(stream) if stream.usable_at(chrono::Utc::now().timestamp()) => {
            let position = core.player.position().unwrap_or(0.0);
            stage.load(&stream.url, position, core.player.is_playing());
            stage.set_playing(core.player.is_playing());
        }
        Some(_) => renew_stream(core, false),
        None => {}
    }
}

/// Decides whether a pipeline failure is one the app can fix by itself. A
/// refused or stale URL and an undecodable format all are, once each — after
/// that the failure is reported rather than retried in a loop.
fn recover_from(core: &Rc<AppCore>, message: &str) -> bool {
    if core.music_video.recovering.replace(true) {
        return false;
    }
    if message == playback::NO_DECODER {
        crate::logger::info(
            "musicvideo",
            "no decoder for that format; retrying with the most decodable codec",
        );
        renew_stream(core, true);
        return true;
    }
    if message == playback::STREAM_REFUSED || stream_expired(core) {
        crate::logger::info("musicvideo", "stream refused or expired; renewing it");
        renew_stream(core, false);
        return true;
    }
    core.music_video.recovering.set(false);
    false
}

fn stream_expired(core: &Rc<AppCore>) -> bool {
    let now = chrono::Utc::now().timestamp();
    core.music_video
        .stream
        .borrow()
        .as_ref()
        .is_some_and(|stream| !stream.usable_at(now))
}

/// Signed stream URLs expire after a few hours, YouTube occasionally refuses
/// one outright, and the best-looking format is occasionally one this
/// GStreamer has no decoder for. Either way the fix is the same: re-resolve
/// the stream for the match already decided — no search, no model, no
/// alignment — and, when a decoder was the problem, ask for the codec most
/// certain to decode.
fn renew_stream(core: &Rc<AppCore>, strict: bool) {
    let Some(found) = core.music_video.state.borrow().matched().cloned() else {
        return;
    };
    *core.music_video.stream.borrow_mut() = None;
    let seq = core.music_video.seq.get();
    send(
        core,
        Request::Renew {
            seq,
            video_id: found.video_id,
            settings: settings(core),
            strict,
        },
    );
}

/// "Try Again" after a failure: the same match with a fresh stream when one
/// was decided, otherwise the remembered decision — never a new search that
/// could replace a video the listener picked.
pub fn retry(core: &Rc<AppCore>) {
    core.music_video.recovering.set(false);
    if core.music_video.state.borrow().matched().is_some() {
        if let Some(stage) = core.music_video.stage.borrow().as_ref() {
            stage.unload();
        }
        renew_stream(core, false);
        core.hub.emit(&AppEvent::MusicVideoChanged);
    } else {
        request_resolve(core, false);
    }
}

/// The quality ceiling changed: the match stands, only its stream is
/// re-resolved at the new height.
pub fn requality(core: &Rc<AppCore>) {
    if !core.music_video.enabled.get() {
        return;
    }
    if core.music_video.state.borrow().matched().is_none() {
        return;
    }
    core.music_video.recovering.set(false);
    if let Some(stage) = core.music_video.stage.borrow().as_ref() {
        stage.unload();
    }
    renew_stream(core, false);
}

/// Shifts the video against the audio by hand, on top of whatever the
/// alignment found.
pub fn nudge_offset(core: &Rc<AppCore>, delta: f64) {
    let Some(mut found) = core.music_video.state.borrow().matched().cloned() else {
        return;
    };
    found.trim += delta;
    apply_trim(core, found);
}

/// Drops the hand-set trim, back to what the aligner heard.
pub fn reset_offset(core: &Rc<AppCore>) {
    let Some(mut found) = core.music_video.state.borrow().matched().cloned() else {
        return;
    };
    found.trim = 0.0;
    apply_trim(core, found);
}

fn apply_trim(core: &Rc<AppCore>, found: VideoMatch) {
    let Some(track) = core.player.current_track() else {
        return;
    };
    core.db
        .set_music_video_trim(&track.title, &track.artist, found.trim);
    if let Some(stage) = core.music_video.stage.borrow().as_ref() {
        stage.set_mapping(&found);
        stage.resync(core.player.position().unwrap_or(0.0));
    }
    publish(core, VideoState::Ready(found));
}

/// Replaces the match with one the user picked from the chooser. A hand-picked
/// video is remembered as such and never second-guessed by a later search.
pub fn choose(core: &Rc<AppCore>, candidate: Candidate) {
    let Some(track) = core.player.current_track() else {
        return;
    };
    let seq = next_seq(core);
    publish(core, VideoState::Searching(Phase::Loading));
    send(
        core,
        Request::Choose {
            seq,
            track,
            candidate,
            settings: settings(core),
        },
    );
}

/// Uses the video a pasted link points at. Returns false when the text holds
/// no YouTube video, so the chooser can say so where it was typed.
pub fn choose_link(core: &Rc<AppCore>, text: &str) -> bool {
    let Some(video_id) = search::video_id_from_link(text) else {
        return false;
    };
    let Some(track) = core.player.current_track() else {
        return false;
    };
    let seq = next_seq(core);
    publish(core, VideoState::Searching(Phase::Loading));
    send(
        core,
        Request::ChooseLink {
            seq,
            track,
            video_id,
            settings: settings(core),
        },
    );
    true
}

/// Asks for the full candidate list so the chooser has something to show.
pub fn request_candidates(core: &Rc<AppCore>) {
    let Some(track) = core.player.current_track() else {
        return;
    };
    let seq = core.music_video.seq.get();
    core.music_video.candidates_seq.set(seq);
    send(core, Request::Candidates { seq, track });
}

/// Re-runs the search from scratch, ignoring what was cached — the way out of
/// a stale "no video" answer.
pub fn refresh(core: &Rc<AppCore>) {
    if core.music_video.enabled.get() {
        request_resolve(core, true);
    }
}

fn request_resolve(core: &Rc<AppCore>, force: bool) {
    core.music_video.recovering.set(false);
    let Some(track) = core.player.current_track() else {
        next_seq(core);
        publish(core, VideoState::Off);
        return;
    };
    if !available() {
        publish(
            core,
            VideoState::Failed(
                "Video playback is unavailable — GStreamer's playbin3 element is missing".into(),
            ),
        );
        return;
    }
    let seq = next_seq(core);
    publish(core, VideoState::Searching(Phase::Searching));
    send(
        core,
        Request::Resolve {
            seq,
            track,
            settings: settings(core),
            force,
        },
    );
}

/// Warms the next song in the queue: its match decided, its stream resolved
/// and aged past YouTube's start-up refusal, its alignment done — so the
/// video appears with the song instead of a spinner. Only while a video is on
/// screen: nobody watching means nothing worth downloading ahead.
fn prefetch_next(core: &Rc<AppCore>) {
    if !core.music_video.is_showing() {
        return;
    }
    let (_, next) = core.player.current_and_next();
    let Some(track) = next else { return };
    send(
        core,
        Request::Prefetch {
            track,
            settings: settings(core),
        },
    );
}

fn settings(core: &Rc<AppCore>) -> Settings {
    let config = core.config.borrow();
    Settings {
        max_height: config.music_video_quality,
        use_llm: config.music_video_llm,
        model: config.music_video_llm_model.clone(),
        align: config.music_video_align,
    }
}

fn next_seq(core: &Rc<AppCore>) -> u64 {
    let seq = core.music_video.seq.get() + 1;
    core.music_video.seq.set(seq);
    core.music_video.latest.store(seq, Ordering::Release);
    seq
}

fn send(core: &Rc<AppCore>, request: Request) {
    if let Some(tx) = core.music_video.tx.borrow().as_ref() {
        let _ = tx.send_blocking(request);
    }
}

fn publish(core: &Rc<AppCore>, state: VideoState) {
    *core.music_video.state.borrow_mut() = state;
    core.hub.emit(&AppEvent::MusicVideoChanged);
}

/// Points the stage at a stream for the match on screen, if anything shows
/// it.
fn show_stream(core: &Rc<AppCore>, stage: &VideoStage, stream: &stream::Stream) {
    if !core.music_video.is_showing() {
        return;
    }
    let position = core.player.position().unwrap_or(0.0);
    stage.load(&stream.url, position, core.player.is_playing());
    stage.set_playing(core.player.is_playing());
}

fn apply_response(core: &Rc<AppCore>, response: Response) {
    let current = core.music_video.seq.get();
    match response {
        Response::Progress { seq, phase } => {
            if seq == current
                && matches!(*core.music_video.state.borrow(), VideoState::Searching(_))
            {
                publish(core, VideoState::Searching(phase));
            }
        }
        Response::Resolved { seq, state, stream } => {
            if seq != current {
                return;
            }
            *core.music_video.stream.borrow_mut() = stream.clone();
            if let (Some(stream), VideoState::Ready(found)) = (stream, &state) {
                if let Some(stage) = ensure_stage(core) {
                    stage.set_mapping(found);
                    show_stream(core, &stage, &stream);
                }
            }
            publish(core, state);
            prefetch_next(core);
        }
        Response::Renewed { seq, stream } => {
            if seq != current {
                return;
            }
            let Some(stream) = stream else {
                publish(
                    core,
                    VideoState::Failed("Couldn't get a fresh stream for this video".into()),
                );
                return;
            };
            *core.music_video.stream.borrow_mut() = Some(stream.clone());
            if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                show_stream(core, stage, &stream);
            }
            core.hub.emit(&AppEvent::MusicVideoChanged);
        }
        Response::Aligned { found } => {
            let Some(showing) = core.music_video.state.borrow().matched().cloned() else {
                return;
            };
            if showing.video_id != found.video_id {
                return;
            }
            let updated = VideoMatch {
                trim: showing.trim,
                ..found
            };
            if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                stage.set_mapping(&updated);
                stage.resync(core.player.position().unwrap_or(0.0));
            }
            publish(core, VideoState::Ready(updated));
        }
        Response::Candidates { seq, list } => {
            if seq != core.music_video.candidates_seq.get() {
                return;
            }
            *core.music_video.candidates.borrow_mut() = list;
            core.hub.emit(&AppEvent::MusicVideoCandidates);
        }
        Response::LinkFailed { seq, message } => {
            if seq != current {
                return;
            }
            core.toast(&message);
            request_resolve(core, false);
        }
    }
}

/// Builds the video pipeline the first time one is needed, and reports a
/// failure through the same state channel as everything else so the lens can
/// explain itself.
fn ensure_stage(core: &Rc<AppCore>) -> Option<Rc<VideoStage>> {
    if let Some(stage) = core.music_video.stage.borrow().clone() {
        return Some(stage);
    }
    if !core.music_video.sink_ready.get() {
        if let Err(err) = playback::register_sink() {
            crate::logger::error("musicvideo", &format!("video sink unavailable: {err}"));
            publish(
                core,
                VideoState::Failed(format!("Video playback is unavailable — {err}")),
            );
            return None;
        }
        core.music_video.sink_ready.set(true);
    }
    match VideoStage::new() {
        Ok(stage) => {
            let weak = Rc::downgrade(core);
            stage.connect_state(move |state| {
                let Some(core) = weak.upgrade() else { return };
                if let StageState::Failed(message) = state {
                    if recover_from(&core, message) {
                        return;
                    }
                }
                if matches!(state, StageState::Playing) {
                    core.music_video.recovering.set(false);
                }
                core.hub.emit(&AppEvent::MusicVideoChanged);
            });
            *core.music_video.stage.borrow_mut() = Some(Rc::clone(&stage));
            Some(stage)
        }
        Err(err) => {
            crate::logger::error("musicvideo", &format!("video stage: {err}"));
            publish(core, VideoState::Failed(err));
            None
        }
    }
}

/// Human wording for a quality ceiling, shared by Preferences and the lens.
pub fn quality_label(height: i32) -> String {
    format!("{height}p")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quality_heights_are_offered_smallest_first() {
        assert!(QUALITY_HEIGHTS.windows(2).all(|pair| pair[0] < pair[1]));
        assert_eq!(quality_label(720), "720p");
    }

    #[test]
    fn a_ready_state_exposes_its_match() {
        let found = worker::build_match(&Candidate::bare("abc"), "");
        assert!(VideoState::Ready(found).matched().is_some());
        assert!(VideoState::Missing(String::new()).matched().is_none());
        assert!(VideoState::Searching(Phase::Searching).matched().is_none());
    }

    #[test]
    fn only_gstreamers_own_buffers_are_swept() {
        assert!(is_download_buffer("flaccy-MLNVX3"));
        assert!(is_download_buffer("flaccy-a1b2c3"));
        assert!(!is_download_buffer("flaccy-mv-audit"));
        assert!(!is_download_buffer("flaccy-notes.txt"));
        assert!(!is_download_buffer("flaccy"));
        assert!(!is_download_buffer("other-MLNVX3"));
    }
}
