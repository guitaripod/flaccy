use crate::db::Db;
use crate::events::AppEvent;
use crate::filters::{self, LibraryFilter};
use crate::library::{format_last_played, format_time, format_total_duration, Track};
use crate::recap::Period;
use crate::ui::filter_chips::{ChipBar, SourceBar};
use crate::ui::{context, controls, Ui};
use adw::prelude::*;
use flaccy_shared::load_progress::group_digits;
use gtk::glib;
use gtk::glib::BoxedAnyObject;
use gtk::pango;
use gtk::{gdk, gio};
use std::cell::{Cell, RefCell};
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

pub(crate) type MenuHandler = dyn Fn(&Track, &gtk::Widget, f64, f64);

/// Drop secondary columns as the songs table loses width so Title (and
/// eventually Artist) stay readable instead of crushing into ellipsis soup.
fn install_songs_column_adaptation(
    column_view: &gtk::ColumnView,
    album: &gtk::ColumnViewColumn,
    plays: &gtk::ColumnViewColumn,
    quality: &gtk::ColumnViewColumn,
    artist: &gtk::ColumnViewColumn,
    duration: &gtk::ColumnViewColumn,
    added: &gtk::ColumnViewColumn,
    last_played: &gtk::ColumnViewColumn,
) {
    let album = album.clone();
    let plays = plays.clone();
    let quality = quality.clone();
    let artist = artist.clone();
    let duration = duration.clone();
    let added = added.clone();
    let last_played = last_played.clone();
    crate::ui::resize::watch_width(column_view, move |width, _| {
        let wide = width >= 900;
        let medium = width >= 640;
        let compact = width >= 420;
        quality.set_visible(wide);
        plays.set_visible(wide);
        added.set_visible(wide);
        last_played.set_visible(wide);
        album.set_visible(medium);
        duration.set_visible(compact);
        artist.set_visible(compact);
    });
}

/// What the Songs chips currently admit, and what the Plays column counts.
/// Most Played swaps the Plays column to plays inside the chosen time range and
/// ranks by the shared rule; every other chip counts plays over all time.
struct Mode {
    filter: Cell<LibraryFilter>,
    range: Cell<Period>,
    allowed: RefCell<Option<HashSet<String>>>,
    source: RefCell<String>,
    range_plays: RefCell<HashMap<String, i64>>,
    rank: RefCell<HashMap<i64, usize>>,
}

impl Mode {
    fn admits(&self, track: &Track) -> bool {
        filters::source_admits(&self.source.borrow(), &track.rel_path) && self.admits_filter(track)
    }

    fn admits_filter(&self, track: &Track) -> bool {
        match self.filter.get() {
            LibraryFilter::All => true,
            LibraryFilter::MostPlayed => self.range_plays.borrow().contains_key(&track.rel_path),
            LibraryFilter::Favorites => track.loved,
            LibraryFilter::Lossless => filters::is_lossless(track),
            LibraryFilter::RecentlyAdded
            | LibraryFilter::RecentlyPlayed
            | LibraryFilter::Rediscover => self
                .allowed
                .borrow()
                .as_ref()
                .map_or(true, |set| set.contains(&track.rel_path)),
        }
    }

    fn counts_in_range(&self) -> bool {
        self.filter.get() == LibraryFilter::MostPlayed
    }

    fn plays(&self, track: &Track) -> i64 {
        if self.counts_in_range() {
            self.range_plays
                .borrow()
                .get(&track.rel_path)
                .copied()
                .unwrap_or(0)
        } else {
            track.play_count
        }
    }

    /// Ascending means fewer plays first. In a range that is the reverse of the
    /// shared ranking, so the descending sort a chip applies lists the most
    /// played first with the rule's own tie-breaks.
    fn plays_order(&self, a: &Track, b: &Track) -> Ordering {
        if self.counts_in_range() {
            let rank = self.rank.borrow();
            let position = |track: &Track| rank.get(&track.id).copied().unwrap_or(usize::MAX);
            return position(b).cmp(&position(a));
        }
        a.play_count
            .cmp(&b.play_count)
            .then_with(|| a.last_played.cmp(&b.last_played))
    }

    fn plays_header(&self) -> String {
        if self.counts_in_range() {
            format!("Plays · {}", self.range.get().label())
        } else {
            "Plays".to_string()
        }
    }
}

struct Columns {
    title: gtk::ColumnViewColumn,
    plays: gtk::ColumnViewColumn,
    last_played: gtk::ColumnViewColumn,
    added: gtk::ColumnViewColumn,
}

impl Columns {
    fn all(&self) -> [&gtk::ColumnViewColumn; 4] {
        [&self.title, &self.plays, &self.last_played, &self.added]
    }
}

struct View {
    ui: Rc<Ui>,
    mode: Rc<Mode>,
    store: gio::ListStore,
    filter: gtk::CustomFilter,
    column_view: gtk::ColumnView,
    selection: gtk::MultiSelection,
    scroll: gtk::ScrolledWindow,
    stack: gtk::Stack,
    status: gtk::Label,
    columns: Columns,
    chips: RefCell<Option<Rc<ChipBar>>>,
    sources: RefCell<Option<Rc<SourceBar>>>,
    actions: RefCell<Vec<gtk::Button>>,
    epoch: Cell<u64>,
    applied_rows: RefCell<Vec<u64>>,
    total_seconds: Cell<f64>,
    pending: Pending,
}

/// What happened to the table while its page was off screen. Nothing is done
/// about it until the page is shown, or until something reads the table.
#[derive(Default)]
struct Pending {
    library: Cell<bool>,
    counts: Cell<bool>,
    search: Cell<bool>,
}

/// How a library change reached the rows of the table.
#[derive(PartialEq, Eq, Clone, Copy)]
enum RowChange {
    Untouched,
    Patched,
    Replaced,
}

const PATCH_ROW_LIMIT: usize = 128;

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let store = gio::ListStore::new::<BoxedAnyObject>();
    let (saved_filter, saved_range, saved_sort, saved_descending, saved_source) = {
        let config = ui.core.config.borrow();
        (
            LibraryFilter::from_id(&config.songs_filter),
            filters::range_from_id(&config.songs_range),
            config.songs_sort.clone(),
            config.songs_sort_descending,
            config.songs_source.clone(),
        )
    };
    let mode = Rc::new(Mode {
        filter: Cell::new(LibraryFilter::All),
        range: Cell::new(saved_range),
        allowed: RefCell::new(None),
        source: RefCell::new(saved_source),
        range_plays: RefCell::new(HashMap::new()),
        rank: RefCell::new(HashMap::new()),
    });

    let filter = {
        let query = Rc::clone(&ui.query);
        let mode = Rc::clone(&mode);
        let needle = filters::SearchNeedle::default();
        gtk::CustomFilter::new(move |obj| {
            let Some(boxed) = obj.downcast_ref::<BoxedAnyObject>() else {
                return true;
            };
            let track = boxed.borrow::<Track>();
            if !mode.admits(&track) {
                return false;
            }
            let query = query.borrow();
            needle.matches(&query, &[&track.title, &track.artist, &track.album])
        })
    };
    let filter_model = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));

    let column_view = gtk::ColumnView::builder()
        .reorderable(true)
        .show_row_separators(false)
        .build();
    column_view.add_css_class("data-table");

    let sort_model = gtk::SortListModel::new(Some(filter_model), column_view.sorter());
    let selection = gtk::MultiSelection::new(Some(sort_model));
    column_view.set_model(Some(&selection));

    let menu_handler: Rc<MenuHandler> = {
        let ui = Rc::clone(ui);
        let selection = selection.clone();
        Rc::new(move |track, anchor, x, y| {
            let selected = selected_tracks(&selection);
            let clicked_in_selection = selected.iter().any(|t| t.rel_path == track.rel_path);
            if selected.len() >= 2 && clicked_in_selection {
                let local: Vec<Track> = selected
                    .iter()
                    .filter(|track| !crate::remote::is_remote(&track.rel_path))
                    .cloned()
                    .collect();
                let has_duplicates =
                    !crate::hygiene::find_duplicate_groups(&local, &ui.core.music_root())
                        .is_empty();
                let downloads = crate::remote::downloads_state(
                    selected.iter().map(|track| track.rel_path.as_str()),
                );
                context::popup_menu_at(
                    anchor,
                    &bulk_menu(selected.len(), has_duplicates, downloads),
                    x,
                    y,
                );
            } else {
                let menu = context::track_menu(
                    &track.rel_path,
                    track.loved,
                    ui.core.has_previous_version(&track.rel_path),
                );
                context::popup_menu_at(anchor, &menu, x, y);
            }
        })
    };
    install_bulk_actions(ui, &selection);

    let track_column = track_number_column(ui);
    column_view.append_column(&track_column);
    let title_column = title_column(
        ui,
        true,
        |track| track.title.clone(),
        |a, b| filters::cmp_ignore_case(&a.title, &b.title),
        Some(Rc::clone(&menu_handler)),
    );
    column_view.append_column(&title_column);
    let artist_column = string_column(
        ui,
        "Artist",
        true,
        |track| track.artist.clone(),
        |a, b| filters::cmp_ignore_case(&a.artist, &b.artist),
        None,
    );
    column_view.append_column(&artist_column);
    let album_column = string_column(
        ui,
        "Album",
        true,
        |track| track.album.clone(),
        |a, b| filters::cmp_ignore_case(&a.album, &b.album),
        None,
    );
    column_view.append_column(&album_column);
    let duration_column = string_column(
        ui,
        "Duration",
        false,
        |track| format_time(track.duration),
        |a, b| {
            a.duration
                .partial_cmp(&b.duration)
                .unwrap_or(Ordering::Equal)
        },
        None,
    );
    column_view.append_column(&duration_column);
    let plays_column = {
        let text_mode = Rc::clone(&mode);
        let order_mode = Rc::clone(&mode);
        string_column(
            ui,
            "Plays",
            false,
            move |track| {
                let plays = text_mode.plays(track);
                if plays > 0 {
                    plays.to_string()
                } else {
                    String::new()
                }
            },
            move |a, b| order_mode.plays_order(a, b),
            None,
        )
    };
    column_view.append_column(&plays_column);
    let last_played_column = string_column(
        ui,
        "Last Played",
        false,
        |track| {
            track
                .last_played
                .map(|at| format_last_played(at, chrono::Utc::now().timestamp()))
                .unwrap_or_default()
        },
        |a, b| a.last_played.cmp(&b.last_played),
        None,
    );
    column_view.append_column(&last_played_column);
    let added_column = string_column(
        ui,
        "Added",
        false,
        |track| format_date_added(track.date_added),
        |a, b| a.date_added.cmp(&b.date_added),
        None,
    );
    column_view.append_column(&added_column);
    let quality_column = string_column(
        ui,
        "Quality",
        false,
        |track| track.quality_badge().unwrap_or_default(),
        |a, b| {
            let score = |t: &Track| {
                (t.bit_depth.unwrap_or(0) as i64) * 1_000_000 + t.sample_rate.unwrap_or(0) as i64
            };
            score(a).cmp(&score(b))
        },
        None,
    );
    column_view.append_column(&quality_column);

    let columns = Columns {
        title: title_column.clone(),
        plays: plays_column.clone(),
        last_played: last_played_column.clone(),
        added: added_column.clone(),
    };
    let sort_column = columns
        .all()
        .into_iter()
        .chain([
            &artist_column,
            &album_column,
            &duration_column,
            &quality_column,
        ])
        .find(|column| column_key(column) == saved_sort)
        .unwrap_or(&title_column)
        .clone();
    column_view.sort_by_column(
        Some(&sort_column),
        if saved_descending {
            gtk::SortType::Descending
        } else {
            gtk::SortType::Ascending
        },
    );
    install_songs_column_adaptation(
        &column_view,
        &album_column,
        &plays_column,
        &quality_column,
        &artist_column,
        &duration_column,
        &added_column,
        &last_played_column,
    );

    {
        let ui = Rc::clone(ui);
        column_view.connect_activate(move |view, position| {
            let Some(model) = view.model() else { return };
            let tracks = tracks_of(&model);
            if (position as usize) < tracks.len() {
                ui.core.play_tracks(tracks, position as usize);
            }
        });
    }

    let scroll = gtk::ScrolledWindow::builder()
        .vexpand(true)
        .child(&column_view)
        .build();
    ui.register_scroller(&scroll);

    let status = gtk::Label::builder()
        .xalign(0.0)
        .margin_start(16)
        .margin_end(16)
        .margin_top(6)
        .margin_bottom(8)
        .build();
    status.add_css_class("dim");
    status.add_css_class("caption");

    let list_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
    list_box.append(&scroll);
    list_box.append(&status);

    let empty = adw::StatusPage::builder()
        .icon_name("audio-x-generic-symbolic")
        .title("No Songs")
        .description("Flaccy found no audio files in your music folder. Add music there, then choose Rescan Library in Preferences.")
        .build();

    let stack = gtk::Stack::new();
    stack.set_hhomogeneous(false);
    stack.set_vhomogeneous(false);
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&list_box, Some("list"));

    let view = Rc::new(View {
        ui: Rc::clone(ui),
        mode,
        store,
        filter,
        column_view: column_view.clone(),
        selection: selection.clone(),
        scroll: scroll.clone(),
        stack: stack.clone(),
        status,
        columns,
        chips: RefCell::new(None),
        sources: RefCell::new(None),
        actions: RefCell::new(Vec::new()),
        epoch: Cell::new(0),
        applied_rows: RefCell::new(Vec::new()),
        total_seconds: Cell::new(0.0),
        pending: Pending::default(),
    });

    let header = view.header_row(saved_filter);
    list_box.prepend(&header);
    view.install_scroll_reset_and_sort_memory();
    {
        let view = Rc::clone(&view);
        selection.connect_items_changed(move |_, _, _, _| view.update_status(true));
    }
    {
        let view = Rc::clone(&view);
        selection.connect_selection_changed(move |_, _, _| view.update_status(false));
    }

    view.sync_library(true);
    view.choose(saved_filter, false);

    {
        let view = Rc::clone(&view);
        ui.core
            .hub
            .subscribe_widget(&stack, move |_, event| match event {
                AppEvent::LibraryReloaded => view.on_library_changed(true),
                AppEvent::LovedChanged { .. } => view.on_library_changed(false),
                AppEvent::NaturalEnd(_) => view.on_play_ended(),
                AppEvent::RemoteChanged => view.refresh_sources(),
                AppEvent::SearchChanged(_) => view.on_search_changed(),
                AppEvent::LocateCurrent => view.locate_current(),
                _ => {}
            });
    }
    {
        let view = Rc::clone(&view);
        stack.connect_map(move |_| view.flush_pending());
    }

    stack.upcast()
}

fn column_key(column: &gtk::ColumnViewColumn) -> String {
    column.id().map(|id| id.to_string()).unwrap_or_default()
}

fn tracks_of(model: &gtk::SelectionModel) -> Vec<Track> {
    (0..model.n_items())
        .filter_map(|i| {
            model
                .item(i)
                .and_then(|o| o.downcast::<BoxedAnyObject>().ok())
                .map(|b| b.borrow::<Track>().clone())
        })
        .collect()
}

impl View {
    /// The chip row with the Play, Shuffle and Save as Playlist buttons at its
    /// end: all three act on the list exactly as it is filtered and sorted.
    fn header_row(self: &Rc<Self>, selected: LibraryFilter) -> gtk::Widget {
        let chips = ChipBar::new(
            &LibraryFilter::SONGS,
            selected,
            self.mode.range.get(),
            {
                let view = Rc::clone(self);
                move |filter| view.choose(filter, true)
            },
            {
                let view = Rc::clone(self);
                move |range| view.set_range(range)
            },
        );
        let scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::External)
            .vscrollbar_policy(gtk::PolicyType::Never)
            .hexpand(true)
            .child(&chips.widget)
            .build();
        let sources = SourceBar::new({
            let view = Rc::downgrade(self);
            move |source| {
                if let Some(view) = view.upgrade() {
                    view.choose_source(source);
                }
            }
        });
        *self.chips.borrow_mut() = Some(chips);
        *self.sources.borrow_mut() = Some(sources);
        self.refresh_sources();

        let actions = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(2)
            .margin_top(10)
            .margin_bottom(4)
            .margin_end(12)
            .build();
        let specs: [(&str, &str, fn(&Rc<View>)); 3] = [
            (
                "media-playback-start-symbolic",
                "Play this list",
                View::play_list,
            ),
            (
                "media-playlist-shuffle-symbolic",
                "Shuffle this list",
                View::shuffle_list,
            ),
            (
                "list-add-symbolic",
                "Save this list as a playlist…",
                View::save_list,
            ),
        ];
        for (icon, tooltip, handler) in specs {
            let button = gtk::Button::from_icon_name(icon);
            button.add_css_class("flat");
            button.add_css_class("circular");
            button.set_tooltip_text(Some(tooltip));
            let view = Rc::clone(self);
            button.connect_clicked(move |_| handler(&view));
            actions.append(&button);
            self.actions.borrow_mut().push(button);
        }

        let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        row.append(&scroller);
        row.append(&actions);
        let header = gtk::Box::new(gtk::Orientation::Vertical, 0);
        header.append(&row);
        header.append(&self.source_row());
        header.upcast()
    }

    /// The source chips on a row of their own under the filter chips, which
    /// already fill a default-width window. The row only exists while a server
    /// is saved.
    fn source_row(&self) -> gtk::Widget {
        let sources = self.sources.borrow().clone().expect("the source bar is built first");
        sources.widget.set_margin_start(12);
        sources.widget.set_margin_end(12);
        sources.widget.set_margin_bottom(4);
        let wrapper = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::External)
            .vscrollbar_policy(gtk::PolicyType::Never)
            .child(&sources.widget)
            .visible(sources.widget.is_visible())
            .build();
        sources
            .widget
            .bind_property("visible", &wrapper, "visible")
            .sync_create()
            .build();
        wrapper.upcast()
    }

    fn visible_tracks(self: &Rc<Self>) -> Vec<Track> {
        self.flush_pending();
        tracks_of(self.selection.upcast_ref())
    }

    fn play_list(self: &Rc<Self>) {
        self.ui
            .core
            .play_list(self.visible_tracks(), false, self.mode.filter.get().label());
    }

    fn shuffle_list(self: &Rc<Self>) {
        self.ui
            .core
            .play_list(self.visible_tracks(), true, self.mode.filter.get().label());
    }

    /// Why Save as Playlist has no songs to save: the search, the filter chip
    /// or an empty library, whichever is actually responsible.
    fn empty_list_message(&self) -> String {
        let query = self.ui.query.borrow().clone();
        let filter = self.mode.filter.get();
        if !query.is_empty() {
            format!("Nothing to save — no song matches the search “{query}”. Clear the search and try again.")
        } else if filter != LibraryFilter::All {
            format!(
                "Nothing to save — no songs fit the {} filter. Choose All to include everything.",
                filter.label()
            )
        } else {
            "Nothing to save — the library has no songs yet.".to_string()
        }
    }

    fn save_list(self: &Rc<Self>) {
        let tracks = self.visible_tracks();
        if tracks.is_empty() {
            self.ui.core.toast(&self.empty_list_message());
            return;
        }
        let name = match self.mode.filter.get() {
            LibraryFilter::MostPlayed => {
                format!("Most Played · {}", self.mode.range.get().label())
            }
            LibraryFilter::All => "All Songs".to_string(),
            filter => filter.label().to_string(),
        };
        crate::ui::playlists::prompt_save_tracks(
            &self.ui,
            &name,
            tracks.into_iter().map(|t| t.rel_path).collect(),
        );
    }

    /// Rebuilds the source chips from the saved servers, and widens the list
    /// to every source when the one it was narrowed to is gone.
    fn refresh_sources(self: &Rc<Self>) {
        let Some(sources) = self.sources.borrow().clone() else {
            return;
        };
        let servers: Vec<(String, String)> = crate::remote::handle()
            .map(|remote| {
                remote
                    .servers()
                    .into_iter()
                    .map(|server| (server.id, server.name))
                    .collect()
            })
            .unwrap_or_default();
        let wanted = self.mode.source.borrow().clone();
        let lit = sources.refresh(&servers, &wanted);
        if lit != wanted {
            self.choose_source(lit);
        }
    }

    /// Narrows the list to one source, or to all of them for an empty id.
    fn choose_source(self: &Rc<Self>, source: String) {
        {
            let mut config = self.ui.core.config.borrow_mut();
            if config.songs_source != source {
                config.songs_source = source.clone();
                drop(config);
                self.ui.core.save_config();
            }
        }
        *self.mode.source.borrow_mut() = source;
        self.filter.changed(gtk::FilterChange::Different);
        self.update_status(true);
    }

    /// Turns a chip on. `natural_sort` is true for a click: the chip then also
    /// orders the list the way it reads (newest first, most played first), once,
    /// and the person is free to re-sort. A restored chip keeps the saved sort.
    fn choose(self: &Rc<Self>, filter: LibraryFilter, natural_sort: bool) {
        {
            let mut config = self.ui.core.config.borrow_mut();
            if config.songs_filter == filter.id() {
                drop(config);
            } else {
                config.songs_filter = filter.id().to_string();
                drop(config);
                self.ui.core.save_config();
            }
        }
        self.epoch.set(self.epoch.get() + 1);
        if filter == LibraryFilter::MostPlayed {
            self.fetch_most_played(natural_sort);
            return;
        }
        let library = self.ui.core.library.borrow().clone();
        let now = chrono::Utc::now().timestamp();
        *self.mode.allowed.borrow_mut() =
            filters::songs_allowed(filter, &library.tracks, &library.albums, now);
        self.mode.filter.set(filter);
        self.finish(natural_sort);
    }

    fn set_range(self: &Rc<Self>, range: Period) {
        self.mode.range.set(range);
        {
            let mut config = self.ui.core.config.borrow_mut();
            config.songs_range = range.api_value().to_string();
            config.songs_filter = LibraryFilter::MostPlayed.id().to_string();
        }
        self.ui.core.save_config();
        self.epoch.set(self.epoch.get() + 1);
        self.fetch_most_played(true);
    }

    /// Counts plays inside the range on a worker thread (a grouped query over
    /// the scrobble table), then switches the list over in one step so the
    /// previous list stays up until the new one is ready.
    fn fetch_most_played(self: &Rc<Self>, natural_sort: bool) {
        let epoch = self.epoch.get();
        let range = self.mode.range.get();
        let db_path = self.ui.core.db_path.clone();
        let (tx, rx) = async_channel::bounded::<HashMap<String, i64>>(1);
        std::thread::Builder::new()
            .name("flaccy-most-played".into())
            .spawn(move || {
                let now = chrono::Utc::now().timestamp();
                let counts = Db::open(&db_path)
                    .map(|db| db.scrobble_counts_since(range.cutoff_unix(now)))
                    .unwrap_or_default();
                let _ = tx.send_blocking(counts);
            })
            .ok();
        let view = Rc::clone(self);
        glib::spawn_future_local(async move {
            let Ok(counts) = rx.recv().await else { return };
            if view.epoch.get() != epoch {
                return;
            }
            let library = view.ui.core.library.borrow().clone();
            let (plays, rank) = filters::most_played_ranking(&library.tracks, &counts);
            *view.mode.rank.borrow_mut() = rank_by_track_id(&library.tracks, &rank);
            *view.mode.range_plays.borrow_mut() = plays;
            view.mode.filter.set(LibraryFilter::MostPlayed);
            view.finish(natural_sort);
        });
    }

    /// Everything that follows a change of what the list admits or what Plays
    /// counts: header, order, rows, scroll, summary and the highlighted chip.
    fn finish(self: &Rc<Self>, natural_sort: bool) {
        let filter = self.mode.filter.get();
        self.columns
            .plays
            .set_title(Some(&self.mode.plays_header()));
        if let Some(chips) = self.chips.borrow().as_ref() {
            chips.set_range(self.mode.range.get());
            chips.set_selected(filter);
        }
        if natural_sort {
            if let Some((column, order)) = self.natural_sort(filter) {
                self.column_view.sort_by_column(Some(column), order);
            }
        }
        if let Some(sorter) = self.columns.plays.sorter() {
            sorter.changed(gtk::SorterChange::Different);
        }
        self.filter.changed(gtk::FilterChange::Different);
        self.rebind_rows();
        if natural_sort {
            self.scroll_to_top();
        }
        self.update_status(true);
    }

    fn natural_sort(
        &self,
        filter: LibraryFilter,
    ) -> Option<(&gtk::ColumnViewColumn, gtk::SortType)> {
        match filter {
            LibraryFilter::MostPlayed | LibraryFilter::Rediscover => {
                Some((&self.columns.plays, gtk::SortType::Descending))
            }
            LibraryFilter::RecentlyAdded => Some((&self.columns.added, gtk::SortType::Descending)),
            LibraryFilter::RecentlyPlayed => {
                Some((&self.columns.last_played, gtk::SortType::Descending))
            }
            LibraryFilter::All | LibraryFilter::Favorites | LibraryFilter::Lossless => None,
        }
    }

    /// Tells every visible cell to re-read its text, so the Plays column shows
    /// the count the active chip means.
    fn rebind_rows(&self) {
        self.ui.core.hub.emit(&AppEvent::SongCellsChanged);
    }

    fn scroll_to_top(&self) {
        let vadj = self.scroll.vadjustment();
        gtk::glib::idle_add_local_once(move || vadj.set_value(vadj.lower()));
    }

    /// Reloads the library into the table when something it shows changed, then
    /// brings the chip's membership up to date with it. `refresh_counts` is
    /// whether a Most Played range must be counted again even when no row
    /// changed, because the plays behind it may have.
    fn sync_library(self: &Rc<Self>, refresh_counts: bool) {
        let library = self.ui.core.library.borrow().clone();
        let signature = filters::library_signature(&library);
        let change = self.apply_rows(&library, &signature);
        self.stack
            .set_visible_child_name(if library.tracks.is_empty() {
                "empty"
            } else {
                "list"
            });
        if change != RowChange::Untouched || (refresh_counts && self.mode.counts_in_range()) {
            self.refresh_membership(&library, change);
        }
    }

    /// Brings the table's rows in line with the library. A handful of rows that
    /// differ (a play counted, a song loved) are swapped one by one, which keeps
    /// the selection and the scroll position; anything bigger replaces the lot.
    fn apply_rows(
        &self,
        library: &crate::library::Library,
        signature: &filters::LibrarySignature,
    ) -> RowChange {
        let mut applied = self.applied_rows.borrow_mut();
        if *applied == signature.track_rows {
            return RowChange::Untouched;
        }
        let patch = differing_rows(&applied, &signature.track_rows);
        *applied = signature.track_rows.clone();
        drop(applied);
        match patch {
            Some(rows) => {
                for row in rows {
                    let replacement = BoxedAnyObject::new(library.tracks[row].clone());
                    self.store.splice(row as u32, 1, &[replacement]);
                }
                RowChange::Patched
            }
            None => {
                let items: Vec<BoxedAnyObject> = library
                    .tracks
                    .iter()
                    .map(|track| BoxedAnyObject::new(track.clone()))
                    .collect();
                self.store.splice(0, self.store.n_items(), &items);
                RowChange::Replaced
            }
        }
    }

    fn refresh_membership(self: &Rc<Self>, library: &crate::library::Library, change: RowChange) {
        match self.mode.filter.get() {
            LibraryFilter::MostPlayed => self.fetch_most_played(false),
            LibraryFilter::All if change == RowChange::Patched => {}
            LibraryFilter::All | LibraryFilter::Favorites | LibraryFilter::Lossless => {
                self.filter.changed(gtk::FilterChange::Different);
            }
            filter => {
                let now = chrono::Utc::now().timestamp();
                *self.mode.allowed.borrow_mut() =
                    filters::songs_allowed(filter, &library.tracks, &library.albums, now);
                self.filter.changed(gtk::FilterChange::Different);
            }
        }
    }

    fn is_shown(&self) -> bool {
        self.stack.is_mapped()
    }

    fn on_library_changed(self: &Rc<Self>, refresh_counts: bool) {
        if !self.is_shown() {
            self.pending.library.set(true);
            if refresh_counts {
                self.pending.counts.set(true);
            }
            return;
        }
        self.sync_library(refresh_counts);
    }

    /// A finished song only matters to the table while a Most Played range is
    /// showing: the plays it counts come from the scrobble table, which has
    /// just grown. Every other chip hears about the play through the library.
    fn on_play_ended(self: &Rc<Self>) {
        if !self.mode.counts_in_range() {
            return;
        }
        if !self.is_shown() {
            self.pending.counts.set(true);
            return;
        }
        self.fetch_most_played(false);
    }

    fn on_search_changed(&self) {
        if !self.is_shown() {
            self.pending.search.set(true);
            return;
        }
        self.filter.changed(gtk::FilterChange::Different);
    }

    /// Catches the table up with everything that happened while it was off
    /// screen. Runs when the page is shown and before anything reads the table
    /// from outside, so none of them can see rows from before the change.
    fn flush_pending(self: &Rc<Self>) {
        let library = self.pending.library.replace(false);
        let counts = self.pending.counts.replace(false);
        let search = self.pending.search.replace(false);
        if library {
            self.sync_library(counts);
        } else if counts && self.mode.counts_in_range() {
            self.fetch_most_played(false);
        }
        if search {
            self.filter.changed(gtk::FilterChange::Different);
        }
    }

    /// "1,234 songs · 3 d 4 hr", or the same for the selection while rows are
    /// selected. The whole list's duration is summed only when its rows
    /// changed; picking rows costs what the picked rows cost.
    fn update_status(&self, rows_changed: bool) {
        if rows_changed {
            self.total_seconds.set(self.duration_of_all());
        }
        let selected = self.selection.selection();
        let (count, seconds, noun) = if selected.size() > 0 {
            (
                selected.size() as usize,
                self.duration_of_selected(&selected),
                "selected",
            )
        } else {
            (
                self.selection.n_items() as usize,
                self.total_seconds.get(),
                "",
            )
        };
        let text = if noun.is_empty() {
            let word = if count == 1 { "song" } else { "songs" };
            format!(
                "{} {word} · {}",
                group_digits(count),
                format_total_duration(seconds)
            )
        } else {
            format!(
                "{} {noun} · {}",
                group_digits(count),
                format_total_duration(seconds)
            )
        };
        self.status.set_label(&text);
        let has_rows = self.selection.n_items() > 0;
        for button in self.actions.borrow().iter() {
            button.set_sensitive(has_rows);
        }
    }

    fn duration_of_all(&self) -> f64 {
        (0..self.selection.n_items())
            .filter_map(|i| self.selection.item(i).and_downcast::<BoxedAnyObject>())
            .map(|boxed| boxed.borrow::<Track>().duration)
            .sum()
    }

    fn duration_of_selected(&self, selected: &gtk::Bitset) -> f64 {
        let Some((positions, first)) = gtk::BitsetIter::init_first(selected) else {
            return 0.0;
        };
        std::iter::once(first)
            .chain(positions)
            .filter_map(|i| self.selection.item(i).and_downcast::<BoxedAnyObject>())
            .map(|boxed| boxed.borrow::<Track>().duration)
            .sum()
    }

    /// Ctrl+J: scrolls to the playing song and selects it, first widening the
    /// list to everything when the active chip is what hides it.
    fn locate_current(self: &Rc<Self>) {
        self.flush_pending();
        let Some(current) = self.ui.core.player.current_track() else {
            self.ui.core.toast("Nothing is playing");
            return;
        };
        let mut position = self.position_of(&current.rel_path);
        if position.is_none() && self.mode.filter.get() != LibraryFilter::All {
            self.choose(LibraryFilter::All, false);
            position = self.position_of(&current.rel_path);
        }
        let Some(position) = position else {
            let query = self.ui.query.borrow().clone();
            let message = if query.is_empty() {
                "The playing song isn't in the Songs list — its file may have left the library.".to_string()
            } else {
                format!("The playing song doesn't match the search “{query}”. Clear the search to find it.")
            };
            self.ui.core.toast(&message);
            return;
        };
        let column_view = self.column_view.clone();
        gtk::glib::idle_add_local_once(move || {
            column_view.scroll_to(
                position,
                None::<&gtk::ColumnViewColumn>,
                gtk::ListScrollFlags::FOCUS | gtk::ListScrollFlags::SELECT,
                None,
            );
        });
    }

    fn position_of(&self, rel_path: &str) -> Option<u32> {
        (0..self.selection.n_items()).find(|i| {
            self.selection
                .item(*i)
                .and_downcast::<BoxedAnyObject>()
                .is_some_and(|boxed| boxed.borrow::<Track>().rel_path == rel_path)
        })
    }

    /// Clicking a header re-sorts under a preserved pixel offset, which strands
    /// the view deep in the new order; snap back to the top, and remember the
    /// sort for the next launch.
    fn install_scroll_reset_and_sort_memory(self: &Rc<Self>) {
        let Some(sorter) = self.column_view.sorter() else {
            return;
        };
        let view = Rc::clone(self);
        sorter.connect_changed(move |sorter, _| {
            view.scroll_to_top();
            let Some(sorter) = sorter.downcast_ref::<gtk::ColumnViewSorter>() else {
                return;
            };
            let Some(column) = sorter.primary_sort_column() else {
                return;
            };
            let key = column_key(&column);
            let descending = sorter.primary_sort_order() == gtk::SortType::Descending;
            let mut config = view.ui.core.config.borrow_mut();
            if config.songs_sort == key && config.songs_sort_descending == descending {
                return;
            }
            config.songs_sort = key;
            config.songs_sort_descending = descending;
            drop(config);
            view.ui.core.save_config();
        });
    }
}

/// Collects the tracks currently highlighted in the multi-selection, in model
/// order, for the bulk context-menu actions.
fn selected_tracks(selection: &gtk::MultiSelection) -> Vec<Track> {
    let mut tracks = Vec::new();
    for position in 0..selection.n_items() {
        if selection.is_selected(position) {
            if let Some(boxed) = selection.item(position).and_downcast::<BoxedAnyObject>() {
                tracks.push(boxed.borrow::<Track>().clone());
            }
        }
    }
    tracks
}

/// Registers the `songs.*` action group backing the multi-select context menu;
/// each action resolves the live selection at activation time. The group lives
/// on the window because the popovers that reference it are parented to the
/// window root, not the column view.
fn install_bulk_actions(ui: &Rc<Ui>, selection: &gtk::MultiSelection) {
    let actions = gio::SimpleActionGroup::new();

    let add = |name: &str, handler: Box<dyn Fn(Vec<Track>)>| {
        let action = gio::SimpleAction::new(name, None);
        let selection = selection.clone();
        action.connect_activate(move |_, _| handler(selected_tracks(&selection)));
        actions.add_action(&action);
    };

    {
        let ui = Rc::clone(ui);
        add(
            "bulk-play",
            Box::new(move |tracks| {
                if !tracks.is_empty() {
                    ui.core.play_tracks(tracks, 0);
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-play-next",
            Box::new(move |tracks| {
                for track in tracks.iter().rev() {
                    ui.core.player.insert_next(track.clone());
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-queue",
            Box::new(move |tracks| {
                for track in &tracks {
                    ui.core.player.add_to_queue(track.clone());
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-love",
            Box::new(move |tracks| {
                for track in &tracks {
                    if !track.loved {
                        ui.core.toggle_love(&track.rel_path);
                    }
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-unlove",
            Box::new(move |tracks| {
                for track in &tracks {
                    if track.loved {
                        ui.core.toggle_love(&track.rel_path);
                    }
                }
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-download",
            Box::new(move |tracks| {
                crate::ui::window::keep_songs(&ui, paths_of(&tracks), true);
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-remove-download",
            Box::new(move |tracks| {
                crate::ui::window::keep_songs(&ui, paths_of(&tracks), false);
            }),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-dedup",
            Box::new(move |tracks| crate::ui::cleanup::present_selection_dedup(&ui, tracks)),
        );
    }
    {
        let ui = Rc::clone(ui);
        add(
            "bulk-delete",
            Box::new(move |tracks| crate::ui::delete::present_delete_tracks(&ui, tracks)),
        );
    }

    ui.window.insert_action_group("songs", Some(&actions));
}

fn paths_of(tracks: &[Track]) -> Vec<String> {
    tracks.iter().map(|track| track.rel_path.clone()).collect()
}

fn bulk_menu(count: usize, has_duplicates: bool, downloads: Option<bool>) -> gio::Menu {
    let menu = gio::Menu::new();
    let play_section = gio::Menu::new();
    play_section.append(
        Some(&format!("Play {count} Songs")),
        Some("songs.bulk-play"),
    );
    menu.append_section(None, &play_section);

    let queue_section = gio::Menu::new();
    queue_section.append(Some("Play Next"), Some("songs.bulk-play-next"));
    queue_section.append(Some("Add to Queue"), Some("songs.bulk-queue"));
    menu.append_section(None, &queue_section);

    let love_section = gio::Menu::new();
    love_section.append(Some("Love on Last.fm"), Some("songs.bulk-love"));
    love_section.append(Some("Unlove"), Some("songs.bulk-unlove"));
    menu.append_section(None, &love_section);

    if let Some(kept) = downloads {
        let download_section = gio::Menu::new();
        let (label, action) = context::download_entry(kept, "songs.bulk-remove-download", "songs.bulk-download");
        download_section.append(Some(label), Some(action));
        menu.append_section(None, &download_section);
    }

    if has_duplicates {
        let dedup_section = gio::Menu::new();
        dedup_section.append(
            Some("Remove Duplicates in Selection"),
            Some("songs.bulk-dedup"),
        );
        menu.append_section(None, &dedup_section);
    }

    let delete_section = gio::Menu::new();
    delete_section.append(
        Some(&format!("Move {count} Songs to Trash…")),
        Some("songs.bulk-delete"),
    );
    menu.append_section(None, &delete_section);
    menu
}

/// The rows whose digest differs between two builds of the same-sized list, or
/// `None` when the list changed size or too much of it changed to swap row by
/// row.
fn differing_rows(applied: &[u64], next: &[u64]) -> Option<Vec<usize>> {
    if applied.len() != next.len() {
        return None;
    }
    let mut rows = Vec::new();
    for (row, (old, new)) in applied.iter().zip(next).enumerate() {
        if old != new {
            if rows.len() >= PATCH_ROW_LIMIT {
                return None;
            }
            rows.push(row);
        }
    }
    (rows.len() * 8 <= next.len()).then_some(rows)
}

/// The Most Played ranking keyed by track id, which hashes in a fraction of
/// the time a path does and is looked up twice per comparison of a sort.
fn rank_by_track_id(
    tracks: &[Track],
    rank_by_path: &HashMap<String, usize>,
) -> HashMap<i64, usize> {
    tracks
        .iter()
        .filter_map(|track| Some((track.id, *rank_by_path.get(&track.rel_path)?)))
        .collect()
}

fn format_date_added(unix: i64) -> String {
    if unix <= 0 {
        return String::new();
    }
    chrono::DateTime::<chrono::Utc>::from_timestamp(unix, 0)
        .map(|stamp| {
            stamp
                .with_timezone(&chrono::Local)
                .format("%b %-d, %Y")
                .to_string()
        })
        .unwrap_or_default()
}

/// The songs table's leading column: the track number, replaced by the live
/// equalizer on whichever row the player is on — the same marker the album and
/// playlist lists use.
pub(crate) fn track_number_column(ui: &Rc<Ui>) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    {
        let ui = Rc::clone(ui);
        factory.connect_setup(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let cell = controls::track_index_cell("");
            item.set_child(Some(&cell.widget));
            watch_now_playing_cell(&ui, &cell.widget, item);
        });
    }
    {
        let ui = Rc::clone(ui);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(widget) = item.child() else { return };
            let Some(cell) = controls::TrackIndexCell::from_widget(&widget) else {
                return;
            };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let track = boxed.borrow::<Track>();
            cell.set_text(&if track.track_number > 0 {
                track.track_number.to_string()
            } else {
                String::new()
            });
            apply_now_playing_cell(&ui, &widget, item);
        });
    }
    let sorter = track_sorter(|a, b| a.track_number.cmp(&b.track_number));
    gtk::ColumnViewColumn::builder()
        .id("track #")
        .title("Track #")
        .factory(&factory)
        .sorter(&sorter)
        .resizable(true)
        .build()
}

/// Paints one songs-table cell for the now-playing row. Cells recycle, so the
/// check always resolves the list item's *current* track rather than whatever
/// was bound when the widget was created.
pub(crate) fn apply_now_playing_cell(ui: &Rc<Ui>, widget: &gtk::Widget, item: &gtk::ListItem) {
    let current = ui.core.player.current_track();
    let is_current = item
        .item()
        .and_downcast::<BoxedAnyObject>()
        .zip(current)
        .is_some_and(|(boxed, track)| boxed.borrow::<Track>().rel_path == track.rel_path);
    if let Some(cell) = controls::TrackIndexCell::from_widget(widget) {
        cell.set_state(is_current, ui.core.player.is_playing());
        return;
    }
    if is_current {
        widget.add_css_class("now-playing-cell");
    } else {
        widget.remove_css_class("now-playing-cell");
    }
}

/// Keeps a recycled cell's chip in step with the library: a reload that
/// recognised a re-export lights it even when the row object it is bound to
/// is a snapshot from before.
fn watch_cell_chip(ui: &Rc<Ui>, chip: &gtk::Label, item: &gtk::ListItem) {
    let item_weak = item.downgrade();
    let ui = Rc::clone(ui);
    let hub = Rc::clone(&ui.core.hub);
    hub.subscribe_widget(chip, move |chip, event| {
        if !matches!(event, AppEvent::LibraryReloaded) {
            return;
        }
        let Some(boxed) = item_weak
            .upgrade()
            .and_then(|item| item.item())
            .and_downcast::<BoxedAnyObject>()
        else {
            return;
        };
        let rel_path = boxed.borrow::<Track>().rel_path.clone();
        let visible = ui
            .core
            .library
            .borrow()
            .track_by_rel_path(&rel_path)
            .is_some_and(controls::shows_new_mix);
        chip.set_visible(visible);
    });
}

/// Keeps a recycled cell following the player for as long as the widget lives.
pub(crate) fn watch_now_playing_cell(ui: &Rc<Ui>, widget: &gtk::Widget, item: &gtk::ListItem) {
    let ui_ref = Rc::clone(ui);
    let item_weak = item.downgrade();
    ui.core.hub.subscribe_widget(widget, move |widget, event| {
        if !matches!(
            event,
            AppEvent::TrackChanged(_) | AppEvent::PlayingChanged(_)
        ) {
            return;
        }
        if let Some(item) = item_weak.upgrade() {
            apply_now_playing_cell(&ui_ref, widget, &item);
        }
    });
}

/// Re-reads a cell's text when the table announces that what its columns count
/// has changed (the Plays column switching between all-time and a range), so the
/// rows keep their objects, their selection and their scroll position.
fn watch_cell_text(
    ui: &Rc<Ui>,
    label: &gtk::Label,
    item: &gtk::ListItem,
    text_for: Rc<impl Fn(&Track) -> String + 'static>,
) {
    let item_weak = item.downgrade();
    ui.core.hub.subscribe_widget(label, move |label, event| {
        if !matches!(event, AppEvent::SongCellsChanged) {
            return;
        }
        let Some(item) = item_weak.upgrade() else {
            return;
        };
        let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
            return;
        };
        let text = text_for(&boxed.borrow::<Track>());
        label.set_label(&text);
    });
}

pub(crate) fn track_sorter(compare: impl Fn(&Track, &Track) -> Ordering + 'static) -> gtk::CustomSorter {
    gtk::CustomSorter::new(move |a, b| {
        let (Some(a), Some(b)) = (
            a.downcast_ref::<BoxedAnyObject>(),
            b.downcast_ref::<BoxedAnyObject>(),
        ) else {
            return gtk::Ordering::Equal;
        };
        let track_a = a.borrow::<Track>();
        let track_b = b.borrow::<Track>();
        compare(&track_a, &track_b)
            .then_with(|| track_a.rel_path.cmp(&track_b.rel_path))
            .into()
    })
}

pub(crate) fn string_column(
    ui: &Rc<Ui>,
    title: &str,
    expand: bool,
    text_for: impl Fn(&Track) -> String + 'static,
    compare: impl Fn(&Track, &Track) -> Ordering + 'static,
    menu: Option<Rc<MenuHandler>>,
) -> gtk::ColumnViewColumn {
    cell_column(ui, title, expand, false, text_for, compare, menu)
}

/// A title column: the text, and beside it the New mix chip while the song's
/// latest re-export is recent.
pub(crate) fn title_column(
    ui: &Rc<Ui>,
    expand: bool,
    text_for: impl Fn(&Track) -> String + 'static,
    compare: impl Fn(&Track, &Track) -> Ordering + 'static,
    menu: Option<Rc<MenuHandler>>,
) -> gtk::ColumnViewColumn {
    cell_column(ui, "Title", expand, true, text_for, compare, menu)
}

/// The text label of a cell, whether the cell is the label itself or a box
/// holding it beside a chip.
fn cell_label(cell: &gtk::Widget) -> Option<gtk::Label> {
    cell.clone()
        .downcast::<gtk::Label>()
        .ok()
        .or_else(|| cell.first_child().and_downcast::<gtk::Label>())
}

/// The downloads mark beside a title, for a song kept on this computer.
fn cell_mark(cell: &gtk::Widget) -> Option<gtk::Image> {
    cell.first_child()?
        .next_sibling()
        .and_downcast::<gtk::Image>()
        .filter(|mark| mark.has_css_class("kept-mark"))
}

fn kept_mark() -> gtk::Image {
    let mark = gtk::Image::from_icon_name("folder-download-symbolic");
    mark.add_css_class("kept-mark");
    mark.add_css_class("dim");
    mark.set_pixel_size(12);
    mark.set_valign(gtk::Align::Center);
    mark.set_tooltip_text(Some("Downloaded: plays without the server"));
    mark.set_visible(false);
    mark
}

/// Shows a remote song the way its source allows: dimmed while its server is
/// out of reach and none of it is on this computer, marked while it is kept.
fn apply_remote_state(cell: &gtk::Widget, rel_path: &str) {
    cell.set_opacity(if crate::remote::is_dimmed(rel_path) { 0.45 } else { 1.0 });
    if let Some(mark) = cell_mark(cell) {
        mark.set_visible(crate::remote::is_downloaded(rel_path));
    }
}

/// Keeps a recycled cell's dimming and download mark following the remote
/// library for as long as the widget lives.
fn watch_remote_state(ui: &Rc<Ui>, cell: &gtk::Widget, item: &gtk::ListItem) {
    let item_weak = item.downgrade();
    ui.core.hub.subscribe_widget(cell, move |cell, event| {
        if !matches!(event, AppEvent::RemoteChanged) {
            return;
        }
        let Some(boxed) = item_weak
            .upgrade()
            .and_then(|item| item.item())
            .and_downcast::<BoxedAnyObject>()
        else {
            return;
        };
        let rel_path = boxed.borrow::<Track>().rel_path.clone();
        apply_remote_state(cell, &rel_path);
    });
}

fn cell_chip(cell: &gtk::Widget) -> Option<gtk::Label> {
    cell.last_child()
        .and_downcast::<gtk::Label>()
        .filter(|chip| chip.has_css_class("new-mix-chip"))
}

fn cell_column(
    ui: &Rc<Ui>,
    title: &str,
    expand: bool,
    with_chip: bool,
    text_for: impl Fn(&Track) -> String + 'static,
    compare: impl Fn(&Track, &Track) -> Ordering + 'static,
    menu: Option<Rc<MenuHandler>>,
) -> gtk::ColumnViewColumn {
    let factory = gtk::SignalListItemFactory::new();
    let setup_ui = Rc::clone(ui);
    let text_for = Rc::new(text_for);
    let setup_text = Rc::clone(&text_for);
    factory.connect_setup(move |_, item| {
        let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
            return;
        };
        let label = gtk::Label::builder()
            .xalign(0.0)
            .ellipsize(pango::EllipsizeMode::End)
            .build();
        let cell: gtk::Widget = if with_chip {
            label.set_hexpand(true);
            let chip = controls::new_mix_chip();
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            row.append(&label);
            row.append(&kept_mark());
            row.append(&chip);
            watch_cell_chip(&setup_ui, &chip, item);
            row.upcast()
        } else {
            label.clone().upcast()
        };
        item.set_child(Some(&cell));
        watch_now_playing_cell(&setup_ui, &cell, item);
        watch_remote_state(&setup_ui, &cell, item);
        watch_cell_text(&setup_ui, &label, item, Rc::clone(&setup_text));
        if let Some(menu) = menu.clone() {
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
                let track = boxed.borrow::<Track>().clone();
                menu(&track, &anchor, x, y);
            });
            cell.add_controller(gesture);
        }
    });
    {
        let text_for = Rc::clone(&text_for);
        let bind_ui = Rc::clone(ui);
        factory.connect_bind(move |_, item| {
            let Some(item) = item.downcast_ref::<gtk::ListItem>() else {
                return;
            };
            let Some(cell) = item.child() else {
                return;
            };
            let Some(label) = cell_label(&cell) else {
                return;
            };
            let Some(boxed) = item.item().and_downcast::<BoxedAnyObject>() else {
                return;
            };
            let track = boxed.borrow::<Track>();
            label.set_label(&text_for(&track));
            if let Some(chip) = cell_chip(&cell) {
                chip.set_visible(controls::shows_new_mix(&track));
            }
            apply_remote_state(&cell, &track.rel_path);
            drop(track);
            apply_now_playing_cell(&bind_ui, &cell, item);
        });
    }

    let sorter = track_sorter(compare);

    gtk::ColumnViewColumn::builder()
        .id(title.to_lowercase())
        .title(title)
        .factory(&factory)
        .sorter(&sorter)
        .expand(expand)
        .resizable(true)
        .build()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_few_changed_rows_are_swapped_in_place() {
        let applied: Vec<u64> = (0..200).collect();
        let mut next = applied.clone();
        next[3] = 900;
        next[150] = 901;
        assert_eq!(differing_rows(&applied, &next), Some(vec![3, 150]));
    }

    #[test]
    fn a_resized_or_mostly_changed_list_is_replaced_whole() {
        let applied: Vec<u64> = (0..200).collect();
        assert_eq!(differing_rows(&applied, &applied[..199]), None);
        let churned: Vec<u64> = (1000..1200).collect();
        assert_eq!(differing_rows(&applied, &churned), None);
        let small: Vec<u64> = (0..4).collect();
        let mut small_next = small.clone();
        small_next[1] = 99;
        assert_eq!(differing_rows(&small, &small_next), None);
    }

    #[test]
    fn the_row_limit_caps_how_many_rows_are_patched() {
        let applied: Vec<u64> = (0..10_000).collect();
        let mut next = applied.clone();
        for row in 0..=PATCH_ROW_LIMIT {
            next[row] += 50_000;
        }
        assert_eq!(differing_rows(&applied, &next), None);
    }
}
