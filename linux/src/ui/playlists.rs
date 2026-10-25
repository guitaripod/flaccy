use crate::events::AppEvent;
use crate::library::{format_time, Library, Track};
use crate::ui::mosaic::{AlbumRef, Mosaic};
use crate::ui::playlist_cover::PlaylistArt;
use crate::ui::track_page::{
    matches, reveal, reveal_row, ControlBar, Frame, PageKind, PageMode, TableOptions, TrackLayout,
    TrackTable, FILTER_THRESHOLD,
};
use crate::ui::{artwork_editor, context, Ui};
use adw::prelude::*;
use flaccy_shared::playlist_cover;
use gtk::glib::BoxedAnyObject;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

const PICKER_COVER_SIDE: i32 = 48;
const THUMB_PX: i32 = 40;
const DETAIL_COVER_SIDE: i32 = 200;
const DETAIL_COVER_COMPACT_SIDE: i32 = 148;
const DETAIL_COVER_WIDE_SIDE: i32 = 288;
const ALBUM_COLUMN_MIN_WIDTH: i32 = 640;
const DETAIL_KEY: &str = "flaccy-playlist-detail";

#[derive(Clone, Copy, PartialEq)]
enum PlaylistSort {
    Name,
    RecentlyCreated,
    MostSongs,
    Longest,
}

impl PlaylistSort {
    const ALL: [PlaylistSort; 4] = [
        PlaylistSort::Name,
        PlaylistSort::RecentlyCreated,
        PlaylistSort::MostSongs,
        PlaylistSort::Longest,
    ];

    fn label(self) -> &'static str {
        match self {
            PlaylistSort::Name => "Name",
            PlaylistSort::RecentlyCreated => "Recently Created",
            PlaylistSort::MostSongs => "Most Songs",
            PlaylistSort::Longest => "Longest",
        }
    }

    fn id(self) -> &'static str {
        match self {
            PlaylistSort::Name => "name",
            PlaylistSort::RecentlyCreated => "recently_created",
            PlaylistSort::MostSongs => "most_songs",
            PlaylistSort::Longest => "longest",
        }
    }

    fn from_id(id: &str) -> PlaylistSort {
        Self::ALL
            .into_iter()
            .find(|sort| sort.id() == id)
            .unwrap_or(PlaylistSort::Name)
    }
}

/// One playlist as the grid and the picker show it: its playable size and the
/// first few distinct albums that give it a cover.
#[derive(Clone)]
struct PlaylistCard {
    id: i64,
    name: String,
    created_at: i64,
    tracks: usize,
    duration: f64,
    covers: Vec<AlbumRef>,
}

impl PlaylistCard {
    fn subtitle(&self) -> String {
        if self.tracks == 0 {
            "Empty".to_string()
        } else {
            format!("{} · {}", songs_text(self.tracks), span_text(self.duration))
        }
    }
}

fn songs_text(count: usize) -> String {
    if count == 1 {
        "1 song".to_string()
    } else {
        format!("{count} songs")
    }
}

/// Total running time as people say it: minutes under an hour, hours and
/// minutes after, whole hours once the minutes stop mattering.
fn span_text(seconds: f64) -> String {
    let minutes = (seconds / 60.0).round() as i64;
    let (hours, rest) = (minutes / 60, minutes % 60);
    if hours == 0 {
        format!("{} min", rest.max(1))
    } else if rest == 0 || hours >= 48 {
        format!("{hours} hr")
    } else {
        format!("{hours} hr {rest} min")
    }
}

fn created_text(created_at: i64) -> String {
    chrono::DateTime::from_timestamp(created_at, 0)
        .map(|stamp| {
            stamp
                .with_timezone(&chrono::Local)
                .format("%b %-d, %Y")
                .to_string()
        })
        .unwrap_or_default()
}

/// Maps every library track to the (title, artist) key its album's artwork is
/// cached under, which is the album grouping and not the track's own tags.
fn album_index(library: &Library) -> HashMap<&str, (&str, &str)> {
    let mut index = HashMap::new();
    for album in &library.albums {
        for track in &album.tracks {
            index.insert(
                track.rel_path.as_str(),
                (album.title.as_str(), album.artist.as_str()),
            );
        }
    }
    index
}

/// The albums a playlist's automatic mosaic is drawn from: the first distinct
/// releases among its tracks, in playlist order, keyed the way the album grid
/// keys its artwork.
fn cover_albums<'a>(
    rel_paths: impl Iterator<Item = &'a str>,
    album_of: &HashMap<&str, (&str, &str)>,
) -> Vec<AlbumRef> {
    let albums: Vec<AlbumRef> = rel_paths
        .filter_map(|rel| album_of.get(rel))
        .map(|(title, artist)| (title.to_string(), artist.to_string()))
        .collect();
    playlist_cover::mosaic_albums(&albums)
}

/// Every playlist resolved against the live library: files that have left the
/// library neither count nor play, matching what the detail page lists.
fn load_cards(ui: &Rc<Ui>) -> Vec<PlaylistCard> {
    let library = ui.core.library.borrow().clone();
    let by_path: HashMap<&str, &Track> = library
        .tracks
        .iter()
        .map(|track| (track.rel_path.as_str(), track))
        .collect();
    let album_of = album_index(&library);
    let mut grouped: HashMap<i64, Vec<String>> = HashMap::new();
    for (playlist_id, rel) in ui.core.db.all_playlist_tracks() {
        grouped.entry(playlist_id).or_default().push(rel);
    }
    ui.core
        .db
        .fetch_playlists()
        .into_iter()
        .map(|row| {
            let rels = grouped.remove(&row.id).unwrap_or_default();
            let playable: Vec<&Track> = rels
                .iter()
                .filter_map(|rel| by_path.get(rel.as_str()).copied())
                .collect();
            PlaylistCard {
                id: row.id,
                name: row.name,
                created_at: row.created_at,
                tracks: playable.len(),
                duration: playable.iter().map(|track| track.duration).sum(),
                covers: cover_albums(
                    playable.iter().map(|track| track.rel_path.as_str()),
                    &album_of,
                ),
            }
        })
        .collect()
}

fn sort_cards(cards: &mut [PlaylistCard], sort: PlaylistSort) {
    let name_key = |card: &PlaylistCard| card.name.to_lowercase();
    match sort {
        PlaylistSort::Name => cards.sort_by_key(|card| (name_key(card), card.id)),
        PlaylistSort::RecentlyCreated => {
            cards.sort_by_key(|card| (-card.created_at, name_key(card), card.id))
        }
        PlaylistSort::MostSongs => {
            cards.sort_by_key(|card| (std::cmp::Reverse(card.tracks), name_key(card), card.id))
        }
        PlaylistSort::Longest => {
            cards.sort_by_key(|card| (-(card.duration as i64), name_key(card), card.id))
        }
    }
}

/// Digest of everything the grid renders, so an unrelated library event does
/// not splice the model and throw away the scroll position.
fn cards_fingerprint(cards: &[PlaylistCard]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for card in cards {
        let row = format!(
            "{}|{}|{}|{}|{:?}",
            card.id, card.name, card.tracks, card.duration as i64, card.covers
        );
        hash = hash.rotate_left(5) ^ crate::palette::fnv1a_64(&row);
    }
    hash
}

/// The playlists page: a responsive grid of mosaic-cover cards under a header
/// with sorting and creation, searchable through the window's search field.
pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();
    let sort_mode = Rc::new(Cell::new(PlaylistSort::from_id(
        &ui.core.config.borrow().playlist_sort,
    )));
    let cards: Rc<RefCell<Vec<PlaylistCard>>> = Rc::new(RefCell::new(Vec::new()));

    let filter = {
        let query = Rc::clone(&ui.query);
        gtk::CustomFilter::new(move |obj| {
            let Some(boxed) = obj.downcast_ref::<BoxedAnyObject>() else {
                return true;
            };
            let query = query.borrow();
            if query.is_empty() {
                return true;
            }
            boxed
                .borrow::<PlaylistCard>()
                .name
                .to_lowercase()
                .contains(&query.to_lowercase())
        })
    };
    let filter_model = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
    let selection = gtk::NoSelection::new(Some(filter_model.clone()));

    let factory = gtk::SignalListItemFactory::new();
    {
        let ui = Rc::clone(ui);
        factory.connect_setup(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let cell = build_card_cell(&ui);
            let menu_gesture = gtk::GestureClick::builder()
                .button(gdk::BUTTON_SECONDARY)
                .build();
            {
                let item_weak = item.downgrade();
                let anchor = cell.clone();
                let ui = Rc::clone(&ui);
                menu_gesture.connect_pressed(move |_, _, x, y| {
                    let Some(card) = item_weak.upgrade().and_then(|item| card_of(&item)) else {
                        return;
                    };
                    let has_cover = ui.core.db.has_playlist_cover(card.id);
                    let downloads = context::playlist_downloads(&ui.core, card.id);
                    context::popup_menu_at(
                        &anchor,
                        &playlist_list_menu(card.id, has_cover, downloads),
                        x,
                        y,
                    );
                });
            }
            cell.add_controller(menu_gesture);
            if let Some(parts) = CardCell::from_widget(cell.upcast_ref()) {
                let item_weak = item.downgrade();
                let play_ui = Rc::clone(&ui);
                parts.fab.connect_clicked(move |_| {
                    if let Some(card) = item_weak.upgrade().and_then(|item| card_of(&item)) {
                        play_playlist(&play_ui, card.id, false);
                    }
                });
                let item_weak = item.downgrade();
                artwork_editor::attach_playlist_image_drop(&parts.art.widget(), &ui, move || {
                    item_weak
                        .upgrade()
                        .and_then(|item| card_of(&item))
                        .map(|card| card.id)
                });
            }
            item.set_child(Some(&cell));
        });
    }
    {
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(parts) = item.child().and_then(|child| CardCell::from_widget(&child)) else {
                return;
            };
            let Some(card) = card_of(item) else { return };
            parts.title.set_label(&card.name);
            parts.title.set_tooltip_text(Some(&card.name));
            parts.subtitle.set_label(&card.subtitle());
            parts.fab.set_sensitive(card.tracks > 0);
            parts.art.bind(card.id, &card.name, card.covers.clone());
        });
    }

    let grid = gtk::GridView::builder()
        .model(&selection)
        .factory(&factory)
        .min_columns(1)
        .max_columns(3)
        .single_click_activate(true)
        .margin_top(12)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    grid.add_css_class("album-grid");
    grid.add_css_class("playlist-grid");
    crate::ui::controls::bind_adaptive_grid_columns(&grid, 164);
    {
        let ui = Rc::clone(ui);
        grid.connect_activate(move |grid, position| {
            let card = grid
                .model()
                .and_then(|model| model.item(position))
                .and_downcast::<BoxedAnyObject>()
                .map(|boxed| boxed.borrow::<PlaylistCard>().clone());
            if let Some(card) = card {
                push_playlist_detail(&ui, card.id);
            }
        });
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&grid)
        .build();
    ui.register_scroller(&scroll);

    let no_results = adw::StatusPage::builder()
        .icon_name("system-search-symbolic")
        .title("No Results")
        .description("No playlist matches your search.")
        .vexpand(true)
        .build();
    let results = gtk::Stack::new();
    results.add_named(&scroll, Some("grid"));
    results.add_named(&no_results, Some("none"));

    let heading = gtk::Label::builder().label("Playlists").xalign(0.0).build();
    heading.add_css_class("title-1");
    let summary = gtk::Label::builder().xalign(0.0).build();
    summary.add_css_class("dim");
    summary.add_css_class("caption");
    let titles = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    titles.append(&heading);
    titles.append(&summary);

    let sort_labels: Vec<&str> = PlaylistSort::ALL.iter().map(|s| s.label()).collect();
    let sort_dropdown = gtk::DropDown::from_strings(&sort_labels);
    sort_dropdown.set_valign(gtk::Align::Center);
    sort_dropdown.set_tooltip_text(Some("Sort playlists"));
    sort_dropdown.set_selected(
        PlaylistSort::ALL
            .iter()
            .position(|s| *s == sort_mode.get())
            .unwrap_or(0) as u32,
    );

    let new_content = adw::ButtonContent::builder()
        .icon_name("list-add-symbolic")
        .label("New Playlist")
        .build();
    let new_button = gtk::Button::builder()
        .child(&new_content)
        .valign(gtk::Align::Center)
        .tooltip_text("New Playlist")
        .build();
    new_button.add_css_class("pill");
    {
        let ui = Rc::clone(ui);
        new_button.connect_clicked(move |_| prompt_new_playlist(&ui, None));
    }

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .margin_top(24)
        .margin_start(24)
        .margin_end(24)
        .build();
    header.append(&titles);
    header.append(&sort_dropdown);
    header.append(&new_button);

    let list_page = gtk::Box::new(gtk::Orientation::Vertical, 0);
    list_page.append(&header);
    list_page.append(&results);

    let page_bin = adw::BreakpointBin::new();
    page_bin.set_size_request(320, 200);
    page_bin.set_child(Some(&list_page));
    install_list_breakpoints(
        &page_bin,
        &header,
        &summary,
        &new_button,
        &new_content,
        &grid,
    );

    let empty = adw::StatusPage::builder()
        .icon_name("view-list-symbolic")
        .title("No Playlists")
        .description("Create a playlist, then add songs from any track's context menu.")
        .build();
    let empty_button = gtk::Button::with_label("New Playlist");
    empty_button.add_css_class("pill");
    empty_button.add_css_class("suggested-action");
    empty_button.set_halign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        empty_button.connect_clicked(move |_| prompt_new_playlist(&ui, None));
    }
    empty.set_child(Some(&empty_button));

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&page_bin, Some("list"));

    {
        let results = results.clone();
        let store = store.clone();
        filter_model.connect_items_changed(move |model, _, _, _| {
            let none = model.n_items() == 0 && store.n_items() > 0;
            results.set_visible_child_name(if none { "none" } else { "grid" });
        });
    }

    let rebuild: Rc<dyn Fn(bool)> = {
        let store = store.clone();
        let stack = stack.clone();
        let scroll = scroll.clone();
        let results = results.clone();
        let summary = summary.clone();
        let ui = Rc::clone(ui);
        let sort_mode = Rc::clone(&sort_mode);
        let cards = Rc::clone(&cards);
        let applied = Cell::new(0u64);
        Rc::new(move |force| {
            let mut loaded = load_cards(&ui);
            sort_cards(&mut loaded, sort_mode.get());
            let fingerprint = cards_fingerprint(&loaded);
            if force {
                applied.set(0);
            }
            summary.set_label(&match loaded.len() {
                1 => "1 playlist".to_string(),
                count => format!("{count} playlists"),
            });
            if applied.replace(fingerprint) != fingerprint {
                let saved = scroll.vadjustment().value();
                let items: Vec<BoxedAnyObject> = loaded
                    .iter()
                    .map(|card| BoxedAnyObject::new(card.clone()))
                    .collect();
                store.splice(0, store.n_items(), &items);
                if saved > 0.0 {
                    let adj = scroll.vadjustment();
                    glib::idle_add_local_once(move || adj.set_value(saved));
                }
            }
            results.set_visible_child_name(if store.n_items() > 0 && loaded.is_empty() {
                "none"
            } else {
                "grid"
            });
            stack.set_visible_child_name(if loaded.is_empty() { "empty" } else { "list" });
            *cards.borrow_mut() = loaded;
        })
    };
    rebuild(false);

    {
        let ui = Rc::clone(ui);
        let sort_mode = Rc::clone(&sort_mode);
        let rebuild = Rc::clone(&rebuild);
        let scroll = scroll.clone();
        sort_dropdown.connect_selected_notify(move |dropdown| {
            let sort =
                PlaylistSort::ALL[(dropdown.selected() as usize).min(PlaylistSort::ALL.len() - 1)];
            if sort_mode.replace(sort) == sort {
                return;
            }
            ui.core.config.borrow_mut().playlist_sort = sort.id().to_string();
            ui.core.save_config();
            scroll.vadjustment().set_value(0.0);
            rebuild(false);
        });
    }

    {
        let rebuild = Rc::clone(&rebuild);
        let filter = filter.clone();
        let cards = Rc::clone(&cards);
        let refresh_pending = Rc::new(Cell::new(false));
        ui.core
            .hub
            .subscribe_widget(&stack, move |_, event| match event {
                AppEvent::LibraryReloaded => rebuild(false),
                AppEvent::SearchChanged(_) => filter.changed(gtk::FilterChange::Different),
                AppEvent::AlbumEnriched { title, artist }
                | AppEvent::AlbumArtworkChanged { title, artist } => {
                    let shown = cards
                        .borrow()
                        .iter()
                        .any(|card| card.covers.iter().any(|(t, a)| t == title && a == artist));
                    if shown && !refresh_pending.replace(true) {
                        let rebuild = Rc::clone(&rebuild);
                        let refresh_pending = Rc::clone(&refresh_pending);
                        glib::timeout_add_local_once(
                            std::time::Duration::from_millis(600),
                            move || {
                                refresh_pending.set(false);
                                rebuild(true);
                            },
                        );
                    }
                }
                _ => {}
            });
    }

    stack.upcast()
}

fn card_of(item: &gtk::ListItem) -> Option<PlaylistCard> {
    item.item()
        .and_downcast::<BoxedAnyObject>()
        .map(|boxed| boxed.borrow::<PlaylistCard>().clone())
}

/// The widgets of one grid card, in fixed order: a cover with a play button
/// laid over it, then the name and the size line.
struct CardCell {
    art: PlaylistArt,
    fab: gtk::Button,
    title: gtk::Label,
    subtitle: gtk::Label,
}

impl CardCell {
    fn from_widget(widget: &gtk::Widget) -> Option<Self> {
        let overlay = widget.first_child().and_downcast::<gtk::Overlay>()?;
        let cover = overlay.child().and_downcast::<gtk::Overlay>()?;
        let fab = cover.next_sibling().and_downcast::<gtk::Button>()?;
        let title = overlay.next_sibling().and_downcast::<gtk::Label>()?;
        let subtitle = title.next_sibling().and_downcast::<gtk::Label>()?;
        Some(Self {
            art: PlaylistArt::from_widget(cover.upcast_ref())?,
            fab,
            title,
            subtitle,
        })
    }
}

fn build_card_cell(ui: &Rc<Ui>) -> gtk::Box {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .hexpand(true)
        .valign(gtk::Align::Start)
        .build();
    cell.add_css_class("album-tile");
    cell.add_css_class("playlist-tile");

    let art = PlaylistArt::new(ui, 0, "", 0, "cover", Vec::new());
    art.widget().set_size_request(120, -1);
    let fab = gtk::Button::from_icon_name("media-playback-start-symbolic");
    fab.set_halign(gtk::Align::End);
    fab.set_valign(gtk::Align::End);
    fab.set_margin_end(10);
    fab.set_margin_bottom(10);
    fab.set_tooltip_text(Some("Play"));
    fab.add_css_class("circular");
    fab.add_css_class("playlist-fab");
    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&art.widget()));
    overlay.add_overlay(&fab);
    cell.append(&overlay);

    let title = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(16)
        .hexpand(true)
        .build();
    title.add_css_class("album-title");
    cell.append(&title);

    let subtitle = gtk::Label::builder()
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(18)
        .hexpand(true)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    cell.append(&subtitle);
    cell
}

/// Collapses the list header for narrow windows: the summary line goes, the
/// New Playlist button shrinks to its icon, and the grid's margins tighten.
fn install_list_breakpoints(
    bin: &adw::BreakpointBin,
    header: &gtk::Box,
    summary: &gtk::Label,
    new_button: &gtk::Button,
    new_content: &adw::ButtonContent,
    grid: &gtk::GridView,
) {
    let compact = adw::Breakpoint::new(adw::BreakpointCondition::new_length(
        adw::BreakpointConditionLengthType::MaxWidth,
        520.0,
        adw::LengthUnit::Px,
    ));
    {
        let header = header.clone();
        let summary = summary.clone();
        let new_button = new_button.clone();
        let new_content = new_content.clone();
        let grid = grid.clone();
        compact.connect_apply(move |_| {
            summary.set_visible(false);
            new_content.set_label("");
            new_button.remove_css_class("pill");
            new_button.add_css_class("circular");
            header.set_margin_top(16);
            header.set_margin_start(14);
            header.set_margin_end(14);
            grid.set_margin_start(8);
            grid.set_margin_end(8);
        });
    }
    {
        let header = header.clone();
        let summary = summary.clone();
        let new_button = new_button.clone();
        let new_content = new_content.clone();
        let grid = grid.clone();
        compact.connect_unapply(move |_| {
            summary.set_visible(true);
            new_content.set_label("New Playlist");
            new_button.remove_css_class("circular");
            new_button.add_css_class("pill");
            header.set_margin_top(24);
            header.set_margin_start(24);
            header.set_margin_end(24);
            grid.set_margin_start(24);
            grid.set_margin_end(24);
        });
    }
    bin.add_breakpoint(compact);
}

/// Playlist picker backing the context menus' "Add to Playlist…" item; a flat
/// dialog instead of a nested submenu because GtkPopoverMenu (4.22) truncates
/// menus that embed submenu sections. Searchable once the list grows, with each
/// playlist's cover, and marks the ones that already hold the song.
pub fn present_add_to_playlist(ui: &Rc<Ui>, rel_path: &str) {
    let mut cards = load_cards(ui);
    sort_cards(&mut cards, PlaylistSort::Name);
    let holding: HashSet<i64> = ui
        .core
        .db
        .all_playlist_tracks()
        .into_iter()
        .filter(|(_, rel)| rel == rel_path)
        .map(|(playlist_id, _)| playlist_id)
        .collect();

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");

    let dialog = adw::Dialog::builder().content_width(380).build();

    let new_row = adw::ActionRow::builder()
        .title("New Playlist…")
        .activatable(true)
        .build();
    let new_icon = gtk::Image::from_icon_name("list-add-symbolic");
    new_icon.add_css_class("playlist-picker-new");
    new_icon.set_pixel_size(20);
    new_row.add_prefix(&new_icon);
    {
        let ui = Rc::clone(ui);
        let rel = rel_path.to_string();
        let dialog = dialog.clone();
        new_row.connect_activated(move |_| {
            dialog.close();
            prompt_new_playlist(&ui, Some(rel.clone()));
        });
    }
    list.append(&new_row);

    for card in &cards {
        let row = adw::ActionRow::builder()
            .title(glib::markup_escape_text(&card.name))
            .subtitle(card.subtitle())
            .activatable(true)
            .build();
        let art = PlaylistArt::new(
            ui,
            card.id,
            &card.name,
            PICKER_COVER_SIDE,
            "playlist-thumb",
            card.covers.clone(),
        );
        art.widget().set_valign(gtk::Align::Center);
        row.add_prefix(&art.widget());
        let already = holding.contains(&card.id);
        if already {
            let check = gtk::Image::from_icon_name("object-select-symbolic");
            check.add_css_class("accent");
            check.set_tooltip_text(Some("Already in this playlist"));
            row.add_suffix(&check);
        }
        let ui = Rc::clone(ui);
        let rel = rel_path.to_string();
        let name = card.name.clone();
        let playlist_id = card.id;
        let dialog = dialog.clone();
        row.connect_activated(move |_| {
            if already {
                ui.core.toast(&format!("Already in {name}"));
            } else {
                match ui.core.db.add_track_to_playlist(playlist_id, &rel) {
                    Ok(()) => {
                        ui.core.hub.emit(&AppEvent::LibraryReloaded);
                        ui.core.toast(&format!("Added to {name}"));
                    }
                    Err(err) => {
                        crate::logger::error("database", &format!("playlist add failed: {err}"));
                        ui.core.toast(&write_failure_message("add to", &name));
                    }
                }
            }
            dialog.close();
        });
        list.append(&row);
    }

    let names: Rc<Vec<String>> =
        Rc::new(cards.iter().map(|card| card.name.to_lowercase()).collect());
    let query = Rc::new(RefCell::new(String::new()));
    {
        let names = Rc::clone(&names);
        let query = Rc::clone(&query);
        list.set_filter_func(move |row| {
            let index = row.index();
            let query = query.borrow();
            if index == 0 || query.is_empty() {
                return true;
            }
            names
                .get(index as usize - 1)
                .is_some_and(|name| name.contains(query.as_str()))
        });
    }

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(8)
        .margin_bottom(18)
        .margin_start(18)
        .margin_end(18)
        .build();
    if cards.len() >= FILTER_THRESHOLD {
        let search = gtk::SearchEntry::builder()
            .placeholder_text("Find a playlist")
            .build();
        {
            let list = list.clone();
            let query = Rc::clone(&query);
            search.connect_search_changed(move |entry| {
                *query.borrow_mut() = entry.text().to_lowercase();
                list.invalidate_filter();
            });
        }
        content.append(&search);
        dialog.set_focus(Some(&search));
    }
    content.append(&list);
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .max_content_height(520)
        .child(&content)
        .build();

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(
        &adw::HeaderBar::builder()
            .title_widget(&adw::WindowTitle::new("Add to Playlist", ""))
            .build(),
    );
    toolbar.set_content(Some(&scroll));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(&ui.window));
}

pub fn prompt_new_playlist(ui: &Rc<Ui>, add_rel_path: Option<String>) {
    let dialog = adw::AlertDialog::builder()
        .heading("New Playlist")
        .body("Name your new playlist.")
        .close_response("cancel")
        .default_response("create")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("create", "Create");
    dialog.set_response_appearance("create", adw::ResponseAppearance::Suggested);

    let entry = gtk::Entry::builder()
        .placeholder_text("Playlist name")
        .activates_default(true)
        .build();
    dialog.set_extra_child(Some(&entry));

    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response != "create" {
            return;
        }
        let name = entry.text().trim().to_string();
        if name.is_empty() {
            return;
        }
        match ui.core.db.create_playlist(&name) {
            Ok(id) => {
                if let Some(rel) = &add_rel_path {
                    let _ = ui.core.db.add_track_to_playlist(id, rel);
                    ui.core.toast(&format!("Added to {name}"));
                }
                crate::logger::info("database", &format!("created playlist '{name}'"));
                ui.core.hub.emit(&AppEvent::LibraryReloaded);
            }
            Err(err) => {
                crate::logger::error("database", &format!("create playlist failed: {err}"));
                ui.core.toast(&write_failure_message("create", &name));
            }
        }
    });
    dialog.present(Some(&window));
}

/// Names and saves a list of songs as a new playlist, in the order given — the
/// Songs page uses it to keep a filtered list such as Most Played · 7D.
pub fn prompt_save_tracks(ui: &Rc<Ui>, default_name: &str, rel_paths: Vec<String>) {
    let dialog = adw::AlertDialog::builder()
        .heading("Save as Playlist")
        .body(format!(
            "{} will be saved in the order they are listed.",
            if rel_paths.len() == 1 {
                "1 song".to_string()
            } else {
                format!("{} songs", rel_paths.len())
            }
        ))
        .close_response("cancel")
        .default_response("save")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("save", "Save");
    dialog.set_response_appearance("save", adw::ResponseAppearance::Suggested);

    let entry = gtk::Entry::builder()
        .text(default_name)
        .activates_default(true)
        .build();
    dialog.set_extra_child(Some(&entry));

    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response != "save" {
            return;
        }
        let name = entry.text().trim().to_string();
        if name.is_empty() {
            return;
        }
        let saved = ui
            .core
            .db
            .create_playlist(&name)
            .and_then(|id| ui.core.db.add_tracks_to_playlist(id, &rel_paths));
        match saved {
            Ok(()) => {
                crate::logger::info(
                    "database",
                    &format!("saved {} songs as playlist '{name}'", rel_paths.len()),
                );
                ui.core.toast(&format!("Saved “{name}”"));
                ui.core.hub.emit(&AppEvent::LibraryReloaded);
            }
            Err(err) => {
                crate::logger::error("database", &format!("save playlist failed: {err}"));
                ui.core.toast(&write_failure_message("create", &name));
            }
        }
    });
    dialog.present(Some(&window));
}

/// Everything the detail page needs to redraw itself when the playlist or the
/// library changes underneath it. The page owns it, and every widget callback
/// holds it weakly, so it lives exactly as long as the page does.
struct DetailView {
    ui: Rc<Ui>,
    playlist_id: i64,
    created_at: i64,
    page: gtk::glib::WeakRef<adw::NavigationPage>,
    scroll: gtk::ScrolledWindow,
    list: gtk::ListBox,
    title: gtk::Label,
    info: gtk::Label,
    art: PlaylistArt,
    backdrop: gtk::DrawingArea,
    dominant: Rc<RefCell<Option<(u8, u8, u8)>>>,
    play: gtk::Button,
    shuffle: gtk::Button,
    frame: Rc<Frame>,
    bar: ControlBar,
    stack: gtk::Stack,
    layout: Cell<TrackLayout>,
    table: RefCell<Option<Rc<TrackTable>>>,
    empty: adw::StatusPage,
    hint: gtk::Label,
    entries: Rc<RefCell<Vec<(i64, Track)>>>,
    query: Rc<RefCell<String>>,
    album_labels: RefCell<Vec<gtk::Label>>,
    show_albums: Cell<bool>,
    applied: Cell<u64>,
}

impl DetailView {
    /// Shows the album column in the list rows only while the pane has room
    /// for it beside the titles.
    fn set_show_albums(&self, shown: bool) {
        self.show_albums.set(shown);
        for label in self.album_labels.borrow().iter() {
            label.set_visible(shown);
        }
    }

    fn choose_layout(self: &Rc<Self>, layout: TrackLayout) {
        if self.layout.get() == layout {
            return;
        }
        self.ui.core.config.borrow_mut().detail_layout = layout.id().to_string();
        self.ui.core.save_config();
        self.show_layout(layout);
        self.frame.scroll_to_top();
    }

    fn show_layout(self: &Rc<Self>, layout: TrackLayout) {
        self.layout.set(layout);
        self.bar.set_layout(layout);
        if layout == TrackLayout::Table {
            self.ensure_table();
            self.stack.set_visible_child_name("table");
            self.hint
                .set_label("A table is a view of the playlist: switch to List to reorder · right-click to remove");
        } else {
            self.stack.set_visible_child_name("list");
            self.hint
                .set_label("Drag rows to reorder · right-click to remove");
        }
        self.apply_query();
    }

    fn ensure_table(self: &Rc<Self>) {
        if self.table.borrow().is_some() {
            return;
        }
        let options = TableOptions {
            kind: Some(PageKind::Playlist),
            disc_of: None,
            artists_vary: true,
        };
        let menu: Rc<crate::ui::songs::MenuHandler> = {
            let view = Rc::downgrade(self);
            Rc::new(move |track, anchor, x, y| {
                let Some(view) = view.upgrade() else { return };
                let row_id = view
                    .entries
                    .borrow()
                    .get((track.track_number.max(1) - 1) as usize)
                    .map(|(row_id, _)| *row_id);
                let menu = context::track_menu(
                    &track.rel_path,
                    track.loved,
                    view.ui.core.has_previous_version(&track.rel_path),
                );
                if let Some(row_id) = row_id {
                    let remove_section = gio::Menu::new();
                    let remove_item = gio::MenuItem::new(Some("Remove from Playlist"), None);
                    remove_item.set_action_and_target_value(
                        Some("win.playlist-remove-row"),
                        Some(&(view.playlist_id, row_id).to_variant()),
                    );
                    remove_section.append_item(&remove_item);
                    menu.append_section(None, &remove_section);
                }
                context::popup_menu_at(anchor, &menu, x, y);
            })
        };
        let table = {
            let ui = Rc::clone(&self.ui);
            let frame = Rc::clone(&self.frame);
            TrackTable::new(
                &self.ui,
                options,
                menu,
                move |tracks, index| ui.core.play_tracks(tracks, index),
                move || frame.scroll_to_top(),
            )
        };
        table.set_tracks(&self.numbered_tracks());
        self.stack.add_named(&table.widget, Some("table"));
        *self.table.borrow_mut() = Some(Rc::new(table));
    }

    /// The playlist's songs with their place in it standing in for the track
    /// number, which is what the table's first column shows and sorts by.
    fn numbered_tracks(&self) -> Vec<Track> {
        self.entries
            .borrow()
            .iter()
            .enumerate()
            .map(|(index, (_, track))| {
                let mut track = track.clone();
                track.track_number = index as i32 + 1;
                track
            })
            .collect()
    }

    fn apply_query(&self) {
        self.list.invalidate_filter();
        if let Some(table) = self.table.borrow().as_ref() {
            table.set_query(&self.query.borrow());
        }
        self.update_filter_status();
    }

    fn locate_playing(&self) {
        let Some(current) = self.ui.core.player.current_track() else {
            self.ui.core.toast("Nothing is playing");
            return;
        };
        let index = self
            .entries
            .borrow()
            .iter()
            .position(|(_, track)| track.rel_path == current.rel_path);
        let Some(index) = index else {
            self.ui.core.toast(&format!(
                "“{}” isn't in this playlist",
                current.title
            ));
            return;
        };
        if !self.query.borrow().is_empty() {
            self.query.borrow_mut().clear();
            self.apply_query();
            self.bar.clear_filter();
        }
        let scroll = self.frame.scroll.clone();
        let table = self.table.borrow().clone();
        let layout = self.layout.get();
        let row = self.list.row_at_index(index as i32);
        let rel_path = current.rel_path.clone();
        glib::idle_add_local_once(move || match (layout, table) {
            (TrackLayout::Table, Some(table)) => {
                if let Some(position) = table.position_of(&rel_path) {
                    reveal_row(&scroll, &table, position);
                }
            }
            _ => {
                if let Some(row) = row {
                    reveal(&scroll, &row);
                }
            }
        });
    }

    /// Drops this page from the navigation stack, for a playlist that was
    /// deleted while its page was open.
    fn close(&self) {
        let Some(page) = self.page.upgrade() else {
            return;
        };
        if self.ui.nav.visible_page().as_ref() == Some(&page) {
            self.ui.nav.pop();
        } else {
            self.ui.nav.remove(&page);
        }
    }

    fn refresh(self: &Rc<Self>) {
        let ui = &self.ui;
        let Some(name) = ui.core.db.playlist_name(self.playlist_id) else {
            self.close();
            return;
        };
        let library = ui.core.library.borrow().clone();
        let by_path: HashMap<&str, &Track> = library
            .tracks
            .iter()
            .map(|track| (track.rel_path.as_str(), track))
            .collect();
        let resolved: Vec<(i64, Track)> = ui
            .core
            .db
            .playlist_tracks(self.playlist_id)
            .into_iter()
            .filter_map(|row| {
                by_path
                    .get(row.rel_path.as_str())
                    .map(|track| (row.row_id, (*track).clone()))
            })
            .collect();

        let mut fingerprint = crate::palette::fnv1a_64(&name);
        for (row_id, track) in &resolved {
            fingerprint = fingerprint.rotate_left(5)
                ^ crate::palette::fnv1a_64(&format!("{row_id}|{}", track.rel_path));
        }
        if self.applied.replace(fingerprint) == fingerprint {
            return;
        }

        self.title.set_label(&name);
        if let Some(page) = self.page.upgrade() {
            page.set_title(&name);
        }
        let duration: f64 = resolved.iter().map(|(_, track)| track.duration).sum();
        let created = created_text(self.created_at);
        let mut info_parts = if resolved.is_empty() {
            vec!["No songs yet".to_string()]
        } else {
            vec![songs_text(resolved.len()), span_text(duration)]
        };
        if !created.is_empty() {
            info_parts.push(format!("Created {created}"));
        }
        self.info.set_label(&info_parts.join(" · "));

        let album_of = album_index(&library);
        let covers = cover_albums(
            resolved.iter().map(|(_, track)| track.rel_path.as_str()),
            &album_of,
        );
        self.art.bind(self.playlist_id, &name, covers);
        if resolved.is_empty() {
            *self.dominant.borrow_mut() = None;
            self.backdrop.queue_draw();
        }

        let saved = self.scroll.vadjustment().value();
        while let Some(child) = self.list.first_child() {
            self.list.remove(&child);
        }
        let mut labels = Vec::with_capacity(resolved.len());
        for (index, (row_id, track)) in resolved.iter().enumerate() {
            let (row, album_label) = self.build_row(index + 1, *row_id, track, &album_of);
            self.list.append(&row);
            labels.push(album_label);
        }
        *self.album_labels.borrow_mut() = labels;
        *self.entries.borrow_mut() = resolved;

        let has_tracks = !self.entries.borrow().is_empty();
        self.play.set_sensitive(has_tracks);
        self.shuffle.set_sensitive(has_tracks);
        self.stack.set_visible(has_tracks);
        self.empty.set_visible(!has_tracks);
        self.hint.set_visible(has_tracks);
        self.bar
            .show_filter(self.entries.borrow().len() >= FILTER_THRESHOLD);
        if let Some(table) = self.table.borrow().as_ref() {
            table.set_tracks(&self.numbered_tracks());
        }
        self.apply_query();
        if saved > 0.0 {
            let adj = self.scroll.vadjustment();
            glib::idle_add_local_once(move || adj.set_value(saved));
        }
    }

    fn update_filter_status(&self) {
        let query = self.query.borrow();
        if query.is_empty() {
            self.bar.set_status(None);
            return;
        }
        let entries = self.entries.borrow();
        let shown = entries
            .iter()
            .filter(|(_, track)| matches(track, &query))
            .count();
        self.bar.set_status(Some(&if shown == 0 {
            "No songs match".to_string()
        } else {
            format!("{shown} of {}", entries.len())
        }));
    }

    fn build_row(
        self: &Rc<Self>,
        index: usize,
        row_id: i64,
        track: &Track,
        album_of: &HashMap<&str, (&str, &str)>,
    ) -> (gtk::ListBoxRow, gtk::Label) {
        let ui = &self.ui;
        let row_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .margin_top(8)
            .margin_bottom(8)
            .margin_start(12)
            .margin_end(12)
            .build();
        let index_cell = crate::ui::controls::track_index_cell(&index.to_string());
        row_box.append(&index_cell.widget);

        let thumb = Mosaic::new();
        thumb.set_fixed_size(THUMB_PX);
        thumb.widget().set_valign(gtk::Align::Center);
        thumb.widget().add_css_class("cover-thumb");
        let album: Option<AlbumRef> = album_of
            .get(track.rel_path.as_str())
            .map(|(title, artist)| (title.to_string(), artist.to_string()));
        let seed = album
            .as_ref()
            .map(|(title, artist)| format!("{title}|{artist}"))
            .unwrap_or_else(|| track.rel_path.clone());
        thumb.set_covers(ui, &seed, album.as_slice(), None);
        if let Some(album) = album {
            let weak_ui = Rc::downgrade(ui);
            ui.core
                .hub
                .subscribe_widget(thumb.widget(), move |host, event| {
                    let AppEvent::AlbumArtworkChanged { title, artist } = event else {
                        return;
                    };
                    if (title, artist) != (&album.0, &album.1) {
                        return;
                    }
                    if let (Some(ui), Some(thumb)) = (weak_ui.upgrade(), Mosaic::from_root(host)) {
                        thumb.set_covers(&ui, &seed, std::slice::from_ref(&album), None);
                    }
                });
        }
        row_box.append(thumb.widget());

        let text_box = gtk::Box::new(gtk::Orientation::Vertical, 2);
        text_box.set_hexpand(true);
        text_box.set_valign(gtk::Align::Center);
        let title = gtk::Label::builder()
            .label(&track.title)
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .tooltip_text(&track.title)
            .build();
        let title_row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        title_row.append(&title);
        title_row.append(&crate::ui::controls::live_new_mix_chip(ui, track));
        text_box.append(&title_row);
        let artist = gtk::Label::builder()
            .label(&track.artist)
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        artist.add_css_class("dim");
        artist.add_css_class("caption");
        text_box.append(&artist);
        row_box.append(&text_box);

        let album_label = gtk::Label::builder()
            .label(&track.album)
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .max_width_chars(22)
            .width_chars(22)
            .tooltip_text(&track.album)
            .visible(self.show_albums.get())
            .build();
        album_label.add_css_class("dim");
        album_label.add_css_class("caption");
        row_box.append(&album_label);

        let heart = gtk::Image::from_icon_name("emote-love-symbolic");
        heart.add_css_class("loved-heart");
        heart.set_visible(track.loved);
        row_box.append(&heart);
        {
            let rel = track.rel_path.clone();
            ui.core.hub.subscribe_widget(&heart, move |heart, event| {
                if let AppEvent::LovedChanged { rel_path, loved } = event {
                    if rel_path == &rel {
                        heart.set_visible(*loved);
                    }
                }
            });
        }

        let duration = gtk::Label::new(Some(&format_time(track.duration)));
        duration.add_css_class("duration-label");
        row_box.append(&duration);

        let handle = gtk::Image::from_icon_name("list-drag-handle-symbolic");
        handle.add_css_class("playlist-drag-handle");
        handle.set_tooltip_text(Some("Drag to reorder"));
        row_box.append(&handle);

        let row = gtk::ListBoxRow::builder().child(&row_box).build();
        attach_playlist_row_menu(ui, &row, self.playlist_id, row_id, track);
        self.attach_reorder_dnd(&row);
        crate::ui::controls::attach_now_playing_row(
            ui,
            &row,
            &index_cell,
            &title,
            track.rel_path.clone(),
        );
        (row, album_label)
    }

    /// Drag a row onto another to take that row's place; a highlight line shows
    /// where it will land. Disabled while the list is filtered, because the
    /// visible rows no longer map onto the stored order.
    fn attach_reorder_dnd(self: &Rc<Self>, row: &gtk::ListBoxRow) {
        let drag = gtk::DragSource::builder()
            .actions(gdk::DragAction::MOVE)
            .build();
        {
            let row = row.clone();
            let view = Rc::downgrade(self);
            drag.connect_prepare(move |_, _, _| {
                let view = view.upgrade()?;
                if !view.query.borrow().is_empty() {
                    return None;
                }
                Some(gdk::ContentProvider::for_value(&(row.index()).to_value()))
            });
        }
        {
            let row = row.clone();
            drag.connect_drag_begin(move |source, _| {
                let paintable = gtk::WidgetPaintable::new(Some(&row));
                source.set_icon(Some(&paintable), 24, 24);
            });
        }
        row.add_controller(drag);

        let drop = gtk::DropTarget::new(i32::static_type(), gdk::DragAction::MOVE);
        {
            let list = self.list.clone();
            let row = row.clone();
            let view = Rc::downgrade(self);
            drop.connect_enter(move |_, _, _| {
                let Some(view) = view.upgrade() else {
                    return gdk::DragAction::empty();
                };
                if !view.query.borrow().is_empty() {
                    return gdk::DragAction::empty();
                }
                list.drag_highlight_row(&row);
                gdk::DragAction::MOVE
            });
        }
        {
            let list = self.list.clone();
            drop.connect_leave(move |_| list.drag_unhighlight_row());
        }
        {
            let view = Rc::downgrade(self);
            let row = row.clone();
            drop.connect_drop(move |_, value, _, _| {
                let Some(view) = view.upgrade() else {
                    return false;
                };
                view.list.drag_unhighlight_row();
                let Ok(source_index) = value.get::<i32>() else {
                    return false;
                };
                let target_index = row.index();
                if source_index == target_index || source_index < 0 || target_index < 0 {
                    return false;
                }
                let mut order: Vec<i64> = view.entries.borrow().iter().map(|(id, _)| *id).collect();
                if source_index as usize >= order.len() {
                    return false;
                }
                let moved = order.remove(source_index as usize);
                order.insert((target_index as usize).min(order.len()), moved);
                if let Err(err) = view.ui.core.db.reorder_playlist(view.playlist_id, &order) {
                    crate::logger::error("database", &format!("reorder failed: {err}"));
                    return false;
                }
                view.ui.core.hub.emit(&AppEvent::LibraryReloaded);
                true
            });
        }
        row.add_controller(drop);
    }
}

pub(crate) fn push_playlist_detail(ui: &Rc<Ui>, playlist_id: i64) {
    let name = ui
        .core
        .db
        .playlist_name(playlist_id)
        .unwrap_or_else(|| "Playlist".to_string());
    let created_at = ui
        .core
        .db
        .fetch_playlists()
        .iter()
        .find(|row| row.id == playlist_id)
        .map(|row| row.created_at)
        .unwrap_or(0);

    let dominant: Rc<RefCell<Option<(u8, u8, u8)>>> = Rc::new(RefCell::new(None));
    let backdrop = crate::ui::controls::hero_backdrop(&dominant);

    let art = PlaylistArt::new(
        ui,
        playlist_id,
        &name,
        DETAIL_COVER_SIDE,
        "cover-large",
        Vec::new(),
    );
    {
        let dominant = Rc::clone(&dominant);
        let backdrop = backdrop.downgrade();
        art.set_on_color(Rc::new(move |color| {
            *dominant.borrow_mut() = Some(color);
            if let Some(backdrop) = backdrop.upgrade() {
                backdrop.queue_draw();
            }
        }));
    }
    let cover_host = editable_cover(ui, &art, playlist_id);

    let eyebrow = gtk::Label::builder().label("Playlist").xalign(0.0).build();
    eyebrow.add_css_class("playlist-eyebrow");
    let title = gtk::Label::builder()
        .label(&name)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .build();
    title.add_css_class("title-1");
    let info = gtk::Label::builder().xalign(0.0).wrap(true).build();
    info.add_css_class("dim");
    info.add_css_class("caption");

    let play = gtk::Button::builder().label("Play").build();
    play.add_css_class("pill");
    play.add_css_class("suggested-action");
    play.set_action_name(Some("win.playlist-play"));
    play.set_action_target_value(Some(&playlist_id.to_variant()));
    let shuffle = gtk::Button::builder().label("Shuffle").build();
    shuffle.add_css_class("pill");
    shuffle.set_action_name(Some("win.playlist-shuffle"));
    shuffle.set_action_target_value(Some(&playlist_id.to_variant()));
    let more = gtk::MenuButton::builder()
        .icon_name("view-more-symbolic")
        .tooltip_text("More")
        .valign(gtk::Align::Center)
        .build();
    more.add_css_class("circular");
    {
        let ui = Rc::clone(ui);
        more.set_create_popup_func(move |button| {
            let has_cover = ui.core.db.has_playlist_cover(playlist_id);
            let downloads = context::playlist_downloads(&ui.core, playlist_id);
            button.set_menu_model(Some(&playlist_manage_menu(playlist_id, has_cover, downloads)));
        });
    }
    let buttons = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .margin_top(12)
        .build();
    buttons.append(&play);
    buttons.append(&shuffle);
    buttons.append(&more);

    let meta = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    meta.append(&eyebrow);
    meta.append(&title);
    meta.append(&info);
    meta.append(&buttons);

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(24)
        .build();
    header.add_css_class("album-detail-header");
    header.append(&cover_host);
    header.append(&meta);

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .valign(gtk::Align::Start)
        .build();
    list.add_css_class("boxed-list");

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&list, Some("list"));

    let empty = adw::StatusPage::builder()
        .icon_name("audio-x-generic-symbolic")
        .title("No Songs Yet")
        .description("Right-click any song and choose Add to Playlist.")
        .visible(false)
        .build();
    empty.add_css_class("compact");

    let hint = gtk::Label::new(Some("Drag rows to reorder · right-click to remove"));
    hint.add_css_class("dim-more");
    hint.add_css_class("caption");
    hint.set_xalign(0.0);

    let frame = {
        let art = art.clone();
        let cover_host = cover_host.clone();
        Frame::new(ui, &header, move |mode| {
            let side = match mode {
                PageMode::Wide => DETAIL_COVER_WIDE_SIDE,
                PageMode::Regular => DETAIL_COVER_SIDE,
                PageMode::Compact => DETAIL_COVER_COMPACT_SIDE,
            };
            art.set_side(side);
            cover_host.set_halign(if mode == PageMode::Compact {
                gtk::Align::Center
            } else {
                gtk::Align::Start
            });
        })
    };

    let saved = TrackLayout::from_id(&ui.core.config.borrow().detail_layout)
        .resolved_for(PageKind::Playlist);
    let slot: Rc<RefCell<Option<std::rc::Weak<DetailView>>>> = Rc::new(RefCell::new(None));
    let with_view = |slot: &Rc<RefCell<Option<std::rc::Weak<DetailView>>>>| {
        let slot = Rc::clone(slot);
        move || slot.borrow().as_ref().and_then(std::rc::Weak::upgrade)
    };
    let bar = {
        let on_layout = with_view(&slot);
        let on_filter = with_view(&slot);
        let on_jump = with_view(&slot);
        ControlBar::new(
            PageKind::Playlist,
            saved,
            move |layout| {
                if let Some(view) = on_layout() {
                    view.choose_layout(layout);
                }
            },
            move |needle| {
                if let Some(view) = on_filter() {
                    *view.query.borrow_mut() = needle.to_string();
                    view.apply_query();
                }
            },
            move || {
                if let Some(view) = on_jump() {
                    view.locate_playing();
                }
            },
        )
    };
    frame.body.append(&bar.widget);
    frame.body.append(&stack);
    frame.body.append(&empty);
    frame.body.append(&hint);

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&frame.root);

    let page = adw::NavigationPage::builder()
        .title(&name)
        .child(&overlay)
        .build();

    let view = Rc::new(DetailView {
        ui: Rc::clone(ui),
        playlist_id,
        created_at,
        page: page.downgrade(),
        scroll: frame.scroll.clone(),
        list: list.clone(),
        title,
        info,
        art,
        backdrop,
        dominant,
        play,
        shuffle,
        frame: Rc::clone(&frame),
        bar,
        stack: stack.clone(),
        layout: Cell::new(saved),
        table: RefCell::new(None),
        empty,
        hint: hint.clone(),
        entries: Rc::new(RefCell::new(Vec::new())),
        query: Rc::new(RefCell::new(String::new())),
        album_labels: RefCell::new(Vec::new()),
        show_albums: Cell::new(true),
        applied: Cell::new(0),
    });
    *slot.borrow_mut() = Some(Rc::downgrade(&view));

    {
        let view = Rc::downgrade(&view);
        list.set_filter_func(move |row| {
            let Some(view) = view.upgrade() else {
                return true;
            };
            let query = view.query.borrow();
            if query.is_empty() {
                return true;
            }
            let entries = view.entries.borrow();
            entries
                .get(row.index().max(0) as usize)
                .is_none_or(|(_, track)| matches(track, &query))
        });
    }
    {
        let ui = Rc::clone(ui);
        let view = Rc::downgrade(&view);
        list.connect_row_activated(move |_, row| {
            let Some(view) = view.upgrade() else { return };
            let tracks: Vec<Track> = view
                .entries
                .borrow()
                .iter()
                .map(|(_, track)| track.clone())
                .collect();
            let index = row.index().max(0) as usize;
            if index < tracks.len() {
                ui.core.play_tracks(tracks, index);
            }
        });
    }
    {
        let view = Rc::downgrade(&view);
        crate::ui::resize::watch_width(&stack, move |width, _| {
            if let Some(view) = view.upgrade() {
                view.set_show_albums(width >= ALBUM_COLUMN_MIN_WIDTH);
            }
        });
    }

    view.refresh();
    view.show_layout(saved);

    {
        let view = Rc::downgrade(&view);
        ui.core
            .hub
            .subscribe_widget(&frame.scroll, move |_, event| {
                if let (AppEvent::LibraryReloaded, Some(view)) = (event, view.upgrade()) {
                    view.refresh();
                }
            });
    }

    unsafe {
        page.set_data(DETAIL_KEY, Rc::clone(&view));
    }
    ui.nav.push(&page);
}

fn attach_playlist_list_menu(row: &impl IsA<gtk::Widget>, ui: &Rc<Ui>, playlist_id: i64) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let target = row.clone().upcast::<gtk::Widget>();
    let ui = Rc::clone(ui);
    gesture.connect_pressed(move |_, _, x, y| {
        let has_cover = ui.core.db.has_playlist_cover(playlist_id);
        let downloads = context::playlist_downloads(&ui.core, playlist_id);
        context::popup_menu_at(
            &target,
            &playlist_list_menu(playlist_id, has_cover, downloads),
            x,
            y,
        );
    });
    row.add_controller(gesture);
}

/// The detail page's cover with the pencil that fades in on hover or focus,
/// the playlist menu on right-click, and a drop target: an image dropped on it
/// opens the cover editor with that picture already framed.
fn editable_cover(ui: &Rc<Ui>, art: &PlaylistArt, playlist_id: i64) -> gtk::Overlay {
    let host = gtk::Overlay::new();
    host.set_child(Some(&art.widget()));
    host.set_halign(gtk::Align::Start);
    host.set_valign(gtk::Align::Start);
    host.add_css_class("album-cover-host");
    let pencil = gtk::Button::from_icon_name("document-edit-symbolic");
    pencil.add_css_class("osd");
    pencil.add_css_class("circular");
    pencil.add_css_class("artwork-pencil");
    pencil.set_halign(gtk::Align::End);
    pencil.set_valign(gtk::Align::End);
    pencil.set_tooltip_text(Some("Edit Cover"));
    pencil.update_property(&[gtk::accessible::Property::Label("Edit Cover")]);
    {
        let ui = Rc::clone(ui);
        pencil.connect_clicked(move |_| {
            artwork_editor::present_playlist(&ui, playlist_id, None);
        });
    }
    host.add_overlay(&pencil);
    attach_playlist_list_menu(&host, ui, playlist_id);
    artwork_editor::attach_playlist_image_drop(&host, ui, move || Some(playlist_id));
    host
}

fn playlist_list_menu(playlist_id: i64, has_cover: bool, downloads: Option<bool>) -> gio::Menu {
    let menu = gio::Menu::new();
    let play_section = gio::Menu::new();
    play_section.append_item(&playlist_item("Play", "win.playlist-play", playlist_id));
    play_section.append_item(&playlist_item(
        "Shuffle",
        "win.playlist-shuffle",
        playlist_id,
    ));
    menu.append_section(None, &play_section);
    menu.append_section(None, &playlist_manage_menu(playlist_id, has_cover, downloads));
    menu
}

fn playlist_manage_menu(playlist_id: i64, has_cover: bool, downloads: Option<bool>) -> gio::Menu {
    let manage_section = gio::Menu::new();
    if let Some(kept) = downloads {
        let (label, action) = context::download_entry(kept, "win.playlist-unpin", "win.playlist-pin");
        manage_section.append_item(&playlist_item(label, action, playlist_id));
    }
    manage_section.append_item(&playlist_item(
        "Rename…",
        "win.playlist-rename",
        playlist_id,
    ));
    manage_section.append_item(&playlist_item(
        "Edit Cover…",
        "win.playlist-cover-edit",
        playlist_id,
    ));
    if has_cover {
        manage_section.append_item(&playlist_item(
            "Use Automatic Cover",
            "win.playlist-cover-reset",
            playlist_id,
        ));
    }
    manage_section.append_item(&playlist_item("Delete", "win.playlist-delete", playlist_id));
    manage_section
}

fn playlist_item(label: &str, action: &str, playlist_id: i64) -> gio::MenuItem {
    let entry = gio::MenuItem::new(Some(label), None);
    entry.set_action_and_target_value(Some(action), Some(&playlist_id.to_variant()));
    entry
}

/// Resolves a playlist's stored track order against the live library, dropping
/// rows whose file has since left the library.
fn resolve_playlist_tracks(ui: &Rc<Ui>, playlist_id: i64) -> Vec<Track> {
    let library = ui.core.library.borrow().clone();
    let by_rel_path: HashMap<&str, &Track> = library
        .tracks
        .iter()
        .map(|track| (track.rel_path.as_str(), track))
        .collect();
    ui.core
        .db
        .playlist_tracks(playlist_id)
        .into_iter()
        .filter_map(|row| {
            by_rel_path
                .get(row.rel_path.as_str())
                .map(|track| (*track).clone())
        })
        .collect()
}

/// The toast for a playlist change the database refused, worded the same as
/// the Apple clients: `verb` completes "Couldn't {verb} “{name}”".
fn write_failure_message(verb: &str, name: &str) -> String {
    format!(
        "Couldn't {verb} “{name}” — the library database couldn't be written. Check free disk space and try again."
    )
}

/// Deletes a playlist, telling the listener when the database refuses.
fn delete_playlist_or_toast(ui: &Rc<Ui>, playlist_id: i64) -> bool {
    let name = ui.core.db.playlist_name(playlist_id).unwrap_or_default();
    match ui.core.db.delete_playlist(playlist_id) {
        Ok(()) => true,
        Err(err) => {
            crate::logger::error("database", &format!("delete playlist failed: {err}"));
            ui.core.toast(&write_failure_message("delete", &name));
            false
        }
    }
}

/// Why a playlist with nothing to play has nothing to play: it holds no songs,
/// or none of the songs it holds are in the library any more.
fn unplayable_playlist_message(ui: &Rc<Ui>, playlist_id: i64) -> String {
    let name = ui.core.db.playlist_name(playlist_id).unwrap_or_default();
    match ui.core.db.playlist_tracks(playlist_id).len() {
        0 => format!("“{name}” has no songs yet. Add some from a song’s menu."),
        1 => format!("The song in “{name}” is no longer in the library. Its file may have moved."),
        held => format!(
            "None of the {held} songs in “{name}” are in the library any more. Their files may have moved."
        ),
    }
}

pub fn play_playlist(ui: &Rc<Ui>, playlist_id: i64, shuffle: bool) {
    let tracks = resolve_playlist_tracks(ui, playlist_id);
    if tracks.is_empty() {
        ui.core.toast(&unplayable_playlist_message(ui, playlist_id));
        return;
    }
    if shuffle != ui.core.player.shuffle_enabled() {
        ui.core.player.toggle_shuffle();
    }
    ui.core.play_tracks(tracks, 0);
}

pub fn prompt_rename_playlist(ui: &Rc<Ui>, playlist_id: i64) {
    let current = ui.core.db.playlist_name(playlist_id).unwrap_or_default();
    let dialog = adw::AlertDialog::builder()
        .heading("Rename Playlist")
        .body("Choose a new name.")
        .close_response("cancel")
        .default_response("rename")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("rename", "Rename");
    dialog.set_response_appearance("rename", adw::ResponseAppearance::Suggested);

    let entry = gtk::Entry::builder()
        .text(&current)
        .activates_default(true)
        .build();
    dialog.set_extra_child(Some(&entry));

    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response != "rename" {
            return;
        }
        let name = entry.text().trim().to_string();
        if name.is_empty() {
            return;
        }
        match ui.core.db.rename_playlist(playlist_id, &name) {
            Ok(()) => {
                crate::logger::info(
                    "database",
                    &format!("renamed playlist {playlist_id} to '{name}'"),
                );
                ui.core.hub.emit(&AppEvent::LibraryReloaded);
            }
            Err(err) => {
                crate::logger::error("database", &format!("rename playlist failed: {err}"));
                ui.core.toast(&write_failure_message("rename", &current));
            }
        }
    });
    dialog.present(Some(&window));
}

pub fn confirm_delete_playlist(ui: &Rc<Ui>, playlist_id: i64) {
    let name = ui.core.db.playlist_name(playlist_id).unwrap_or_default();
    let dialog = adw::AlertDialog::builder()
        .heading("Delete Playlist?")
        .body(format!(
            "“{name}” will be removed. Your music files stay untouched."
        ))
        .close_response("cancel")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("delete", "Delete");
    dialog.set_response_appearance("delete", adw::ResponseAppearance::Destructive);
    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response == "delete" && delete_playlist_or_toast(&ui, playlist_id) {
            ui.core.hub.emit(&AppEvent::LibraryReloaded);
        }
    });
    dialog.present(Some(&window));
}

fn attach_playlist_row_menu(
    ui: &Rc<Ui>,
    row: &gtk::ListBoxRow,
    playlist_id: i64,
    row_id: i64,
    track: &Track,
) {
    let gesture = gtk::GestureClick::builder()
        .button(gdk::BUTTON_SECONDARY)
        .build();
    let ui = Rc::clone(ui);
    let target = row.clone();
    let rel_path = track.rel_path.clone();
    gesture.connect_pressed(move |_, _, x, y| {
        let loved = ui
            .core
            .library
            .borrow()
            .track_by_rel_path(&rel_path)
            .map(|t| t.loved)
            .unwrap_or(false);
        let menu = context::track_menu(&rel_path, loved, ui.core.has_previous_version(&rel_path));
        let remove_section = gio::Menu::new();
        let remove_item = gio::MenuItem::new(Some("Remove from Playlist"), None);
        remove_item.set_action_and_target_value(
            Some("win.playlist-remove-row"),
            Some(&(playlist_id, row_id).to_variant()),
        );
        remove_section.append_item(&remove_item);
        menu.append_section(None, &remove_section);
        context::popup_menu_at(&target, &menu, x, y);
    });
    row.add_controller(gesture);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn card(id: i64, name: &str, created_at: i64, tracks: usize, duration: f64) -> PlaylistCard {
        PlaylistCard {
            id,
            name: name.to_string(),
            created_at,
            tracks,
            duration,
            covers: Vec::new(),
        }
    }

    fn names(cards: &[PlaylistCard]) -> Vec<&str> {
        cards.iter().map(|card| card.name.as_str()).collect()
    }

    #[test]
    fn span_reads_as_people_say_it() {
        assert_eq!(span_text(10.0), "1 min");
        assert_eq!(span_text(39.0 * 60.0), "39 min");
        assert_eq!(span_text(3600.0), "1 hr");
        assert_eq!(span_text(4.0 * 3600.0 + 41.0 * 60.0), "4 hr 41 min");
        assert_eq!(span_text(60.0 * 3600.0 + 20.0 * 60.0), "60 hr");
    }

    #[test]
    fn song_counts_pluralize() {
        assert_eq!(songs_text(1), "1 song");
        assert_eq!(songs_text(0), "0 songs");
        assert_eq!(songs_text(2), "2 songs");
    }

    #[test]
    fn sorts_order_by_their_key_with_name_as_tiebreak() {
        let mut cards = vec![
            card(1, "beta", 10, 5, 100.0),
            card(2, "Alpha", 30, 5, 400.0),
            card(3, "gamma", 20, 9, 400.0),
        ];
        sort_cards(&mut cards, PlaylistSort::Name);
        assert_eq!(names(&cards), ["Alpha", "beta", "gamma"]);
        sort_cards(&mut cards, PlaylistSort::RecentlyCreated);
        assert_eq!(names(&cards), ["Alpha", "gamma", "beta"]);
        sort_cards(&mut cards, PlaylistSort::MostSongs);
        assert_eq!(names(&cards), ["gamma", "Alpha", "beta"]);
        sort_cards(&mut cards, PlaylistSort::Longest);
        assert_eq!(names(&cards), ["Alpha", "gamma", "beta"]);
    }

    #[test]
    fn sort_ids_round_trip() {
        for sort in PlaylistSort::ALL {
            assert!(PlaylistSort::from_id(sort.id()) == sort);
        }
        assert!(PlaylistSort::from_id("nonsense") == PlaylistSort::Name);
    }

    #[test]
    fn covers_take_the_first_four_distinct_albums() {
        let albums = [
            ("A", "x"),
            ("A", "x"),
            ("B", "x"),
            ("C", "y"),
            ("D", "y"),
            ("E", "z"),
        ];
        let rels: Vec<String> = (0..albums.len()).map(|i| format!("t{i}")).collect();
        let album_of: HashMap<&str, (&str, &str)> = rels
            .iter()
            .map(String::as_str)
            .zip(albums.iter().copied())
            .collect();
        let covers = cover_albums(rels.iter().map(String::as_str), &album_of);
        assert_eq!(covers.len(), 4);
        assert_eq!(covers[0], ("A".to_string(), "x".to_string()));
        assert_eq!(covers[3], ("D".to_string(), "y".to_string()));
    }
}
