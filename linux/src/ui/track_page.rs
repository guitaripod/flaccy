use crate::library::{format_time, Track};
pub use flaccy_shared::track_page_layout::{
    balance_columns, column_count, even_runs, page_mode, PageKind, PageMode, TrackLayout,
    FILTER_THRESHOLD, SONGS_PER_COLUMN,
};
use crate::ui::songs::{string_column, track_number_column, MenuHandler};
use crate::ui::{resize, Ui};
use adw::prelude::*;
use gtk::gio;
use gtk::glib::BoxedAnyObject;
use std::cell::{Cell, RefCell};
use std::cmp::Ordering;
use std::collections::HashMap;
use std::rc::Rc;

const RAIL_WIDTH: i32 = 380;
const TABLE_HEADER: f64 = 36.0;

pub fn layout_label(layout: TrackLayout) -> &'static str {
    match layout {
        TrackLayout::List => "List",
        TrackLayout::Table => "Table",
        TrackLayout::Columns => "Columns",
    }
}

pub fn layout_icon(layout: TrackLayout) -> &'static str {
    match layout {
        TrackLayout::List => "view-list-symbolic",
        TrackLayout::Table => "view-list-ordered-symbolic",
        TrackLayout::Columns => "view-dual-symbolic",
    }
}

const FIELD_BREAK: char = '\0';

/// What a page's filter box searches in one song: title, artist and album,
/// lowercased once and kept apart by a NUL that a typed needle can never
/// contain, so a match can never straddle two fields. Built once per song per
/// page build, not once per keystroke.
pub fn search_text(track: &Track) -> String {
    let capacity = track.title.len() + track.artist.len() + track.album.len() + 2;
    let mut text = String::with_capacity(capacity);
    text.push_str(&track.title.to_lowercase());
    text.push(FIELD_BREAK);
    text.push_str(&track.artist.to_lowercase());
    text.push(FIELD_BREAK);
    text.push_str(&track.album.to_lowercase());
    text
}

/// Whether a song's `search_text` answers a page's filter box; `needle` is
/// already lowercase.
pub fn matches_text(text: &str, needle: &str) -> bool {
    needle.is_empty() || text.contains(needle)
}

/// The page shell both song pages share: a hero, a scrolling body, and — in a
/// wide window — the hero moved into a rail of its own beside the body.
pub struct Frame {
    pub root: gtk::Box,
    pub scroll: gtk::ScrolledWindow,
    pub body: gtk::Box,
    content: gtk::Box,
    clamp: adw::Clamp,
    header: gtk::Box,
    header_slot: gtk::Box,
    rail: gtk::ScrolledWindow,
    rail_box: gtk::Box,
    mode: Cell<Option<PageMode>>,
    on_mode: Box<dyn Fn(PageMode)>,
}

impl Frame {
    /// `on_mode` runs whenever the width crosses into another arrangement,
    /// and once when the page first gets a width, so the page can size its
    /// cover to the room the hero has.
    pub fn new(ui: &Rc<Ui>, header: &gtk::Box, on_mode: impl Fn(PageMode) + 'static) -> Rc<Frame> {
        header.set_valign(gtk::Align::Start);
        let header_slot = gtk::Box::new(gtk::Orientation::Vertical, 0);
        let body = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(16)
            .build();
        let content = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(24)
            .margin_top(32)
            .margin_bottom(32)
            .margin_start(32)
            .margin_end(32)
            .build();
        content.add_css_class("album-detail-content");
        content.append(&header_slot);
        content.append(&body);
        header_slot.append(header);

        let clamp = adw::Clamp::builder()
            .maximum_size(1080)
            .child(&content)
            .build();
        let scroll = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .hexpand(true)
            .vexpand(true)
            .child(&clamp)
            .build();
        ui.register_scroller(&scroll);

        let rail_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .margin_top(32)
            .margin_bottom(32)
            .margin_start(32)
            .margin_end(16)
            .build();
        rail_box.add_css_class("detail-rail");
        let rail = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .width_request(RAIL_WIDTH)
            .hexpand(false)
            .vexpand(true)
            .visible(false)
            .child(&rail_box)
            .build();

        let root = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        root.append(&rail);
        root.append(&scroll);

        let frame = Rc::new(Frame {
            root: root.clone(),
            scroll,
            body,
            content,
            clamp,
            header: header.clone(),
            header_slot,
            rail,
            rail_box,
            mode: Cell::new(None),
            on_mode: Box::new(on_mode),
        });
        let weak = Rc::downgrade(&frame);
        resize::watch_width(&root, move |width, _| {
            if let Some(frame) = weak.upgrade() {
                frame.arrange(page_mode(width));
            }
        });
        frame
    }

    pub fn scroll_to_top(&self) {
        self.scroll.vadjustment().set_value(0.0);
    }

    fn arrange(&self, mode: PageMode) {
        if self.mode.replace(Some(mode)) == Some(mode) {
            return;
        }
        let in_rail = mode == PageMode::Wide;
        self.rail.set_visible(in_rail);
        let target: &gtk::Box = if in_rail {
            &self.rail_box
        } else {
            &self.header_slot
        };
        if self.header.parent().as_ref() != Some(target.upcast_ref()) {
            if let Some(parent) = self.header.parent().and_downcast::<gtk::Box>() {
                parent.remove(&self.header);
            }
            target.append(&self.header);
        }
        let (orientation, spacing) = match mode {
            PageMode::Wide => (gtk::Orientation::Vertical, 20),
            PageMode::Regular => (gtk::Orientation::Horizontal, 24),
            PageMode::Compact => (gtk::Orientation::Vertical, 16),
        };
        self.header.set_orientation(orientation);
        self.header.set_spacing(spacing);
        let (edge, vertical, gap) = match mode {
            PageMode::Compact => (16, 20, 16),
            PageMode::Regular => (32, 32, 24),
            PageMode::Wide => (24, 32, 20),
        };
        self.content.set_margin_start(edge);
        self.content.set_margin_end(edge + if in_rail { 8 } else { 0 });
        self.content.set_margin_top(vertical);
        self.content.set_margin_bottom(vertical);
        self.content.set_spacing(gap);
        self.clamp.set_maximum_size(if in_rail { 1240 } else { 1080 });
        (self.on_mode)(mode);
    }
}

/// The strip above the songs: a filter, the layout switch and a button that
/// scrolls the playing song into view.
pub struct ControlBar {
    pub widget: gtk::Box,
    filter: gtk::SearchEntry,
    status: gtk::Label,
    buttons: Vec<(TrackLayout, gtk::ToggleButton)>,
}

impl ControlBar {
    pub fn new(
        kind: PageKind,
        current: TrackLayout,
        on_layout: impl Fn(TrackLayout) + 'static,
        on_filter: impl Fn(&str) + 'static,
        on_jump: impl Fn() + 'static,
    ) -> ControlBar {
        let widget = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(10)
            .build();
        widget.add_css_class("track-controls");

        let filter = gtk::SearchEntry::builder()
            .placeholder_text(match kind {
                PageKind::Album => "Filter this album",
                PageKind::Playlist => "Filter this playlist",
            })
            .hexpand(true)
            .visible(false)
            .build();
        let status = gtk::Label::builder().visible(false).build();
        status.add_css_class("dim");
        status.add_css_class("caption");
        let spacer = gtk::Box::builder().hexpand(true).build();

        let jump = gtk::Button::from_icon_name("find-location-symbolic");
        jump.add_css_class("flat");
        jump.set_tooltip_text(Some("Show the playing song (Ctrl+J)"));
        jump.update_property(&[gtk::accessible::Property::Label("Show the playing song")]);
        jump.connect_clicked(move |_| on_jump());

        let switch = gtk::Box::new(gtk::Orientation::Horizontal, 0);
        switch.add_css_class("linked");
        let mut buttons: Vec<(TrackLayout, gtk::ToggleButton)> = Vec::new();
        let on_layout = Rc::new(on_layout);
        for layout in TrackLayout::ALL
            .into_iter()
            .filter(|layout| layout.offered_on(kind))
        {
            let button = gtk::ToggleButton::builder()
                .icon_name(layout_icon(layout))
                .tooltip_text(format!("{} layout", layout_label(layout)))
                .active(layout == current)
                .build();
            button.update_property(&[gtk::accessible::Property::Label(&format!(
                "{} layout",
                layout_label(layout)
            ))]);
            if let Some((_, first)) = buttons.first() {
                button.set_group(Some(first));
            }
            let on_layout = Rc::clone(&on_layout);
            button.connect_toggled(move |button| {
                if button.is_active() {
                    on_layout(layout);
                }
            });
            switch.append(&button);
            buttons.push((layout, button));
        }

        widget.append(&filter);
        widget.append(&status);
        widget.append(&spacer);
        widget.append(&jump);
        widget.append(&switch);

        filter.connect_search_changed(move |entry| on_filter(&entry.text().to_lowercase()));
        ControlBar {
            widget,
            filter,
            status,
            buttons,
        }
    }

    pub fn set_layout(&self, layout: TrackLayout) {
        for (candidate, button) in &self.buttons {
            if *candidate == layout && !button.is_active() {
                button.set_active(true);
            }
        }
    }

    pub fn clear_filter(&self) {
        self.filter.set_text("");
    }

    pub fn show_filter(&self, shown: bool) {
        self.filter.set_visible(shown);
        if !shown {
            self.filter.set_text("");
        }
    }

    pub fn set_status(&self, text: Option<&str>) {
        self.status.set_visible(text.is_some());
        self.status.set_label(text.unwrap_or_default());
    }
}

/// What a song's table cell may show beyond the song itself.
#[derive(Clone, Default)]
pub struct TableOptions {
    pub kind: Option<PageKind>,
    pub disc_of: Option<Rc<std::collections::HashMap<String, String>>>,
    pub artists_vary: bool,
}

/// The songs of a page as a sortable table. It never scrolls by itself: it is
/// as tall as its rows and the page scrolls it, so the hero and the table move
/// together in a narrow window.
pub struct TrackTable {
    pub widget: gtk::ScrolledWindow,
    column_view: gtk::ColumnView,
    store: gio::ListStore,
    filter: gtk::CustomFilter,
    query: Rc<RefCell<String>>,
    search: Rc<RefCell<HashMap<String, String>>>,
    selection: gtk::SingleSelection,
}

impl TrackTable {
    pub fn new(
        ui: &Rc<Ui>,
        options: TableOptions,
        menu: Rc<MenuHandler>,
        on_play: impl Fn(Vec<Track>, usize) + 'static,
        on_sorted: impl Fn() + 'static,
    ) -> TrackTable {
        let store = gio::ListStore::new::<BoxedAnyObject>();
        let query: Rc<RefCell<String>> = Rc::new(RefCell::new(String::new()));
        let search: Rc<RefCell<HashMap<String, String>>> = Rc::new(RefCell::new(HashMap::new()));
        let filter = {
            let query = Rc::clone(&query);
            let search = Rc::clone(&search);
            gtk::CustomFilter::new(move |obj| {
                let Some(boxed) = obj.downcast_ref::<BoxedAnyObject>() else {
                    return true;
                };
                let query = query.borrow();
                if query.is_empty() {
                    return true;
                }
                search
                    .borrow()
                    .get(&boxed.borrow::<Track>().rel_path)
                    .is_none_or(|text| matches_text(text, &query))
            })
        };
        let filtered = gtk::FilterListModel::new(Some(store.clone()), Some(filter.clone()));
        let column_view = gtk::ColumnView::builder()
            .reorderable(false)
            .show_row_separators(false)
            .single_click_activate(true)
            .build();
        column_view.add_css_class("data-table");
        let sorted = gtk::SortListModel::new(Some(filtered), column_view.sorter());
        let selection = gtk::SingleSelection::builder()
            .model(&sorted)
            .autoselect(false)
            .can_unselect(true)
            .build();
        column_view.set_model(Some(&selection));

        let kind = options.kind.unwrap_or(PageKind::Album);
        let number = track_number_column(ui);
        number.set_title(Some("#"));
        number.set_fixed_width(64);
        column_view.append_column(&number);

        let title = string_column(
            ui,
            "Title",
            true,
            |track| track.title.clone(),
            |a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()),
            Some(Rc::clone(&menu)),
        );
        column_view.append_column(&title);

        let artist = string_column(
            ui,
            "Artist",
            true,
            |track| track.artist.clone(),
            |a, b| a.artist.to_lowercase().cmp(&b.artist.to_lowercase()),
            Some(Rc::clone(&menu)),
        );
        column_view.append_column(&artist);

        let album = (kind == PageKind::Playlist).then(|| {
            let column = string_column(
                ui,
                "Album",
                true,
                |track| track.album.clone(),
                |a, b| a.album.to_lowercase().cmp(&b.album.to_lowercase()),
                Some(Rc::clone(&menu)),
            );
            column_view.append_column(&column);
            column
        });

        let disc = options.disc_of.clone().map(|labels| {
            let sorter_labels = Rc::clone(&labels);
            let column = string_column(
                ui,
                "Disc",
                false,
                move |track| labels.get(&track.rel_path).cloned().unwrap_or_default(),
                move |a, b| {
                    let label = |track: &Track| {
                        sorter_labels
                            .get(&track.rel_path)
                            .cloned()
                            .unwrap_or_default()
                    };
                    label(a).cmp(&label(b))
                },
                Some(Rc::clone(&menu)),
            );
            column_view.append_column(&column);
            column
        });

        let plays = string_column(
            ui,
            "Plays",
            false,
            |track| {
                if track.play_count > 0 {
                    track.play_count.to_string()
                } else {
                    String::new()
                }
            },
            |a, b| a.play_count.cmp(&b.play_count),
            Some(Rc::clone(&menu)),
        );
        column_view.append_column(&plays);

        let quality = string_column(
            ui,
            "Quality",
            false,
            |track| track.quality_badge().unwrap_or_default(),
            |a, b| {
                let score = |t: &Track| {
                    (t.bit_depth.unwrap_or(0) as i64) * 1_000_000
                        + t.sample_rate.unwrap_or(0) as i64
                };
                score(a).cmp(&score(b))
            },
            Some(Rc::clone(&menu)),
        );
        column_view.append_column(&quality);

        let duration = string_column(
            ui,
            "Time",
            false,
            |track| format_time(track.duration),
            |a, b| {
                a.duration
                    .partial_cmp(&b.duration)
                    .unwrap_or(Ordering::Equal)
            },
            Some(Rc::clone(&menu)),
        );
        column_view.append_column(&duration);

        let artists_vary = options.artists_vary || kind == PageKind::Playlist;
        resize::watch_width(&column_view, move |width, _| {
            artist.set_visible(artists_vary && width >= 480);
            if let Some(album) = &album {
                album.set_visible(width >= 760);
            }
            if let Some(disc) = &disc {
                disc.set_visible(width >= 420);
            }
            quality.set_visible(width >= 640);
            plays.set_visible(width >= 560);
            duration.set_visible(true);
        });

        {
            let selection = selection.clone();
            let on_play = Rc::new(on_play);
            column_view.connect_activate(move |_, position| {
                let tracks = tracks_of(&selection);
                if (position as usize) < tracks.len() {
                    on_play(tracks, position as usize);
                }
                selection.unselect_all();
            });
        }
        column_view.sorter().map(|sorter| {
            sorter.connect_changed(move |_, _| on_sorted());
        });

        let widget = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .vscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .child(&column_view)
            .build();
        widget.add_css_class("detail-table");
        TrackTable {
            widget,
            column_view,
            store,
            filter,
            query,
            search,
            selection,
        }
    }

    pub fn set_tracks(&self, tracks: &[Track]) {
        *self.search.borrow_mut() = tracks
            .iter()
            .map(|track| (track.rel_path.clone(), search_text(track)))
            .collect();
        let items: Vec<BoxedAnyObject> = tracks
            .iter()
            .map(|track| BoxedAnyObject::new(track.clone()))
            .collect();
        self.store.splice(0, self.store.n_items(), &items);
    }

    pub fn set_query(&self, query: &str) {
        *self.query.borrow_mut() = query.to_string();
        self.filter.changed(gtk::FilterChange::Different);
    }

    /// The row the playing song sits on, if this table shows it.
    pub fn position_of(&self, rel_path: &str) -> Option<u32> {
        (0..self.selection.n_items()).find(|index| {
            self.selection
                .item(*index)
                .and_downcast::<BoxedAnyObject>()
                .is_some_and(|boxed| boxed.borrow::<Track>().rel_path == rel_path)
        })
    }

    /// Where a row's top edge sits inside the table, assuming equal row
    /// heights, which the table's cells guarantee.
    pub fn row_offset(&self, position: u32) -> f64 {
        let rows = f64::from(self.selection.n_items().max(1));
        let body = (f64::from(self.column_view.height()) - TABLE_HEADER).max(0.0);
        TABLE_HEADER + body * f64::from(position) / rows
    }
}

fn tracks_of(selection: &gtk::SingleSelection) -> Vec<Track> {
    (0..selection.n_items())
        .filter_map(|index| selection.item(index).and_downcast::<BoxedAnyObject>())
        .map(|boxed| boxed.borrow::<Track>().clone())
        .collect()
}

/// Scrolls `scroll` so `widget`, which lives inside it, sits about a third of
/// the way down the viewport.
pub fn reveal(scroll: &gtk::ScrolledWindow, widget: &impl IsA<gtk::Widget>) {
    let Some(point) = widget.compute_point(scroll, &gtk::graphene::Point::new(0.0, 0.0)) else {
        return;
    };
    scroll_by(scroll, f64::from(point.y()));
}

fn scroll_by(scroll: &gtk::ScrolledWindow, offset_in_view: f64) {
    let adjustment = scroll.vadjustment();
    let target = adjustment.value() + offset_in_view - adjustment.page_size() * 0.33;
    let upper = (adjustment.upper() - adjustment.page_size()).max(0.0);
    adjustment.set_value(target.clamp(0.0, upper));
}

/// Scrolls the page so a table row is in view.
pub fn reveal_row(scroll: &gtk::ScrolledWindow, table: &TrackTable, position: u32) {
    let Some(point) = table
        .column_view
        .compute_point(scroll, &gtk::graphene::Point::new(0.0, 0.0))
    else {
        return;
    };
    scroll_by(scroll, f64::from(point.y()) + table.row_offset(position));
}

#[cfg(test)]
mod tests {
    use super::*;

    fn song(title: &str, artist: &str, album: &str) -> Track {
        Track {
            id: 0,
            rel_path: format!("{title}.flac"),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            album_artist: None,
            track_number: 1,
            duration: 1.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
        }
    }

    fn reference(track: &Track, needle: &str) -> bool {
        needle.is_empty()
            || track.title.to_lowercase().contains(needle)
            || track.artist.to_lowercase().contains(needle)
            || track.album.to_lowercase().contains(needle)
    }

    #[test]
    fn search_text_answers_like_lowercasing_each_field() {
        let tracks = [
            song("Blue Monday", "New Order", "Power, Corruption & Lies"),
            song("ÄÖ Straße", "Σίσυφος", "ΟΔΥΣΣΕΥΣ"),
            song("", "", ""),
        ];
        let needles = [
            "", "blue", "order", "lies", "monday new", "new order power", "ö str", "σίσυφος",
            "οδυσσευσ", "ς", "\u{1}", "zzz",
        ];
        for track in &tracks {
            let text = search_text(track);
            for needle in needles {
                assert_eq!(
                    matches_text(&text, needle),
                    reference(track, needle),
                    "{:?} against {needle:?}",
                    track.title
                );
            }
        }
    }

    #[test]
    fn a_match_never_straddles_two_fields() {
        let text = search_text(&song("abc", "def", "ghi"));
        assert!(matches_text(&text, "bc"));
        assert!(!matches_text(&text, "cd"));
        assert!(!matches_text(&text, "fg"));
    }
}
