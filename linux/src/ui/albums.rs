use crate::events::AppEvent;
use crate::filters::{self, LibraryFilter};
use crate::library::{Album, Library};
use crate::ui::album_layouts::AlbumBody;
use crate::ui::filter_chips::ChipBar;
use crate::ui::track_page::PageMode;
use crate::ui::{context, debut, Ui};
use adw::prelude::*;
use gtk::glib::BoxedAnyObject;
use gtk::{gdk, gio, glib, pango};
use std::cell::{Cell, RefCell};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// The edge, in pixels, of the cover bitmap an album page asks the artwork
/// cache for: enough for the largest hero without a visible upscale.
const COVER_REQUEST_PX: u32 = 320;

/// Mirrors LibraryViewModel.AlbumSort on the Apple clients — same options,
/// same semantics, same order.
#[derive(Clone, Copy, PartialEq, Eq)]
enum AlbumSort {
    Title,
    Artist,
    Year,
    RecentlyAdded,
    RecentlyPlayed,
}

impl AlbumSort {
    const ALL: [AlbumSort; 5] = [
        AlbumSort::Title,
        AlbumSort::Artist,
        AlbumSort::Year,
        AlbumSort::RecentlyAdded,
        AlbumSort::RecentlyPlayed,
    ];

    fn label(self) -> &'static str {
        match self {
            AlbumSort::Title => "Title",
            AlbumSort::Artist => "Artist",
            AlbumSort::Year => "Year",
            AlbumSort::RecentlyAdded => "Recently Added",
            AlbumSort::RecentlyPlayed => "Recently Played",
        }
    }

    fn id(self) -> &'static str {
        match self {
            AlbumSort::Title => "title",
            AlbumSort::Artist => "artist",
            AlbumSort::Year => "year",
            AlbumSort::RecentlyAdded => "recently_added",
            AlbumSort::RecentlyPlayed => "recently_played",
        }
    }

    fn from_id(id: &str) -> AlbumSort {
        Self::ALL
            .into_iter()
            .find(|sort| sort.id() == id)
            .unwrap_or(AlbumSort::Artist)
    }
}

/// What the grid keeps of an album: the few fields a tile shows, the key it is
/// found by, and where it sat in the library when the grid was built. The
/// tracks stay in the library, so building the grid copies no track and a
/// tile always opens the album as the library holds it now.
struct AlbumCard {
    key: String,
    title: String,
    artist: String,
    year: Option<String>,
    index: usize,
}

impl AlbumCard {
    fn of(album: &Album, index: usize) -> Self {
        Self {
            key: album.key(),
            title: album.title.clone(),
            artist: album.artist.clone(),
            year: album.year.clone(),
            index,
        }
    }

    fn subtitle(&self) -> String {
        match &self.year {
            Some(year) if !year.is_empty() => format!("{} · {}", self.artist, year),
            _ => self.artist.clone(),
        }
    }

    /// The album this tile stands for in `library`: the one at the remembered
    /// position when it is still the same album, otherwise found by its key.
    fn album_in<'a>(&self, library: &'a Library) -> Option<&'a Album> {
        library
            .albums
            .get(self.index)
            .filter(|album| album.title == self.title && album.artist == self.artist)
            .or_else(|| library.album_by_key(&self.key))
    }
}

type SortKey = (u8, i64, String, String);

/// Same comparisons as iOS sortedAlbums: title/artist alphabetical, year
/// ascending with unknown years last, recently added/played newest first with
/// never-played albums trailing alphabetically. Computed once per album.
fn sort_key(album: &Album, sort: AlbumSort) -> SortKey {
    let title = album.title.to_lowercase();
    match sort {
        AlbumSort::Title => (0, 0, title, album.artist.to_lowercase()),
        AlbumSort::Artist => (0, 0, album.artist.to_lowercase(), title),
        AlbumSort::Year => (
            0,
            0,
            album
                .year
                .clone()
                .filter(|year| !year.is_empty())
                .unwrap_or_else(|| "9999".to_string()),
            title,
        ),
        AlbumSort::RecentlyAdded => (0, -album.added_unix(), title, String::new()),
        AlbumSort::RecentlyPlayed => match album.last_played_unix() {
            Some(played) => (0, -played, title, String::new()),
            None => (1, 0, title, String::new()),
        },
    }
}

/// The positions of `albums` in display order for `sort`.
fn sorted_order(albums: &[Album], sort: AlbumSort) -> Vec<usize> {
    let mut order: Vec<usize> = (0..albums.len()).collect();
    order.sort_by_cached_key(|&index| sort_key(&albums[index], sort));
    order
}

/// Everything the grid's rows depend on. Two builds with the same state would
/// produce the same rows, so the second is skipped.
#[derive(Clone, Copy, PartialEq, Eq)]
struct GridState {
    content: u64,
    recency: u64,
    sort: AlbumSort,
}

impl GridState {
    fn of(signature: &filters::LibrarySignature, sort: AlbumSort) -> Self {
        let by_recency = matches!(sort, AlbumSort::RecentlyAdded | AlbumSort::RecentlyPlayed);
        Self {
            content: signature.albums,
            recency: if by_recency { signature.album_recency } else { 0 },
            sort,
        }
    }
}

/// The chip membership last computed, and what it was computed from. The
/// ranges behind Recently Added and Rediscover move with the clock, so an hour
/// is as long as a membership is trusted for.
#[derive(Default)]
struct AdmissionStamp {
    library: filters::BuiltFrom,
    chip: Cell<Option<LibraryFilter>>,
    hour: Cell<i64>,
}

impl AdmissionStamp {
    fn is_current(&self, library: &Rc<Library>, chip: LibraryFilter, now: i64) -> bool {
        self.library.is(library) && self.chip.get() == Some(chip) && self.hour.get() == now / 3600
    }

    fn record(&self, library: &Rc<Library>, chip: LibraryFilter, now: i64) {
        self.library.set(library);
        self.chip.set(Some(chip));
        self.hour.set(now / 3600);
    }
}

/// The albums page.
///
/// `debut_presenting` is why the empty state and the Debut cannot collide: the
/// once-per-library Debut owns the whole page while it runs, so the empty state
/// never gets to tell a first-time user their library is empty over the top of
/// the library being built.
pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();
    let sort_mode = Rc::new(Cell::new(AlbumSort::from_id(
        &ui.core.config.borrow().album_sort,
    )));

    let chip_filter = Rc::new(Cell::new(LibraryFilter::from_id(
        &ui.core.config.borrow().albums_filter,
    )));
    let allowed: Rc<RefCell<Option<HashSet<String>>>> = Rc::new(RefCell::new(None));

    let filter = {
        let query = Rc::clone(&ui.query);
        let allowed = Rc::clone(&allowed);
        let needle = filters::SearchNeedle::default();
        gtk::CustomFilter::new(move |obj| {
            let Some(boxed) = obj.downcast_ref::<BoxedAnyObject>() else {
                return true;
            };
            let card = boxed.borrow::<AlbumCard>();
            if allowed
                .borrow()
                .as_ref()
                .is_some_and(|keys| !keys.contains(&card.key))
            {
                return false;
            }
            let query = query.borrow();
            needle.matches(&query, &[&card.title, &card.artist])
        })
    };
    let filter_model = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
    let selection = gtk::NoSelection::new(Some(filter_model));

    let bound: Rc<RefCell<HashMap<String, glib::WeakRef<gtk::Picture>>>> =
        Rc::new(RefCell::new(HashMap::new()));

    let factory = gtk::SignalListItemFactory::new();
    let setup_ui = Rc::clone(ui);
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let cell = build_album_cell();
        {
            let item_weak = item.downgrade();
            let drop_ui = Rc::clone(&setup_ui);
            crate::ui::artwork_editor::attach_image_drop(&cell, &setup_ui, move || {
                let boxed = item_weak.upgrade()?.item().and_downcast::<BoxedAnyObject>()?;
                let library = drop_ui.core.library.borrow().clone();
                let album = boxed.borrow::<AlbumCard>().album_in(&library).cloned();
                album
            });
        }
        let gesture = gtk::GestureClick::builder()
            .button(gdk::BUTTON_SECONDARY)
            .build();
        let item_weak = item.downgrade();
        let anchor = cell.clone();
        let menu_ui = Rc::clone(&setup_ui);
        gesture.connect_pressed(move |_, _, x, y| {
            let Some(item) = item_weak.upgrade() else {
                return;
            };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let key = boxed.borrow::<AlbumCard>().key.clone();
            context::popup_menu_at(
                &anchor,
                &context::album_menu(&key, context::album_downloads(&menu_ui.core, &key)),
                x,
                y,
            );
        });
        cell.add_controller(gesture);
        item.set_child(Some(&cell));
    });
    {
        let ui = Rc::clone(ui);
        let bound = Rc::clone(&bound);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(cell) = item.child() else { return };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let card = boxed.borrow::<AlbumCard>();
            let Some(picture) = cell.first_child().and_downcast::<gtk::Picture>() else {
                return;
            };
            let Some(title) = picture.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            let Some(subtitle) = title.next_sibling().and_downcast::<gtk::Label>() else {
                return;
            };
            title.set_label(&card.title);
            title.set_tooltip_text(Some(&card.title));
            subtitle.set_label(&card.subtitle());
            picture.set_paintable(Some(&ui.core.artwork.placeholder(&card.key)));
            let expected = card.key.clone();
            let item_weak = item.downgrade();
            let weak = picture.downgrade();
            let wanted = {
                let item_weak = item_weak.clone();
                let expected = expected.clone();
                move || still_bound_album(&item_weak, &expected)
            };
            ui.core.artwork.request_while(
                wanted,
                &card.title,
                &card.artist,
                168,
                move |texture, _| {
                    if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                        if still_bound_album(&item_weak, &expected) {
                            picture.set_paintable(Some(texture));
                        }
                    }
                },
            );
            bound.borrow_mut().insert(card.key.clone(), picture.downgrade());
        });
    }
    {
        let bound = Rc::clone(&bound);
        factory.connect_unbind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            if let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() {
                bound.borrow_mut().remove(&boxed.borrow::<AlbumCard>().key);
            }
        });
    }

    let grid = gtk::GridView::builder()
        .model(&selection)
        .factory(&factory)
        .min_columns(1)
        // Low starting max so natural width stays small; grows with allocation.
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
            let library = ui.core.library.borrow().clone();
            let card = boxed.borrow::<AlbumCard>();
            if let Some(album) = card.album_in(&library) {
                push_album_detail(&ui, album);
            }
        });
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&grid)
        .build();
    ui.register_scroller(&scroll);

    let sort_labels: Vec<&str> = AlbumSort::ALL.iter().map(|s| s.label()).collect();
    let sort_dropdown = gtk::DropDown::from_strings(&sort_labels);
    sort_dropdown.set_valign(gtk::Align::Center);
    sort_dropdown.set_tooltip_text(Some("Sort albums"));
    sort_dropdown.set_selected(
        AlbumSort::ALL
            .iter()
            .position(|s| *s == sort_mode.get())
            .unwrap_or(1) as u32,
    );
    let sort_label = gtk::Label::new(Some("Sort"));
    sort_label.add_css_class("dim");
    sort_label.add_css_class("caption");
    let sort_controls = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(10)
        .margin_end(24)
        .valign(gtk::Align::Center)
        .build();
    sort_controls.append(&sort_label);
    sort_controls.append(&sort_dropdown);

    let header_row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    header_row.append(&sort_controls);
    let grid_content = gtk::Box::new(gtk::Orientation::Vertical, 0);
    grid_content.append(&header_row);
        grid_content.append(&scroll);

    let empty = build_empty_state(ui);

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&grid_content, Some("grid"));

    let debut_presenting = Rc::new(Cell::new(false));

    let rebuild: Rc<dyn Fn()> = {
        let store = store.clone();
        let stack = stack.clone();
        let scroll = scroll.clone();
        let ui = Rc::clone(ui);
        let sort_mode = Rc::clone(&sort_mode);
        let debut_presenting = Rc::clone(&debut_presenting);
        let chip_filter = Rc::clone(&chip_filter);
        let allowed = Rc::clone(&allowed);
        let filter = filter.clone();
        let applied = Cell::new(None::<GridState>);
        let admission = AdmissionStamp::default();
        Rc::new(move || {
            let library = ui.core.library.borrow().clone();
            let now = chrono::Utc::now().timestamp();
            let chip = chip_filter.get();
            if !admission.is_current(&library, chip, now) {
                let admitted = filters::albums_allowed(chip, &library.albums, now);
                if *allowed.borrow() != admitted {
                    *allowed.borrow_mut() = admitted;
                    filter.changed(gtk::FilterChange::Different);
                }
                admission.record(&library, chip, now);
            }
            let sort = sort_mode.get();
            let state = GridState::of(&filters::library_signature(&library), sort);
            if applied.replace(Some(state)) != Some(state) {
                let saved = scroll.vadjustment().value();
                let items: Vec<BoxedAnyObject> = sorted_order(&library.albums, sort)
                    .into_iter()
                    .map(|index| BoxedAnyObject::new(AlbumCard::of(&library.albums[index], index)))
                    .collect();
                store.splice(0, store.n_items(), &items);
                if saved > 0.0 {
                    let adj = scroll.vadjustment();
                    glib::idle_add_local_once(move || adj.set_value(saved));
                }
            }
            stack.set_visible_child_name(if debut_presenting.get() {
                "debut"
            } else if library.albums.is_empty() {
                "empty"
            } else {
                "grid"
            });
        })
    };
    debut::install(ui, &stack, &debut_presenting, &rebuild);
    rebuild();

    {
        let on_filter = {
            let ui = Rc::clone(ui);
            let chip_filter = Rc::clone(&chip_filter);
            let rebuild = Rc::clone(&rebuild);
            let scroll = scroll.clone();
            let sort_dropdown = sort_dropdown.clone();
            move |picked: LibraryFilter| {
                chip_filter.set(picked);
                ui.core.config.borrow_mut().albums_filter = picked.id().to_string();
                ui.core.save_config();
                scroll.vadjustment().set_value(0.0);
                let natural = match picked {
                    LibraryFilter::RecentlyAdded => Some(AlbumSort::RecentlyAdded),
                    LibraryFilter::RecentlyPlayed => Some(AlbumSort::RecentlyPlayed),
                    _ => None,
                };
                let before = sort_dropdown.selected();
                if let Some(sort) = natural {
                    let index = AlbumSort::ALL.iter().position(|s| *s == sort).unwrap_or(0);
                    sort_dropdown.set_selected(index as u32);
                }
                if sort_dropdown.selected() == before {
                    rebuild();
                }
            }
        };
        let chips = ChipBar::new(
            &LibraryFilter::ALBUMS,
            chip_filter.get(),
            filters::DEFAULT_RANGE,
            on_filter,
            |_| {},
        );
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::External)
            .vscrollbar_policy(gtk::PolicyType::Never)
            .hexpand(true)
            .margin_start(12)
            .child(&chips.widget)
            .build();
        header_row.prepend(&scroller);
    }

    {
        let ui = Rc::clone(ui);
        let sort_mode = Rc::clone(&sort_mode);
        let rebuild = Rc::clone(&rebuild);
        let scroll = scroll.clone();
        sort_dropdown.connect_selected_notify(move |dropdown| {
            let sort = AlbumSort::ALL[(dropdown.selected() as usize).min(AlbumSort::ALL.len() - 1)];
            if sort_mode.replace(sort) == sort {
                return;
            }
            ui.core.config.borrow_mut().album_sort = sort.id().to_string();
            ui.core.save_config();
            scroll.vadjustment().set_value(0.0);
            rebuild();
        });
    }

    {
        let library_dirty = Rc::new(Cell::new(false));
        let search_dirty = Rc::new(Cell::new(false));
        {
            let rebuild = Rc::clone(&rebuild);
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
        let rebuild = Rc::clone(&rebuild);
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
        let bound = Rc::clone(&bound);
        ui.core
            .hub
            .clone()
            .subscribe_widget(&stack, move |_, event| {
                if let AppEvent::AlbumEnriched { title, artist }
                | AppEvent::AlbumArtworkChanged { title, artist } = event
                {
                    if matches!(event, AppEvent::AlbumEnriched { .. }) {
                        ui.core.artwork.invalidate(title, artist);
                    }
                    let key = format!("{title}|{artist}");
                    let picture = bound.borrow().get(&key).and_then(|w| w.upgrade());
                    if let Some(picture) = picture {
                        let weak = picture.downgrade();
                        let bound = Rc::clone(&bound);
                        let placeholder = ui.core.artwork.placeholder(&key);
                        ui.core
                            .artwork
                            .request(title, artist, 168, move |texture, _| {
                                if let Some(picture) = weak.upgrade() {
                                    let still = bound
                                        .borrow()
                                        .get(&key)
                                        .and_then(|w| w.upgrade())
                                        .is_some_and(|current| current == picture);
                                    if still {
                                        match texture {
                                            Some(texture) => picture.set_paintable(Some(texture)),
                                            None => picture.set_paintable(Some(&placeholder)),
                                        }
                                    }
                                }
                            });
                    }
                }
            });
    }

    stack.upcast()
}

/// Turns the "No Music Found" page into a live scan report while a *rescan* is
/// running: the stage, what it means, and the running counts — instead of
/// telling someone their library is empty while it is still being read. A first
/// scan is the Debut's, not this one's.
fn attach_scan_status(ui: &Rc<Ui>, empty: &adw::StatusPage, actions: &gtk::Box) {
    let idle_title = empty.title().to_string();
    let idle_description = empty.description().map(|text| text.to_string());
    let idle_icon = empty.icon_name().map(|name| name.to_string());
    let actions = actions.clone();
    ui.core
        .hub
        .subscribe_widget(empty, move |empty, event| match event {
            AppEvent::ScanProgress(state) if state.phase.blocks_library() => {
                empty.set_icon_name(Some("content-loading-symbolic"));
                empty.set_title(state.phase.headline());
                let detail = state.detail();
                let description = if detail.is_empty() {
                    state.phase.explanation().to_string()
                } else {
                    format!("{}\n{detail}", state.phase.explanation())
                };
                empty.set_description(Some(&description));
                actions.set_visible(false);
            }
            AppEvent::ScanFinished { .. } => {
                empty.set_icon_name(idle_icon.as_deref());
                empty.set_title(&idle_title);
                empty.set_description(idle_description.as_deref());
                actions.set_visible(true);
            }
            _ => {}
        });
}

/// The "No Music Found" page with its way forward: pick the music folder,
/// download the sample album, and watch a scan that is already under way.
/// Home shows the same page while the library is empty.
pub(crate) fn build_empty_state(ui: &Rc<Ui>) -> adw::StatusPage {
    let empty = adw::StatusPage::builder()
        .icon_name("audio-x-generic-symbolic")
        .title("No Music Found")
        .description("Drop FLAC or MP3 files into your music folder, then rescan.\nChoose a different folder in Preferences.")
        .build();
    let empty_actions = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .halign(gtk::Align::Center)
        .build();
    let empty_button = gtk::Button::with_label("Choose Music Folder");
    empty_button.add_css_class("pill");
    empty_button.add_css_class("suggested-action");
    empty_button.set_action_name(Some("app.preferences"));
    empty_actions.append(&empty_button);
    let sample_button = gtk::Button::with_label("Download Sample Album");
    sample_button.add_css_class("pill");
    {
        let ui = Rc::clone(ui);
        sample_button.connect_clicked(move |_| crate::samples::download(&ui.core));
    }
    empty_actions.append(&sample_button);
    let sample_progress = gtk::Label::new(None);
    sample_progress.add_css_class("dim");
    sample_progress.add_css_class("caption");
    sample_progress.set_visible(false);
    empty_actions.append(&sample_progress);
    {
        let sample_button = sample_button.clone();
        let sample_progress_ref = sample_progress.clone();
        ui.core
            .hub
            .subscribe_widget(&empty_actions, move |_, event| {
                if let AppEvent::SampleDownload { text, done, failed } = event {
                    sample_progress_ref.set_visible(true);
                    sample_progress_ref.set_label(text);
                    sample_button.set_sensitive(*done);
                    if *done && !failed {
                        sample_button.set_label("Sample Album Added");
                    }
                }
            });
    }
    empty.set_child(Some(&empty_actions));
    attach_scan_status(ui, &empty, &empty_actions);
    empty
}

/// Guards an async artwork callback against GridView cell recycling: the shared
/// tile widget may have been rebound to a different album by the time a queued
/// cover decode lands, so only paint if the list item still holds this album.
fn still_bound_album(item: &glib::WeakRef<gtk::ListItem>, expected: &str) -> bool {
    item.upgrade()
        .and_then(|item| item.item())
        .and_downcast::<BoxedAnyObject>()
        .is_some_and(|boxed| boxed.borrow::<AlbumCard>().key == expected)
}

/// Empty tile shell reused by the GridView factory: cover picture, title, and
/// subtitle in fixed order (the bind step fills them and requests artwork).
fn build_album_cell() -> gtk::Box {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(140)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Start)
        .hexpand(true)
        .build();
    cell.add_css_class("album-tile");

    let picture = gtk::Picture::builder()
        .width_request(140)
        .height_request(140)
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    cell.append(&picture);

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

pub fn push_album_detail(ui: &Rc<Ui>, album: &Album) {
    let dominant: Rc<RefCell<Option<(u8, u8, u8)>>> = Rc::new(RefCell::new(None));

    let backdrop = crate::ui::controls::hero_backdrop(&dominant);

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(24)
        .build();
    header.add_css_class("album-detail-header");

    let picture = gtk::Picture::builder()
        .width_request(160)
        .height_request(160)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Start)
        .halign(gtk::Align::Start)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover-large");
    picture.add_css_class("album-detail-cover");
    picture.set_paintable(Some(&ui.core.artwork.placeholder(&album.key())));
    {
        let weak = picture.downgrade();
        let backdrop_weak = backdrop.downgrade();
        let dominant = Rc::clone(&dominant);
        ui.core
            .artwork
            .request(&album.title, &album.artist, COVER_REQUEST_PX, move |texture, color| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
                if let Some(color) = color {
                    *dominant.borrow_mut() = Some(color);
                    if let Some(backdrop) = backdrop_weak.upgrade() {
                        backdrop.queue_draw();
                    }
                }
            });
    }
    let cover_host = cover_host_with_pencil(ui, album, &picture);
    header.append(&cover_host);

    let meta = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .build();
    title.add_css_class("title-1");
    meta.append(&title);
    let artist = gtk::Label::builder()
        .label(&album.artist)
        .xalign(0.0)
        .build();
    artist.add_css_class("title-4");
    artist.add_css_class("dim");
    artist.set_halign(gtk::Align::Start);
    {
        let album_artist = album.artist.clone();
        crate::ui::controls::attach_label_nav(ui, &artist, "Go to Artist", move |ui| {
            crate::ui::goto_artist(ui, &album_artist);
        });
    }
    meta.append(&artist);

    let info_text = |year: Option<&String>, genre: Option<&String>| {
        let mut info_parts: Vec<String> = Vec::new();
        if let Some(year) = year.filter(|y| !y.is_empty()) {
            info_parts.push(year.clone());
        }
        if let Some(genre) = genre.filter(|g| !g.is_empty()) {
            info_parts.push(genre.clone());
        }
        info_parts.push(format!(
            "{} songs · {} min",
            album.tracks.len(),
            (album.total_duration() / 60.0).round() as i64
        ));
        info_parts.join(" · ")
    };
    let info = gtk::Label::builder()
        .label(info_text(album.year.as_ref(), album.genre.as_ref()))
        .xalign(0.0)
        .build();
    info.add_css_class("dim");
    info.add_css_class("caption");
    meta.append(&info);

    let playcount = gtk::Label::builder().xalign(0.0).visible(false).build();
    playcount.add_css_class("dim");
    playcount.add_css_class("caption");
    meta.append(&playcount);
    load_user_playcount(ui, album, &playcount);

    crate::enrichment::request_album(&ui.core, &album.title, &album.artist);
    {
        let ui_ref = Rc::clone(ui);
        let album_title = album.title.clone();
        let album_artist = album.artist.clone();
        let picture_weak = picture.downgrade();
        let backdrop_weak = backdrop.downgrade();
        let dominant_ref = Rc::clone(&dominant);
        let info_for = {
            let album = album.clone();
            move |year: Option<&String>, genre: Option<&String>| {
                let mut info_parts: Vec<String> = Vec::new();
                if let Some(year) = year.filter(|y| !y.is_empty()) {
                    info_parts.push(year.clone());
                }
                if let Some(genre) = genre.filter(|g| !g.is_empty()) {
                    info_parts.push(genre.clone());
                }
                info_parts.push(format!(
                    "{} songs · {} min",
                    album.tracks.len(),
                    (album.total_duration() / 60.0).round() as i64
                ));
                info_parts.join(" · ")
            }
        };
        ui.core.hub.subscribe_widget(&info, move |info, event| {
            let (AppEvent::AlbumEnriched { title, artist }
            | AppEvent::AlbumArtworkChanged { title, artist }) = event
            else {
                return;
            };
            if title != &album_title || artist != &album_artist {
                return;
            }
            if let Some(status) = ui_ref.core.db.album_info_status(title, artist) {
                info.set_label(&info_for(status.year.as_ref(), status.genre.as_ref()));
            }
            let picture_weak = picture_weak.clone();
            let backdrop_weak = backdrop_weak.clone();
            let dominant_ref = Rc::clone(&dominant_ref);
            ui_ref
                .core
                .artwork
                .request(title, artist, COVER_REQUEST_PX, move |texture, color| {
                    if let (Some(picture), Some(texture)) = (picture_weak.upgrade(), texture) {
                        picture.set_paintable(Some(texture));
                    }
                    if let Some(color) = color {
                        *dominant_ref.borrow_mut() = Some(color);
                        if let Some(backdrop) = backdrop_weak.upgrade() {
                            backdrop.queue_draw();
                        }
                    }
                });
        });
    }

    if let Some(badge_text) = album_quality_summary(album) {
        let badge = gtk::Label::new(Some(&badge_text));
        badge.add_css_class("quality-badge");
        badge.set_halign(gtk::Align::Start);
        badge.set_margin_top(4);
        meta.append(&badge);
    }

    let buttons = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .margin_top(12)
        .build();
    let play = gtk::Button::builder().label("Play").build();
    play.add_css_class("pill");
    play.add_css_class("suggested-action");
    play.set_action_name(Some("win.play-album"));
    play.set_action_target_value(Some(&album.key().to_variant()));
    let shuffle = gtk::Button::builder().label("Shuffle").build();
    shuffle.add_css_class("pill");
    shuffle.set_action_name(Some("win.shuffle-album"));
    shuffle.set_action_target_value(Some(&album.key().to_variant()));
    buttons.append(&play);
    buttons.append(&shuffle);
    meta.append(&buttons);
    header.append(&meta);

    let frame = {
        let cover_host = cover_host.clone();
        let picture = picture.clone();
        crate::ui::track_page::Frame::new(ui, &header, move |mode| {
            let side = match mode {
                PageMode::Wide => 288,
                PageMode::Regular => 200,
                PageMode::Compact => 148,
            };
            cover_host.set_size_request(side, side);
            picture.set_size_request(side, side);
            cover_host.set_halign(if mode == PageMode::Compact {
                gtk::Align::Center
            } else {
                gtk::Align::Start
            });
        })
    };
    let body = AlbumBody::new(ui, album, &frame);
    frame.body.append(&body.widget);

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&frame.root);

    let page = adw::NavigationPage::builder()
        .title(album.title.clone())
        .child(&overlay)
        .build();
    unsafe {
        page.set_data("album-body", body);
    }
    ui.nav.push(&page);
}

/// The album page's cover with the pencil that fades in on hover or focus,
/// the album menu on right-click, and a drop target: an image dropped on the
/// cover opens the artwork editor with that image already framed.
fn cover_host_with_pencil(ui: &Rc<Ui>, album: &Album, picture: &gtk::Picture) -> gtk::Overlay {
    let host = gtk::Overlay::new();
    host.set_child(Some(picture));
    host.set_halign(gtk::Align::Start);
    host.set_valign(gtk::Align::Start);
    host.add_css_class("album-cover-host");
    let pencil = gtk::Button::from_icon_name("document-edit-symbolic");
    pencil.add_css_class("osd");
    pencil.add_css_class("circular");
    pencil.add_css_class("artwork-pencil");
    pencil.set_halign(gtk::Align::End);
    pencil.set_valign(gtk::Align::End);
    pencil.set_tooltip_text(Some("Edit Artwork"));
    pencil.update_property(&[gtk::accessible::Property::Label("Edit Artwork")]);
    let key = album.key();
    {
        let ui = Rc::clone(ui);
        let key = key.clone();
        let fallback = album.clone();
        pencil.connect_clicked(move |_| {
            let library = ui.core.library.borrow().clone();
            let album = library.album_by_key(&key).cloned().unwrap_or_else(|| fallback.clone());
            crate::ui::artwork_editor::present(&ui, &album, None);
        });
    }
    host.add_overlay(&pencil);
    context::attach_album_context_menu(&host, &ui.core, key.clone());
    {
        let ui_for_drop = Rc::clone(ui);
        let fallback = album.clone();
        crate::ui::artwork_editor::attach_image_drop(&host, ui, move || {
            let library = ui_for_drop.core.library.borrow().clone();
            Some(library.album_by_key(&key).cloned().unwrap_or_else(|| fallback.clone()))
        });
    }
    host
}

/// How many times this album was played ("You've played this N times"),
/// counted from the local listening history, which the Last.fm history sync
/// keeps complete; refreshed when the sync brings in new plays.
fn load_user_playcount(ui: &Rc<Ui>, album: &Album, label: &gtk::Label) {
    show_album_plays(ui, album, label);
    let ui_ref = Rc::clone(ui);
    let album = album.clone();
    ui.core.hub.subscribe_widget(label, move |label, event| {
        if matches!(event, AppEvent::HistorySynced { .. } | AppEvent::ScrobbleRecorded) {
            show_album_plays(&ui_ref, &album, label);
        }
    });
}

fn show_album_plays(ui: &Rc<Ui>, album: &Album, label: &gtk::Label) {
    let db_path = ui.core.db_path.clone();
    let title = album.title.clone();
    let songs: Vec<(String, String)> = album
        .tracks
        .iter()
        .map(|track| (track.title.clone(), track.artist.clone()))
        .collect();
    let (tx, rx) = async_channel::bounded::<i64>(1);
    std::thread::Builder::new()
        .name("flaccy-album-plays".into())
        .spawn(move || {
            let count = crate::db::Db::open(&db_path)
                .map(|db| db.album_listen_count(&title, &songs))
                .unwrap_or(0);
            let _ = tx.send_blocking(count);
        })
        .ok();
    let weak = label.downgrade();
    gtk::glib::spawn_future_local(async move {
        let Ok(count) = rx.recv().await else {
            return;
        };
        if let Some(label) = weak.upgrade() {
            label.set_label(&format!(
                "You've played this {count} time{}",
                if count == 1 { "" } else { "s" }
            ));
            label.set_visible(count > 0);
        }
    });
}

pub(crate) fn album_quality_summary(album: &Album) -> Option<String> {
    let badges: Vec<String> = album
        .tracks
        .iter()
        .filter_map(|t| t.quality_badge())
        .collect();
    if badges.is_empty() {
        return None;
    }
    let first = &badges[0];
    if badges.iter().all(|b| b == first) {
        Some(first.clone())
    } else {
        Some("Mixed Quality".to_string())
    }
}

#[cfg(test)]
mod sort_tests {
    use super::*;
    use crate::library::TrackRow;

    fn album(title: &str, year: Option<&str>, added: i64, played: Option<i64>) -> Album {
        Album {
            title: title.to_string(),
            artist: "Artist".to_string(),
            year: year.map(String::from),
            genre: None,
            tracks: vec![TrackRow {
                id: 0,
                rel_path: format!("{title}/01.flac"),
                title: "Song".to_string(),
                artist: "Artist".to_string(),
                album: title.to_string(),
                album_artist: None,
                track_number: 1,
                duration: 100.0,
                codec: None,
                bit_depth: None,
                sample_rate: None,
                channels: None,
                loved: false,
                play_count: 0,
                date_added: added,
                last_played: played,
                revision: 1,
                revised_at: None,
                file_modified_ms: None,
                disc_number: None,
            }],
        }
    }

    fn sorted_titles(albums: &[Album], sort: AlbumSort) -> Vec<&str> {
        sorted_order(albums, sort)
            .into_iter()
            .map(|index| albums[index].title.as_str())
            .collect()
    }

    #[test]
    fn recently_added_orders_newest_first() {
        let albums = vec![
            album("Old", None, 100, None),
            album("New", None, 300, None),
            album("Mid", None, 200, None),
        ];
        assert_eq!(
            sorted_titles(&albums, AlbumSort::RecentlyAdded),
            vec!["New", "Mid", "Old"]
        );
    }

    #[test]
    fn year_sorts_ascending_with_unknown_last() {
        let albums = vec![
            album("NoYear", None, 0, None),
            album("Nineties", Some("1994"), 0, None),
            album("Modern", Some("2020"), 0, None),
        ];
        assert_eq!(
            sorted_titles(&albums, AlbumSort::Year),
            vec!["Nineties", "Modern", "NoYear"]
        );
    }

    #[test]
    fn recently_played_puts_never_played_last_alphabetically() {
        let albums = vec![
            album("Zebra Unplayed", None, 0, None),
            album("Alpha Unplayed", None, 0, None),
            album("Played Older", None, 0, Some(50)),
            album("Played Newer", None, 0, Some(90)),
        ];
        assert_eq!(
            sorted_titles(&albums, AlbumSort::RecentlyPlayed),
            vec![
                "Played Newer",
                "Played Older",
                "Alpha Unplayed",
                "Zebra Unplayed"
            ]
        );
    }

    #[test]
    fn title_and_artist_sorts_ignore_case_and_break_ties_on_the_other_field() {
        let mut lower = album("alpha", None, 0, None);
        lower.artist = "zed".to_string();
        let mut upper = album("Alpha", None, 0, None);
        upper.artist = "Abe".to_string();
        let other = album("Beta", None, 0, None);
        let albums = vec![lower, other, upper];
        assert_eq!(
            sorted_titles(&albums, AlbumSort::Title),
            vec!["Alpha", "alpha", "Beta"]
        );
        let by_artist: Vec<&str> = sorted_order(&albums, AlbumSort::Artist)
            .into_iter()
            .map(|index| albums[index].artist.as_str())
            .collect();
        assert_eq!(by_artist, vec!["Abe", "Artist", "zed"]);
    }

    #[test]
    fn equal_keys_keep_library_order() {
        let albums = vec![
            album("Same", None, 5, None),
            album("same", None, 5, None),
            album("SAME", None, 5, None),
        ];
        assert_eq!(sorted_order(&albums, AlbumSort::RecentlyAdded), vec![0, 1, 2]);
    }

    #[test]
    fn a_card_finds_its_album_by_position_then_by_key() {
        let albums = vec![
            album("One", None, 0, None),
            album("Two", None, 0, None),
            album("Three", None, 0, None),
        ];
        let card = AlbumCard::of(&albums[1], 1);
        let library = Library {
            tracks: Vec::new(),
            albums: albums.clone(),
            artists: Vec::new(),
            index: Default::default(),
        };
        assert_eq!(card.album_in(&library).map(|a| a.title.as_str()), Some("Two"));
        let reordered = Library {
            tracks: Vec::new(),
            albums: vec![albums[2].clone(), albums[0].clone(), albums[1].clone()],
            artists: Vec::new(),
            index: Default::default(),
        };
        assert_eq!(
            card.album_in(&reordered).map(|a| a.title.as_str()),
            Some("Two")
        );
        let gone = Library {
            tracks: Vec::new(),
            albums: vec![albums[0].clone()],
            artists: Vec::new(),
            index: Default::default(),
        };
        assert!(card.album_in(&gone).is_none());
    }

    #[test]
    fn grid_state_ignores_recency_unless_the_sort_reads_it() {
        let signature = |recency: u64| filters::LibrarySignature {
            track_rows: Vec::new(),
            albums: 7,
            album_recency: recency,
            artists: 0,
        };
        assert!(GridState::of(&signature(1), AlbumSort::Title) == GridState::of(&signature(2), AlbumSort::Title));
        assert!(
            GridState::of(&signature(1), AlbumSort::RecentlyPlayed)
                != GridState::of(&signature(2), AlbumSort::RecentlyPlayed)
        );
        assert!(GridState::of(&signature(1), AlbumSort::Title) != GridState::of(&signature(1), AlbumSort::Artist));
    }

    #[test]
    fn sort_ids_round_trip() {
        for sort in AlbumSort::ALL {
            assert!(AlbumSort::from_id(sort.id()) == sort);
        }
        assert!(AlbumSort::from_id("garbage") == AlbumSort::Artist);
    }
}
