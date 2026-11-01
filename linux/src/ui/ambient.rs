use crate::ui::frame_look::{self, Crop, CropTracker, Frame};
use gtk::gdk;
use gtk::glib;
use gtk::graphene;
use gtk::gsk;
use gtk::prelude::*;
use gtk::subclass::prelude::*;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// The glow's grid: tiny, because it is stretched over the whole stage and
/// only its colours matter.
const GLOW_WIDTH: usize = 32;
const GLOW_HEIGHT: usize = 18;
/// The height frames are read back at for measuring bars; the width follows
/// the frame's shape.
const SAMPLE_HEIGHT: f64 = 72.0;
/// How soon after a video starts the first looks are taken, then how often
/// after that.
const FIRST_LOOKS: [Duration; 3] = [
    Duration::from_millis(400),
    Duration::from_millis(900),
    Duration::from_millis(1200),
];
const LOOK_EVERY: Duration = Duration::from_secs(3);
/// How long one glow takes to blend into the next, counted on the video's own
/// frames.
const BLEND_MICROS: i64 = 1_400_000;
/// How many videos' crops are remembered for the session.
const REMEMBERED_CROPS: usize = 64;

/// Told whenever the settled crop changes.
type CropListener = Box<dyn Fn(Crop)>;

thread_local! {
    static CROPS: RefCell<HashMap<String, Crop>> = RefCell::new(HashMap::new());
}

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct AmbientGlow {
        pub current: RefCell<Option<gdk::Texture>>,
        pub previous: RefCell<Option<gdk::Texture>>,
        pub blend_started: Cell<Option<i64>>,
        pub source: RefCell<Option<(gdk::Paintable, glib::SignalHandlerId)>>,
        pub timer: RefCell<Option<glib::SourceId>>,
        pub looks: Cell<usize>,
        pub running: Cell<bool>,
        pub tracker: Cell<CropTracker>,
        pub key: RefCell<String>,
        pub on_crop: RefCell<Option<CropListener>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for AmbientGlow {
        const NAME: &'static str = "FlaccyAmbientGlow";
        type Type = super::AmbientGlow;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for AmbientGlow {
        fn constructed(&self) {
            self.parent_constructed();
            let obj = self.obj();
            obj.add_css_class("np-ambient");
            obj.add_css_class("np-ambient-off");
            obj.set_can_target(false);
        }

        fn dispose(&self) {
            let obj = self.obj();
            obj.set_running(false);
            obj.set_source(None);
        }
    }

    impl WidgetImpl for AmbientGlow {
        fn measure(&self, _orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            (0, 0, -1, -1)
        }

        fn unmap(&self) {
            self.obj().cancel_timer();
            self.parent_unmap();
        }

        fn map(&self) {
            self.parent_map();
            self.obj().schedule_look();
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let obj = self.obj();
            let (width, height) = (obj.width() as f32, obj.height() as f32);
            if width <= 0.0 || height <= 0.0 {
                return;
            }
            let blend = obj.blend_progress();
            let bounds = graphene::Rect::new(0.0, 0.0, width, height);
            let cover = cover(width, height);
            snapshot.push_clip(&bounds);
            if let Some(previous) = self.previous.borrow().as_ref() {
                if blend < 1.0 {
                    snapshot.append_scaled_texture(previous, gsk::ScalingFilter::Linear, &cover);
                }
            }
            if let Some(current) = self.current.borrow().as_ref() {
                snapshot.push_opacity(blend as f64);
                snapshot.append_scaled_texture(current, gsk::ScalingFilter::Linear, &cover);
                snapshot.pop();
            }
            snapshot.pop();
        }
    }

    /// The glow is stretched to cover the stage with the shape of its grid.
    fn cover(width: f32, height: f32) -> graphene::Rect {
        let aspect = GLOW_WIDTH as f32 / GLOW_HEIGHT as f32;
        let (w, h) = if width / height > aspect {
            (width, width / aspect)
        } else {
            (height * aspect, height)
        };
        graphene::Rect::new((width - w) / 2.0, (height - h) / 2.0, w, h)
    }
}

glib::wrapper! {
    /// The light a music video casts around itself: every few seconds a frame
    /// is read back at a tiny size, blurred and darkened, and blended in under
    /// the stage over the video's own next frames, so it costs no frames of
    /// its own. The same look measures the black bars burnt into the upload.
    pub struct AmbientGlow(ObjectSubclass<imp::AmbientGlow>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for AmbientGlow {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl AmbientGlow {
    /// The paintable whose frames the glow follows.
    pub fn set_source(&self, paintable: Option<&gdk::Paintable>) {
        let imp = self.imp();
        if imp.source.borrow().as_ref().map(|(current, _)| current) == paintable {
            return;
        }
        if let Some((old, handler)) = imp.source.borrow_mut().take() {
            old.disconnect(handler);
        }
        if let Some(paintable) = paintable {
            let weak = self.downgrade();
            let handler = paintable.connect_invalidate_contents(move |_| {
                if let Some(glow) = weak.upgrade() {
                    glow.on_frame();
                }
            });
            *imp.source.borrow_mut() = Some((paintable.clone(), handler));
        }
    }

    /// A new video: its crop starts from what was settled for it earlier this
    /// session, and the first looks come quickly.
    pub fn set_video(&self, key: &str) {
        let imp = self.imp();
        if *imp.key.borrow() == key {
            return;
        }
        *imp.key.borrow_mut() = key.to_string();
        let remembered = CROPS.with(|crops| crops.borrow().get(key).copied());
        let crop = remembered.unwrap_or(Crop::NONE);
        imp.tracker.set(CropTracker::settled(crop));
        imp.looks.set(0);
        self.report_crop(crop);
        self.cancel_timer();
        self.schedule_look();
    }

    /// Looks are taken only while the video plays where it can be seen.
    pub fn set_running(&self, running: bool) {
        if self.imp().running.replace(running) == running {
            return;
        }
        if running {
            self.schedule_look();
        } else {
            self.cancel_timer();
        }
    }

    /// Fades the glow out, for a song with no video to cast it.
    pub fn clear(&self) {
        self.add_css_class("np-ambient-off");
    }

    pub fn connect_crop(&self, f: impl Fn(Crop) + 'static) {
        *self.imp().on_crop.borrow_mut() = Some(Box::new(f));
    }

    fn report_crop(&self, crop: Crop) {
        if let Some(f) = self.imp().on_crop.borrow().as_ref() {
            f(crop);
        }
    }

    fn cancel_timer(&self) {
        if let Some(source) = self.imp().timer.borrow_mut().take() {
            source.remove();
        }
    }

    fn schedule_look(&self) {
        let imp = self.imp();
        if !imp.running.get() || !self.is_mapped() || imp.timer.borrow().is_some() {
            return;
        }
        let delay = FIRST_LOOKS
            .get(imp.looks.get())
            .copied()
            .unwrap_or(LOOK_EVERY);
        let weak = self.downgrade();
        let source = glib::timeout_add_local_once(delay, move || {
            let Some(glow) = weak.upgrade() else { return };
            glow.imp().timer.borrow_mut().take();
            glow.look();
            glow.schedule_look();
        });
        *imp.timer.borrow_mut() = Some(source);
    }

    /// Reads the current frame back small, measures its bars, and starts
    /// blending in the glow it casts.
    fn look(&self) {
        let imp = self.imp();
        let Some(paintable) = imp
            .source
            .borrow()
            .as_ref()
            .map(|(paintable, _)| paintable.clone())
        else {
            return;
        };
        let (width, height) = (paintable.intrinsic_width(), paintable.intrinsic_height());
        if width <= 0 || height <= 0 {
            return;
        }
        imp.looks.set(imp.looks.get() + 1);
        let started = Instant::now();
        let frame_aspect = width as f64 / height as f64;
        let sample_width = (SAMPLE_HEIGHT * frame_aspect).round().clamp(24.0, 192.0) as i32;
        let Some((pixels, stride)) =
            read_back(self, &paintable, sample_width, SAMPLE_HEIGHT as i32)
        else {
            return;
        };
        let frame = Frame {
            pixels: &pixels,
            width: sample_width as usize,
            height: SAMPLE_HEIGHT as usize,
            stride,
            channels: 3,
        };
        let mut tracker = imp.tracker.get();
        if tracker.observe(frame_look::measure_bars(&frame, frame_aspect)) {
            let crop = tracker.applied();
            remember(&imp.key.borrow(), crop);
            self.report_crop(crop);
        }
        imp.tracker.set(tracker);
        let glow = frame_look::glow(&frame, tracker.applied(), GLOW_WIDTH, GLOW_HEIGHT);
        let texture = gdk::MemoryTexture::new(
            GLOW_WIDTH as i32,
            GLOW_HEIGHT as i32,
            gdk::MemoryFormat::R8g8b8a8,
            &glib::Bytes::from_owned(glow),
            GLOW_WIDTH * 4,
        );
        self.blend_to(texture.upcast());
        if crate::frame_stats::enabled() {
            crate::logger::info(
                "frames",
                &format!(
                    "ambient look took {:.2}ms",
                    started.elapsed().as_secs_f64() * 1000.0
                ),
            );
        }
    }

    fn blend_to(&self, texture: gdk::Texture) {
        let imp = self.imp();
        let mostly_current = self.blend_progress() >= 0.5;
        let outgoing = if mostly_current {
            imp.current.borrow_mut().take()
        } else {
            imp.previous.borrow_mut().take()
        };
        *imp.previous.borrow_mut() = outgoing;
        *imp.current.borrow_mut() = Some(texture);
        imp.blend_started.set(Some(self.now()));
        self.remove_css_class("np-ambient-off");
        self.queue_draw();
    }

    /// Moves a blend on by redrawing with the video's frame, and settles it
    /// once it is done.
    fn on_frame(&self) {
        let imp = self.imp();
        if imp.blend_started.get().is_none() {
            return;
        }
        if self.blend_progress() >= 1.0 {
            imp.blend_started.set(None);
            imp.previous.borrow_mut().take();
        }
        self.queue_draw();
    }

    fn blend_progress(&self) -> f32 {
        match self.imp().blend_started.get() {
            Some(started) => {
                ((self.now() - started) as f64 / BLEND_MICROS as f64).clamp(0.0, 1.0) as f32
            }
            None => 1.0,
        }
    }

    fn now(&self) -> i64 {
        self.frame_clock()
            .map(|clock| clock.frame_time())
            .filter(|time| *time > 0)
            .unwrap_or_else(glib::monotonic_time)
    }
}

/// Keeps a video's settled crop for the rest of the session, so coming back to
/// it, or to Now Playing, starts cropped.
fn remember(key: &str, crop: Crop) {
    if key.is_empty() {
        return;
    }
    CROPS.with(|crops| {
        let mut crops = crops.borrow_mut();
        if crops.len() >= REMEMBERED_CROPS && !crops.contains_key(key) {
            crops.clear();
        }
        crops.insert(key.to_string(), crop);
    });
}

/// Renders the paintable's current frame at `width`×`height` with the window's
/// own renderer and reads the pixels back as RGB rows. The frame's texture is
/// scaled with mipmaps where it can be found, so a small read averages the
/// picture instead of picking scattered pixels from it.
fn read_back(
    widget: &impl IsA<gtk::Widget>,
    paintable: &gdk::Paintable,
    width: i32,
    height: i32,
) -> Option<(Vec<u8>, usize)> {
    let renderer = widget.as_ref().native()?.renderer()?;
    let full = gtk::Snapshot::new();
    let (full_width, full_height) = (
        paintable.intrinsic_width() as f64,
        paintable.intrinsic_height() as f64,
    );
    paintable.snapshot(&full, full_width, full_height);
    let node = full.to_node()?;
    let bounds = graphene::Rect::new(0.0, 0.0, width as f32, height as f32);
    let small = gtk::Snapshot::new();
    match frame_texture(&node) {
        Some(texture) => {
            small.append_scaled_texture(&texture, gsk::ScalingFilter::Trilinear, &bounds)
        }
        None => {
            small.scale(
                width as f32 / full_width as f32,
                height as f32 / full_height as f32,
            );
            small.append_node(&node);
        }
    }
    let texture = renderer.render_texture(small.to_node()?, Some(&bounds));
    let mut downloader = gdk::TextureDownloader::new(&texture);
    downloader.set_format(gdk::MemoryFormat::R8g8b8);
    let (bytes, stride) = downloader.download_bytes();
    Some((bytes.to_vec(), stride))
}

/// The video frame's own texture inside what the paintable drew, looking
/// through the wrappers a video sink puts around it.
fn frame_texture(node: &gsk::RenderNode) -> Option<gdk::Texture> {
    if let Some(node) = node.downcast_ref::<gsk::TextureNode>() {
        return Some(node.texture());
    }
    if let Some(node) = node.downcast_ref::<gsk::TextureScaleNode>() {
        return Some(node.texture());
    }
    if let Some(node) = node.downcast_ref::<gsk::ContainerNode>() {
        return (0..node.n_children()).find_map(|index| frame_texture(&node.child(index)));
    }
    let child = if let Some(node) = node.downcast_ref::<gsk::TransformNode>() {
        node.child()
    } else if let Some(node) = node.downcast_ref::<gsk::OpacityNode>() {
        node.child()
    } else if let Some(node) = node.downcast_ref::<gsk::ClipNode>() {
        node.child()
    } else if let Some(node) = node.downcast_ref::<gsk::ColorMatrixNode>() {
        node.child()
    } else if let Some(node) = node.downcast_ref::<gsk::MaskNode>() {
        node.source()
    } else {
        return None;
    };
    frame_texture(&child)
}
