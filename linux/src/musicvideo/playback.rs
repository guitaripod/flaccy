use super::sync::{self, Correction, Governor};
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
    pub paintable: gdk::Paintable,
    governor: RefCell<Governor>,
    state: RefCell<StageState>,
    offset: Cell<f64>,
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
        let sink = gst::ElementFactory::make("gtk4paintablesink")
            .build()
            .map_err(|_| "the GTK video sink is unavailable".to_string())?;
        let paintable: gdk::Paintable = sink.property("paintable");

        let pipeline = gst::ElementFactory::make("playbin3")
            .build()
            .map_err(|_| "playbin3 is unavailable".to_string())?;
        pipeline.set_property_from_str("flags", PIPELINE_FLAGS);
        pipeline.set_property("video-sink", &sink);
        pipeline.set_property(
            "buffer-duration",
            (BUFFER_DURATION_SECONDS * gst::ClockTime::SECOND.nseconds()) as i64,
        );

        let stage = Rc::new(Self {
            pipeline,
            paintable,
            governor: RefCell::new(Governor::default()),
            state: RefCell::new(StageState::Idle),
            offset: Cell::new(0.0),
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

    pub fn set_offset(&self, offset: f64) {
        self.offset.set(offset);
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
        self.governor.borrow_mut().reset(self.now());
        self.pending_start
            .set(Some(sync::target(audio_position, self.offset.get())));
        self.publish(StageState::Opening);
        let _ = self.pipeline.set_state(gst::State::Paused);
    }

    pub fn unload(&self) {
        let _ = self.pipeline.set_state(gst::State::Null);
        *self.loaded_url.borrow_mut() = None;
        self.wants_playing.set(false);
        self.seeking.set(false);
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
        let target = if playing {
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
        self.seek_to(sync::target(audio_position, self.offset.get()));
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
        let position = self.position()?;
        let target = sync::target(audio_position, self.offset.get());
        let drift = position - target;
        match self.governor.borrow_mut().step(drift, self.now()) {
            Some(Correction::Seek) => self.seek_to(target),
            Some(Correction::Rate(rate)) => self.set_rate(rate),
            None => {}
        }
        Some(drift)
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
        duration > 0.0 && sync::target(audio_position, self.offset.get()) > duration + 0.5
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    /// Seeks to where the audio will be by the time the seek lands, not to
    /// where it is now. A flushing seek over the network takes long enough
    /// that aiming at the present would leave the video permanently that far
    /// behind, seeking again and again to chase it.
    fn seek_to(&self, seconds: f64) {
        let aim = seconds.max(0.0) + self.seek_latency.get();
        let position = gst::ClockTime::from_nseconds(
            (aim * gst::ClockTime::SECOND.nseconds() as f64) as u64,
        );
        self.seeking.set(true);
        self.seek_started_at.set(self.now());
        if self
            .pipeline
            .seek_simple(gst::SeekFlags::FLUSH | gst::SeekFlags::ACCURATE, position)
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
        let blended = self.seek_latency.get() * (1.0 - SEEK_LATENCY_WEIGHT)
            + elapsed * SEEK_LATENCY_WEIGHT;
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
        let Some(bus) = self.pipeline.bus() else { return };
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
            self.seek_to(start);
        }
    }

    fn resume_if_wanted(&self) {
        if self.wants_playing.get() {
            let _ = self.pipeline.set_state(gst::State::Playing);
        }
        if !matches!(*self.state.borrow(), StageState::Failed(_)) {
            self.publish(StageState::Playing);
        }
    }
}

impl Drop for VideoStage {
    fn drop(&mut self) {
        let _ = self.pipeline.set_state(gst::State::Null);
    }
}

/// Turns GStreamer's wording into something worth putting on screen. A stream
/// URL that has aged out is the common case and is worth naming, because the
/// fix — reopening the video — is one the app can offer.
pub fn friendly_pipeline_error(raw: &str) -> String {
    let lowered = raw.to_lowercase();
    if lowered.contains("plug-in") || lowered.contains("plugin") || lowered.contains("decode")
        || lowered.contains("decoder") || lowered.contains("codec")
    {
        return NO_DECODER.to_string();
    }
    if lowered.contains("403") || lowered.contains("forbidden") || lowered.contains("not found") {
        return "This video\'s stream expired".to_string();
    }
    if lowered.contains("resolve") || lowered.contains("network") || lowered.contains("connect") {
        return "Couldn\'t reach the video".to_string();
    }
    "Video playback failed".to_string()
}

/// Named because the resolver watches for it: this failure is fixable by
/// asking the site for a format this machine can actually decode.
pub const NO_DECODER: &str = "No decoder for this video";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_the_failures_worth_naming() {
        assert_eq!(
            friendly_pipeline_error("Server returned 403 Forbidden"),
            "This video's stream expired"
        );
        assert_eq!(
            friendly_pipeline_error("Could not resolve server name"),
            "Couldn't reach the video"
        );
        assert_eq!(
            friendly_pipeline_error("Your GStreamer installation is missing a decoder"),
            "No decoder for this video"
        );
        assert_eq!(friendly_pipeline_error("Internal data stream error"), "Video playback failed");
    }
}
