use super::flow_geometry::{clamped, Glide, Slot};
use super::{album_facts, request_size, AlbumCard, AlbumView, Shelf};
use crate::theme::AlbumsView;
use adw::prelude::*;
use gtk::subclass::prelude::ObjectSubclassIsExt;
use gtk::{gdk, glib, pango};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

/// How many places Page Up and Page Down move.
const PAGE: f64 = 5.0;

/// A pointer has to travel this far before a press becomes a drag of the
/// shelf instead of a click on a cover.
const DRAG_THRESHOLD: f64 = 8.0;

/// A move of more places than this starts this many places short of where it
/// is going instead of running the whole way: crossing a large shelf would
/// otherwise ask for every cover on the way just to flash it past.
const LONGEST_GLIDE: f64 = 7.0;

/// The backdrop takes the middle cover's color once the shelf has rested on
/// it this long, so flicking through does not flash every album's color.
const BACKDROP_SETTLE: Duration = Duration::from_millis(260);

mod imp {
    use super::super::flow_geometry::{Flow, Glide, Slot};
    use crate::ui::FrameDriver;
    use gtk::prelude::*;
    use gtk::subclass::prelude::*;
    use gtk::{glib, graphene, gsk};
    use std::cell::{Cell, RefCell};

    /// Enough covers for a carousel far wider than any screen; the ones that
    /// do not show are not drawn or laid out.
    pub const POOL: usize = 48;

    pub type Binder = Box<dyn Fn(usize, &gtk::Picture, i32)>;

    #[derive(Default)]
    pub struct CoverFlow {
        pub pool: RefCell<Vec<gtk::Picture>>,
        pub bound: RefCell<Vec<Option<usize>>>,
        pub glide: Cell<Glide>,
        pub target: Cell<f64>,
        pub count: Cell<usize>,
        pub centre: Cell<Option<usize>>,
        pub driver: FrameDriver,
        pub binder: RefCell<Option<Binder>>,
        pub on_centre: RefCell<Option<Box<dyn Fn(Option<usize>)>>>,
        pub on_activate: RefCell<Option<Box<dyn Fn(usize)>>>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for CoverFlow {
        const NAME: &'static str = "FlaccyCoverFlow";
        type Type = super::CoverFlow;
        type ParentType = gtk::Widget;

        fn class_init(klass: &mut Self::Class) {
            klass.set_css_name("coverflow");
        }
    }

    impl ObjectImpl for CoverFlow {
        fn constructed(&self) {
            self.parent_constructed();
            let widget = self.obj();
            widget.set_overflow(gtk::Overflow::Hidden);
            widget.set_focusable(true);
            widget.set_hexpand(true);
            widget.set_vexpand(true);
            let pool: Vec<gtk::Picture> = (0..POOL)
                .map(|_| {
                    let picture = gtk::Picture::builder()
                        .content_fit(gtk::ContentFit::Cover)
                        .can_shrink(true)
                        .build();
                    picture.set_overflow(gtk::Overflow::Hidden);
                    picture.add_css_class("cover");
                    picture.add_css_class("flow-cover");
                    picture.set_child_visible(false);
                    picture.set_parent(&*widget);
                    picture
                })
                .collect();
            *self.bound.borrow_mut() = vec![None; POOL];
            *self.pool.borrow_mut() = pool;
        }

        fn dispose(&self) {
            self.driver.stop();
            for picture in self.pool.borrow_mut().drain(..) {
                picture.unparent();
            }
        }
    }

    impl CoverFlow {
        pub fn flow(&self) -> Flow {
            let widget = self.obj();
            Flow::fitting(widget.width() as f64, widget.height() as f64)
        }

        pub fn slots(&self) -> Vec<Slot> {
            let widget = self.obj();
            self.flow().slots(
                widget.width() as f64,
                widget.height() as f64,
                self.glide.get().position,
                self.count.get(),
            )
        }

        /// Gives every cover that shows the album it stands for, asking the
        /// binder only for the ones whose album changed.
        pub fn bind(&self, slots: &[Slot], side: i32) {
            let pool = self.pool.borrow();
            let binder = self.binder.borrow();
            let Some(binder) = binder.as_ref() else {
                return;
            };
            for slot in slots {
                let at = slot.index % POOL;
                let fresh = self.bound.borrow()[at] != Some(slot.index);
                if fresh {
                    self.bound.borrow_mut()[at] = Some(slot.index);
                    binder(slot.index, &pool[at], side);
                }
            }
        }
    }

    impl WidgetImpl for CoverFlow {
        fn measure(&self, orientation: gtk::Orientation, _for_size: i32) -> (i32, i32, i32, i32) {
            match orientation {
                gtk::Orientation::Horizontal => (240, 720, -1, -1),
                _ => (172, 400, -1, -1),
            }
        }

        fn size_allocate(&self, width: i32, height: i32, _baseline: i32) {
            let flow = Flow::fitting(width as f64, height as f64);
            let slots = flow.slots(
                width as f64,
                height as f64,
                self.glide.get().position,
                self.count.get(),
            );
            self.bind(&slots, flow.side as i32);
            let pool = self.pool.borrow();
            let mut shown = [false; POOL];
            for slot in &slots {
                let at = slot.index % POOL;
                shown[at] = true;
                let picture = &pool[at];
                picture.set_child_visible(true);
                picture.set_opacity(slot.opacity);
                let side = slot.side.round() as i32;
                let place = graphene::Point::new(slot.x.round() as f32, slot.y.round() as f32);
                picture.measure(gtk::Orientation::Horizontal, -1);
                picture.allocate(
                    side,
                    side,
                    -1,
                    Some(gsk::Transform::new().translate(&place)),
                );
            }
            for (picture, shown) in pool.iter().zip(shown) {
                if !shown {
                    picture.set_child_visible(false);
                }
            }
        }
    }
}

glib::wrapper! {
    /// A shelf of covers flipped through sideways: the one in the middle at
    /// full size, its neighbours smaller on either side. It lays out only the
    /// covers that show, so it is as quick over ten thousand albums as over
    /// ten, and it runs a frame clock only while it is moving.
    pub struct CoverFlow(ObjectSubclass<imp::CoverFlow>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Default for CoverFlow {
    fn default() -> Self {
        glib::Object::new()
    }
}

impl CoverFlow {
    /// Tells the carousel how many albums the shelf holds now. Every cover is
    /// rebound, since any place may hold a different album.
    pub fn set_count(&self, count: usize) {
        let imp = self.imp();
        imp.count.set(count);
        let place = clamped(imp.target.get().round(), count);
        imp.target.set(place);
        imp.glide.set(Glide {
            position: place,
            velocity: 0.0,
        });
        imp.driver.stop();
        self.rebind_all();
        self.announce_centre(true);
    }

    /// Forgets which album every cover shows, so the next layout asks for all
    /// of them again.
    pub fn rebind_all(&self) {
        for bound in self.imp().bound.borrow_mut().iter_mut() {
            *bound = None;
        }
        self.queue_allocate();
    }

    pub fn place(&self) -> f64 {
        self.imp().target.get()
    }

    /// The album in the middle, or nearest it while the shelf is moving.
    pub fn centre(&self) -> Option<usize> {
        let imp = self.imp();
        (imp.count.get() > 0)
            .then(|| clamped(imp.glide.get().position.round(), imp.count.get()) as usize)
    }

    /// The places whose covers are laid out now.
    pub fn shown(&self) -> Vec<usize> {
        self.imp()
            .bound
            .borrow()
            .iter()
            .flatten()
            .copied()
            .collect()
    }

    /// The cover drawn for the album at `index`, when it shows.
    pub fn picture_for(&self, index: usize) -> Option<gtk::Picture> {
        let imp = self.imp();
        let at = index % imp::POOL;
        (imp.bound.borrow()[at] == Some(index)).then(|| imp.pool.borrow()[at].clone())
    }

    pub fn connect_bind(&self, binder: impl Fn(usize, &gtk::Picture, i32) + 'static) {
        *self.imp().binder.borrow_mut() = Some(Box::new(binder));
    }

    pub fn connect_centre(&self, callback: impl Fn(Option<usize>) + 'static) {
        *self.imp().on_centre.borrow_mut() = Some(Box::new(callback));
    }

    pub fn connect_activated(&self, callback: impl Fn(usize) + 'static) {
        *self.imp().on_activate.borrow_mut() = Some(Box::new(callback));
    }

    fn announce_centre(&self, even_if_same: bool) {
        let imp = self.imp();
        let centre = self.centre();
        if imp.centre.replace(centre) != centre || even_if_same {
            if let Some(callback) = imp.on_centre.borrow().as_ref() {
                callback(centre);
            }
        }
    }

    fn moved(&self) {
        self.queue_allocate();
        self.announce_centre(false);
    }

    /// Sets the shelf directly at `place`, as a drag does.
    fn hold_at(&self, place: f64) {
        let imp = self.imp();
        imp.driver.stop();
        let place = clamped(place, imp.count.get());
        imp.target.set(place);
        imp.glide.set(Glide {
            position: place,
            velocity: 0.0,
        });
        self.moved();
    }

    /// Sends the shelf to `place`, gliding there unless animations are off.
    pub fn go_to(&self, place: f64) {
        let imp = self.imp();
        let place = clamped(place, imp.count.get());
        imp.target.set(place);
        let animated =
            gtk::Settings::default().is_none_or(|settings| settings.is_gtk_enable_animations());
        if !animated || !self.is_mapped() {
            self.hold_at(place);
            return;
        }
        let glide = imp.glide.get();
        let distance = place - glide.position;
        if distance.abs() > LONGEST_GLIDE {
            imp.glide.set(Glide {
                position: place - LONGEST_GLIDE.copysign(distance),
                velocity: 0.0,
            });
        }
        let weak = self.downgrade();
        imp.driver.start(self, move |seconds| {
            let Some(flow) = weak.upgrade() else { return };
            let imp = flow.imp();
            let mut glide = imp.glide.get();
            let moving = glide.step(imp.target.get(), seconds);
            imp.glide.set(glide);
            flow.moved();
            if !moving {
                imp.driver.stop();
            }
        });
    }

    pub fn step(&self, by: f64) {
        self.go_to(self.imp().target.get().round() + by);
    }

    fn slot_at(&self, x: f64, y: f64) -> Option<Slot> {
        self.imp().slots().into_iter().rev().find(|slot| {
            x >= slot.x && x < slot.x + slot.side && y >= slot.y && y < slot.y + slot.side
        })
    }

    pub fn index_at(&self, x: f64, y: f64) -> Option<usize> {
        self.slot_at(x, y).map(|slot| slot.index)
    }

    fn activate_centre(&self) {
        if let (Some(centre), Some(callback)) =
            (self.centre(), self.imp().on_activate.borrow().as_ref())
        {
            callback(centre);
        }
    }

    /// A click on the middle cover opens it; a click on any other brings it
    /// to the middle.
    fn clicked(&self, x: f64, y: f64) {
        self.grab_focus();
        match self.index_at(x, y) {
            Some(index) if Some(index) == self.centre() => self.activate_centre(),
            Some(index) => self.go_to(index as f64),
            None => {}
        }
    }

    fn key_pressed(&self, key: gdk::Key) -> glib::Propagation {
        let last = self.imp().count.get().saturating_sub(1) as f64;
        match key {
            gdk::Key::Left | gdk::Key::KP_Left | gdk::Key::h => self.step(-1.0),
            gdk::Key::Right | gdk::Key::KP_Right | gdk::Key::l => self.step(1.0),
            gdk::Key::Page_Up => self.step(-PAGE),
            gdk::Key::Page_Down => self.step(PAGE),
            gdk::Key::Home => self.go_to(0.0),
            gdk::Key::End => self.go_to(last),
            gdk::Key::Return | gdk::Key::KP_Enter => self.activate_centre(),
            _ => return glib::Propagation::Proceed,
        }
        glib::Propagation::Stop
    }

    /// Wires the pointer, the wheel, the touchpad and the keyboard.
    fn attach_input(&self) {
        let dragged = Rc::new(Cell::new(false));
        let drag_from = Rc::new(Cell::new(0.0));
        let drag = gtk::GestureDrag::new();
        {
            let (weak, dragged, drag_from) =
                (self.downgrade(), Rc::clone(&dragged), Rc::clone(&drag_from));
            drag.connect_drag_begin(move |_, _, _| {
                dragged.set(false);
                if let Some(flow) = weak.upgrade() {
                    drag_from.set(flow.imp().glide.get().position);
                }
            });
        }
        {
            let (weak, dragged, drag_from) =
                (self.downgrade(), Rc::clone(&dragged), Rc::clone(&drag_from));
            drag.connect_drag_update(move |_, dx, _| {
                let Some(flow) = weak.upgrade() else { return };
                if dx.abs() < DRAG_THRESHOLD && !dragged.get() {
                    return;
                }
                dragged.set(true);
                flow.hold_at(drag_from.get() - dx / flow.imp().flow().pitch());
            });
        }
        {
            let (weak, dragged) = (self.downgrade(), Rc::clone(&dragged));
            drag.connect_drag_end(move |gesture, dx, dy| {
                let Some(flow) = weak.upgrade() else { return };
                if dragged.get() {
                    flow.go_to(flow.imp().glide.get().position.round());
                } else if let Some((x, y)) = gesture.start_point() {
                    flow.clicked(x + dx, y + dy);
                }
            });
        }
        self.add_controller(drag);

        let scroll = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::BOTH_AXES);
        {
            let weak = self.downgrade();
            scroll.connect_scroll(move |controller, dx, dy| {
                let Some(flow) = weak.upgrade() else {
                    return glib::Propagation::Proceed;
                };
                let travelled = if dx.abs() > dy.abs() { dx } else { dy };
                if controller.unit() == gdk::ScrollUnit::Surface {
                    let imp = flow.imp();
                    flow.hold_at(imp.glide.get().position + travelled / imp.flow().pitch());
                } else {
                    flow.step(travelled.signum() * travelled.abs().max(1.0).round());
                }
                glib::Propagation::Stop
            });
        }
        {
            let weak = self.downgrade();
            scroll.connect_scroll_end(move |_| {
                if let Some(flow) = weak.upgrade() {
                    flow.go_to(flow.imp().glide.get().position.round());
                }
            });
        }
        self.add_controller(scroll);

        let keys = gtk::EventControllerKey::new();
        {
            let weak = self.downgrade();
            keys.connect_key_pressed(move |_, key, _, modifiers| {
                let chord = gdk::ModifierType::CONTROL_MASK
                    | gdk::ModifierType::ALT_MASK
                    | gdk::ModifierType::SUPER_MASK;
                match weak.upgrade() {
                    Some(flow) if !modifiers.intersects(chord) => flow.key_pressed(key),
                    _ => glib::Propagation::Proceed,
                }
            });
        }
        self.add_controller(keys);
    }
}

/// The albums one at a time: the carousel, what the middle album is beneath
/// it with Play, Shuffle and Open, and a slider to cross a large shelf in one
/// move. Arrow keys, the wheel, a drag or a click on a neighbour turn it.
pub struct Carousel {
    root: gtk::Overlay,
    flow: CoverFlow,
    shelf: Rc<Shelf>,
}

struct Caption {
    shelf: Rc<Shelf>,
    title: gtk::Label,
    artist: gtk::Label,
    facts: gtk::Label,
    counter: gtk::Label,
    actions: gtk::Box,
    slider: gtk::Scale,
    sliding: Cell<bool>,
}

fn pill(label: &str, icon: &str, suggested: bool) -> gtk::Button {
    let content = adw::ButtonContent::builder()
        .label(label)
        .icon_name(icon)
        .build();
    let button = gtk::Button::builder().child(&content).build();
    button.add_css_class("pill");
    if suggested {
        button.add_css_class("suggested-action");
    }
    button
}

impl Caption {
    fn show(&self, centre: Option<usize>) {
        let count = self.shelf.count();
        let album = centre.and_then(|index| self.shelf.album_at(index as u32));
        self.actions.set_sensitive(album.is_some());
        self.slider.set_visible(count > 1);
        self.sliding.set(true);
        self.slider
            .set_range(0.0, count.saturating_sub(1).max(1) as f64);
        self.slider.set_value(centre.unwrap_or(0) as f64);
        self.sliding.set(false);
        match (album, centre) {
            (Some(album), Some(index)) => {
                self.title.set_label(&album.title);
                self.artist.set_label(&album.artist);
                self.facts.set_label(&album_facts(&album));
                self.counter.set_label(&format!("{} of {count}", index + 1));
            }
            _ => {
                self.title.set_label("No albums here");
                self.artist.set_label("");
                self.facts
                    .set_label("Nothing matches the search or the filter that is on.");
                self.counter.set_label("");
            }
        }
    }
}

fn caption(shelf: &Rc<Shelf>, flow: &CoverFlow) -> (gtk::Box, Rc<Caption>) {
    let title = gtk::Label::builder()
        .ellipsize(pango::EllipsizeMode::End)
        .justify(gtk::Justification::Center)
        .build();
    title.add_css_class("title-1");
    title.add_css_class("flow-title");
    let artist = gtk::Label::builder()
        .ellipsize(pango::EllipsizeMode::End)
        .halign(gtk::Align::Center)
        .build();
    artist.add_css_class("title-4");
    artist.add_css_class("dim");
    let facts = gtk::Label::builder()
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    facts.add_css_class("dim");
    facts.add_css_class("caption");

    let play = pill("Play", "flaccy-play-symbolic", true);
    let shuffle = pill("Shuffle", "flaccy-shuffle-symbolic", false);
    let open = pill("Open", "flaccy-album-symbolic", false);
    open.set_tooltip_text(Some("Open the album (Enter)"));
    let actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .halign(gtk::Align::Center)
        .margin_top(8)
        .build();
    actions.append(&play);
    actions.append(&shuffle);
    actions.append(&open);

    let slider = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 1.0);
    slider.set_draw_value(false);
    slider.set_hexpand(true);
    slider.set_tooltip_text(Some("Move through the shelf"));
    slider.update_property(&[gtk::accessible::Property::Label("Position in the shelf")]);
    let counter = gtk::Label::builder().width_chars(11).xalign(1.0).build();
    counter.add_css_class("dim");
    counter.add_css_class("caption");
    counter.add_css_class("numeric");
    let rail = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_top(6)
        .build();
    rail.append(&slider);
    rail.append(&counter);

    let widget = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .margin_start(32)
        .margin_end(32)
        .margin_bottom(20)
        .build();
    widget.add_css_class("flow-caption");
    widget.append(&title);
    widget.append(&artist);
    widget.append(&facts);
    widget.append(&actions);
    widget.append(&rail);

    let caption = Rc::new(Caption {
        shelf: Rc::clone(shelf),
        title,
        artist,
        facts,
        counter,
        actions,
        slider: slider.clone(),
        sliding: Cell::new(false),
    });
    for (button, shuffled) in [(&play, false), (&shuffle, true)] {
        let (shelf, flow) = (Rc::clone(shelf), flow.downgrade());
        button.connect_clicked(move |_| {
            if let Some(centre) = flow.upgrade().and_then(|flow| flow.centre()) {
                shelf.play(centre as u32, shuffled);
            }
        });
    }
    {
        let (shelf, flow) = (Rc::clone(shelf), flow.downgrade());
        open.connect_clicked(move |_| {
            if let Some(centre) = flow.upgrade().and_then(|flow| flow.centre()) {
                shelf.open(centre as u32);
            }
        });
    }
    {
        let (weak, flow) = (Rc::downgrade(&caption), flow.downgrade());
        slider.connect_value_changed(move |slider| {
            let (Some(caption), Some(flow)) = (weak.upgrade(), flow.upgrade()) else {
                return;
            };
            if !caption.sliding.get() {
                flow.go_to(slider.value().round());
            }
        });
    }
    {
        let (weak, shelf) = (Rc::downgrade(&caption), Rc::clone(shelf));
        crate::ui::controls::attach_label_nav(
            &shelf.ui,
            &caption.artist,
            "Go to Artist",
            move |ui| {
                if let Some(caption) = weak.upgrade() {
                    let artist = caption.artist.label();
                    if !artist.is_empty() {
                        crate::ui::goto_artist(ui, &artist);
                    }
                }
            },
        );
    }
    (widget, caption)
}

/// Asks for the cover of the album at `index` and paints it into `picture`
/// if that picture still stands for that album when the cover arrives.
fn bind_cover(
    shelf: &Rc<Shelf>,
    flow: &CoverFlow,
    index: usize,
    picture: &gtk::Picture,
    side: i32,
) {
    let Some(boxed) = shelf.card_at(index as u32) else {
        return;
    };
    let card = boxed.borrow::<AlbumCard>();
    picture.set_paintable(Some(&shelf.ui.core.artwork.placeholder(&card.key)));
    let (weak_flow, weak_picture) = (flow.downgrade(), picture.downgrade());
    let still_shown = {
        let (weak_flow, weak_picture) = (weak_flow.clone(), weak_picture.clone());
        move || {
            weak_flow
                .upgrade()
                .and_then(|flow| flow.picture_for(index))
                .zip(weak_picture.upgrade())
                .is_some_and(|(shown, picture)| shown == picture)
        }
    };
    let wanted = still_shown.clone();
    shelf.ui.core.artwork.request_while(
        wanted,
        &card.title,
        &card.artist,
        request_size(side),
        move |texture, _| {
            if let (Some(picture), Some(texture)) = (weak_picture.upgrade(), texture) {
                if still_shown() {
                    picture.set_paintable(Some(texture));
                }
            }
        },
    );
}

/// The wash behind the carousel, in the color of the cover it rests on.
fn backdrop(shelf: &Rc<Shelf>, flow: &CoverFlow) -> (gtk::DrawingArea, Rc<dyn Fn(Option<usize>)>) {
    let dominant: Rc<RefCell<Option<(u8, u8, u8)>>> = Rc::new(RefCell::new(None));
    let area = crate::ui::controls::hero_backdrop(&dominant);
    area.set_can_target(false);
    let pending: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
    let (shelf, weak_area, weak_flow) = (Rc::clone(shelf), area.downgrade(), flow.downgrade());
    let follow: Rc<dyn Fn(Option<usize>)> = Rc::new(move |centre| {
        if let Some(waiting) = pending.borrow_mut().take() {
            waiting.remove();
        }
        let Some(index) = centre else { return };
        let (shelf, weak_area, weak_flow) =
            (Rc::clone(&shelf), weak_area.clone(), weak_flow.clone());
        let (dominant, pending_done) = (Rc::clone(&dominant), Rc::clone(&pending));
        let waiting = glib::timeout_add_local_once(BACKDROP_SETTLE, move || {
            pending_done.borrow_mut().take();
            let Some(boxed) = shelf.card_at(index as u32) else {
                return;
            };
            let card = boxed.borrow::<AlbumCard>();
            shelf.ui.core.artwork.request(
                &card.title,
                &card.artist,
                request_size(140),
                move |_, color| {
                    let still_there = weak_flow
                        .upgrade()
                        .is_some_and(|flow| flow.centre() == Some(index));
                    if let (Some(area), Some(color), true) =
                        (weak_area.upgrade(), color, still_there)
                    {
                        *dominant.borrow_mut() = Some(color);
                        area.queue_draw();
                    }
                },
            );
        });
        *pending.borrow_mut() = Some(waiting);
    });
    (area, follow)
}

/// Keeps the carousel's count in step with the shelf for as long as the
/// carousel lives. The shelf outlives every view of it, so the handler is
/// taken off again when this one goes.
fn follow_shelf(shelf: &Rc<Shelf>, flow: &CoverFlow) {
    let (weak_flow, weak_shelf) = (flow.downgrade(), Rc::downgrade(shelf));
    let handler = shelf.albums.connect_items_changed(move |_, _, _, _| {
        if let (Some(flow), Some(shelf)) = (weak_flow.upgrade(), weak_shelf.upgrade()) {
            flow.set_count(shelf.count() as usize);
        }
    });
    let (albums, handler) = (shelf.albums.clone(), RefCell::new(Some(handler)));
    flow.connect_destroy(move |_| {
        if let Some(handler) = handler.borrow_mut().take() {
            albums.disconnect(handler);
        }
    });
}

pub fn build(shelf: &Rc<Shelf>, glow: bool) -> Carousel {
    let flow = CoverFlow::default();
    flow.attach_input();
    flow.update_property(&[gtk::accessible::Property::Label("Albums")]);
    {
        let (shelf, weak) = (Rc::clone(shelf), flow.downgrade());
        flow.connect_bind(move |index, picture, side| {
            if let Some(flow) = weak.upgrade() {
                bind_cover(&shelf, &flow, index, picture, side);
            }
        });
    }
    {
        let shelf = Rc::clone(shelf);
        flow.connect_activated(move |index| shelf.open(index as u32));
    }
    {
        let weak = flow.downgrade();
        super::attach_menu(shelf, &flow, move |x, y| {
            weak.upgrade()
                .and_then(|flow| flow.index_at(x, y))
                .map(|index| index as u32)
        });
    }
    {
        let (drop_shelf, weak) = (Rc::clone(shelf), flow.downgrade());
        crate::ui::artwork_editor::attach_image_drop(&flow, &shelf.ui, move || {
            drop_shelf.album_at(weak.upgrade()?.centre()? as u32)
        });
    }

    let (caption_widget, caption) = caption(shelf, &flow);
    let content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    content.add_css_class("album-carousel");
    content.append(&flow);
    content.append(&caption_widget);
    let root = gtk::Overlay::new();
    let follow_backdrop = glow.then(|| {
        let (area, follow) = backdrop(shelf, &flow);
        root.set_child(Some(&area));
        root.add_overlay(&content);
        root.set_measure_overlay(&content, true);
        follow
    });
    if follow_backdrop.is_none() {
        root.set_child(Some(&content));
    }
    flow.connect_centre(move |centre| {
        caption.show(centre);
        if let Some(follow) = &follow_backdrop {
            follow(centre);
        }
    });
    flow.set_count(shelf.count() as usize);
    {
        let weak = flow.downgrade();
        shelf.ui.register_stepper(&flow, move |step| {
            let Some(flow) = weak.upgrade() else { return };
            match step {
                crate::ui::Step::Forward => flow.step(1.0),
                crate::ui::Step::Back => flow.step(-1.0),
                crate::ui::Step::First => flow.go_to(0.0),
                crate::ui::Step::Last => flow.go_to(f64::MAX),
            }
        });
    }
    follow_shelf(shelf, &flow);
    Carousel {
        root,
        flow,
        shelf: Rc::clone(shelf),
    }
}

impl AlbumView for Carousel {
    fn widget(&self) -> gtk::Widget {
        self.root.clone().upcast()
    }

    fn kind(&self) -> AlbumsView {
        AlbumsView::Carousel
    }

    fn scroll_to_top(&self) {
        self.flow.go_to(0.0);
    }

    fn place(&self) -> f64 {
        self.flow.place()
    }

    fn restore(&self, place: f64) {
        self.flow.hold_at(place.round());
    }

    fn cover_changed(&self, title: &str, artist: &str) {
        let key = format!("{title}|{artist}");
        let shows = self
            .flow
            .shown()
            .into_iter()
            .any(|index| self.shelf.key_at(index as u32).as_deref() == Some(key.as_str()));
        if shows {
            self.flow.rebind_all();
        }
    }

    fn focus(&self) {
        self.flow.grab_focus();
    }
}
