pub mod carousel;
pub mod flow_geometry;
pub mod grid;
pub mod list;

use crate::library::{Album, Library};
use crate::theme::{AlbumsView, Look};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::{gdk, glib};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// What a view keeps of an album: the few fields a tile shows, the key it is
/// found by, and where it sat in the library when the shelf was built. The
/// tracks stay in the library, so building the shelf copies no track and a
/// tile always opens the album as the library holds it now.
pub struct AlbumCard {
    pub key: String,
    pub title: String,
    pub artist: String,
    pub year: Option<String>,
    index: usize,
}

impl AlbumCard {
    pub fn of(album: &Album, index: usize) -> Self {
        Self {
            key: album.key(),
            title: album.title.clone(),
            artist: album.artist.clone(),
            year: album.year.clone(),
            index,
        }
    }

    pub fn subtitle(&self) -> String {
        match &self.year {
            Some(year) if !year.is_empty() => format!("{} · {}", self.artist, year),
            _ => self.artist.clone(),
        }
    }

    /// The album this tile stands for in `library`: the one at the remembered
    /// position when it is still the same album, otherwise found by its key.
    pub fn album_in<'a>(&self, library: &'a Library) -> Option<&'a Album> {
        library
            .albums
            .get(self.index)
            .filter(|album| album.title == self.title && album.artist == self.artist)
            .or_else(|| library.album_by_key(&self.key))
    }
}

/// The albums as the page has filtered and sorted them, and what every view
/// can do with one: open it, play it, offer its menu, take a dropped cover.
pub struct Shelf {
    pub ui: Rc<Ui>,
    pub albums: gtk::FilterListModel,
}

impl Shelf {
    pub fn count(&self) -> u32 {
        self.albums.n_items()
    }

    pub fn card_at(&self, position: u32) -> Option<BoxedAnyObject> {
        self.albums.item(position).and_downcast::<BoxedAnyObject>()
    }

    pub fn key_at(&self, position: u32) -> Option<String> {
        self.card_at(position)
            .map(|boxed| boxed.borrow::<AlbumCard>().key.clone())
    }

    /// The album at `position` as the library holds it now.
    pub fn album_at(&self, position: u32) -> Option<Album> {
        let boxed = self.card_at(position)?;
        let library = self.ui.core.library.borrow().clone();
        let album = boxed.borrow::<AlbumCard>().album_in(&library).cloned();
        album
    }

    pub fn open(&self, position: u32) {
        if let Some(album) = self.album_at(position) {
            crate::ui::albums::push_album_detail(&self.ui, &album);
        }
    }

    pub fn play(&self, position: u32, shuffle: bool) {
        if let Some(key) = self.key_at(position) {
            self.ui.core.play_album_key(&key, shuffle);
        }
    }

    pub fn menu(&self, anchor: &impl IsA<gtk::Widget>, position: u32, x: f64, y: f64) {
        let Some(key) = self.key_at(position) else {
            return;
        };
        context::popup_menu_at(
            anchor,
            &context::album_menu(&key, context::album_downloads(&self.ui.core, &key)),
            x,
            y,
        );
    }
}

/// The covers a view has on screen, by album key, so a cover that was just
/// found or replaced is redrawn where it shows and nowhere else.
#[derive(Default)]
pub struct ShownCovers {
    shown: RefCell<HashMap<String, (glib::WeakRef<gtk::Picture>, u32)>>,
}

impl ShownCovers {
    pub fn show(&self, key: &str, picture: &gtk::Picture, size: u32) {
        self.shown
            .borrow_mut()
            .insert(key.to_string(), (picture.downgrade(), size));
    }

    pub fn hide(&self, key: &str) {
        self.shown.borrow_mut().remove(key);
    }

    pub fn pictures(&self) -> Vec<gtk::Picture> {
        self.shown
            .borrow()
            .values()
            .filter_map(|(picture, _)| picture.upgrade())
            .collect()
    }

    fn showing(&self, key: &str) -> Option<(gtk::Picture, u32)> {
        let shown = self.shown.borrow();
        let (picture, size) = shown.get(key)?;
        Some((picture.upgrade()?, *size))
    }

    /// Asks for the album's cover again and paints it if the same picture
    /// still shows that album when it arrives.
    pub fn refresh(self: &Rc<Self>, ui: &Rc<Ui>, title: &str, artist: &str) {
        let key = format!("{title}|{artist}");
        let Some((picture, size)) = self.showing(&key) else {
            return;
        };
        let covers = Rc::clone(self);
        let placeholder = ui.core.artwork.placeholder(&key);
        let weak = picture.downgrade();
        ui.core
            .artwork
            .request(title, artist, size, move |texture, _| {
                let Some(picture) = weak.upgrade() else {
                    return;
                };
                if !covers
                    .showing(&key)
                    .is_some_and(|(current, _)| current == picture)
                {
                    return;
                }
                match texture {
                    Some(texture) => picture.set_paintable(Some(texture)),
                    None => picture.set_paintable(Some(&placeholder)),
                }
            });
    }
}

/// A cover that is exactly `side` wide and tall whatever picture is in it: a
/// picture left to itself asks for the size of its image, so it sits over a
/// box of the wanted size instead of in the layout. Returns the widget to
/// place and the picture to paint.
pub fn fixed_cover(side: i32, class: &str) -> (gtk::Overlay, gtk::Picture) {
    let frame = gtk::Box::builder()
        .width_request(side)
        .height_request(side)
        .build();
    let picture = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .can_shrink(true)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class(class);
    let host = gtk::Overlay::builder()
        .child(&frame)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .build();
    host.add_overlay(&picture);
    (host, picture)
}

/// The picture of a cover built by `fixed_cover`.
pub fn fixed_cover_picture(host: &gtk::Widget) -> Option<gtk::Picture> {
    host.last_child().and_downcast::<gtk::Picture>()
}

/// One way of laying the shelf out.
pub trait AlbumView {
    fn widget(&self) -> gtk::Widget;
    fn kind(&self) -> AlbumsView;
    fn scroll_to_top(&self);
    /// Where the view rests, to put a rebuilt view of the same kind back.
    fn place(&self) -> f64;
    fn restore(&self, place: f64);
    /// The cover of this album was found or replaced.
    fn cover_changed(&self, title: &str, artist: &str);
    /// Takes the keyboard, where the view is driven by it.
    fn focus(&self) {}
}

/// "2019 · Rock · 12 songs · 48 min", leaving out whatever is not known.
fn facts(year: Option<&str>, genre: Option<&str>, songs: usize, seconds: f64) -> String {
    let mut parts: Vec<String> = Vec::new();
    parts.extend(year.filter(|year| !year.is_empty()).map(str::to_string));
    parts.extend(genre.filter(|genre| !genre.is_empty()).map(str::to_string));
    parts.push(match songs {
        1 => "1 song".to_string(),
        count => format!("{count} songs"),
    });
    if seconds >= 60.0 {
        parts.push(format!("{} min", (seconds / 60.0).round() as i64));
    }
    parts.join(" · ")
}

/// What an album is, in one line under its name.
pub fn album_facts(album: &Album) -> String {
    facts(
        album.year.as_deref(),
        album.genre.as_deref(),
        album.tracks.len(),
        album.tracks.iter().map(|track| track.duration).sum(),
    )
}

/// The size, in logical pixels, to ask the artwork cache for when a cover is
/// drawn `side` wide: a little more than it needs, in steps, so views of
/// nearly the same size share what is cached.
pub fn request_size(side: i32) -> u32 {
    const STEPS: [u32; 6] = [64, 168, 256, 320, 420, 512];
    let wanted = (side.max(1) as u32) * 6 / 5;
    STEPS
        .into_iter()
        .find(|step| *step >= wanted)
        .unwrap_or(512)
}

/// Builds the view the look asks for.
pub fn build(shelf: &Rc<Shelf>, look: &Look) -> Box<dyn AlbumView> {
    match look.albums {
        AlbumsView::Grid => Box::new(grid::build(shelf, look.cover_size, false)),
        AlbumsView::Wall => Box::new(grid::build(shelf, look.cover_size, true)),
        AlbumsView::List => Box::new(list::build(shelf)),
        AlbumsView::Carousel => Box::new(carousel::build(shelf, look.glow)),
    }
}

/// What about a look the Albums page is built from: the view, and of the
/// rest only what that view draws with (the cover size for a grid or a wall,
/// the glow for the carousel). A change to anything else restyles the page
/// without rebuilding it.
pub fn shape_of(look: &Look) -> (AlbumsView, i32, bool) {
    match look.albums {
        AlbumsView::Grid | AlbumsView::Wall => (look.albums, look.cover_size, false),
        AlbumsView::List => (look.albums, 0, false),
        AlbumsView::Carousel => (look.albums, 0, look.glow),
    }
}

/// A right click on `widget` opens the album menu for whatever `position_at`
/// says is under the pointer.
pub fn attach_menu(
    shelf: &Rc<Shelf>,
    widget: &impl IsA<gtk::Widget>,
    position_at: impl Fn(f64, f64) -> Option<u32> + 'static,
) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let shelf = Rc::clone(shelf);
    let anchor = widget.as_ref().downgrade();
    gesture.connect_pressed(move |_, _, x, y| {
        if let (Some(anchor), Some(position)) = (anchor.upgrade(), position_at(x, y)) {
            shelf.menu(&anchor, position, x, y);
        }
    });
    widget.as_ref().add_controller(gesture);
}

/// The position in `model` of the album a list item currently holds.
pub fn item_card(item: &glib::WeakRef<gtk::ListItem>) -> Option<BoxedAnyObject> {
    item.upgrade()?.item().and_downcast::<BoxedAnyObject>()
}

/// Guards an async artwork callback against cell recycling: the shared tile
/// widget may have been rebound to a different album by the time a queued
/// cover decode lands, so only paint if the list item still holds this album.
pub fn still_bound(item: &glib::WeakRef<gtk::ListItem>, expected: &str) -> bool {
    item_card(item).is_some_and(|boxed| boxed.borrow::<AlbumCard>().key == expected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_cover_is_asked_for_a_step_above_what_it_fills() {
        assert_eq!(request_size(48), 64);
        assert_eq!(request_size(140), 168);
        assert_eq!(request_size(172), 256);
        assert_eq!(request_size(264), 320);
        assert_eq!(request_size(320), 420);
        assert_eq!(request_size(440), 512);
        assert_eq!(request_size(0), 64);
    }

    #[test]
    fn facts_leave_out_what_is_not_known() {
        assert_eq!(facts(Some("2019"), Some("Rock"), 3, 2880.0), "2019 · Rock · 3 songs · 48 min");
        assert_eq!(facts(None, Some(""), 1, 30.0), "1 song");
        assert_eq!(facts(Some(""), None, 0, 0.0), "0 songs");
    }
}
