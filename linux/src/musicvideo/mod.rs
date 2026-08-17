pub mod align;
pub mod llm;
pub mod playback;
pub mod score;
pub mod search;
pub mod stream;
pub mod sync;

use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use crate::library::Track;
use gtk::glib;
use playback::{StageState, VideoStage};
use std::cell::{Cell, RefCell};
use std::path::{Path, PathBuf};
use std::rc::Rc;
use std::time::Duration;

/// How often the video is measured against the audio clock. Fast enough that a
/// gap is closed before it reads as lip-sync error, slow enough to cost
/// nothing.
const SYNC_INTERVAL: Duration = Duration::from_millis(200);

/// How long a remembered "this song has no music video" stands. Videos get
/// uploaded; a permanent no would be wrong.
const MISS_TTL_DAYS: f64 = 30.0;

/// Quality ceilings offered in Preferences, smallest first.
pub const QUALITY_HEIGHTS: [i32; 4] = [360, 480, 720, 1080];

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

/// The video chosen for one library track, and how far its timeline sits from
/// the audio on disk.
#[derive(Clone)]
pub struct VideoMatch {
    pub video_id: String,
    pub title: String,
    pub channel: String,
    pub duration: f64,
    pub offset: f64,
    pub aligned: bool,
    pub chosen_by_user: bool,
    pub reason: String,
}

#[derive(Clone)]
pub enum VideoState {
    Off,
    Searching,
    Ready(VideoMatch),
    Missing,
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

enum Request {
    Resolve {
        seq: u64,
        track: Track,
        settings: Settings,
        force: bool,
    },
    Choose {
        seq: u64,
        track: Track,
        candidate: Candidate,
        settings: Settings,
    },
    Candidates {
        seq: u64,
        track: Track,
    },
    /// Re-resolves the stream for a match already decided — the signed URL
    /// aged out mid-session, or the format it named turned out to be one this
    /// GStreamer cannot decode.
    Renew {
        seq: u64,
        video_id: String,
        settings: Settings,
        strict: bool,
    },
}

enum Response {
    Resolved {
        seq: u64,
        state: VideoState,
        stream: Option<stream::Stream>,
    },
    Renewed {
        seq: u64,
        stream: Option<stream::Stream>,
    },
    Aligned {
        seq: u64,
        offset: f64,
    },
    Candidates {
        seq: u64,
        list: Vec<Candidate>,
    },
}

pub struct MusicVideoHandle {
    tx: RefCell<Option<async_channel::Sender<Request>>>,
    stage: RefCell<Option<Rc<VideoStage>>>,
    state: RefCell<VideoState>,
    seq: Cell<u64>,
    enabled: Cell<bool>,
    visible: Cell<bool>,
    drift: Cell<Option<f64>>,
    candidates: RefCell<Vec<Candidate>>,
    candidates_seq: Cell<u64>,
    stream: RefCell<Option<stream::Stream>>,
    sink_ready: Cell<bool>,
    /// Guards the one automatic retry a failed stream is allowed, so a video
    /// that simply cannot play reports that instead of reloading forever.
    recovering: Cell<bool>,
}

impl MusicVideoHandle {
    pub fn new() -> Self {
        Self {
            tx: RefCell::new(None),
            stage: RefCell::new(None),
            state: RefCell::new(VideoState::Off),
            seq: Cell::new(0),
            enabled: Cell::new(false),
            visible: Cell::new(false),
            drift: Cell::new(None),
            candidates: RefCell::new(Vec::new()),
            candidates_seq: Cell::new(0),
            stream: RefCell::new(None),
            sink_ready: Cell::new(false),
            recovering: Cell::new(false),
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

    /// True once the song has outlasted the video it was matched to.
    pub fn exhausted(&self, audio_position: f64) -> bool {
        self.stage
            .borrow()
            .as_ref()
            .is_some_and(|stage| stage.exhausted(audio_position))
    }

    pub fn stage_state(&self) -> StageState {
        self.stage
            .borrow()
            .as_ref()
            .map(|stage| stage.state())
            .unwrap_or(StageState::Idle)
    }

    /// The paintable every video surface draws, created on first use so a
    /// session that never opens the video lens never builds a pipeline.
    pub fn paintable(&self) -> Option<gtk::gdk::Paintable> {
        self.stage.borrow().as_ref().map(|stage| stage.paintable.clone())
    }
}

/// Whether this build can show video at all. Checked once so the UI can
/// explain itself instead of failing silently.
pub fn available() -> bool {
    gst::ElementFactory::find("playbin3").is_some()
}

pub fn start(core: &Rc<AppCore>) {
    let (request_tx, request_rx) = async_channel::unbounded::<Request>();
    let (response_tx, response_rx) = async_channel::unbounded::<Response>();
    *core.music_video.tx.borrow_mut() = Some(request_tx);

    let db_path = core.db_path.clone();
    let root = core.music_root();
    std::thread::Builder::new()
        .name("flaccy-musicvideo".into())
        .spawn(move || worker(&db_path, &root, request_rx, response_tx))
        .ok();

    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        while let Ok(response) = response_rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            apply_response(&core, response);
        }
    });

    wire_transport(core);
    start_sync_loop(core);
    sweep_download_buffers();
}

/// The download buffer that makes the video seekable is a temporary file
/// GStreamer removes when the pipeline stops — unless the app was killed
/// first, in which case it is left behind. Anything older than a day cannot
/// belong to this session, so it goes.
fn sweep_download_buffers() {
    let Some(cache) = dirs::cache_dir() else { return };
    let Ok(entries) = std::fs::read_dir(&cache) else { return };
    let cutoff = std::time::Duration::from_secs(24 * 60 * 60);
    let mut removed = 0usize;
    for entry in entries.filter_map(Result::ok) {
        let name = entry.file_name();
        let Some(name) = name.to_str() else { continue };
        if !name.starts_with("flaccy-") {
            continue;
        }
        let stale = entry
            .metadata()
            .and_then(|meta| meta.modified())
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

/// Mirrors the audio transport onto the video stage and re-resolves whenever
/// the song changes.
fn wire_transport(core: &Rc<AppCore>) {
    let weak = Rc::downgrade(core);
    core.hub.subscribe(move |event| {
        let Some(core) = weak.upgrade() else { return false };
        if !core.music_video.enabled.get() {
            return true;
        }
        match event {
            AppEvent::TrackChanged(_) => {
                core.music_video.drift.set(None);
                if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                    stage.unload();
                }
                *core.music_video.stream.borrow_mut() = None;
                request_resolve(&core, false);
            }
            AppEvent::PlayingChanged(playing) => {
                if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                    stage.set_playing(*playing && core.music_video.visible.get());
                }
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

fn start_sync_loop(core: &Rc<AppCore>) {
    let weak = Rc::downgrade(core);
    glib::timeout_add_local(SYNC_INTERVAL, move || {
        let Some(core) = weak.upgrade() else {
            return glib::ControlFlow::Break;
        };
        if !core.music_video.enabled.get() || !core.music_video.visible.get() {
            return glib::ControlFlow::Continue;
        }
        let Some(stage) = core.music_video.stage.borrow().clone() else {
            return glib::ControlFlow::Continue;
        };
        if !core.player.is_playing() {
            return glib::ControlFlow::Continue;
        }
        let Some(position) = core.player.position() else {
            return glib::ControlFlow::Continue;
        };
        core.music_video.drift.set(stage.follow(position));
        glib::ControlFlow::Continue
    });
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
        if let Some(stage) = core.music_video.stage.borrow().as_ref() {
            stage.unload();
        }
        *core.music_video.stream.borrow_mut() = None;
        core.music_video.drift.set(None);
        publish(core, VideoState::Off);
    }
}

/// Whether a video surface is actually on screen. Off screen the pipeline is
/// parked rather than torn down, so returning to the lens is instant.
pub fn set_visible(core: &Rc<AppCore>, visible: bool) {
    core.music_video.visible.set(visible);
    let stage = core.music_video.stage.borrow().clone();
    let Some(stage) = stage else { return };
    if !visible {
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
/// stale URL and an undecodable format both are, once each — after that the
/// failure is reported rather than retried in a loop.
fn recover_from(core: &Rc<AppCore>, message: &str) -> bool {
    if core.music_video.recovering.replace(true) {
        return false;
    }
    if message == playback::NO_DECODER {
        crate::logger::info("musicvideo", "no decoder for that format; retrying in H.264");
        renew_stream(core, true);
        return true;
    }
    if stream_expired(core) {
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

/// Signed stream URLs expire after a few hours, and the best-looking format is
/// occasionally one this GStreamer has no decoder for. Either way the fix is
/// the same: re-resolve the stream for the match already decided — no search,
/// no model, no alignment — and, when a decoder was the problem, ask for the
/// codec that always works.
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

/// Shifts the video against the audio by hand, for the rare case where the
/// automatic alignment finds nothing to lock onto.
pub fn nudge_offset(core: &Rc<AppCore>, delta: f64) {
    let Some(mut found) = core.music_video.state.borrow().matched().cloned() else {
        return;
    };
    found.offset += delta;
    apply_offset(core, found);
}

pub fn reset_offset(core: &Rc<AppCore>) {
    let Some(mut found) = core.music_video.state.borrow().matched().cloned() else {
        return;
    };
    found.offset = 0.0;
    apply_offset(core, found);
}

fn apply_offset(core: &Rc<AppCore>, found: VideoMatch) {
    let Some(track) = core.player.current_track() else { return };
    core.db
        .set_music_video_offset(&track.title, &track.artist, found.offset, found.aligned);
    if let Some(stage) = core.music_video.stage.borrow().as_ref() {
        stage.set_offset(found.offset);
        stage.resync(core.player.position().unwrap_or(0.0));
    }
    publish(core, VideoState::Ready(found));
}

/// Replaces the match with one the user picked from the chooser. A hand-picked
/// video is remembered as such and never second-guessed by a later search.
pub fn choose(core: &Rc<AppCore>, candidate: Candidate) {
    let Some(track) = core.player.current_track() else { return };
    let seq = next_seq(core);
    publish(core, VideoState::Searching);
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

/// Asks for the full candidate list so the chooser has something to show.
pub fn request_candidates(core: &Rc<AppCore>) {
    let Some(track) = core.player.current_track() else { return };
    let seq = core.music_video.seq.get();
    core.music_video.candidates_seq.set(seq);
    send(core, Request::Candidates { seq, track });
}

/// Re-runs the search from scratch, ignoring what was cached — the way out of
/// a wrong match or a stale failure.
pub fn refresh(core: &Rc<AppCore>) {
    request_resolve(core, true);
}

fn request_resolve(core: &Rc<AppCore>, force: bool) {
    core.music_video.recovering.set(false);
    let Some(track) = core.player.current_track() else {
        publish(core, VideoState::Off);
        return;
    };
    if !available() {
        publish(core, VideoState::Failed("Video playback is unavailable".into()));
        return;
    }
    let seq = next_seq(core);
    publish(core, VideoState::Searching);
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

fn apply_response(core: &Rc<AppCore>, response: Response) {
    match response {
        Response::Resolved { seq, state, stream } => {
            if seq != core.music_video.seq.get() {
                return;
            }
            *core.music_video.stream.borrow_mut() = stream.clone();
            if let (Some(stream), VideoState::Ready(found)) = (stream, &state) {
                if let Some(stage) = ensure_stage(core) {
                    stage.set_offset(found.offset);
                    if core.music_video.visible.get() {
                        let position = core.player.position().unwrap_or(0.0);
                        stage.load(&stream.url, position, core.player.is_playing());
                        stage.set_playing(core.player.is_playing());
                    }
                }
            }
            publish(core, state);
        }
        Response::Renewed { seq, stream } => {
            if seq != core.music_video.seq.get() {
                return;
            }
            let Some(stream) = stream else {
                publish(core, VideoState::Failed("This video's stream expired".into()));
                return;
            };
            *core.music_video.stream.borrow_mut() = Some(stream.clone());
            if core.music_video.visible.get() {
                if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                    let position = core.player.position().unwrap_or(0.0);
                    stage.load(&stream.url, position, core.player.is_playing());
                    stage.set_playing(core.player.is_playing());
                }
            }
            core.hub.emit(&AppEvent::MusicVideoChanged);
        }
        Response::Aligned { seq, offset } => {
            if seq != core.music_video.seq.get() {
                return;
            }
            let Some(mut found) = core.music_video.state.borrow().matched().cloned() else {
                return;
            };
            found.offset = offset;
            found.aligned = true;
            if let Some(stage) = core.music_video.stage.borrow().as_ref() {
                stage.set_offset(offset);
                stage.resync(core.player.position().unwrap_or(0.0));
            }
            publish(core, VideoState::Ready(found));
        }
        Response::Candidates { seq, list } => {
            if seq != core.music_video.candidates_seq.get() {
                return;
            }
            *core.music_video.candidates.borrow_mut() = list;
            core.hub.emit(&AppEvent::MusicVideoCandidates);
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
            publish(core, VideoState::Failed("Video playback is unavailable".into()));
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

fn worker(
    db_path: &Path,
    root: &Path,
    rx: async_channel::Receiver<Request>,
    tx: async_channel::Sender<Response>,
) {
    let Ok(db) = Db::open(db_path) else { return };
    while let Ok(request) = rx.recv_blocking() {
        match request {
            Request::Resolve {
                seq,
                track,
                settings,
                force,
            } => {
                if !rx.is_empty() {
                    continue;
                }
                handle_resolve(&db, root, seq, &track, &settings, force, &tx);
            }
            Request::Choose {
                seq,
                track,
                candidate,
                settings,
            } => {
                let found = VideoMatch {
                    video_id: candidate.id.clone(),
                    title: candidate.title.clone(),
                    channel: candidate.channel.clone(),
                    duration: candidate.duration,
                    offset: 0.0,
                    aligned: false,
                    chosen_by_user: true,
                    reason: "You picked this one".to_string(),
                };
                db.save_music_video(&track.title, &track.artist, Some(&found), 1.0);
                deliver(&db, root, seq, &track, found, &settings, &tx);
            }
            Request::Candidates { seq, track } => {
                let list = match search::search(&track.title, &track.artist) {
                    search::SearchOutcome::Found(found) => found,
                    _ => Vec::new(),
                };
                let _ = tx.send_blocking(Response::Candidates { seq, list });
            }
            Request::Renew {
                seq,
                video_id,
                settings,
                strict,
            } => {
                let now = chrono::Utc::now().timestamp();
                let response = match stream::resolve(&video_id, settings.max_height, now, strict) {
                    Ok(resolved) => Response::Renewed {
                        seq,
                        stream: Some(resolved),
                    },
                    Err(err) => {
                        crate::logger::warn("musicvideo", &format!("stream renewal failed: {err}"));
                        Response::Renewed { seq, stream: None }
                    }
                };
                let _ = tx.send_blocking(response);
            }
        }
    }
}

fn handle_resolve(
    db: &Db,
    root: &Path,
    seq: u64,
    track: &Track,
    settings: &Settings,
    force: bool,
    tx: &async_channel::Sender<Response>,
) {
    if !force {
        if let Some(row) = db.fetch_music_video(&track.title, &track.artist) {
            match row.video_id.clone() {
                Some(video_id) => {
                    let found = VideoMatch {
                        video_id,
                        title: row.video_title,
                        channel: row.channel,
                        duration: row.duration,
                        offset: row.offset,
                        aligned: row.aligned,
                        chosen_by_user: row.chosen_by_user,
                        reason: row.reason,
                    };
                    deliver(db, root, seq, track, found, settings, tx);
                    return;
                }
                None if row.age_days <= MISS_TTL_DAYS => {
                    let _ = tx.send_blocking(Response::Resolved {
                        seq,
                        state: VideoState::Missing,
                        stream: None,
                    });
                    return;
                }
                None => {}
            }
        }
    }

    match pick(track, settings) {
        Pick::Chosen(found) => {
            db.save_music_video(&track.title, &track.artist, Some(&found), 1.0);
            deliver(db, root, seq, track, found, settings, tx);
        }
        Pick::Nothing => {
            db.save_music_video(&track.title, &track.artist, None, 0.0);
            let _ = tx.send_blocking(Response::Resolved {
                seq,
                state: VideoState::Missing,
                stream: None,
            });
        }
        Pick::Failed(err) => {
            let _ = tx.send_blocking(Response::Resolved {
                seq,
                state: VideoState::Failed(err),
                stream: None,
            });
        }
    }
}

enum Pick {
    Chosen(VideoMatch),
    Nothing,
    Failed(String),
}

/// Search, rank, and — when the ranking is close — let a local model read the
/// titles and break the tie.
fn pick(track: &Track, settings: &Settings) -> Pick {
    let candidates = match search::search(&track.title, &track.artist) {
        search::SearchOutcome::Found(found) => found,
        search::SearchOutcome::Empty => return Pick::Nothing,
        search::SearchOutcome::Failed(err) => return Pick::Failed(err),
    };
    let ranked = score::rank(&track.title, &track.artist, track.duration, &candidates);
    if ranked.is_empty() {
        return Pick::Nothing;
    }
    if score::decisive(&ranked) {
        return Pick::Chosen(build_match(
            ranked[0].candidate,
            "Matched on title, channel and runtime",
        ));
    }

    let shortlist: Vec<&Candidate> = ranked.iter().take(5).map(|s| s.candidate).collect();
    let scores: Vec<f64> = ranked.iter().take(5).map(|s| s.score).collect();
    if settings.use_llm {
        if let Some(model) = llm::choose_model(&settings.model, &llm::installed_models()) {
            if let Some(verdict) = llm::adjudicate(
                &model,
                &score::search_title(&track.title),
                &track.artist,
                track.duration,
                &shortlist,
            ) {
                let blended = llm::blend(&scores, &verdict);
                let best = blended
                    .iter()
                    .enumerate()
                    .max_by(|a, b| a.1.partial_cmp(b.1).unwrap_or(std::cmp::Ordering::Equal));
                if let Some((index, best_score)) = best {
                    if *best_score >= score::ACCEPT {
                        let reason = if verdict.reason.is_empty() {
                            format!("Chosen by {model}")
                        } else {
                            format!("{} — {model}", verdict.reason)
                        };
                        return Pick::Chosen(build_match(shortlist[index], &reason));
                    }
                }
                return Pick::Nothing;
            }
        }
    }

    if ranked[0].score >= score::ACCEPT {
        Pick::Chosen(build_match(
            ranked[0].candidate,
            "Best match among close results",
        ))
    } else {
        Pick::Nothing
    }
}

fn build_match(candidate: &Candidate, reason: &str) -> VideoMatch {
    VideoMatch {
        video_id: candidate.id.clone(),
        title: candidate.title.clone(),
        channel: candidate.channel.clone(),
        duration: candidate.duration,
        offset: 0.0,
        aligned: false,
        chosen_by_user: false,
        reason: clip_reason(reason),
    }
}

/// The caption under the video is one line. A model asked for a short sentence
/// sometimes writes a paragraph, so it is cut to its first sentence and capped.
fn clip_reason(reason: &str) -> String {
    let first = reason
        .split_inclusive(['.', '!', '?'])
        .next()
        .unwrap_or(reason)
        .trim();
    let clipped: String = first.chars().take(REASON_LIMIT).collect();
    if clipped.chars().count() < first.chars().count() {
        format!("{}…", clipped.trim_end())
    } else {
        clipped.to_string()
    }
}

/// Characters of reasoning the caption can carry before it stops being a
/// caption.
const REASON_LIMIT: usize = 90;

/// Resolves a playable stream for a decided match, hands it back, and — the
/// first time a video is used — measures how far its soundtrack sits from the
/// file on disk so the picture lines up with what is being heard.
fn deliver(
    db: &Db,
    root: &Path,
    seq: u64,
    track: &Track,
    found: VideoMatch,
    settings: &Settings,
    tx: &async_channel::Sender<Response>,
) {
    let now = chrono::Utc::now().timestamp();
    match stream::resolve(&found.video_id, settings.max_height, now, false) {
        Ok(resolved) => {
            let needs_alignment = settings.align && !found.aligned;
            let _ = tx.send_blocking(Response::Resolved {
                seq,
                state: VideoState::Ready(found.clone()),
                stream: Some(resolved),
            });
            if needs_alignment {
                align_in_background(db, root, seq, track, &found, tx);
            }
        }
        Err(err) => {
            let _ = tx.send_blocking(Response::Resolved {
                seq,
                state: VideoState::Failed(err),
                stream: None,
            });
        }
    }
}

fn align_in_background(
    db: &Db,
    root: &Path,
    seq: u64,
    track: &Track,
    found: &VideoMatch,
    tx: &async_channel::Sender<Response>,
) {
    let local = root.join(&track.rel_path);
    if !local.is_file() {
        return;
    }
    let scratch = scratch_dir();
    let Some(audio) = stream::download_audio(&found.video_id, &scratch) else {
        crate::logger::warn(
            "musicvideo",
            &format!("could not fetch audio to align {}", found.video_id),
        );
        return;
    };
    let alignment = align::estimate(&local, &audio);
    let _ = std::fs::remove_file(&audio);
    let Some(alignment) = alignment else {
        crate::logger::info(
            "musicvideo",
            &format!("no confident alignment for {}", found.video_id),
        );
        db.set_music_video_offset(&track.title, &track.artist, found.offset, true);
        return;
    };
    crate::logger::info(
        "musicvideo",
        &format!(
            "aligned {} at {:+.2}s (confidence {:.2})",
            found.video_id, alignment.offset, alignment.confidence
        ),
    );
    db.set_music_video_offset(&track.title, &track.artist, alignment.offset, true);
    let _ = tx.send_blocking(Response::Aligned {
        seq,
        offset: alignment.offset,
    });
}

fn scratch_dir() -> PathBuf {
    let base = dirs::cache_dir().unwrap_or_else(std::env::temp_dir);
    base.join("flaccy").join("musicvideo")
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
    fn a_models_paragraph_is_cut_down_to_a_caption() {
        assert_eq!(clip_reason("Official channel."), "Official channel.");
        assert_eq!(
            clip_reason("It is the official video. It also has the most views by far."),
            "It is the official video."
        );
        let rambling = "The channel is the artist's official YouTube account and the title \
                        format matches their standard music video uploads exactly";
        let clipped = clip_reason(rambling);
        assert!(clipped.chars().count() <= REASON_LIMIT + 1);
        assert!(clipped.ends_with('…'));
        assert_eq!(clip_reason(""), "");
    }

    #[test]
    fn a_ready_state_exposes_its_match() {
        let found = VideoMatch {
            video_id: "abc".into(),
            title: "t".into(),
            channel: "c".into(),
            duration: 1.0,
            offset: 0.0,
            aligned: false,
            chosen_by_user: false,
            reason: String::new(),
        };
        assert!(VideoState::Ready(found).matched().is_some());
        assert!(VideoState::Missing.matched().is_none());
        assert!(VideoState::Searching.matched().is_none());
    }
}
