use crate::ui::stage_layout::{
    self, Anchor, Arrangement, LyricsStyle, Rect, Scrim, Side, StageInput,
};
use adw::prelude::*;
use gtk::gdk;
use gtk::glib;
use gtk::graphene;
use gtk::gsk;
use gtk::subclass::prelude::*;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// How long the picture takes to move when a column comes or goes, or the
/// cover opens out into the video.
const TRANSITION_MS: u32 = 320;
/// How far the status pill sits below the top of the picture or the header.
const STATUS_GAP: f64 = 14.0;
/// The width a cover's title is measured at, so a long title reserves its
/// second line however wide the cover ends up.
const TITLE_MEASURE_WIDTH: f64 = 240.0;
/// How far Up Next slides in from its edge as it appears.
const SHEET_SLIDE: f64 = 40.0;
/// The shade under a column over the picture, darkest at its outer edge.
const SCRIM_STOPS: [(f32, f32); 3] = [(0.0, 0.86), (0.55, 0.68), (1.0, 0.0)];

/// Told after a layout pass that changed where things go.
type ArrangedListener = Rc<dyn Fn(&Arrangement)>;

/// What the stage holds, bottom to top.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Layer {
    Ambient,
    Poster,
    Video,
    Status,
    Lyrics,
    Card,
    Queue,
}

const LAYERS: [Layer; 7] = [
    Layer::Ambient,
    Layer::Poster,
    Layer::Video,
    Layer::Status,
    Layer::Lyrics,
    Layer::Card,
    Layer::Queue,
];

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct VideoStage {
        pub slots: RefCell<[Option<gtk::Widget>; 7]>,
        pub input: Cell<StageInput>,
        pub shown: Cell<Option<Arrangement>>,
        pub from: Cell<Option<Arrangement>>,
        pub progress: Cell<f64>,
        pub animation: RefCell<Option<adw::TimedAnimation>>,
        pub reported: Cell<Option<Arrangement>>,
        pub report_queued: Cell<bool>,
        pub on_arranged: RefCell<Option<ArrangedListener>>,
        pub scrim_alpha: Cell<f64>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for VideoStage {
        const NAME: &'static str = "FlaccyVideoStage";
        type Type = super::VideoStage;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for VideoStage {
        fn constructed(&self) {
            self.parent_constructed();
            self.progress.set(1.0);
            let obj = self.obj();
            obj.set_overflow(gtk::Overflow::Hidden);
            obj.set_hexpand(true);
            obj.set_vexpand(true);
            obj.add_css_class("np-video-stage");
        }

        fn dispose(&self) {
            for slot in self.slots.borrow_mut().iter_mut() {
                if let Some(child) = slot.take() {
                    child.unparent();
                }
            }
        }
    }

    impl WidgetImpl for VideoStage {
        fn measure(&self, _orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            (0, 0, -1, -1)
        }

        fn size_allocate(&self, width: i32, height: i32, _baseline: i32) {
            self.obj().arrange_children(width as f64, height as f64);
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let obj = self.obj();
            let slots = self.slots.borrow();
            for (layer, child) in LAYERS.iter().zip(slots.iter()) {
                if *layer == Layer::Lyrics {
                    if let Some(scrim) = self.shown.get().and_then(|shown| shown.scrim) {
                        draw_scrim(snapshot, scrim, self.scrim_alpha.get());
                    }
                }
                if let Some(child) = child {
                    obj.snapshot_child(child, snapshot);
                }
            }
        }
    }

    fn draw_scrim(snapshot: &gtk::Snapshot, scrim: Scrim, alpha: f64) {
        if alpha <= 0.0 || scrim.rect.width <= 0.0 {
            return;
        }
        let rect = scrim.rect;
        let bounds = graphene::Rect::new(
            rect.x as f32,
            rect.y as f32,
            rect.width as f32,
            rect.height as f32,
        );
        let (from, to) = match scrim.side {
            Side::Left => (rect.x, rect.right()),
            Side::Right => (rect.right(), rect.x),
        };
        let stops: Vec<gsk::ColorStop> = SCRIM_STOPS
            .iter()
            .map(|(offset, shade)| {
                gsk::ColorStop::new(*offset, gdk::RGBA::new(0.0, 0.0, 0.0, shade * alpha as f32))
            })
            .collect();
        snapshot.append_linear_gradient(
            &bounds,
            &graphene::Point::new(from as f32, 0.0),
            &graphene::Point::new(to as f32, 0.0),
            &stops,
        );
    }
}

glib::wrapper! {
    /// Now Playing: the music video as large as the window allows and the
    /// glow it casts around it, or the cover with its title under it while
    /// there is no video, and the lyrics, Up Next or Comments and title card
    /// laid beside, under or over it as `stage_layout` decides. Columns coming
    /// and going and the cover opening out into the video move the picture
    /// with a short glide and fade; a resize just lays everything out again.
    pub struct VideoStage(ObjectSubclass<imp::VideoStage>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for VideoStage {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl VideoStage {
    /// Puts `child` in `layer`, replacing whatever was there.
    pub fn set_layer(&self, layer: Layer, child: Option<&impl IsA<gtk::Widget>>) {
        let index = layer_index(layer);
        let imp = self.imp();
        if let Some(old) = imp.slots.borrow_mut()[index].take() {
            old.unparent();
        }
        if let Some(child) = child {
            let child = child.as_ref();
            let above = imp.slots.borrow()[index + 1..]
                .iter()
                .flatten()
                .next()
                .cloned();
            match above {
                Some(above) => child.insert_before(self, Some(&above)),
                None => child.set_parent(self),
            }
            imp.slots.borrow_mut()[index] = Some(child.clone());
        }
        self.queue_allocate();
    }

    pub fn layer(&self, layer: Layer) -> Option<gtk::Widget> {
        self.imp().slots.borrow()[layer_index(layer)].clone()
    }

    pub fn set_lyrics(&self, lyrics: Option<LyricsStyle>) {
        self.change(|input| input.lyrics = lyrics);
    }

    pub fn set_queue(&self, queue: bool) {
        self.change(|input| input.queue = queue);
    }

    pub fn set_lyrics_side(&self, side: Side) {
        self.change(|input| input.lyrics_side = side);
    }

    /// What the picture is: the video, at its shape once any bars are
    /// cropped away, or the cover, framed square with its title under it.
    /// The stage glides from one to the other, fading the cover out as the
    /// video opens up out of it.
    pub fn set_picture(&self, framed: bool, aspect: f64) {
        self.change(|input| {
            input.framed = framed;
            input.aspect = aspect;
        });
    }

    pub fn set_insets(&self, top: f64, bottom: f64) {
        let mut input = self.imp().input.get();
        if input.top_inset == top && input.bottom_inset == bottom {
            return;
        }
        input.top_inset = top;
        input.bottom_inset = bottom;
        self.imp().input.set(input);
        self.queue_allocate();
    }

    /// How far the header and the dock reach while they show: the side
    /// panels keep clear of that much even while they rest, so nothing moves
    /// under the pointer as they come and go.
    pub fn set_chrome_insets(&self, top: f64, bottom: f64) {
        let mut input = self.imp().input.get();
        if input.chrome_top == top && input.chrome_bottom == bottom {
            return;
        }
        input.chrome_top = top;
        input.chrome_bottom = bottom;
        self.imp().input.set(input);
        self.queue_allocate();
    }

    pub fn set_zoom(&self, zoom: f64) {
        let mut input = self.imp().input.get();
        if input.zoom == zoom {
            return;
        }
        input.zoom = zoom;
        self.imp().input.set(input);
        self.queue_allocate();
    }

    /// Runs `f` after a layout pass whenever where things go changed in a way
    /// the lyrics or the picture's frame have to follow; never from inside
    /// the layout pass itself.
    pub fn connect_arranged(&self, f: impl Fn(&Arrangement) + 'static) {
        *self.imp().on_arranged.borrow_mut() = Some(Rc::new(f));
    }

    /// Hands the arrangement over again after the next layout pass, for a
    /// follower that was away: the panels coming back onto the stage.
    pub fn rearrange(&self) {
        self.imp().reported.set(None);
        self.queue_allocate();
    }

    /// Where things went in the last layout pass, transition included.
    pub fn arrangement(&self) -> Option<Arrangement> {
        self.imp().shown.get()
    }

    /// Changes the input and glides from what is on screen to the new
    /// arrangement.
    fn change(&self, edit: impl FnOnce(&mut StageInput)) {
        let imp = self.imp();
        let mut input = imp.input.get();
        let before = input;
        edit(&mut input);
        if input == before {
            return;
        }
        imp.input.set(input);
        if self.is_mapped() && imp.shown.get().is_some() {
            self.start_transition();
        }
        self.queue_allocate();
    }

    fn start_transition(&self) {
        let imp = self.imp();
        if let Some(animation) = imp.animation.borrow_mut().take() {
            animation.skip();
        }
        imp.from.set(imp.shown.get());
        imp.progress.set(0.0);
        let weak = self.downgrade();
        let target = adw::CallbackAnimationTarget::new(move |value| {
            if let Some(stage) = weak.upgrade() {
                stage.imp().progress.set(value);
                stage.queue_allocate();
            }
        });
        let animation = adw::TimedAnimation::new(self, 0.0, 1.0, TRANSITION_MS, target);
        animation.set_easing(adw::Easing::EaseOutCubic);
        *imp.animation.borrow_mut() = Some(animation.clone());
        animation.play();
    }

    fn arrange_children(&self, width: f64, height: f64) {
        let imp = self.imp();
        let mut input = imp.input.get();
        input.width = width;
        input.height = height;
        input.title_height = self.title_height(input.zoom);
        let target = stage_layout::arrange(input);
        let t = imp.progress.get().clamp(0.0, 1.0);
        let from = if t < 1.0 { imp.from.get() } else { None };
        let video = match from {
            Some(from) => from.video.lerp(target.video, t),
            None => target.video,
        };
        let cover = |arrangement: &Arrangement| if arrangement.framed { 1.0 } else { 0.0 };
        let cover_weight = match from {
            Some(from) => cover(&from) + (cover(&target) - cover(&from)) * t,
            None => cover(&target),
        };
        let stage = Rect::new(0.0, 0.0, width, height);
        let visible = video.intersection(stage);

        self.place(Layer::Ambient, stage, 1.0 - cover_weight);
        self.place(Layer::Poster, video, cover_weight);
        self.place(Layer::Video, video, 1.0 - cover_weight);
        self.place_status(visible, &input);

        let lyrics_opacity = self.place_column(
            Layer::Lyrics,
            from.and_then(|from| from.lyrics),
            target.lyrics,
            t,
            |(placement, rect)| (placement, rect),
            0.0,
        );
        let scrim = match (from.and_then(|from| from.scrim), target.scrim) {
            (_, Some(_)) => lyrics_opacity,
            (Some(_), None) => 1.0 - t,
            (None, None) => 0.0,
        };
        imp.scrim_alpha.set(scrim);
        let queue_side = match input.lyrics_side {
            Side::Left => 1.0,
            Side::Right => -1.0,
        };
        self.place_column(
            Layer::Queue,
            from.and_then(|from| from.queue),
            target.queue,
            t,
            |(rect, floating)| (floating, rect),
            SHEET_SLIDE * input.zoom * queue_side,
        );
        self.place_card(target.card);

        let shown = Arrangement {
            video,
            scrim: target.scrim.or(from.and_then(|from| from.scrim)),
            ..target
        };
        imp.shown.set(Some(shown));
        if t >= 1.0 {
            imp.from.set(None);
        }
        self.report(target);
    }

    fn place(&self, layer: Layer, rect: Rect, opacity: f64) {
        let Some(child) = self.layer(layer) else {
            return;
        };
        if !child.is_visible() {
            return;
        }
        if opacity <= 0.0 || rect.width < 1.0 || rect.height < 1.0 {
            child.set_child_visible(false);
            return;
        }
        child.set_child_visible(true);
        child.set_opacity(opacity);
        child.measure(gtk::Orientation::Horizontal, -1);
        child.measure(gtk::Orientation::Vertical, -1);
        child.size_allocate(&allocation(rect), -1);
    }

    /// The status pill at its natural size, centred across the top of the
    /// picture and clear of the header.
    fn place_status(&self, area: Rect, input: &StageInput) {
        let Some(child) = self.layer(Layer::Status) else {
            return;
        };
        if !child.is_visible() {
            return;
        }
        let gap = STATUS_GAP * input.zoom;
        let limit = (area.width - 2.0 * gap).max(1.0) as i32;
        let (minimum, natural, _, _) = child.measure(gtk::Orientation::Horizontal, -1);
        let width = natural.min(limit).max(minimum).max(1);
        let (_, height, _, _) = child.measure(gtk::Orientation::Vertical, width);
        let rect = Rect::new(
            area.x + (area.width - width as f64) / 2.0,
            area.y.max(input.top_inset) + gap,
            width as f64,
            height as f64,
        );
        child.size_allocate(&allocation(rect), -1);
    }

    /// How tall the title under a cover is, measured on the card itself
    /// rather than on whatever reveals it, which measures nothing while it
    /// is folded away.
    fn title_height(&self, zoom: f64) -> f64 {
        let Some(card) = self.layer(Layer::Card) else {
            return 0.0;
        };
        let body = match card.downcast_ref::<gtk::Revealer>() {
            Some(revealer) => revealer.child(),
            None => Some(card),
        };
        let Some(body) = body else { return 0.0 };
        let width = (TITLE_MEASURE_WIDTH * zoom).round() as i32;
        let (_, natural, _, _) = body.measure(gtk::Orientation::Vertical, width);
        natural as f64
    }

    /// Places a column that may be appearing, staying or going: it keeps its
    /// target size from the first frame, so its text is wrapped once rather
    /// than on every frame of the glide, and fades (and slides by `slide`)
    /// in or out. Returns the opacity it was given.
    fn place_column<T: Copy, K: PartialEq>(
        &self,
        layer: Layer,
        from: Option<T>,
        to: Option<T>,
        t: f64,
        parts: impl Fn(T) -> (K, Rect),
        slide: f64,
    ) -> f64 {
        let Some(child) = self.layer(layer) else {
            return 0.0;
        };
        let (rect, opacity) = match (from.map(&parts), to.map(&parts)) {
            (Some((was, _)), Some((kind, rect))) if was == kind => (rect, 1.0),
            (_, Some((_, rect))) => (shifted(rect, slide * (1.0 - t)), t),
            (Some((_, rect)), None) if t < 1.0 => (shifted(rect, slide * t), 1.0 - t),
            _ => {
                child.set_child_visible(false);
                return 0.0;
            }
        };
        child.set_child_visible(true);
        child.set_opacity(opacity);
        child.measure(gtk::Orientation::Horizontal, -1);
        child.measure(gtk::Orientation::Vertical, rect.width as i32);
        child.size_allocate(&allocation(rect), -1);
        opacity
    }

    fn place_card(&self, anchor: Option<Anchor>) {
        let Some(child) = self.layer(Layer::Card) else {
            return;
        };
        let Some(anchor) = anchor else {
            child.set_child_visible(false);
            return;
        };
        child.set_child_visible(true);
        let limit = anchor.max_width.max(1.0) as i32;
        let (minimum, natural, _, _) = child.measure(gtk::Orientation::Horizontal, -1);
        let width = if anchor.centered {
            limit.max(minimum)
        } else {
            natural.min(limit).max(minimum).max(1)
        };
        let (_, height, _, _) = child.measure(gtk::Orientation::Vertical, width);
        let x = if anchor.centered {
            anchor.x - width as f64 / 2.0
        } else if anchor.align_right {
            anchor.x - width as f64
        } else {
            anchor.x
        };
        let y = if anchor.from_top {
            anchor.y
        } else {
            anchor.y - height as f64
        };
        child.size_allocate(
            &allocation(Rect::new(x, y, width as f64, height as f64)),
            -1,
        );
    }

    /// Hands the arrangement to whoever follows it, once it settles into
    /// something new, from an idle callback so nothing it changes lands inside
    /// this layout pass.
    fn report(&self, target: Arrangement) {
        let imp = self.imp();
        let changed = imp.reported.get().is_none_or(|reported| {
            reported.placement() != target.placement()
                || reported.floating != target.floating
                || reported.framed != target.framed
                || captions_moved(&reported, &target)
        });
        if !changed || imp.report_queued.replace(true) {
            return;
        }
        let weak = self.downgrade();
        glib::idle_add_local_once(move || {
            let Some(stage) = weak.upgrade() else { return };
            let imp = stage.imp();
            imp.report_queued.set(false);
            let mut input = imp.input.get();
            input.width = stage.width() as f64;
            input.height = stage.height() as f64;
            let target = stage_layout::arrange(input);
            imp.reported.set(Some(target));
            let callback = imp.on_arranged.borrow().clone();
            if let Some(callback) = callback {
                callback(&target);
            }
        });
    }
}

fn captions_moved(before: &Arrangement, after: &Arrangement) -> bool {
    match (before.captions, after.captions) {
        (Some(a), Some(b)) => {
            (a.scale - b.scale).abs() > 0.01
                || (a.margin - b.margin).abs() > 0.5
                || (a.band.width - b.band.width).abs() > 0.5
        }
        (a, b) => a.is_some() != b.is_some(),
    }
}

fn shifted(rect: Rect, by: f64) -> Rect {
    Rect {
        x: rect.x + by,
        ..rect
    }
}

fn layer_index(layer: Layer) -> usize {
    LAYERS
        .iter()
        .position(|candidate| *candidate == layer)
        .unwrap_or(0)
}

fn allocation(rect: Rect) -> gtk::Allocation {
    let x = rect.x.round();
    let y = rect.y.round();
    gtk::Allocation::new(
        x as i32,
        y as i32,
        ((rect.right().round() - x) as i32).max(1),
        ((rect.bottom().round() - y) as i32).max(1),
    )
}
