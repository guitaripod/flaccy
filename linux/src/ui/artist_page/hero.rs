//! The artist page's hero: the artist's photo across the whole width, the name
//! set large over it, and the facts that say who they are and what they are to
//! the person. Without a photo, the blurred wash of the artist's signature
//! album stands in. The picture drifts at a fraction of the scroll speed and
//! dims as it leaves, and a new picture fades in over the old one; nothing
//! moves while the page is still.

use crate::ui::resize;
use adw::prelude::*;
use gtk::subclass::prelude::ObjectSubclassIsExt;
use gtk::{gdk, glib, pango};

/// How far the picture moves for every point the page scrolls.
const PARALLAX: f32 = 0.45;
/// How far the sleeve moves: less than the wash behind it, so the two read as
/// layers at different depths.
const SLEEVE_PARALLAX: f32 = 0.22;
const SLEEVE_INSET: f32 = 56.0;
const SLEEVE_RADIUS: f32 = 14.0;
/// Where the crop of a photo taller than the hero sits, from the top: faces in
/// artist photos sit in the upper half.
const PHOTO_FOCUS: f32 = 0.28;
const MIN_HEIGHT: i32 = 300;
const MAX_HEIGHT: i32 = 470;
const HEIGHT_PER_WIDTH: f64 = 0.36;
const CROSSFADE_MS: u32 = 450;
/// The name's sizes, largest first: it takes the largest one its line fits.
const NAME_SIZES: [f64; 6] = [96.0, 80.0, 66.0, 54.0, 44.0, 36.0];
/// A heavy display face runs about this wide per character, in ems.
const NAME_EM_PER_CHAR: f64 = 0.58;
const TEXT_INSET: i32 = 40;

mod imp {
    use super::*;
    use gtk::subclass::prelude::*;
    use gtk::{graphene, gsk};
    use std::cell::{Cell, RefCell};

    #[derive(Default)]
    pub struct HeroArt {
        pub picture: RefCell<Option<gdk::Texture>>,
        pub previous: RefCell<Option<gdk::Texture>>,
        pub reveal: Cell<f64>,
        pub scroll: Cell<f64>,
        pub animation: RefCell<Option<adw::TimedAnimation>>,
        /// The record's sleeve, shown over its own wash while there is no
        /// photo, and faded out with the wash when one arrives.
        pub sleeve: RefCell<Option<gdk::Texture>>,
        pub sleeve_leaving: Cell<bool>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for HeroArt {
        const NAME: &'static str = "FlaccyArtistHeroArt";
        type Type = super::HeroArt;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for HeroArt {}

    impl WidgetImpl for HeroArt {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }

        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            match orientation {
                gtk::Orientation::Horizontal => (0, 0, -1, -1),
                _ => {
                    let height = super::hero_height(for_size, crate::ui::ui_scale::current());
                    (height, height, -1, -1)
                }
            }
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let widget = self.obj();
            let (width, height) = (widget.width() as f32, widget.height() as f32);
            if width <= 0.0 || height <= 0.0 {
                return;
            }
            let bounds = graphene::Rect::new(0.0, 0.0, width, height);
            let scroll = self.scroll.get().max(0.0) as f32;
            let dark = adw::StyleManager::default().is_dark();
            if dark {
                snapshot.push_mask(gsk::MaskMode::Alpha);
                snapshot.append_linear_gradient(
                    &bounds,
                    &graphene::Point::new(0.0, 0.0),
                    &graphene::Point::new(0.0, height),
                    &[
                        gsk::ColorStop::new(0.0, gdk::RGBA::BLACK),
                        gsk::ColorStop::new(0.74, gdk::RGBA::BLACK),
                        gsk::ColorStop::new(1.0, gdk::RGBA::new(0.0, 0.0, 0.0, 0.0)),
                    ],
                );
                snapshot.pop();
            }
            snapshot.push_clip(&bounds);
            snapshot.append_color(&gdk::RGBA::new(0.08, 0.08, 0.09, 1.0), &bounds);
            let reveal = self.reveal.get() as f32;
            if let Some(previous) = self.previous.borrow().as_ref().filter(|_| reveal < 1.0) {
                append_cover(snapshot, previous, width, height, scroll * PARALLAX);
            }
            if let Some(picture) = self.picture.borrow().as_ref() {
                snapshot.push_opacity(reveal as f64);
                append_cover(snapshot, picture, width, height, scroll * PARALLAX);
                snapshot.pop();
            }
            append_scrims(snapshot, width, height);
            if let Some(sleeve) = self.sleeve.borrow().as_ref() {
                let opacity = if self.sleeve_leaving.get() { 1.0 - reveal } else { reveal };
                if opacity > 0.0 {
                    snapshot.push_opacity(opacity as f64);
                    append_sleeve(snapshot, sleeve, width, height, scroll * SLEEVE_PARALLAX);
                    snapshot.pop();
                }
            }
            let dim = (scroll / height).clamp(0.0, 1.0) * 0.55;
            if dim > 0.0 {
                snapshot.append_color(&gdk::RGBA::new(0.0, 0.0, 0.0, dim), &bounds);
            }
            snapshot.pop();
            if dark {
                snapshot.pop();
            }
        }
    }

    /// Draws `texture` filling the hero, cropped around `PHOTO_FOCUS`, moved
    /// down by `shift`.
    fn append_cover(snapshot: &gtk::Snapshot, texture: &gdk::Texture, width: f32, height: f32, shift: f32) {
        let (texture_w, texture_h) = (texture.width().max(1) as f32, texture.height().max(1) as f32);
        let scale = (width / texture_w).max(height / texture_h);
        let (drawn_w, drawn_h) = (texture_w * scale, texture_h * scale);
        let rect = graphene::Rect::new(
            (width - drawn_w) / 2.0,
            (height - drawn_h) * PHOTO_FOCUS + shift,
            drawn_w,
            drawn_h,
        );
        snapshot.append_scaled_texture(texture, gsk::ScalingFilter::Trilinear, &rect);
    }

    /// The sleeve, square and lifted off the wash, at the trailing side where
    /// the name does not reach.
    fn append_sleeve(snapshot: &gtk::Snapshot, texture: &gdk::Texture, width: f32, height: f32, shift: f32) {
        let Some(side) = super::sleeve_side(width, height) else {
            return;
        };
        let bounds = graphene::Rect::new(
            width - side - SLEEVE_INSET,
            (height - side) / 2.0 + shift,
            side,
            side,
        );
        let rounded = gsk::RoundedRect::from_rect(bounds, SLEEVE_RADIUS);
        snapshot.append_outset_shadow(
            &rounded,
            &gdk::RGBA::new(0.0, 0.0, 0.0, 0.5),
            0.0,
            18.0,
            0.0,
            44.0,
        );
        snapshot.push_rounded_clip(&rounded);
        snapshot.append_scaled_texture(texture, gsk::ScalingFilter::Trilinear, &bounds);
        snapshot.pop();
    }

    /// Darkens the bottom, where the words sit, and the leading edge they
    /// start from, so white type reads over any photo.
    fn append_scrims(snapshot: &gtk::Snapshot, width: f32, height: f32) {
        let bounds = graphene::Rect::new(0.0, 0.0, width, height);
        snapshot.append_linear_gradient(
            &bounds,
            &graphene::Point::new(0.0, 0.0),
            &graphene::Point::new(0.0, height),
            &[
                gsk::ColorStop::new(0.0, gdk::RGBA::new(0.0, 0.0, 0.0, 0.18)),
                gsk::ColorStop::new(0.3, gdk::RGBA::new(0.0, 0.0, 0.0, 0.0)),
                gsk::ColorStop::new(0.55, gdk::RGBA::new(0.0, 0.0, 0.0, 0.12)),
                gsk::ColorStop::new(1.0, gdk::RGBA::new(0.0, 0.0, 0.0, 0.74)),
            ],
        );
        snapshot.append_linear_gradient(
            &bounds,
            &graphene::Point::new(0.0, 0.0),
            &graphene::Point::new(width, 0.0),
            &[
                gsk::ColorStop::new(0.0, gdk::RGBA::new(0.0, 0.0, 0.0, 0.38)),
                gsk::ColorStop::new(0.55, gdk::RGBA::new(0.0, 0.0, 0.0, 0.0)),
            ],
        );
    }
}

glib::wrapper! {
    pub struct HeroArt(ObjectSubclass<imp::HeroArt>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl HeroArt {
    fn new() -> Self {
        let art: Self = glib::Object::new();
        art.set_hexpand(true);
        art.imp().reveal.set(1.0);
        let weak = art.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(art) = weak.upgrade() {
                art.queue_draw();
            }
        });
        art
    }

    /// Shows `texture`, fading it in over whatever was there.
    fn show(&self, texture: gdk::Texture) {
        let imp = self.imp();
        let previous = imp.picture.borrow_mut().replace(texture);
        let animate = previous.is_some() && crate::ui::controls::animations_enabled();
        *imp.previous.borrow_mut() = previous;
        if let Some(running) = imp.animation.borrow_mut().take() {
            running.skip();
        }
        if !animate {
            imp.reveal.set(1.0);
            self.queue_draw();
            return;
        }
        imp.reveal.set(0.0);
        let weak = self.downgrade();
        let target = adw::CallbackAnimationTarget::new(move |value| {
            if let Some(art) = weak.upgrade() {
                art.imp().reveal.set(value);
                art.queue_draw();
            }
        });
        let animation = adw::TimedAnimation::new(self, 0.0, 1.0, CROSSFADE_MS, target);
        animation.set_easing(adw::Easing::EaseOutCubic);
        animation.play();
        *imp.animation.borrow_mut() = Some(animation);
    }

    fn set_scroll(&self, offset: f64) {
        let imp = self.imp();
        if (imp.scroll.get() - offset).abs() < 0.5 {
            return;
        }
        imp.scroll.set(offset);
        self.queue_draw();
    }
}

/// The hero's height for its width, its bounds growing with the interface
/// zoom so the zoomed words keep their room.
pub fn hero_height(width: i32, zoom: f64) -> i32 {
    let (low, high) = (
        (MIN_HEIGHT as f64 * zoom).round() as i32,
        (MAX_HEIGHT as f64 * zoom).round() as i32,
    );
    if width <= 0 {
        return low;
    }
    ((width as f64 * HEIGHT_PER_WIDTH).round() as i32).clamp(low, high)
}

/// The largest name size whose single line fits `room` points, or the
/// smallest, at which the name wraps onto a second line.
pub fn name_size(name: &str, room: f64) -> f64 {
    let chars = name.chars().count().max(4) as f64;
    NAME_SIZES
        .iter()
        .copied()
        .find(|size| chars * size * NAME_EM_PER_CHAR <= room)
        .unwrap_or(NAME_SIZES[NAME_SIZES.len() - 1])
}

/// The side of the sleeve the stand-in shows in a hero `width` wide, or
/// `None` when the hero is too small to show one.
fn sleeve_side(width: f32, height: f32) -> Option<f32> {
    let side = (height * 0.7).min(width * 0.3);
    (side >= 120.0).then_some(side)
}

/// Sizes the name to the room it has: the hero's width, less the sleeve's
/// side when a sleeve is showing.
struct NameFit {
    name: String,
    label: glib::WeakRef<gtk::Label>,
    text: glib::WeakRef<gtk::Box>,
    sleeve: std::cell::Cell<bool>,
}

impl NameFit {
    fn fit(&self, width: i32) {
        let (Some(label), Some(text)) = (self.label.upgrade(), self.text.upgrade()) else {
            return;
        };
        if width <= 1 {
            return;
        }
        let zoom = crate::ui::ui_scale::current();
        let trailing = match sleeve_side(width as f32, hero_height(width, zoom) as f32) {
            Some(side) if self.sleeve.get() => (side + SLEEVE_INSET) as i32 + 32,
            _ => TEXT_INSET,
        };
        text.set_margin_end(trailing);
        let room = (width - TEXT_INSET - trailing).max(120) as f64;
        let size = name_size(&self.name, room / zoom) * zoom;
        let attributes = pango::AttrList::new();
        attributes.insert(pango::AttrSize::new_size_absolute(
            (size * pango::SCALE as f64).round() as i32,
        ));
        label.set_attributes(Some(&attributes));
    }
}

pub struct Hero {
    pub widget: gtk::Overlay,
    art: HeroArt,
    text: gtk::Box,
    eyebrow: gtk::Label,
    meta: gtk::Label,
    mine: gtk::Label,
    has_photo: std::cell::Cell<bool>,
    fit: std::rc::Rc<NameFit>,
}

impl Hero {
    pub fn new(name: &str, meta: &str) -> Self {
        let art = HeroArt::new();
        let eyebrow = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .visible(false)
            .build();
        eyebrow.add_css_class("artist-hero-eyebrow");
        let name_label = gtk::Label::builder()
            .label(name)
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(pango::WrapMode::WordChar)
            .lines(2)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        name_label.add_css_class("artist-hero-name");
        name_label.set_accessible_role(gtk::AccessibleRole::Heading);
        let meta_label = gtk::Label::builder()
            .label(meta)
            .xalign(0.0)
            .wrap(true)
            .build();
        meta_label.add_css_class("artist-hero-meta");
        let mine = gtk::Label::builder().xalign(0.0).visible(false).build();
        mine.add_css_class("artist-hero-mine");
        mine.set_halign(gtk::Align::Start);

        let text = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(4)
            .valign(gtk::Align::End)
            .halign(gtk::Align::Fill)
            .margin_start(TEXT_INSET)
            .margin_end(TEXT_INSET)
            .margin_bottom(30)
            .build();
        text.append(&eyebrow);
        text.append(&name_label);
        text.append(&meta_label);
        text.append(&mine);
        text.set_can_target(false);

        let widget = gtk::Overlay::new();
        widget.set_child(Some(&art));
        widget.add_overlay(&text);
        widget.add_css_class("artist-hero");

        let fit = std::rc::Rc::new(NameFit {
            name: name.to_string(),
            label: name_label.downgrade(),
            text: text.downgrade(),
            sleeve: std::cell::Cell::new(false),
        });
        {
            let fit = std::rc::Rc::clone(&fit);
            resize::watch_width(&widget, move |width, _| fit.fit(width));
        }

        Self {
            widget,
            art,
            text,
            eyebrow,
            meta: meta_label,
            mine,
            has_photo: std::cell::Cell::new(false),
            fit,
        }
    }

    pub fn set_tags(&self, tags: &[String]) {
        let line = tags
            .iter()
            .take(3)
            .map(|tag| tag.to_uppercase())
            .collect::<Vec<_>>()
            .join("  ·  ");
        self.eyebrow.set_label(&line);
        self.eyebrow.set_visible(!line.is_empty());
    }

    pub fn set_meta(&self, meta: &str) {
        self.meta.set_label(meta);
    }

    pub fn set_mine(&self, mine: Option<&str>) {
        self.mine.set_label(mine.unwrap_or_default());
        self.mine.set_visible(mine.is_some());
    }

    /// The artist's photo, which always wins over a stand-in.
    pub fn set_photo(&self, texture: gdk::Texture) {
        self.has_photo.set(true);
        self.art.imp().sleeve_leaving.set(true);
        self.art.show(texture);
        self.fit.sleeve.set(false);
        self.fit.fit(self.widget.width());
    }

    /// The blurred wash of an album, shown only until a photo arrives.
    pub fn set_stand_in(&self, texture: gdk::Texture) {
        if !self.has_photo.get() {
            self.art.show(texture);
        }
    }

    /// The album's sleeve over its wash, shown only until a photo arrives.
    pub fn set_sleeve(&self, texture: gdk::Texture) {
        if self.has_photo.get() {
            return;
        }
        *self.art.imp().sleeve.borrow_mut() = Some(texture);
        self.art.queue_draw();
        self.fit.sleeve.set(true);
        self.fit.fit(self.widget.width());
    }

    pub fn has_photo(&self) -> bool {
        self.has_photo.get()
    }

    /// Follows the page's scroll: the picture drifts and dims and the words
    /// fade as the hero leaves.
    pub fn follow_scroll(&self, offset: f64) {
        let height = self.art.height().max(1) as f64;
        if offset > height && self.art.imp().scroll.get() > height {
            return;
        }
        self.art.set_scroll(offset.min(height + 1.0));
        let fade = 1.0 - (offset / (height * 0.62)).clamp(0.0, 1.0);
        self.text.set_opacity(fade);
    }

    pub fn height(&self) -> i32 {
        self.art.height()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hero_height_follows_the_width_within_its_bounds() {
        assert_eq!(hero_height(0, 1.0), MIN_HEIGHT);
        assert_eq!(hero_height(600, 1.0), MIN_HEIGHT);
        assert_eq!(hero_height(1000, 1.0), 360);
        assert_eq!(hero_height(3000, 1.0), MAX_HEIGHT);
        assert_eq!(hero_height(1000, 1.4), 420);
        assert_eq!(hero_height(3000, 1.4), 658);
    }

    #[test]
    fn the_name_takes_the_largest_size_its_line_fits() {
        assert_eq!(name_size("Metallica", 1200.0), 96.0);
        assert_eq!(name_size("Florence + The Machine", 1200.0), 80.0);
        assert_eq!(name_size("Florence + The Machine", 700.0), 54.0);
        assert_eq!(name_size("The Smashing Pumpkins and the Long Name Orchestra", 500.0), 36.0);
        assert_eq!(name_size("U2", 300.0), 96.0);
    }
}
