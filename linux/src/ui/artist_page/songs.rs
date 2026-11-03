//! The artist's top songs: what the world plays most (Last.fm's order, kept to
//! the songs the library owns) beside what the person plays most, five at a
//! time with room to show ten. A row plays the list from that song.

use crate::library::{format_time, Track};
use crate::ui::{artwork, context, controls, Ui};
use adw::prelude::*;
use flaccy_library::listen_history::title_key;
use flaccy_shared::load_progress::group_digits;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

pub const SHOWN: usize = 5;
pub const EXPANDED: usize = 10;
const THUMB: i32 = 44;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Pick {
    Popular,
    Mine,
}

struct State {
    popular: Vec<Track>,
    mine: Vec<Track>,
    /// The artist's songs in album order, shown when neither Last.fm nor the
    /// history has any.
    fallback: Vec<Track>,
    plays: HashMap<String, i64>,
    pick: Pick,
    /// What the person chose with the chips, which outlasts later arrivals.
    chosen: Option<Pick>,
    /// Whether Last.fm has answered or the page stopped waiting for it, before
    /// which nothing renders so the list does not jump from the person's songs
    /// to the world's.
    answered: bool,
    expanded: bool,
}

pub struct SongsSection {
    pub widget: gtk::Box,
    ui: Rc<Ui>,
    heading: gtk::Label,
    chips: gtk::Box,
    popular_chip: gtk::ToggleButton,
    mine_chip: gtk::ToggleButton,
    list: gtk::ListBox,
    more: gtk::Button,
    state: RefCell<State>,
    silent: Cell<bool>,
}

/// The library's songs by `names`, in that order, each once.
pub fn owned_in_order(names: &[String], owned: &[Track]) -> Vec<Track> {
    let mut by_key: HashMap<String, &Track> = HashMap::new();
    for track in owned {
        by_key
            .entry(title_key(&track.title))
            .and_modify(|kept| {
                if track.play_count > kept.play_count {
                    *kept = track;
                }
            })
            .or_insert(track);
    }
    let mut seen = std::collections::HashSet::new();
    names
        .iter()
        .filter_map(|name| {
            let key = title_key(name);
            if !seen.insert(key.clone()) {
                return None;
            }
            by_key.get(&key).map(|track| (*track).clone())
        })
        .collect()
}

impl SongsSection {
    pub fn new(ui: &Rc<Ui>) -> Rc<Self> {
        let widget = gtk::Box::new(gtk::Orientation::Vertical, 10);
        widget.set_hexpand(true);
        widget.set_visible(false);
        let header = gtk::Box::new(gtk::Orientation::Horizontal, 12);
        let heading = super::discography::section_heading("Top Songs");
        header.append(&heading);
        let chips = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        chips.set_valign(gtk::Align::Center);
        let popular_chip = gtk::ToggleButton::builder().label("Popular").active(true).build();
        let mine_chip = gtk::ToggleButton::builder().label("Your Top").build();
        for chip in [&popular_chip, &mine_chip] {
            chip.add_css_class("pill");
            chip.add_css_class("chip");
            chips.append(chip);
        }
        popular_chip.set_tooltip_text(Some("Most played on Last.fm"));
        mine_chip.set_tooltip_text(Some("Most played by you"));
        mine_chip.set_group(Some(&popular_chip));
        header.append(&chips);
        widget.append(&header);

        let list = gtk::ListBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .build();
        list.add_css_class("artist-songs");
        widget.append(&list);

        let more = gtk::Button::builder().halign(gtk::Align::Start).build();
        more.add_css_class("flat");
        more.add_css_class("artist-link");
        widget.append(&more);

        let section = Rc::new(Self {
            widget,
            ui: Rc::clone(ui),
            heading,
            chips,
            popular_chip,
            mine_chip,
            list,
            more,
            state: RefCell::new(State {
                popular: Vec::new(),
                mine: Vec::new(),
                fallback: Vec::new(),
                plays: HashMap::new(),
                pick: Pick::Popular,
                chosen: None,
                answered: false,
                expanded: false,
            }),
            silent: Cell::new(false),
        });
        {
            let weak = Rc::downgrade(&section);
            section.popular_chip.connect_toggled(move |chip| {
                if let Some(section) = weak.upgrade().filter(|_| chip.is_active()) {
                    section.choose(Pick::Popular);
                }
            });
        }
        {
            let weak = Rc::downgrade(&section);
            section.mine_chip.connect_toggled(move |chip| {
                if let Some(section) = weak.upgrade().filter(|_| chip.is_active()) {
                    section.choose(Pick::Mine);
                }
            });
        }
        {
            let weak = Rc::downgrade(&section);
            section.more.connect_clicked(move |_| {
                if let Some(section) = weak.upgrade() {
                    let expanded = !section.state.borrow().expanded;
                    section.state.borrow_mut().expanded = expanded;
                    section.render();
                }
            });
        }
        {
            let weak = Rc::downgrade(&section);
            section.list.connect_row_activated(move |_, row| {
                let Some(section) = weak.upgrade() else { return };
                let queue = section.current();
                let index = row.index().max(0) as usize;
                if index < queue.len() {
                    section.ui.core.play_tracks(queue, index);
                }
            });
        }
        section
    }

    /// The person's most played songs and plays per title key, known as soon
    /// as the history is read.
    pub fn set_mine(&self, mine: Vec<Track>, plays: HashMap<String, i64>) {
        {
            let mut state = self.state.borrow_mut();
            state.mine = mine;
            state.plays = plays;
        }
        self.settle();
    }

    /// The world's most played songs, known once Last.fm answers.
    pub fn set_popular(&self, popular: Vec<Track>) {
        {
            let mut state = self.state.borrow_mut();
            state.popular = popular;
            state.answered = true;
        }
        self.settle();
    }

    /// The artist's songs in album order, for an artist neither Last.fm nor
    /// the history knows.
    pub fn set_fallback(&self, songs: Vec<Track>) {
        self.state.borrow_mut().fallback = songs;
        self.settle();
    }

    /// Shows what is known when Last.fm is slow to answer, and keeps showing
    /// it when the answer lands later, so the list never moves under the
    /// pointer.
    pub fn stop_waiting(&self) {
        if self.state.borrow().answered {
            return;
        }
        self.state.borrow_mut().answered = true;
        self.settle();
        let mut state = self.state.borrow_mut();
        if !state.popular.is_empty() || !state.mine.is_empty() {
            state.chosen = Some(state.pick);
        }
    }

    fn settle(&self) {
        let (has_popular, has_mine, chosen, answered) = {
            let state = self.state.borrow();
            (!state.popular.is_empty(), !state.mine.is_empty(), state.chosen, state.answered)
        };
        if !answered {
            return;
        }
        self.chips.set_visible(has_popular && has_mine);
        let pick = match chosen {
            Some(Pick::Mine) if has_mine => Pick::Mine,
            Some(Pick::Popular) if has_popular => Pick::Popular,
            _ if has_popular => Pick::Popular,
            _ if has_mine => Pick::Mine,
            _ => Pick::Popular,
        };
        self.silent.set(true);
        match pick {
            Pick::Popular => self.popular_chip.set_active(true),
            Pick::Mine => self.mine_chip.set_active(true),
        }
        self.silent.set(false);
        self.state.borrow_mut().pick = pick;
        self.render();
    }

    fn choose(&self, pick: Pick) {
        if self.silent.get() || self.state.borrow().pick == pick {
            return;
        }
        let mut state = self.state.borrow_mut();
        state.pick = pick;
        state.chosen = Some(pick);
        drop(state);
        self.render();
    }

    fn current(&self) -> Vec<Track> {
        let state = self.state.borrow();
        let source = match state.pick {
            Pick::Popular if !state.popular.is_empty() => &state.popular,
            Pick::Mine if !state.mine.is_empty() => &state.mine,
            _ => &state.fallback,
        };
        source.iter().take(EXPANDED).cloned().collect()
    }

    fn render(&self) {
        while let Some(row) = self.list.first_child() {
            self.list.remove(&row);
        }
        let queue = self.current();
        let state = self.state.borrow();
        let shown = if state.expanded { EXPANDED } else { SHOWN };
        for (index, track) in queue.iter().take(shown).enumerate() {
            let plays = state
                .plays
                .get(&title_key(&track.title))
                .copied()
                .unwrap_or(track.play_count);
            self.list.append(&song_row(&self.ui, track, index + 1, plays));
        }
        let hidden = queue.len().saturating_sub(SHOWN);
        self.more.set_visible(hidden > 0);
        self.more.set_label(if state.expanded {
            "Show Less".to_string()
        } else {
            format!("Show {hidden} More")
        }
        .as_str());
        let title = if state.popular.is_empty() && state.mine.is_empty() {
            "Songs"
        } else if state.pick == Pick::Mine && !self.chips.is_visible() {
            "Your Top Songs"
        } else {
            "Top Songs"
        };
        self.heading.set_label(title);
        self.widget.set_visible(!queue.is_empty());
    }
}

fn song_row(ui: &Rc<Ui>, track: &Track, rank: usize, plays: i64) -> gtk::ListBoxRow {
    let row_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(14)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(10)
        .margin_end(14)
        .build();
    let cell = controls::track_index_cell(&rank.to_string());
    row_box.append(&cell.widget);

    let thumb = gtk::Picture::builder()
        .width_request(THUMB)
        .height_request(THUMB)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Center)
        .build();
    thumb.set_overflow(gtk::Overflow::Hidden);
    thumb.add_css_class("cover-thumb");
    let credit = track.credit().to_string();
    thumb.set_paintable(Some(
        &ui.core.artwork.placeholder(&format!("{}|{}", track.album, credit)),
    ));
    artwork::follow_picture(&ui.core, &thumb, &track.album, &credit, THUMB as u32);
    row_box.append(&thumb);

    let words = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(1)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .build();
    let title = gtk::Label::builder()
        .label(&track.title)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("artist-song-title");
    words.append(&title);
    let album = gtk::Label::builder()
        .label(&track.album)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    album.add_css_class("dim");
    album.add_css_class("caption");
    words.append(&album);
    row_box.append(&words);

    if track.loved {
        let heart = gtk::Image::from_icon_name("emblem-favorite-symbolic");
        heart.add_css_class("artist-song-loved");
        heart.set_tooltip_text(Some("Loved"));
        row_box.append(&heart);
    }
    let plays_label = gtk::Label::builder()
        .label(if plays > 0 { group_digits(plays as usize) } else { String::new() })
        .xalign(1.0)
        .width_chars(7)
        .build();
    plays_label.add_css_class("duration-label");
    if plays > 0 {
        plays_label.set_tooltip_text(Some(&super::listening::plays_text(plays)));
    }
    row_box.append(&plays_label);

    let duration = gtk::Label::builder()
        .label(format_time(track.duration))
        .xalign(1.0)
        .width_chars(5)
        .build();
    duration.add_css_class("duration-label");
    row_box.append(&duration);

    let row = gtk::ListBoxRow::builder().child(&row_box).build();
    row.add_css_class("artist-song");
    controls::attach_now_playing_row(ui, &row, &cell, &title, track.rel_path.clone());
    context::attach_track_context_menu(&row, &ui.core, track.rel_path.clone());
    row
}

#[cfg(test)]
mod tests {
    use super::*;

    fn track(title: &str, plays: i64) -> Track {
        Track {
            id: 0,
            rel_path: format!("A/{title}-{plays}.flac"),
            title: title.to_string(),
            artist: "A".to_string(),
            album: "Album".to_string(),
            album_artist: None,
            track_number: 1,
            duration: 200.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: plays,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    #[test]
    fn names_resolve_to_owned_songs_in_order_once_each() {
        let owned = vec![
            track("Enter Sandman", 3),
            track("Enter Sandman (Remastered)", 40),
            track("One", 1),
        ];
        let names = vec![
            "One".to_string(),
            "Unowned".to_string(),
            "Enter Sandman".to_string(),
            "ONE".to_string(),
        ];
        let resolved = owned_in_order(&names, &owned);
        let titles: Vec<&str> = resolved.iter().map(|t| t.title.as_str()).collect();
        assert_eq!(titles, vec!["One", "Enter Sandman (Remastered)"]);
    }
}
