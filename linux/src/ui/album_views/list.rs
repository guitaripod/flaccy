use super::{
    album_facts, fixed_cover, fixed_cover_picture, item_card, request_size, still_bound, AlbumCard,
    AlbumView, Shelf, ShownCovers,
};
use crate::library::{format_time, Album};
use crate::theme::AlbumsView;
use adw::prelude::*;
use gtk::{glib, pango};
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

const ROW_COVER: i32 = 44;
const PANE_COVER: i32 = 296;
const PANE_WIDTH: i32 = 360;

/// Below this width the list stands alone and a click opens the album, since
/// there is no room for the pane a selection would fill.
const PANE_FROM_WIDTH: i32 = 780;

/// A selection has to rest this long before the pane is filled for it, so
/// holding an arrow key runs down the list without loading every album on the
/// way.
const SELECTION_SETTLE: Duration = Duration::from_millis(70);

/// How many songs of the selected album the pane lists before it says how
/// many more there are.
const PANE_SONGS: usize = 14;

/// The albums as lines of text with the selected one shown large beside them:
/// its cover, what it is, its songs, and Play, Shuffle and Open within reach.
/// Arrow keys move through the shelf; Enter or a double click opens the album.
pub struct List {
    root: gtk::Box,
    scroll: gtk::ScrolledWindow,
    view: gtk::ListView,
    covers: Rc<ShownCovers>,
    shelf: Rc<Shelf>,
    pane: Rc<Pane>,
}

/// The right-hand side: everything shown about the selected album.
struct Pane {
    shelf: Rc<Shelf>,
    widget: gtk::Box,
    cover: gtk::Picture,
    title: gtk::Label,
    artist: gtk::Label,
    facts: gtk::Label,
    songs: gtk::ListBox,
    more: gtk::Label,
    showing: RefCell<Option<Album>>,
    position: Cell<u32>,
    generation: Cell<u64>,
}

fn row() -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .build();
    row.add_css_class("album-row");
    let (cover, _) = fixed_cover(ROW_COVER, "list-cover");
    row.append(&cover);

    let text = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    let title = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("album-title");
    let artist = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    artist.add_css_class("dim");
    artist.add_css_class("caption");
    text.append(&title);
    text.append(&artist);
    row.append(&text);

    let year = gtk::Label::builder()
        .xalign(1.0)
        .valign(gtk::Align::Center)
        .build();
    year.add_css_class("dim");
    year.add_css_class("caption");
    year.add_css_class("numeric");
    row.append(&year);
    row
}

struct RowParts {
    picture: gtk::Picture,
    title: gtk::Label,
    artist: gtk::Label,
    year: gtk::Label,
}

fn row_parts(row: &gtk::Widget) -> Option<RowParts> {
    let cover = row.first_child()?;
    let picture = fixed_cover_picture(&cover)?;
    let text = cover.next_sibling()?;
    let title = text.first_child().and_downcast::<gtk::Label>()?;
    let artist = title.next_sibling().and_downcast::<gtk::Label>()?;
    let year = text.next_sibling().and_downcast::<gtk::Label>()?;
    Some(RowParts {
        picture,
        title,
        artist,
        year,
    })
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

impl Pane {
    fn new(shelf: &Rc<Shelf>) -> Rc<Pane> {
        let (cover_host, cover) = fixed_cover(PANE_COVER, "cover-large");
        let title = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .wrap_mode(pango::WrapMode::WordChar)
            .lines(2)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        title.add_css_class("title-2");
        let artist = gtk::Label::builder()
            .xalign(0.0)
            .halign(gtk::Align::Start)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        artist.add_css_class("title-4");
        artist.add_css_class("dim");
        let facts = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        facts.add_css_class("dim");
        facts.add_css_class("caption");

        let play = pill("Play", "flaccy-play-symbolic", true);
        let shuffle = pill("Shuffle", "flaccy-shuffle-symbolic", false);
        let open = gtk::Button::from_icon_name("flaccy-chevron-right-symbolic");
        open.add_css_class("circular");
        open.set_tooltip_text(Some("Open the album (Enter)"));
        open.update_property(&[gtk::accessible::Property::Label("Open the album")]);
        let actions = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        actions.append(&play);
        actions.append(&shuffle);
        actions.append(&gtk::Box::builder().hexpand(true).build());
        actions.append(&open);

        let songs = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .build();
        songs.add_css_class("album-pane-songs");
        let more = gtk::Label::builder().xalign(0.0).visible(false).build();
        more.add_css_class("dim");
        more.add_css_class("caption");

        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(10)
            .margin_top(24)
            .margin_bottom(24)
            .margin_start(24)
            .margin_end(28)
            .build();
        content.append(&cover_host);
        content.append(&title);
        content.append(&artist);
        content.append(&facts);
        content.append(&actions);
        content.append(&songs);
        content.append(&more);
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vexpand(true)
            .child(&content)
            .build();
        let widget = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .width_request(PANE_WIDTH)
            .hexpand(false)
            .build();
        widget.add_css_class("album-pane");
        widget.append(&scroll);

        let pane = Rc::new(Pane {
            shelf: Rc::clone(shelf),
            widget,
            cover,
            title,
            artist,
            facts,
            songs,
            more,
            showing: RefCell::new(None),
            position: Cell::new(gtk::INVALID_LIST_POSITION),
            generation: Cell::new(0),
        });
        {
            let weak = Rc::downgrade(&pane);
            play.connect_clicked(move |_| {
                if let Some(pane) = weak.upgrade() {
                    pane.shelf.play(pane.position.get(), false);
                }
            });
        }
        {
            let weak = Rc::downgrade(&pane);
            shuffle.connect_clicked(move |_| {
                if let Some(pane) = weak.upgrade() {
                    pane.shelf.play(pane.position.get(), true);
                }
            });
        }
        {
            let weak = Rc::downgrade(&pane);
            open.connect_clicked(move |_| {
                if let Some(pane) = weak.upgrade() {
                    pane.shelf.open(pane.position.get());
                }
            });
        }
        {
            let weak = Rc::downgrade(&pane);
            pane.songs.connect_row_activated(move |_, row| {
                let Some(pane) = weak.upgrade() else { return };
                let tracks = pane
                    .showing
                    .borrow()
                    .as_ref()
                    .map(|album| album.tracks.clone());
                if let Some(tracks) = tracks {
                    pane.shelf
                        .ui
                        .core
                        .play_tracks(tracks, row.index().max(0) as usize);
                }
            });
        }
        {
            let weak = Rc::downgrade(&pane);
            crate::ui::controls::attach_label_nav(
                &shelf.ui,
                &pane.artist,
                "Go to Artist",
                move |ui| {
                    let artist = weak.upgrade().and_then(|pane| {
                        pane.showing
                            .borrow()
                            .as_ref()
                            .map(|album| album.artist.clone())
                    });
                    if let Some(artist) = artist {
                        crate::ui::goto_artist(ui, &artist);
                    }
                },
            );
        }
        pane
    }

    fn song_row(number: usize, title: &str, seconds: f64) -> gtk::ListBoxRow {
        let line = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        let index = gtk::Label::builder()
            .label(number.to_string())
            .xalign(1.0)
            .width_chars(2)
            .build();
        index.add_css_class("dim");
        index.add_css_class("numeric");
        let name = gtk::Label::builder()
            .label(title)
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        let time = gtk::Label::new(Some(&format_time(seconds)));
        time.add_css_class("dim");
        time.add_css_class("numeric");
        line.append(&index);
        line.append(&name);
        line.append(&time);
        gtk::ListBoxRow::builder().child(&line).build()
    }

    /// Fills the pane for the album at `position`, or empties it when the
    /// shelf has nothing there.
    fn show(self: &Rc<Self>, position: u32) {
        self.position.set(position);
        let generation = self.generation.get() + 1;
        self.generation.set(generation);
        let album = self.shelf.album_at(position);
        self.widget.set_sensitive(album.is_some());
        while let Some(row) = self.songs.row_at_index(0) {
            self.songs.remove(&row);
        }
        let Some(album) = album else {
            self.cover.set_paintable(gtk::gdk::Paintable::NONE);
            self.title.set_label("");
            self.artist.set_label("");
            self.facts.set_label("");
            self.more.set_visible(false);
            *self.showing.borrow_mut() = None;
            return;
        };
        self.title.set_label(&album.title);
        self.artist.set_label(&album.artist);
        self.facts.set_label(&album_facts(&album));
        for (index, track) in album.tracks.iter().take(PANE_SONGS).enumerate() {
            self.songs
                .append(&Self::song_row(index + 1, &track.title, track.duration));
        }
        let hidden = album.tracks.len().saturating_sub(PANE_SONGS);
        self.more.set_visible(hidden > 0);
        self.more.set_label(&match hidden {
            1 => "and 1 more song".to_string(),
            count => format!("and {count} more songs"),
        });
        self.cover
            .set_paintable(Some(&self.shelf.ui.core.artwork.placeholder(&album.key())));
        let weak = Rc::downgrade(self);
        self.shelf.ui.core.artwork.request(
            &album.title,
            &album.artist,
            request_size(PANE_COVER),
            move |texture, _| {
                let Some(pane) = weak
                    .upgrade()
                    .filter(|pane| pane.generation.get() == generation)
                else {
                    return;
                };
                if let Some(texture) = texture {
                    pane.cover.set_paintable(Some(texture));
                }
            },
        );
        *self.showing.borrow_mut() = Some(album);
    }

    fn shows(&self, title: &str, artist: &str) -> bool {
        self.showing
            .borrow()
            .as_ref()
            .is_some_and(|album| album.title == title && album.artist == artist)
    }
}

fn factory(shelf: &Rc<Shelf>, covers: &Rc<ShownCovers>) -> gtk::SignalListItemFactory {
    let factory = gtk::SignalListItemFactory::new();
    {
        let shelf = Rc::clone(shelf);
        factory.connect_setup(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let row = row();
            let item_weak = item.downgrade();
            {
                let item_weak = item_weak.clone();
                let drop_shelf = Rc::clone(&shelf);
                crate::ui::artwork_editor::attach_image_drop(&row, &shelf.ui, move || {
                    let boxed = item_card(&item_weak)?;
                    let library = drop_shelf.ui.core.library.borrow().clone();
                    let album = boxed.borrow::<AlbumCard>().album_in(&library).cloned();
                    album
                });
            }
            super::attach_menu(&shelf, &row, move |_, _| {
                item_weak.upgrade().map(|item| item.position())
            });
            item.set_child(Some(&row));
        });
    }
    {
        let shelf = Rc::clone(shelf);
        let covers = Rc::clone(covers);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(boxed) = item.item().and_downcast::<glib::BoxedAnyObject>() else {
                return;
            };
            let card = boxed.borrow::<AlbumCard>();
            let Some(parts) = item.child().as_ref().and_then(row_parts) else {
                return;
            };
            parts.title.set_label(&card.title);
            parts.artist.set_label(&card.artist);
            parts.year.set_label(card.year.as_deref().unwrap_or(""));
            parts
                .picture
                .set_paintable(Some(&shelf.ui.core.artwork.placeholder(&card.key)));
            let size = request_size(ROW_COVER);
            let expected = card.key.clone();
            let item_weak = item.downgrade();
            let weak = parts.picture.downgrade();
            let wanted = {
                let item_weak = item_weak.clone();
                let expected = expected.clone();
                move || still_bound(&item_weak, &expected)
            };
            shelf.ui.core.artwork.request_while(
                wanted,
                &card.title,
                &card.artist,
                size,
                move |texture, _| {
                    if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                        if still_bound(&item_weak, &expected) {
                            picture.set_paintable(Some(texture));
                        }
                    }
                },
            );
            covers.show(&card.key, &parts.picture, size);
        });
    }
    {
        let covers = Rc::clone(covers);
        factory.connect_unbind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let Some(boxed) = item.item().and_downcast::<glib::BoxedAnyObject>() {
                covers.hide(&boxed.borrow::<AlbumCard>().key);
            }
        });
    }
    factory
}

pub fn build(shelf: &Rc<Shelf>) -> List {
    let covers = Rc::new(ShownCovers::default());
    let selection = gtk::SingleSelection::builder()
        .model(&shelf.albums)
        .autoselect(true)
        .can_unselect(false)
        .build();
    let view = gtk::ListView::builder()
        .model(&selection)
        .factory(&factory(shelf, &covers))
        .build();
    view.add_css_class("album-list");
    {
        let shelf = Rc::clone(shelf);
        view.connect_activate(move |_, position| shelf.open(position));
    }
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .hexpand(true)
        .child(&view)
        .build();
    shelf.ui.register_scroller(&scroll);

    let pane = Pane::new(shelf);
    pane.show(selection.selected());
    {
        let pane = Rc::downgrade(&pane);
        let pending: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
        let refill = move |selection: &gtk::SingleSelection| {
            if let Some(waiting) = pending.borrow_mut().take() {
                waiting.remove();
            }
            let (pane, pending_done) = (pane.clone(), Rc::clone(&pending));
            let selected = selection.selected();
            let waiting = glib::timeout_add_local_once(SELECTION_SETTLE, move || {
                pending_done.borrow_mut().take();
                if let Some(pane) = pane.upgrade() {
                    pane.show(selected);
                }
            });
            *pending.borrow_mut() = Some(waiting);
        };
        let on_selected = refill.clone();
        selection.connect_selected_notify(move |selection| on_selected(selection));
        selection.connect_items_changed(move |selection, _, _, _| refill(selection));
    }

    let root = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    root.append(&scroll);
    root.append(&pane.widget);
    {
        let (pane_widget, view) = (pane.widget.downgrade(), view.downgrade());
        crate::ui::resize::watch_width(&root, move |width, _| {
            let (Some(pane), Some(view)) = (pane_widget.upgrade(), view.upgrade()) else {
                return;
            };
            let roomy = width >= PANE_FROM_WIDTH;
            pane.set_visible(roomy);
            view.set_single_click_activate(!roomy);
        });
    }
    List {
        root,
        scroll,
        view,
        covers,
        shelf: Rc::clone(shelf),
        pane,
    }
}

impl AlbumView for List {
    fn widget(&self) -> gtk::Widget {
        self.root.clone().upcast()
    }

    fn kind(&self) -> AlbumsView {
        AlbumsView::List
    }

    fn scroll_to_top(&self) {
        self.scroll.vadjustment().set_value(0.0);
        if self.shelf.count() > 0 {
            self.view.scroll_to(
                0,
                gtk::ListScrollFlags::SELECT | gtk::ListScrollFlags::FOCUS,
                None,
            );
        }
    }

    fn place(&self) -> f64 {
        self.scroll.vadjustment().value()
    }

    fn restore(&self, place: f64) {
        if place > 0.0 {
            let adjustment = self.scroll.vadjustment();
            glib::idle_add_local_once(move || adjustment.set_value(place));
        }
    }

    fn cover_changed(&self, title: &str, artist: &str) {
        self.covers.refresh(&self.shelf.ui, title, artist);
        if self.pane.shows(title, artist) {
            self.pane.show(self.pane.position.get());
        }
    }

    fn focus(&self) {
        self.view.grab_focus();
    }
}
