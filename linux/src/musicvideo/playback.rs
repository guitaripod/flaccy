use super::sync::{Correction, Governor};
use super::VideoMatch;
use gst::prelude::*;
use gtk::gdk;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;

/// A wider buffer than playbin's default, because a video stream stalling is
/// the one thing that visibly breaks sync.
const BUFFER_DURATION_SECONDS: u64 = 5;

/// `download` is what makes this work at all. Streamed straight from HTTP the
/// pipeline refuses every seek — and seeking is how the picture is held to the
/// audio — so playbin is told to spool the stream to its temporary cache
/// instead, which makes the whole video seekable and the corrections local and
/// instant. Measured drift goes from a permanent five seconds to under a
/// twentieth of one.
const PIPELINE_FLAGS: &str = "video+download";

/// With a GL sink, playbin's own software converters are left out
/// (`native-video`): they would force every decoded frame into system memory,
/// where `glsinkbin` can take the decoder's GL or DMA-BUF frames as they are.
const GL_PIPELINE_FLAGS: &str = "video+download+native-video";

type StateObserver = Box<dyn Fn(&StageState)>;

#[derive(Clone, PartialEq, Debug)]
pub enum StageState {
    Idle,
    Opening,
    Buffering(i32),
    Playing,
    Failed(String),
}

/// The video half of music video mode: its own GStreamer pipeline, decoding
/// picture only, rendered into a `GdkPaintable` any number of widgets can
/// show. The lossless file on disk stays the clock; this follows it.
pub struct VideoStage {
    pipeline: gst::Element,
    sink: Sink,
    pub paintable: gdk::Paintable,
    governor: RefCell<Governor>,
    state: RefCell<StageState>,
    /// How the video's timeline maps onto the audio's: the alignment, its
    /// cuts and the listener's trim.
    mapping: RefCell<Option<VideoMatch>>,
    /// Set while the audio is still before the video's first frame — an album
    /// intro the video's edit doesn't have. The picture waits on that frame
    /// instead of being seeked back to it over and over.
    holding: Cell<bool>,
    /// The cut whose jump has already been made, so it is made once.
    crossed_cut: Cell<Option<f64>>,
    caps_logged: Cell<bool>,
    /// Set while a seek is outstanding: drift measured against a pipeline
    /// mid-seek is meaningless and would trigger another one.
    seeking: Cell<bool>,
    wants_playing: Cell<bool>,
    loaded_url: RefCell<Option<String>>,
    /// Where to park once the pipeline has prerolled. A flushing seek issued
    /// before the first frame is decoded is ignored, so the opening seek waits
    /// for the pipeline to be ready to serve it.
    pending_start: Cell<Option<f64>>,
    seek_started_at: Cell<f64>,
    /// Running estimate of how long a flushing seek takes on this connection.
    seek_latency: Cell<f64>,
    started: Instant,
    on_state: RefCell<Option<StateObserver>>,
    bus_watch: RefCell<Option<gst::bus::BusWatchGuard>>,
    rate_change_failures: Cell<u32>,
}

/// How many refused instant rate changes it takes to conclude the pipeline
/// won't do them. One refusal usually just means the pipeline wasn't ready.
const RATE_CHANGE_GIVE_UP: u32 = 4;

/// How far before the video's first frame the audio must be before the
/// picture waits for it rather than chasing it.
const HOLD_MARGIN: f64 = 0.05;

/// Seconds a flushing seek is given to report back before the sync loop stops
/// waiting on it.
const SEEK_WATCHDOG: f64 = 4.0;

/// How much of the newest seek's duration goes into the running estimate.
const SEEK_LATENCY_WEIGHT: f64 = 0.35;

/// A ceiling on the seek-latency estimate, so one pathological stall can't
/// send every later seek minutes into the future.
const MAX_SEEK_LATENCY: f64 = 2.0;

/// Makes the GTK paintable sink available to GStreamer. It is linked into the
/// binary rather than installed system-wide, so a user's plugin set can't
/// leave music video mode without a surface to draw on.
pub fn register_sink() -> Result<(), String> {
    gstgtk4::plugin_register_static().map_err(|err| err.to_string())
}

impl VideoStage {
    pub fn new() -> Result<Rc<Self>, String> {
        let sink = build_sink()?;
        let paintable = sink.paintable.clone();

        let pipeline = gst::ElementFactory::make("playbin3")
            .build()
            .map_err(|_| "playbin3 is unavailable".to_string())?;
        let flags = if sink.gl {
            GL_PIPELINE_FLAGS
        } else {
            PIPELINE_FLAGS
        };
        pipeline.set_property_from_str("flags", flags);
        pipeline.set_property("video-sink", &sink.element);
        pipeline.set_property(
            "buffer-duration",
            (BUFFER_DURATION_SECONDS * gst::ClockTime::SECOND.nseconds()) as i64,
        );

        let stage = Rc::new(Self {
            pipeline,
            sink,
            paintable,
            governor: RefCell::new(Governor::default()),
            state: RefCell::new(StageState::Idle),
            mapping: RefCell::new(None),
            holding: Cell::new(false),
            crossed_cut: Cell::new(None),
            caps_logged: Cell::new(false),
            seeking: Cell::new(false),
            wants_playing: Cell::new(false),
            loaded_url: RefCell::new(None),
            pending_start: Cell::new(None),
            seek_started_at: Cell::new(0.0),
            seek_latency: Cell::new(0.0),
            started: Instant::now(),
            on_state: RefCell::new(None),
            bus_watch: RefCell::new(None),
            rate_change_failures: Cell::new(0),
        });
        stage.watch_bus();
        Ok(stage)
    }

    pub fn connect_state(&self, callback: impl Fn(&StageState) + 'static) {
        *self.on_state.borrow_mut() = Some(Box::new(callback));
    }

    pub fn state(&self) -> StageState {
        self.state.borrow().clone()
    }

    pub fn set_mapping(&self, found: &VideoMatch) {
        *self.mapping.borrow_mut() = Some(found.clone());
        self.crossed_cut.set(None);
    }

    /// Where the video should be for a moment in the local audio, unclamped:
    /// negative while an album intro plays that the video doesn't have.
    fn target(&self, audio_position: f64) -> f64 {
        self.mapping
            .borrow()
            .as_ref()
            .map(|found| found.video_time(audio_position))
            .unwrap_or(audio_position)
    }

    fn base_rate(&self, audio_position: f64) -> f64 {
        self.mapping
            .borrow()
            .as_ref()
            .map(|found| found.rate_at(audio_position))
            .unwrap_or(1.0)
    }

    fn next_cut_after(&self, audio_position: f64) -> Option<f64> {
        self.mapping
            .borrow()
            .as_ref()
            .and_then(|found| found.map.next_cut_after(audio_position))
    }

    /// Points the stage at a stream and parks it at `audio_position`. Reloading
    /// the URL already playing is a no-op, so a re-render of the view never
    /// restarts the video.
    pub fn load(&self, url: &str, audio_position: f64, playing: bool) {
        if self.loaded_url.borrow().as_deref() == Some(url) {
            return;
        }
        let _ = self.pipeline.set_state(gst::State::Null);
        self.pipeline.set_property("uri", url);
        *self.loaded_url.borrow_mut() = Some(url.to_string());
        self.wants_playing.set(playing);
        self.seeking.set(false);
        self.rate_change_failures.set(0);
        self.seek_latency.set(0.0);
        self.caps_logged.set(false);
        self.crossed_cut.set(None);
        self.governor.borrow_mut().reset(self.now());
        let start = self.target(audio_position);
        self.holding.set(start < -HOLD_MARGIN);
        self.pending_start.set(Some(start.max(0.0)));
        self.publish(StageState::Opening);
        let _ = self.pipeline.set_state(gst::State::Paused);
    }

    pub fn unload(&self) {
        let _ = self.pipeline.set_state(gst::State::Null);
        *self.loaded_url.borrow_mut() = None;
        self.wants_playing.set(false);
        self.seeking.set(false);
        self.holding.set(false);
        self.pending_start.set(None);
        self.governor.borrow_mut().reset(self.now());
        self.publish(StageState::Idle);
    }

    /// Mirrors the audio transport. Kept separate from `follow` so a pause
    /// lands on the frame the listener stopped on rather than a frame later.
    pub fn set_playing(&self, playing: bool) {
        self.wants_playing.set(playing);
        if self.loaded_url.borrow().is_none() {
            return;
        }
        if matches!(*self.state.borrow(), StageState::Failed(_)) {
            return;
        }
        let target = if playing && !self.holding.get() {
            gst::State::Playing
        } else {
            gst::State::Paused
        };
        let _ = self.pipeline.set_state(target);
    }

    /// Jumps straight to where the audio now is — for a user scrub, where
    /// converging gradually would look broken.
    pub fn resync(&self, audio_position: f64) {
        if self.loaded_url.borrow().is_none() {
            return;
        }
        self.governor.borrow_mut().reset(self.now());
        self.crossed_cut.set(None);
        if self.hold_if_early(audio_position) {
            return;
        }
        self.seek_for(audio_position);
    }

    /// One step of the sync loop. Returns the measured drift so the view can
    /// show it.
    pub fn follow(&self, audio_position: f64) -> Option<f64> {
        if self.seek_timed_out() {
            self.seeking.set(false);
        }
        if self.loaded_url.borrow().is_none() || self.seeking.get() {
            return None;
        }
        if !matches!(
            *self.state.borrow(),
            StageState::Playing | StageState::Opening
        ) {
            return None;
        }
        if self.hold_if_early(audio_position) {
            return None;
        }
        if self.cut_is_due(audio_position) {
            self.seek_for(audio_position);
            return None;
        }
        let position = self.position()?;
        let drift = position - self.target(audio_position);
        let base = self.base_rate(audio_position);
        let correction = self.governor.borrow_mut().step(drift, self.now(), base);
        match correction {
            Some(Correction::Seek) => self.seek_for(audio_position),
            Some(Correction::Rate(rate)) => self.set_rate(rate),
            None => {}
        }
        Some(drift)
    }

    /// Keeps the picture parked on the video's first frame while the audio is
    /// still in an intro the video's edit cut, and lets it go the moment the
    /// two meet. Returns true while holding.
    fn hold_if_early(&self, audio_position: f64) -> bool {
        let early = self.target(audio_position) < -HOLD_MARGIN;
        if early == self.holding.get() {
            return early;
        }
        self.holding.set(early);
        if early {
            let _ = self.pipeline.set_state(gst::State::Paused);
            self.seek_to(0.0, 1.0);
        } else {
            self.seek_for(audio_position);
            if self.wants_playing.get() {
                let _ = self.pipeline.set_state(gst::State::Playing);
            }
        }
        early
    }

    /// True once the audio, by the time a seek issued now would land, is past
    /// the next cut in the video's edit. The jump is made then, ahead of the
    /// sync loop noticing the drift, so the picture changes on the cut.
    fn cut_is_due(&self, audio_position: f64) -> bool {
        let landing = audio_position + self.seek_latency.get();
        let Some(cut) = self.next_cut_after(audio_position - self.seek_latency.get() - 0.5) else {
            return false;
        };
        if cut > landing || self.crossed_cut.get() == Some(cut) {
            return false;
        }
        self.crossed_cut.set(Some(cut));
        true
    }

    pub fn position(&self) -> Option<f64> {
        self.pipeline
            .query_position::<gst::ClockTime>()
            .map(|time| time.nseconds() as f64 / gst::ClockTime::SECOND.nseconds() as f64)
    }

    fn duration(&self) -> Option<f64> {
        self.pipeline
            .query_duration::<gst::ClockTime>()
            .map(|time| time.nseconds() as f64 / gst::ClockTime::SECOND.nseconds() as f64)
    }

    /// True once the song has outlasted the video — a short edit, or a video
    /// that starts late enough that the offset pushes its end inside the
    /// track. The picture would sit frozen on its last frame, so the lens says
    /// so instead.
    pub fn exhausted(&self, audio_position: f64) -> bool {
        let Some(duration) = self.duration() else {
            return false;
        };
        duration > 0.0 && self.target(audio_position) > duration + 0.5
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    /// Seeks to where the audio will be by the time the seek lands, not to
    /// where it is now. A flushing seek over the network takes long enough
    /// that aiming at the present would leave the video permanently that far
    /// behind, seeking again and again to chase it. The landing is mapped
    /// through the alignment, so a seek that lands past a cut lands on the
    /// far side of it.
    fn seek_for(&self, audio_position: f64) {
        let landing = audio_position + self.seek_latency.get();
        self.seek_to(self.target(landing), self.base_rate(landing));
    }

    /// A flushing seek that also sets the rate, since a flush otherwise puts
    /// the pipeline back to real time.
    fn seek_to(&self, seconds: f64, rate: f64) {
        let aim = seconds.max(0.0);
        let position =
            gst::ClockTime::from_nseconds((aim * gst::ClockTime::SECOND.nseconds() as f64) as u64);
        self.seeking.set(true);
        self.seek_started_at.set(self.now());
        if self
            .pipeline
            .seek(
                rate,
                gst::SeekFlags::FLUSH | gst::SeekFlags::ACCURATE,
                gst::SeekType::Set,
                position,
                gst::SeekType::None,
                gst::ClockTime::NONE,
            )
            .is_err()
        {
            self.seeking.set(false);
        }
    }

    /// Folds how long the seek that just finished took into the running
    /// estimate, so the aim adapts to the connection rather than to a guess.
    fn record_seek_latency(&self) {
        let elapsed = self.now() - self.seek_started_at.get();
        if !(0.0..SEEK_WATCHDOG).contains(&elapsed) {
            return;
        }
        let blended =
            self.seek_latency.get() * (1.0 - SEEK_LATENCY_WEIGHT) + elapsed * SEEK_LATENCY_WEIGHT;
        self.seek_latency.set(blended.clamp(0.0, MAX_SEEK_LATENCY));
    }

    /// A seek whose completion never came back — a stalled range request, a
    /// server that dropped the connection — must not wedge the sync loop, so
    /// after this long the stage assumes it is free to measure drift again.
    fn seek_timed_out(&self) -> bool {
        self.seeking.get() && self.now() - self.seek_started_at.get() > SEEK_WATCHDOG
    }

    /// Applies a rate change without flushing, so closing a small gap costs no
    /// rebuffer. A pipeline that refuses often enough is taken at its word and
    /// left at real time, with the seek path handling drift on its own.
    fn set_rate(&self, rate: f64) {
        if self.rate_change_failures.get() >= RATE_CHANGE_GIVE_UP {
            return;
        }
        let applied = self.pipeline.seek(
            rate,
            gst::SeekFlags::INSTANT_RATE_CHANGE,
            gst::SeekType::None,
            gst::ClockTime::NONE,
            gst::SeekType::None,
            gst::ClockTime::NONE,
        );
        if applied.is_ok() {
            self.rate_change_failures.set(0);
            return;
        }
        let failures = self.rate_change_failures.get() + 1;
        self.rate_change_failures.set(failures);
        if failures == RATE_CHANGE_GIVE_UP {
            crate::logger::warn(
                "musicvideo",
                &format!(
                    "pipeline refuses instant rate changes ({}); drift will be corrected by seeking",
                    applied.unwrap_err()
                ),
            );
        }
    }

    fn publish(&self, state: StageState) {
        {
            if *self.state.borrow() == state {
                return;
            }
            *self.state.borrow_mut() = state.clone();
        }
        let callback = self.on_state.borrow();
        if let Some(callback) = callback.as_ref() {
            callback(&state);
        }
    }

    fn watch_bus(self: &Rc<Self>) {
        let Some(bus) = self.pipeline.bus() else {
            return;
        };
        let weak = Rc::downgrade(self);
        let watch = bus.add_watch_local(move |_, message| {
            let Some(stage) = weak.upgrade() else {
                return glib::ControlFlow::Break;
            };
            stage.handle_message(message);
            glib::ControlFlow::Continue
        });
        *self.bus_watch.borrow_mut() = watch.ok();
    }

    fn handle_message(&self, message: &gst::Message) {
        match message.view() {
            gst::MessageView::AsyncDone(_) => self.on_async_done(),
            gst::MessageView::Buffering(buffering) => {
                let percent = buffering.percent();
                if percent < 100 {
                    let _ = self.pipeline.set_state(gst::State::Paused);
                    self.publish(StageState::Buffering(percent));
                } else {
                    self.resume_if_wanted();
                }
            }
            gst::MessageView::Error(error) => {
                let text = error.error().to_string();
                crate::logger::error("musicvideo", &format!("video pipeline: {text}"));
                let _ = self.pipeline.set_state(gst::State::Null);
                *self.loaded_url.borrow_mut() = None;
                self.pending_start.set(None);
                self.publish(StageState::Failed(friendly_pipeline_error(&text)));
            }
            gst::MessageView::Eos(_) => {
                let _ = self.pipeline.set_state(gst::State::Paused);
            }
            _ => {}
        }
    }

    /// Preroll, or a seek, has finished. The opening seek is issued here
    /// rather than at load time because only now is there a pipeline able to
    /// honour it — and it is issued after the pipeline is running, so the
    /// picture appears even if the seek itself is slow over the network.
    fn on_async_done(&self) {
        if self.seeking.get() {
            self.record_seek_latency();
        }
        self.seeking.set(false);
        self.resume_if_wanted();
        if let Some(start) = self.pending_start.take() {
            self.seek_to(start, 1.0);
        }
        self.log_negotiated_caps();
    }

    fn resume_if_wanted(&self) {
        if self.wants_playing.get() && !self.holding.get() {
            let _ = self.pipeline.set_state(gst::State::Playing);
        }
        if !matches!(*self.state.borrow(), StageState::Failed(_)) {
            self.publish(StageState::Playing);
        }
    }
}

impl VideoStage {
    /// Notes once per video what the decoder handed over and what reached
    /// GTK. GL or DMA-BUF memory end to end means the frames never left the
    /// GPU; system memory means each one was copied through the CPU.
    fn log_negotiated_caps(&self) {
        if self.caps_logged.get() {
            return;
        }
        let Some(decoded) = pad_caps(&self.sink.element) else {
            return;
        };
        self.caps_logged.set(true);
        let shown = pad_caps(&self.sink.paintable_sink).unwrap_or_else(|| "?".into());
        crate::logger::info(
            "musicvideo",
            &format!(
                "decoder hands over {decoded}; GTK paints {shown}{}",
                if self.sink.gl { " (GL sink)" } else { "" }
            ),
        );
    }
}

/// A sink pad's negotiated memory, format and size, in one short phrase.
fn pad_caps(element: &gst::Element) -> Option<String> {
    let caps = element.static_pad("sink")?.current_caps()?;
    let memory = caps
        .features(0)
        .map(|features| features.to_string())
        .filter(|features| !features.is_empty())
        .unwrap_or_else(|| "memory:SystemMemory".to_string());
    let structure = caps.structure(0)?;
    let field = |name: &str| {
        structure
            .value(name)
            .ok()
            .and_then(|value| value.serialize().ok())
            .map(|value| value.to_string())
            .unwrap_or_else(|| "?".into())
    };
    Some(format!(
        "{memory} {} {}x{}",
        field("format"),
        field("width"),
        field("height")
    ))
}

/// The element playbin renders into, the paintable sink inside it, and
/// whether frames can stay on the GPU on the way.
struct Sink {
    element: gst::Element,
    paintable_sink: gst::Element,
    paintable: gdk::Paintable,
    gl: bool,
}

/// The paintable sink, wrapped so frames can stay on the GPU. When GTK hands
/// the sink a GL context, `glsinkbin` takes a hardware decoder's GL or
/// DMA-BUF output without a round trip through system memory; without one,
/// playbin's own converter feeds the sink plain frames.
fn build_sink() -> Result<Sink, String> {
    let paintable_sink = gst::ElementFactory::make("gtk4paintablesink")
        .build()
        .map_err(|_| "the GTK video sink is unavailable".to_string())?;
    let paintable: gdk::Paintable = paintable_sink.property("paintable");
    let has_gl = paintable
        .property::<Option<gdk::GLContext>>("gl-context")
        .is_some();
    if has_gl {
        if let Ok(bin) = gst::ElementFactory::make("glsinkbin")
            .property("sink", &paintable_sink)
            .build()
        {
            return Ok(Sink {
                element: bin,
                paintable_sink,
                paintable,
                gl: true,
            });
        }
    }
    Ok(Sink {
        element: paintable_sink.clone(),
        paintable_sink,
        paintable,
        gl: false,
    })
}

impl Drop for VideoStage {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

/// Turns GStreamer's wording into something worth putting on screen. A stream
/// URL YouTube refuses — aged out, or too new to serve yet — is the common
/// case and is worth naming, because the fix, a fresh URL, is one the app can
/// make by itself.
pub fn friendly_pipeline_error(raw: &str) -> String {
    let lowered = raw.to_lowercase();
    if lowered.contains("plug-in")
        || lowered.contains("plugin")
        || lowered.contains("decode")
        || lowered.contains("decoder")
        || lowered.contains("codec")
    {
        return NO_DECODER.to_string();
    }
    if lowered.contains("403") || lowered.contains("forbidden") || lowered.contains("not found") {
        return STREAM_REFUSED.to_string();
    }
    if lowered.contains("resolve") || lowered.contains("network") || lowered.contains("connect") {
        return "Couldn\'t reach the video's server — check your connection".to_string();
    }
    format!("Video playback failed: {}", first_line(raw))
}

/// The first non-empty line of a GStreamer message, cut to a length that fits
/// the lens.
fn first_line(raw: &str) -> String {
    let line = raw
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("no details from GStreamer");
    let mut shown: String = line.chars().take(90).collect();
    if shown.len() < line.len() {
        shown.push('…');
    }
    shown
}

/// Named because the resolver watches for it: this failure is fixable by
/// asking the site for a format this machine can actually decode.
pub const NO_DECODER: &str = "No decoder for this video";

/// Named because the resolver watches for it: a fresh URL fixes it.
pub const STREAM_REFUSED: &str = "YouTube refused this video's stream";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_the_failures_worth_naming() {
        assert_eq!(
            friendly_pipeline_error("Server returned 403 Forbidden"),
            STREAM_REFUSED
        );
        assert_eq!(
            friendly_pipeline_error("Could not resolve server name"),
            "Couldn't reach the video's server — check your connection"
        );
        assert_eq!(
            friendly_pipeline_error("Your GStreamer installation is missing a decoder"),
            "No decoder for this video"
        );
        assert_eq!(
            friendly_pipeline_error("Internal data stream error"),
            "Video playback failed: Internal data stream error"
        );
    }
}
