use super::{item_card, request_size, still_bound, AlbumCard, AlbumView, Shelf, ShownCovers};
use crate::theme::AlbumsView;
use adw::prelude::*;
use gtk::{glib, pango};
use std::cell::Cell;
use std::rc::Rc;

/// What a grid tile's padding adds to its cover on each row of the grid.
const TILE_PADDING: i32 = 16;
const GRID_MARGIN: i32 = 24;

/// The covers as a grid of tiles with their titles beneath, or as a wall:
/// the same covers with nothing between them, each exactly as wide as its
/// column, and the title shown over a cover only while the pointer is on it.
pub struct Grid {
    scroll: gtk::ScrolledWindow,
    covers: Rc<ShownCovers>,
    shelf: Rc<Shelf>,
    wall: bool,
}

struct TileParts {
    picture: gtk::Picture,
    title: gtk::Label,
    subtitle: gtk::Label,
}

/// Empty grid tile reused by the factory: cover, title and subtitle in fixed
/// order (the bind step fills them and requests artwork).
fn grid_tile(cover: i32) -> gtk::Box {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(cover)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Start)
        .hexpand(true)
        .build();
    cell.add_css_class("album-tile");

    let picture = gtk::Picture::builder()
        .width_request(cover)
        .height_request(cover)
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    cell.append(&picture);

    let chars = (cover / 9).max(10);
    let title = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(chars)
        .hexpand(true)
        .build();
    title.add_css_class("album-title");
    cell.append(&title);

    let subtitle = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(chars + 2)
        .hexpand(true)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    cell.append(&subtitle);
    cell
}

fn grid_parts(cell: &gtk::Widget) -> Option<TileParts> {
    let picture = cell.first_child().and_downcast::<gtk::Picture>()?;
    let title = picture.next_sibling().and_downcast::<gtk::Label>()?;
    let subtitle = title.next_sibling().and_downcast::<gtk::Label>()?;
    Some(TileParts {
        picture,
        title,
        subtitle,
    })
}

/// Empty wall tile: the cover alone, with its title and artist in a caption
/// laid over its foot that the stylesheet shows on hover. Only its height is
/// asked for: its width is its column's, and asking for that too would have
/// the grid ask for more room every time it was given some.
fn wall_tile(side: i32) -> gtk::Overlay {
    let picture = gtk::Picture::builder()
        .height_request(side)
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("wall-tile");

    let title = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("album-title");
    let subtitle = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    subtitle.add_css_class("caption");
    let caption = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(1)
        .valign(gtk::Align::End)
        .can_target(false)
        .build();
    caption.add_css_class("wall-caption");
    caption.append(&title);
    caption.append(&subtitle);

    let cell = gtk::Overlay::builder().child(&picture).build();
    cell.add_overlay(&caption);
    cell.add_css_class("wall-cell");
    cell
}

fn wall_parts(cell: &gtk::Widget) -> Option<TileParts> {
    let overlay = cell.downcast_ref::<gtk::Overlay>()?;
    let picture = overlay.child().and_downcast::<gtk::Picture>()?;
    let caption = picture.next_sibling()?;
    let title = caption.first_child().and_downcast::<gtk::Label>()?;
    let subtitle = title.next_sibling().and_downcast::<gtk::Label>()?;
    Some(TileParts {
        picture,
        title,
        subtitle,
    })
}

/// Keeps a wall's columns filling its width exactly: as many columns as fit
/// at the chosen cover size, each cover as wide as its column.
fn fit_wall(grid: &gtk::GridView, covers: &Rc<ShownCovers>, side: &Rc<Cell<i32>>, cover: i32) {
    let (weak, covers, side) = (grid.downgrade(), Rc::clone(covers), Rc::clone(side));
    crate::ui::resize::watch_width(grid, move |width, _| {
        let Some(grid) = weak.upgrade() else { return };
        let columns = (width / cover.max(1)).clamp(1, 24) as u32;
        let fitted = width / columns as i32;
        if grid.max_columns() != columns {
            if columns > grid.max_columns() {
                grid.set_max_columns(columns);
                grid.set_min_columns(columns);
            } else {
                grid.set_min_columns(columns);
                grid.set_max_columns(columns);
            }
        }
        if side.replace(fitted) != fitted {
            for picture in covers.pictures() {
                picture.set_size_request(-1, fitted);
            }
        }
    });
}

pub fn build(shelf: &Rc<Shelf>, cover: i32, wall: bool) -> Grid {
    let covers = Rc::new(ShownCovers::default());
    let side = Rc::new(Cell::new(cover));
    let factory = gtk::SignalListItemFactory::new();
    {
        let shelf = Rc::clone(shelf);
        let side = Rc::clone(&side);
        factory.connect_setup(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let cell: gtk::Widget = if wall {
                wall_tile(side.get()).upcast()
            } else {
                grid_tile(cover).upcast()
            };
            let item_weak = item.downgrade();
            {
                let item_weak = item_weak.clone();
                let drop_shelf = Rc::clone(&shelf);
                crate::ui::artwork_editor::attach_image_drop(&cell, &shelf.ui, move || {
                    let boxed = item_card(&item_weak)?;
                    let library = drop_shelf.ui.core.library.borrow().clone();
                    let album = boxed.borrow::<AlbumCard>().album_in(&library).cloned();
                    album
                });
            }
            super::attach_menu(&shelf, &cell, move |_, _| {
                item_weak.upgrade().map(|item| item.position())
            });
            item.set_child(Some(&cell));
        });
    }
    {
        let shelf = Rc::clone(shelf);
        let covers = Rc::clone(&covers);
        let side = Rc::clone(&side);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(cell) = item.child() else { return };
            let Some(boxed) = item.item().and_downcast::<glib::BoxedAnyObject>() else {
                return;
            };
            let card = boxed.borrow::<AlbumCard>();
            let Some(parts) = (if wall {
                wall_parts(&cell)
            } else {
                grid_parts(&cell)
            }) else {
                return;
            };
            parts.title.set_label(&card.title);
            parts.title.set_tooltip_text(Some(&card.title));
            parts.subtitle.set_label(&card.subtitle());
            if wall {
                parts.picture.set_size_request(-1, side.get());
            }
            parts
                .picture
                .set_paintable(Some(&shelf.ui.core.artwork.placeholder(&card.key)));
            let size = request_size(side.get().max(cover));
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
        let covers = Rc::clone(&covers);
        factory.connect_unbind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let Some(boxed) = item.item().and_downcast::<glib::BoxedAnyObject>() {
                covers.hide(&boxed.borrow::<AlbumCard>().key);
            }
        });
    }

    let margin = if wall { 0 } else { GRID_MARGIN };
    let grid = gtk::GridView::builder()
        .model(&gtk::NoSelection::new(Some(shelf.albums.clone())))
        .factory(&factory)
        .min_columns(1)
        .max_columns(3)
        .single_click_activate(true)
        .margin_top(margin)
        .margin_bottom(margin)
        .margin_start(margin)
        .margin_end(margin)
        .build();
    grid.add_css_class("album-grid");
    if wall {
        grid.add_css_class("album-wall");
        fit_wall(&grid, &covers, &side, cover);
    } else {
        crate::ui::controls::bind_adaptive_grid_columns(&grid, cover + TILE_PADDING);
    }
    {
        let shelf = Rc::clone(shelf);
        grid.connect_activate(move |_, position| shelf.open(position));
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&grid)
        .build();
    shelf.ui.register_scroller(&scroll);
    Grid {
        scroll,
        covers,
        shelf: Rc::clone(shelf),
        wall,
    }
}

impl AlbumView for Grid {
    fn widget(&self) -> gtk::Widget {
        self.scroll.clone().upcast()
    }

    fn kind(&self) -> AlbumsView {
        if self.wall {
            AlbumsView::Wall
        } else {
            AlbumsView::Grid
        }
    }

    fn scroll_to_top(&self) {
        self.scroll.vadjustment().set_value(0.0);
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
    }
}
