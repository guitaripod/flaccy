use crate::ui::Ui;
use adw::prelude::*;
use gtk::subclass::prelude::ObjectSubclassIsExt;
use gtk::{gdk, glib};
use std::rc::Rc;

/// An album's artwork cache key: its title and credited artist.
pub type AlbumRef = (String, String);

/// Receives an artwork's dominant color as it is computed.
pub type OnColor = Rc<dyn Fn((u8, u8, u8))>;

mod imp {
    use gtk::prelude::*;
    use gtk::subclass::prelude::*;
    use gtk::{gdk, glib, graphene};
    use std::cell::{Cell, RefCell};

    #[derive(Default)]
    pub struct MosaicArt {
        pub tiles: RefCell<Vec<Option<gdk::Paintable>>>,
        pub fixed_size: Cell<i32>,
        pub generation: Cell<u64>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for MosaicArt {
        const NAME: &'static str = "FlaccyMosaicArt";
        type Type = super::MosaicArt;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for MosaicArt {}

    impl WidgetImpl for MosaicArt {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }

        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let fixed = self.fixed_size.get();
            if fixed > 0 {
                return (fixed, fixed, -1, -1);
            }
            match orientation {
                gtk::Orientation::Horizontal => (0, 0, -1, -1),
                _ => {
                    let side = for_size.max(0);
                    (side, side, -1, -1)
                }
            }
        }

        fn snapshot(&self, snapshot: &gtk::Snapshot) {
            let widget = self.obj();
            let (width, height) = (widget.width() as f32, widget.height() as f32);
            let tiles = self.tiles.borrow();
            for (paintable, (column, row, columns, rows)) in
                tiles.iter().zip(super::Mosaic::layout(tiles.len()))
            {
                let Some(paintable) = paintable else { continue };
                let (left, right) = (
                    (*column as f32 * width / 2.0).round(),
                    ((*column + *columns) as f32 * width / 2.0).round(),
                );
                let (top, bottom) = (
                    (*row as f32 * height / 2.0).round(),
                    ((*row + *rows) as f32 * height / 2.0).round(),
                );
                let rect = graphene::Rect::new(left, top, right - left, bottom - top);
                let intrinsic_w = paintable.intrinsic_width().max(1) as f32;
                let intrinsic_h = paintable.intrinsic_height().max(1) as f32;
                let scale = (rect.width() / intrinsic_w).max(rect.height() / intrinsic_h);
                let (drawn_w, drawn_h) = (intrinsic_w * scale, intrinsic_h * scale);
                snapshot.push_clip(&rect);
                snapshot.save();
                snapshot.translate(&graphene::Point::new(
                    rect.x() + (rect.width() - drawn_w) / 2.0,
                    rect.y() + (rect.height() - drawn_h) / 2.0,
                ));
                paintable.snapshot(snapshot, drawn_w as f64, drawn_h as f64);
                snapshot.restore();
                snapshot.pop();
            }
        }
    }
}

glib::wrapper! {
    /// Draws up to four cover-fit tiles straight into the widget's snapshot.
    /// Unlike a grid of pictures it reports a size of its own (the fixed size,
    /// or a square that follows the width), never the size of the art in it.
    pub struct MosaicArt(ObjectSubclass<imp::MosaicArt>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl MosaicArt {
    fn new() -> Self {
        glib::Object::new()
    }

    fn set_fixed_size(&self, size: i32) {
        self.imp().fixed_size.set(size);
        self.queue_resize();
    }

    /// Clears the tiles for a new set of `count` albums and returns the
    /// generation to present with `set_tile`, so art that arrives after the
    /// widget was reused is dropped.
    fn reset(&self, count: usize) -> u64 {
        let imp = self.imp();
        let generation = imp.generation.get().wrapping_add(1);
        imp.generation.set(generation);
        *imp.tiles.borrow_mut() = vec![None; count];
        self.queue_draw();
        generation
    }

    fn fixed_size(&self) -> i32 {
        self.imp().fixed_size.get()
    }

    fn is_current(&self, generation: u64) -> bool {
        self.imp().generation.get() == generation
    }

    fn set_tile(&self, generation: u64, index: usize, paintable: &gdk::Paintable) {
        let imp = self.imp();
        if imp.generation.get() != generation {
            return;
        }
        if let Some(slot) = imp.tiles.borrow_mut().get_mut(index) {
            *slot = Some(paintable.clone());
        }
        self.queue_draw();
    }
}

/// A square cover composed from up to four albums: one fills the tile, two
/// split it, three give one tall half and two quarters, four make a grid. With
/// nothing to show it is the playlist's placeholder gradient with a note icon.
#[derive(Clone)]
pub struct Mosaic {
    root: gtk::Overlay,
    art: MosaicArt,
    icon: gtk::Image,
}

const FLUID_SINGLE_PX: u32 = 232;
const FLUID_MULTI_PX: u32 = 168;

impl Mosaic {
    /// A cover that follows the width it is given until `set_fixed_size` pins it.
    pub fn new() -> Self {
        let art = MosaicArt::new();
        art.set_hexpand(true);
        let icon = gtk::Image::builder()
            .icon_name("flaccy-song-symbolic")
            .pixel_size(40)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .visible(false)
            .build();
        icon.add_css_class("playlist-cover-icon");
        let root = gtk::Overlay::new();
        root.set_child(Some(&art));
        root.add_overlay(&icon);
        root.set_overflow(gtk::Overflow::Hidden);
        Self { root, art, icon }
    }

    /// Recovers a mosaic from its root widget, so an owner can hold the root
    /// weakly instead of keeping a strong handle that closes a reference cycle.
    pub fn from_root(root: &gtk::Overlay) -> Option<Self> {
        let art = root.child().and_downcast::<MosaicArt>()?;
        let icon = art.next_sibling().and_downcast::<gtk::Image>()?;
        Some(Self {
            root: root.clone(),
            art,
            icon,
        })
    }

    /// Fills the whole cover with one picture, such as a cover the person chose.
    pub fn set_picture(&self, texture: &gdk::MemoryTexture) {
        self.icon.set_visible(false);
        let generation = self.art.reset(1);
        self.art.set_tile(generation, 0, texture.upcast_ref());
    }

    pub fn widget(&self) -> &gtk::Overlay {
        &self.root
    }

    /// The artwork size to ask the cache for when one album fills the cover.
    pub fn single_px(&self) -> u32 {
        match self.art.fixed_size() {
            0 => FLUID_SINGLE_PX,
            size => size as u32,
        }
    }

    fn multi_px(&self) -> u32 {
        match self.art.fixed_size() {
            0 => FLUID_MULTI_PX,
            size => (size as u32 / 2).max(1),
        }
    }

    /// Pins the cover to a square of `size` pixels, requesting art to match; 0
    /// lets it follow the width it is given.
    pub fn set_fixed_size(&self, size: i32) {
        self.art.set_fixed_size(size);
        self.icon.set_pixel_size(if size > 0 {
            (size / 2).clamp(12, 40)
        } else {
            40
        });
        let align = if size > 0 {
            gtk::Align::Center
        } else {
            gtk::Align::Fill
        };
        self.root.set_halign(align);
        self.root.set_valign(align);
        self.root.set_hexpand(size == 0);
        self.root.set_vexpand(false);
    }

    /// Tile rectangles as (column, row, columns, rows) on a 2×2 grid.
    pub(crate) fn layout(count: usize) -> &'static [(i32, i32, i32, i32)] {
        match count {
            0 | 1 => &[(0, 0, 2, 2)],
            2 => &[(0, 0, 1, 2), (1, 0, 1, 2)],
            3 => &[(0, 0, 1, 2), (1, 0, 1, 1), (1, 1, 1, 1)],
            _ => &[(0, 0, 1, 1), (1, 0, 1, 1), (0, 1, 1, 1), (1, 1, 1, 1)],
        }
    }

    /// Shows the albums' art, placeholders first and real art as it decodes.
    /// `seed` colors the placeholder when there are no albums. `on_color`
    /// receives the first cover's dominant color.
    pub fn set_covers(
        &self,
        ui: &Rc<Ui>,
        seed: &str,
        covers: &[AlbumRef],
        on_color: Option<OnColor>,
    ) {
        self.icon.set_visible(covers.is_empty());
        if covers.is_empty() {
            let generation = self.art.reset(1);
            self.art.set_tile(
                generation,
                0,
                ui.core.artwork.placeholder(seed).upcast_ref(),
            );
            return;
        }
        let covers = &covers[..covers.len().min(4)];
        let px = if covers.len() == 1 {
            self.single_px()
        } else {
            self.multi_px()
        };
        let generation = self.art.reset(covers.len());
        for (index, (title, artist)) in covers.iter().enumerate() {
            self.art.set_tile(
                generation,
                index,
                ui.core
                    .artwork
                    .placeholder(&format!("{title}|{artist}"))
                    .upcast_ref(),
            );
            let art = self.art.downgrade();
            let on_color = on_color.clone();
            ui.core
                .artwork
                .request(title, artist, px, move |texture, color| {
                    let Some(art) = art.upgrade().filter(|art| art.is_current(generation)) else {
                        return;
                    };
                    if let Some(texture) = texture {
                        art.set_tile(generation, index, texture.upcast_ref());
                    }
                    if let (0, Some(on_color), Some(color)) = (index, &on_color, color) {
                        on_color(color);
                    }
                });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layouts_tile_the_whole_square() {
        for count in 0..=4 {
            let area: i32 = Mosaic::layout(count)
                .iter()
                .map(|(_, _, columns, rows)| columns * rows)
                .sum();
            assert_eq!(area, 4, "layout for {count} albums");
        }
    }
}
