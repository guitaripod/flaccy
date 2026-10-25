use crate::events::AppEvent;
use crate::library::{disc_sections, format_time, Album, Track};
use crate::ui::track_page::{
    balance_columns, column_count, even_runs, matches_text, reveal, reveal_row, search_text,
    ControlBar, Frame, PageKind, TableOptions, TrackLayout, TrackTable, FILTER_THRESHOLD,
    SONGS_PER_COLUMN,
};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

/// One disc, one side, or one run of an album's songs: an optional header over
/// the boxed list of its rows.
struct Block {
    header: Option<gtk::Box>,
    list: gtk::ListBox,
    base: usize,
    len: usize,
}

impl Block {
    fn new(
        ui: &Rc<Ui>,
        all: &Rc<Vec<Track>>,
        search: &Rc<Vec<String>>,
        base: usize,
        len: usize,
        label: Option<(&str, f64)>,
        query: &Rc<RefCell<String>>,
    ) -> Block {
        let list = build_track_list(ui, all, base, &all[base..base + len]);
        {
            let search = Rc::clone(search);
            let query = Rc::clone(query);
            list.set_filter_func(move |row| {
                search
                    .get(base + row.index().max(0) as usize)
                    .is_none_or(|text| matches_text(text, &query.borrow()))
            });
        }
        let header = label.map(|(label, duration)| disc_header(label, len, duration));
        Block {
            header,
            list,
            base,
            len,
        }
    }

    fn append_to(&self, parent: &gtk::Box) {
        if let Some(header) = &self.header {
            parent.append(header);
        }
        parent.append(&self.list);
    }

    fn refresh(&self, search: &[String], needle: &str) {
        self.list.invalidate_filter();
        let any = search[self.base..self.base + self.len]
            .iter()
            .any(|text| matches_text(text, needle));
        if let Some(header) = &self.header {
            header.set_visible(any);
        }
        self.list.set_visible(needle.is_empty() || any);
    }

    fn row_of(&self, index: usize) -> Option<gtk::ListBoxRow> {
        (index >= self.base && index < self.base + self.len)
            .then(|| self.list.row_at_index((index - self.base) as i32))
            .flatten()
    }
}

struct Section {
    label: String,
    duration: f64,
    base: usize,
    len: usize,
}

/// The songs of an album page in the layout the listener chose: the boxed
/// list, a sortable table, or discs flowed side by side across a wide window.
/// A layout is built the first time it is shown.
pub struct AlbumBody {
    pub widget: gtk::Box,
    ui: Rc<Ui>,
    album: Album,
    tracks: Rc<Vec<Track>>,
    search: Rc<Vec<String>>,
    sections: Option<Vec<Section>>,
    frame: Rc<Frame>,
    bar: ControlBar,
    stack: gtk::Stack,
    list_pane: gtk::Box,
    columns_pane: gtk::Box,
    query: Rc<RefCell<String>>,
    layout: Cell<TrackLayout>,
    list_blocks: RefCell<Vec<Block>>,
    column_blocks: RefCell<Vec<Block>>,
    columns_used: Cell<usize>,
    table: RefCell<Option<Rc<TrackTable>>>,
}

impl AlbumBody {
    pub fn new(ui: &Rc<Ui>, album: &Album, frame: &Rc<Frame>) -> Rc<AlbumBody> {
        let tracks = Rc::new(album.tracks.clone());
        let search = Rc::new(tracks.iter().map(search_text).collect::<Vec<_>>());
        let sections = disc_sections(&album.tracks).map(|sections| {
            let mut base = 0;
            sections
                .iter()
                .map(|section| {
                    let built = Section {
                        label: section.label.clone(),
                        duration: section.duration(),
                        base,
                        len: section.tracks.len(),
                    };
                    base += section.tracks.len();
                    built
                })
                .collect()
        });
        let saved = TrackLayout::from_id(&ui.core.config.borrow().detail_layout)
            .resolved_for(PageKind::Album);

        let stack = gtk::Stack::new();
        stack.set_hhomogeneous(false);
        stack.set_vhomogeneous(false);
        let list_pane = gtk::Box::new(gtk::Orientation::Vertical, 16);
        let columns_pane = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(20)
            .homogeneous(true)
            .valign(gtk::Align::Start)
            .build();
        stack.add_named(&list_pane, Some("list"));
        stack.add_named(&columns_pane, Some("columns"));

        let body = Rc::new_cyclic(|weak: &std::rc::Weak<AlbumBody>| {
            let bar = ControlBar::new(
                PageKind::Album,
                saved,
                {
                    let weak = weak.clone();
                    move |layout| {
                        if let Some(body) = weak.upgrade() {
                            body.choose(layout);
                        }
                    }
                },
                {
                    let weak = weak.clone();
                    move |needle| {
                        if let Some(body) = weak.upgrade() {
                            *body.query.borrow_mut() = needle.to_string();
                            body.apply_query();
                        }
                    }
                },
                {
                    let weak = weak.clone();
                    move || {
                        if let Some(body) = weak.upgrade() {
                            body.locate_playing();
                        }
                    }
                },
            );
            bar.show_filter(tracks.len() >= FILTER_THRESHOLD);
            let widget = gtk::Box::new(gtk::Orientation::Vertical, 16);
            widget.append(&bar.widget);
            widget.append(&stack);
            AlbumBody {
                widget,
                ui: Rc::clone(ui),
                album: album.clone(),
                tracks: Rc::clone(&tracks),
                search,
                sections,
                frame: Rc::clone(frame),
                bar,
                stack: stack.clone(),
                list_pane,
                columns_pane,
                query: Rc::new(RefCell::new(String::new())),
                layout: Cell::new(saved),
                list_blocks: RefCell::new(Vec::new()),
                column_blocks: RefCell::new(Vec::new()),
                columns_used: Cell::new(0),
                table: RefCell::new(None),
            }
        });
        {
            let weak = Rc::downgrade(&body);
            crate::ui::resize::watch_width(&stack, move |_, _| {
                if let Some(body) = weak.upgrade() {
                    if body.layout.get() == TrackLayout::Columns {
                        body.rebuild_columns(false);
                    }
                }
            });
        }
        body.show(saved);
        body
    }

    fn choose(&self, layout: TrackLayout) {
        if self.layout.get() == layout {
            return;
        }
        {
            let mut config = self.ui.core.config.borrow_mut();
            config.detail_layout = layout.id().to_string();
        }
        self.ui.core.save_config();
        self.show(layout);
        self.frame.scroll_to_top();
    }

    fn show(&self, layout: TrackLayout) {
        self.layout.set(layout);
        self.bar.set_layout(layout);
        match layout {
            TrackLayout::List => {
                self.ensure_list();
                self.stack.set_visible_child_name("list");
            }
            TrackLayout::Table => {
                self.ensure_table();
                self.stack.set_visible_child_name("table");
            }
            TrackLayout::Columns => {
                self.rebuild_columns(true);
                self.stack.set_visible_child_name("columns");
            }
        }
        self.apply_query();
    }

    fn blocks_for_list(&self) -> Vec<Block> {
        match &self.sections {
            Some(sections) => sections
                .iter()
                .map(|section| {
                    Block::new(
                        &self.ui,
                        &self.tracks,
                        &self.search,
                        section.base,
                        section.len,
                        Some((&section.label, section.duration)),
                        &self.query,
                    )
                })
                .collect(),
            None => vec![Block::new(
                &self.ui,
                &self.tracks,
                &self.search,
                0,
                self.tracks.len(),
                None,
                &self.query,
            )],
        }
    }

    fn ensure_list(&self) {
        if !self.list_blocks.borrow().is_empty() {
            return;
        }
        let blocks = self.blocks_for_list();
        for block in &blocks {
            block.append_to(&self.list_pane);
        }
        *self.list_blocks.borrow_mut() = blocks;
    }

    fn ensure_table(&self) {
        if self.table.borrow().is_some() {
            return;
        }
        let disc_of = self.sections.as_ref().map(|sections| {
            let mut labels = HashMap::new();
            for section in sections {
                for track in &self.tracks[section.base..section.base + section.len] {
                    labels.insert(track.rel_path.clone(), section.label.clone());
                }
            }
            Rc::new(labels)
        });
        let first_artist = self.tracks.first().map(|track| track.artist.clone());
        let options = TableOptions {
            kind: Some(PageKind::Album),
            disc_of,
            artists_vary: self
                .tracks
                .iter()
                .any(|track| Some(&track.artist) != first_artist.as_ref()),
        };
        let menu: Rc<crate::ui::songs::MenuHandler> = Rc::new(|track, anchor, x, y| {
            let menu = context::track_menu(&track.rel_path, track.loved);
            context::popup_menu_at(anchor, &menu, x, y);
        });
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
        table.set_tracks(&self.tracks);
        self.stack.add_named(&table.widget, Some("table"));
        *self.table.borrow_mut() = Some(Rc::new(table));
    }

    fn rebuild_columns(&self, force: bool) {
        let blocks = match &self.sections {
            Some(sections) => sections.len(),
            None => (self.tracks.len() / SONGS_PER_COLUMN).max(1),
        };
        let wanted = column_count(self.stack.width(), blocks);
        if !force && wanted == self.columns_used.get() {
            return;
        }
        self.columns_used.set(wanted);
        while let Some(child) = self.columns_pane.first_child() {
            self.columns_pane.remove(&child);
        }
        let mut built = Vec::new();
        let runs: Vec<Vec<Block>> = match &self.sections {
            Some(sections) => {
                let sizes: Vec<usize> = sections.iter().map(|section| section.len).collect();
                balance_columns(&sizes, wanted)
                    .into_iter()
                    .map(|range| {
                        sections[range]
                            .iter()
                            .map(|section| {
                                Block::new(
                                    &self.ui,
                                    &self.tracks,
                                    &self.search,
                                    section.base,
                                    section.len,
                                    Some((&section.label, section.duration)),
                                    &self.query,
                                )
                            })
                            .collect()
                    })
                    .collect()
            }
            None => even_runs(self.tracks.len(), wanted)
                .into_iter()
                .map(|range| {
                    vec![Block::new(
                        &self.ui,
                        &self.tracks,
                        &self.search,
                        range.start,
                        range.len(),
                        None,
                        &self.query,
                    )]
                })
                .collect(),
        };
        for column_blocks in runs {
            let column = gtk::Box::builder()
                .orientation(gtk::Orientation::Vertical)
                .spacing(12)
                .valign(gtk::Align::Start)
                .build();
            for block in column_blocks {
                block.append_to(&column);
                built.push(block);
            }
            self.columns_pane.append(&column);
        }
        *self.column_blocks.borrow_mut() = built;
        self.apply_query();
    }

    fn apply_query(&self) {
        let needle = self.query.borrow().clone();
        for block in self
            .list_blocks
            .borrow()
            .iter()
            .chain(self.column_blocks.borrow().iter())
        {
            block.refresh(&self.search, &needle);
        }
        if let Some(table) = self.table.borrow().as_ref() {
            table.set_query(&needle);
        }
        if needle.is_empty() {
            self.bar.set_status(None);
            return;
        }
        let shown = self
            .search
            .iter()
            .filter(|text| matches_text(text, &needle))
            .count();
        self.bar.set_status(Some(&if shown == 0 {
            "No songs match".to_string()
        } else {
            format!("{shown} of {}", self.tracks.len())
        }));
    }

    fn locate_playing(&self) {
        let Some(current) = self.ui.core.player.current_track() else {
            self.ui.core.toast("Nothing is playing");
            return;
        };
        let Some(index) = self
            .tracks
            .iter()
            .position(|track| track.rel_path == current.rel_path)
        else {
            self.ui.core.toast(&format!(
                "“{}” isn't on {}",
                current.title, self.album.title
            ));
            return;
        };
        if !self.query.borrow().is_empty() {
            self.query.borrow_mut().clear();
            self.apply_query();
            self.bar.clear_filter();
        }
        let table = self.table.borrow().clone();
        let layout = self.layout.get();
        let scroll = self.frame.scroll.clone();
        let rel_path = current.rel_path.clone();
        let blocks_rows: Vec<gtk::ListBoxRow> = match layout {
            TrackLayout::Table => Vec::new(),
            TrackLayout::List => self
                .list_blocks
                .borrow()
                .iter()
                .filter_map(|block| block.row_of(index))
                .collect(),
            TrackLayout::Columns => self
                .column_blocks
                .borrow()
                .iter()
                .filter_map(|block| block.row_of(index))
                .collect(),
        };
        gtk::glib::idle_add_local_once(move || match (layout, table) {
            (TrackLayout::Table, Some(table)) => {
                if let Some(position) = table.position_of(&rel_path) {
                    reveal_row(&scroll, &table, position);
                }
            }
            _ => {
                if let Some(row) = blocks_rows.first() {
                    reveal(&scroll, row);
                }
            }
        });
    }
}

/// A section header announcing a physical disc or vinyl side, e.g.
/// "Side A · 4 songs · 18 min", evoking the divider between records in a set.
fn disc_header(label: &str, count: usize, duration: f64) -> gtk::Box {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(10)
        .margin_start(4)
        .margin_end(6)
        .build();
    row.add_css_class("disc-header");
    let icon = gtk::Image::from_icon_name("media-optical-symbolic");
    icon.add_css_class("disc-header-icon");
    row.append(&icon);
    let name = gtk::Label::builder().label(label).xalign(0.0).build();
    name.add_css_class("disc-header-label");
    row.append(&name);
    let songs = if count == 1 {
        "1 song".to_string()
    } else {
        format!("{count} songs")
    };
    let meta = gtk::Label::builder()
        .label(format!(
            "{songs} · {} min",
            (duration / 60.0).round().max(1.0) as i64
        ))
        .hexpand(true)
        .xalign(1.0)
        .build();
    meta.add_css_class("disc-header-meta");
    row.append(&meta);
    row
}

/// Builds one boxed track list for a slice of an album's tracks. `base` is the
/// slice's offset within `all_tracks` so activating a row queues the whole
/// album from the correct position regardless of which disc section it sits in.
fn build_track_list(
    ui: &Rc<Ui>,
    all_tracks: &Rc<Vec<Track>>,
    base: usize,
    tracks: &[Track],
) -> gtk::ListBox {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    for track in tracks {
        let row_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .margin_top(10)
            .margin_bottom(10)
            .margin_start(12)
            .margin_end(12)
            .build();
        let index_cell = crate::ui::controls::track_index_cell(&if track.track_number > 0 {
            track.track_number.to_string()
        } else {
            "·".to_string()
        });
        row_box.append(&index_cell.widget);
        let track_title = gtk::Label::builder()
            .label(&track.title)
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::End)
            .tooltip_text(&track.title)
            .build();
        row_box.append(&track_title);
        let heart = gtk::Image::from_icon_name("emote-love-symbolic");
        heart.add_css_class("loved-heart");
        heart.set_visible(track.loved);
        row_box.append(&heart);
        if let Some(badge_text) = track.quality_badge() {
            let badge = gtk::Label::new(Some(&badge_text));
            badge.add_css_class("quality-badge");
            row_box.append(&badge);
        }
        let duration = gtk::Label::new(Some(&format_time(track.duration)));
        duration.add_css_class("duration-label");
        row_box.append(&duration);

        let row = gtk::ListBoxRow::builder().child(&row_box).build();
        context::attach_track_context_menu(&row, &ui.core, track.rel_path.clone());
        crate::ui::controls::attach_now_playing_row(
            ui,
            &row,
            &index_cell,
            &track_title,
            track.rel_path.clone(),
        );
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
        list.append(&row);
    }
    {
        let all_tracks = Rc::clone(all_tracks);
        let ui = Rc::clone(ui);
        list.connect_row_activated(move |_, row| {
            let index = base + row.index().max(0) as usize;
            ui.core.play_tracks((*all_tracks).clone(), index);
        });
    }
    list
}

