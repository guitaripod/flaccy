use crate::events::AppEvent;
use crate::filters;
use crate::library::{Album, ArtistEntry};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::cmp::Reverse;
use std::collections::HashMap;
use std::rc::Rc;

#[derive(Clone, Copy, PartialEq)]
enum ArtistSort {
    Name,
    MostPlayed,
    RecentlyPlayed,
    TrackCount,
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();
    let covers: Rc<RefCell<HashMap<String, (String, String)>>> =
        Rc::new(RefCell::new(HashMap::new()));
    let sort_mode = Rc::new(Cell::new(ArtistSort::Name));
    let bound: Rc<RefCell<HashMap<String, glib::WeakRef<adw::Avatar>>>> =
        Rc::new(RefCell::new(HashMap::new()));

    let filter = {
        let query = Rc::clone(&ui.query);
        let needle = filters::SearchNeedle::default();
        gtk::CustomFilter::new(move |obj| {
            let Some(boxed) = obj.downcast_ref::<BoxedAnyObject>() else {
                return true;
            };
            let query = query.borrow();
            needle.matches(&query, &[&boxed.borrow::<ArtistEntry>().name])
        })
    };
    let filter_model = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
    let selection = gtk::NoSelection::new(Some(filter_model));

    let factory = gtk::SignalListItemFactory::new();
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let cell = build_artist_cell();
        let gesture = gtk::GestureClick::builder()
            .button(gdk::BUTTON_SECONDARY)
            .build();
        let item_weak = item.downgrade();
        let anchor = cell.clone();
        gesture.connect_pressed(move |_, _, x, y| {
            let Some(item) = item_weak.upgrade() else {
                return;
            };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let name = boxed.borrow::<ArtistEntry>().name.clone();
            context::popup_menu_at(&anchor, &context::artist_menu(&name), x, y);
        });
        cell.add_controller(gesture);
        item.set_child(Some(&cell));
    });
    {
        let ui = Rc::clone(ui);
        let covers = Rc::clone(&covers);
        let bound = Rc::clone(&bound);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(cell) = item.child() else { return };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let artist = boxed.borrow::<ArtistEntry>();
            let Some(avatar) = cell.first_child().and_downcast::<adw::Avatar>() else {
                return;
            };
            let Some(name_label) = avatar.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            let Some(counts) = name_label.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            avatar.set_custom_image(gdk::Paintable::NONE);
            avatar.set_text(Some(&artist.name));
            name_label.set_label(&artist.name);
            name_label.set_tooltip_text(Some(&artist.name));
            counts.set_label(&artist_counts_label(&artist));
            let key = crate::hygiene::artist_key(&artist.name);
            if let Some((title, album_artist)) = covers.borrow().get(&key).cloned() {
                let expected = key.clone();
                let item_weak = item.downgrade();
                let weak = avatar.downgrade();
                let wanted = {
                    let item_weak = item_weak.clone();
                    let expected = expected.clone();
                    move || still_bound_artist(&item_weak, &expected)
                };
                ui.core.artwork.request_while(
                    wanted,
                    &title,
                    &album_artist,
                    120,
                    move |texture, _| {
                        if let (Some(avatar), Some(texture)) = (weak.upgrade(), texture) {
                            if still_bound_artist(&item_weak, &expected) {
                                avatar.set_custom_image(Some(texture));
                            }
                        }
                    },
                );
            }
            bound.borrow_mut().insert(key, avatar.downgrade());
        });
    }
    {
        let bound = Rc::clone(&bound);
        factory.connect_unbind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() {
                let key = crate::hygiene::artist_key(&boxed.borrow::<ArtistEntry>().name);
                bound.borrow_mut().remove(&key);
            }
        });
    }

    let grid = gtk::GridView::builder()
        .model(&selection)
        .factory(&factory)
        .min_columns(1)
        .max_columns(3)
        .single_click_activate(true)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    grid.add_css_class("album-grid");
    crate::ui::controls::bind_adaptive_grid_columns(&grid, 156);
    {
        let ui = Rc::clone(ui);
        grid.connect_activate(move |grid, position| {
            let Some(boxed) = grid
                .model()
                .and_then(|model| model.item(position))
                .and_downcast::<BoxedAnyObject>()
            else {
                return;
            };
            let name = boxed.borrow::<ArtistEntry>().name.clone();
            crate::ui::artist_page::push_artist_page(&ui, &name);
        });
    }

    let empty = adw::StatusPage::builder()
        .icon_name("system-users-symbolic")
        .title("No Artists")
        .description("Flaccy lists artists from the audio files in your music folder. Add music there, then choose Rescan Library in Preferences.")
        .build();

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&grid)
        .build();
    ui.register_scroller(&scroll);

    let sort_dropdown =
        gtk::DropDown::from_strings(&["Name", "Most Played", "Recently Played", "Track Count"]);
    sort_dropdown.set_valign(gtk::Align::Center);
    sort_dropdown.set_tooltip_text(Some("Sort artists"));
    let sort_label = gtk::Label::new(Some("Sort"));
    sort_label.add_css_class("dim");
    sort_label.add_css_class("caption");
    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(18)
        .margin_start(24)
        .margin_end(24)
        .halign(gtk::Align::End)
        .build();
    header.append(&sort_label);
    header.append(&sort_dropdown);

    let grid_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    grid_box.append(&header);
    grid_box.append(&scroll);

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&grid_box, Some("grid"));

    let repopulate: Rc<dyn Fn()> = {
        let store = store.clone();
        let covers = Rc::clone(&covers);
        let sort_mode = Rc::clone(&sort_mode);
        let ui = Rc::clone(ui);
        let covers_from = filters::BuiltFrom::default();
        Rc::new(move || {
            let library = ui.core.library.borrow().clone();
            if !covers_from.is(&library) {
                *covers.borrow_mut() = representative_covers(&library.albums);
                covers_from.set(&library);
            }
            let mut sorted = library.artists.clone();
            sort_artists(&mut sorted, sort_mode.get());
            let items: Vec<BoxedAnyObject> = sorted.into_iter().map(BoxedAnyObject::new).collect();
            store.splice(0, store.n_items(), &items);
        })
    };

    let rebuild = {
        let stack = stack.clone();
        let ui = Rc::clone(ui);
        let repopulate = Rc::clone(&repopulate);
        let applied = Cell::new(None::<u64>);
        move || {
            let library = ui.core.library.borrow().clone();
            let fingerprint = filters::library_signature(&library).artists;
            if applied.replace(Some(fingerprint)) != Some(fingerprint) {
                repopulate();
            }
            stack.set_visible_child_name(if library.artists.is_empty() {
                "empty"
            } else {
                "grid"
            });
        }
    };
    rebuild();

    {
        let sort_mode = Rc::clone(&sort_mode);
        let repopulate = Rc::clone(&repopulate);
        let scroll = scroll.clone();
        sort_dropdown.connect_selected_notify(move |dropdown| {
            let mode = match dropdown.selected() {
                1 => ArtistSort::MostPlayed,
                2 => ArtistSort::RecentlyPlayed,
                3 => ArtistSort::TrackCount,
                _ => ArtistSort::Name,
            };
            if sort_mode.replace(mode) != mode {
                scroll.vadjustment().set_value(0.0);
                repopulate();
            }
        });
    }

    {
        let library_dirty = Rc::new(Cell::new(false));
        let search_dirty = Rc::new(Cell::new(false));
        {
            let rebuild = rebuild.clone();
            let filter = filter.clone();
            let library_dirty = Rc::clone(&library_dirty);
            let search_dirty = Rc::clone(&search_dirty);
            ui.core
                .hub
                .subscribe_widget(&stack, move |stack, event| match event {
                    AppEvent::LibraryReloaded if stack.is_mapped() => rebuild(),
                    AppEvent::LibraryReloaded => library_dirty.set(true),
                    AppEvent::SearchChanged(_) if stack.is_mapped() => {
                        filter.changed(gtk::FilterChange::Different)
                    }
                    AppEvent::SearchChanged(_) => search_dirty.set(true),
                    _ => {}
                });
        }
        let rebuild = rebuild.clone();
        let filter = filter.clone();
        stack.connect_map(move |_| {
            if library_dirty.replace(false) {
                rebuild();
            }
            if search_dirty.replace(false) {
                filter.changed(gtk::FilterChange::Different);
            }
        });
    }

    {
        let ui = Rc::clone(ui);
        let covers = Rc::clone(&covers);
        let bound = Rc::clone(&bound);
        ui.core.hub.clone().subscribe_widget(&stack, move |_, event| {
            let (AppEvent::AlbumEnriched { title, artist }
            | AppEvent::AlbumArtworkChanged { title, artist }) = event
            else {
                return;
            };
            let represented: Vec<String> = covers
                .borrow()
                .iter()
                .filter(|(_, (t, a))| t == title && a == artist)
                .map(|(key, _)| key.clone())
                .collect();
            if represented.is_empty() {
                return;
            }
            if matches!(event, AppEvent::AlbumEnriched { .. }) {
                ui.core.artwork.invalidate(title, artist);
            }
            for key in represented {
                let Some(avatar) = bound.borrow().get(&key).and_then(|w| w.upgrade()) else {
                    continue;
                };
                let weak = avatar.downgrade();
                let bound = Rc::clone(&bound);
                ui.core.artwork.request(title, artist, 120, move |texture, _| {
                    if let Some(avatar) = weak.upgrade() {
                        let still = bound
                            .borrow()
                            .get(&key)
                            .and_then(|w| w.upgrade())
                            .is_some_and(|current| current == avatar);
                        if still {
                            avatar.set_custom_image(texture);
                        }
                    }
                });
            }
        });
    }

    stack.upcast()
}

/// Picks each artist's cover-source album — the one with the most tracks, so a
/// stray single doesn't win over the artist's main record — keyed by artist
/// name to the album's `(title, artist)` artwork-cache lookup pair.
fn representative_covers(albums: &[Album]) -> HashMap<String, (String, String)> {
    let mut best: HashMap<String, &Album> = HashMap::new();
    for album in albums {
        let credit_key = crate::hygiene::artist_key(&album.artist);
        for key in std::iter::once(credit_key.clone()).chain(
            album
                .tracks
                .iter()
                .map(|track| crate::hygiene::artist_key(&track.artist)),
        ) {
            best.entry(key)
                .and_modify(|current| {
                    if album.tracks.len() > current.tracks.len() {
                        *current = album;
                    }
                })
                .or_insert(album);
        }
    }
    best.into_iter()
        .map(|(artist, album)| (artist, (album.title.clone(), album.artist.clone())))
        .collect()
}

/// The line under an artist's name. An artist credited with no album of their
/// own — a composer on a compilation, a guest — is described by what they
/// actually appear on, so the cell never reads "0 albums".
fn artist_counts_label(artist: &ArtistEntry) -> String {
    fn plural(count: usize, noun: &str) -> String {
        format!("{count} {noun}{}", if count == 1 { "" } else { "s" })
    }
    let lead = if artist.album_count > 0 {
        plural(artist.album_count, "album")
    } else {
        format!("appears on {}", plural(artist.appearance_count, "album"))
    };
    format!("{lead} · {}", plural(artist.track_count, "track"))
}

type ArtistSortKey = (Reverse<i64>, Reverse<Option<i64>>, String);

fn artist_sort_key(artist: &ArtistEntry, mode: ArtistSort) -> ArtistSortKey {
    let name = artist.name.to_lowercase();
    match mode {
        ArtistSort::Name => (Reverse(0), Reverse(None), name),
        ArtistSort::MostPlayed => (Reverse(artist.play_count), Reverse(None), name),
        ArtistSort::RecentlyPlayed => (Reverse(0), Reverse(artist.last_played), name),
        ArtistSort::TrackCount => (Reverse(artist.track_count as i64), Reverse(None), name),
    }
}

fn sort_artists(artists: &mut [ArtistEntry], mode: ArtistSort) {
    artists.sort_by_cached_key(|artist| artist_sort_key(artist, mode));
}

/// Guards an async avatar callback against GridView cell recycling: only paint
/// if the shared card is still bound to the artist whose cover was requested.
fn still_bound_artist(item: &glib::WeakRef<gtk::ListItem>, expected: &str) -> bool {
    item.upgrade()
        .and_then(|item| item.item())
        .and_downcast::<BoxedAnyObject>()
        .is_some_and(|boxed| {
            crate::hygiene::artist_key(&boxed.borrow::<ArtistEntry>().name) == expected
        })
}

/// Empty artist-card shell reused by the GridView factory: an `adw::Avatar`
/// (initials fallback), name, and counts in fixed order. The bind step fills
/// them and overpaints the avatar with the representative album's cover.
fn build_artist_cell() -> gtk::Box {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(140)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Start)
        .hexpand(true)
        .build();
    cell.add_css_class("album-tile");

    let avatar = adw::Avatar::new(112, None, true);
    avatar.set_halign(gtk::Align::Center);
    cell.append(&avatar);

    let name = gtk::Label::builder()
        .halign(gtk::Align::Center)
        .justify(gtk::Justification::Center)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(16)
        .hexpand(true)
        .build();
    name.add_css_class("album-title");
    cell.append(&name);

    let counts = gtk::Label::builder().halign(gtk::Align::Center).build();
    counts.add_css_class("dim");
    counts.add_css_class("caption");
    cell.append(&counts);

    cell
}

#[cfg(test)]
mod tests {
    use super::*;

    fn artist(name: &str, plays: i64, last: Option<i64>, tracks: usize) -> ArtistEntry {
        ArtistEntry {
            name: name.to_string(),
            album_count: 1,
            appearance_count: 0,
            track_count: tracks,
            play_count: plays,
            last_played: last,
        }
    }

    fn names(artists: &[ArtistEntry]) -> Vec<&str> {
        artists.iter().map(|a| a.name.as_str()).collect()
    }

    #[test]
    fn name_sort_ignores_case() {
        let mut artists = vec![artist("beta", 0, None, 1), artist("Alpha", 0, None, 1)];
        sort_artists(&mut artists, ArtistSort::Name);
        assert_eq!(names(&artists), vec!["Alpha", "beta"]);
    }

    #[test]
    fn most_played_and_track_count_run_high_to_low_then_by_name() {
        let mut artists = vec![
            artist("b", 5, None, 2),
            artist("a", 5, None, 9),
            artist("c", 9, None, 2),
        ];
        sort_artists(&mut artists, ArtistSort::MostPlayed);
        assert_eq!(names(&artists), vec!["c", "a", "b"]);
        sort_artists(&mut artists, ArtistSort::TrackCount);
        assert_eq!(names(&artists), vec!["a", "b", "c"]);
    }

    #[test]
    fn recently_played_puts_the_never_played_last() {
        let mut artists = vec![
            artist("never", 0, None, 1),
            artist("old", 1, Some(10), 1),
            artist("new", 1, Some(20), 1),
        ];
        sort_artists(&mut artists, ArtistSort::RecentlyPlayed);
        assert_eq!(names(&artists), vec!["new", "old", "never"]);
    }
}
