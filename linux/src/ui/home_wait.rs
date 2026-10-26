//! The shape of Home while its first feed is still being read: a hero, a few
//! tiles and a shelf of mixes, drawn as soft blocks that breathe.
//!
//! It is invisible for `PATIENCE_MS` after it appears on screen, so a quick
//! launch goes straight to the finished page, and it animates only while it is
//! mapped. Its owner removes it once the feed has faded in, because a CSS
//! animation on a widget that merely sits hidden would keep the frame clock
//! cycling for as long as the window lives.

use crate::ui::home_parts::{JUMP_BACK_IN_WIDTH, MIX_TILE, MIX_TILE_COMPACT};
use adw::prelude::*;
use flaccy_shared::track_page_layout::PageMode;
use gtk::glib;
use std::cell::RefCell;
use std::rc::Rc;
use std::time::Duration;

pub const PATIENCE_MS: u64 = 250;
pub const CROSSFADE_MS: u32 = 300;

const SHOWN_CLASS: &str = "shown";
const TILE_HEIGHT: i32 = 56;
const TILE_GAP: i32 = 10;
const MIX_BLOCKS: usize = 8;
const PULSE_LAGS: [&str; 3] = ["home-wait-lag-0", "home-wait-lag-1", "home-wait-lag-2"];

pub struct HomeWait {
    root: gtk::Box,
}

impl HomeWait {
    pub fn new() -> Self {
        let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
        root.add_css_class("home-wait");
        root.set_can_target(false);
        root.set_valign(gtk::Align::Start);
        root.update_property(&[gtk::accessible::Property::Label("Loading your library")]);
        wait_for_patience(&root);
        Self { root }
    }

    pub fn widget(&self) -> &gtk::Box {
        &self.root
    }

    /// Redraws the blocks for the room the page has: the tiles beside the hero
    /// when wide, under it otherwise.
    pub fn arrange(&self, mode: PageMode) {
        while let Some(child) = self.root.first_child() {
            self.root.remove(&child);
        }
        let compact = mode == PageMode::Compact;
        let edge = if compact { 16 } else { 32 };
        self.root.set_spacing(if compact { 22 } else { 26 });
        self.root.set_margin_start(edge);
        self.root.set_margin_end(edge);
        self.root.set_margin_top(if compact { 20 } else { 32 });
        self.root.set_margin_bottom(32);
        let hero = hero_block(mode);
        let tiles = tiles_column();
        if mode == PageMode::Wide {
            let row = gtk::Box::new(gtk::Orientation::Horizontal, 32);
            hero.set_hexpand(true);
            tiles.set_size_request(JUMP_BACK_IN_WIDTH, -1);
            tiles.set_valign(gtk::Align::Start);
            row.append(&hero);
            row.append(&tiles);
            self.root.append(&row);
        } else {
            self.root.append(&hero);
            self.root.append(&tiles);
        }
        let side = if mode == PageMode::Compact {
            MIX_TILE_COMPACT
        } else {
            MIX_TILE
        };
        self.root.append(&shelf_column(side));
    }
}

/// Starts the fade-in `PATIENCE_MS` after the blocks reach the screen, and
/// puts them back to invisible and still when they leave it.
fn wait_for_patience(root: &gtk::Box) {
    let pending: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
    {
        let pending = Rc::clone(&pending);
        root.connect_map(move |root| {
            let root = root.clone();
            let arrived = Rc::clone(&pending);
            let id = glib::timeout_add_local_once(Duration::from_millis(PATIENCE_MS), move || {
                arrived.borrow_mut().take();
                root.add_css_class(SHOWN_CLASS);
            });
            if let Some(stale) = pending.borrow_mut().replace(id) {
                stale.remove();
            }
        });
    }
    root.connect_unmap(move |root| {
        if let Some(id) = pending.borrow_mut().take() {
            id.remove();
        }
        root.remove_css_class(SHOWN_CLASS);
    });
}

fn block(width: i32, height: i32, classes: &[&str]) -> gtk::Box {
    let block = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    block.set_size_request(width, height);
    block.add_css_class("home-wait-block");
    for class in classes {
        block.add_css_class(class);
    }
    block
}

fn lagged(block: gtk::Box, index: usize) -> gtk::Box {
    block.add_css_class(PULSE_LAGS[index % PULSE_LAGS.len()]);
    block
}

fn title_bar(width: i32) -> gtk::Box {
    let bar = block(width, 20, &["home-wait-bar"]);
    bar.set_halign(gtk::Align::Start);
    bar
}

/// The hero's outline with the cover, three lines of words and the buttons
/// where the real card puts them.
fn hero_block(mode: PageMode) -> gtk::Box {
    let cover = match mode {
        PageMode::Wide => 200,
        PageMode::Regular => 168,
        PageMode::Compact => 120,
    };
    let hero = block(-1, -1, &["home-wait-hero"]);
    hero.set_orientation(gtk::Orientation::Vertical);
    hero.set_spacing(14);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 16);
    top.set_margin_top(16);
    top.set_margin_start(16);
    top.set_margin_end(16);
    top.append(&inner(cover, cover));
    let words = gtk::Box::new(gtk::Orientation::Vertical, 10);
    words.set_hexpand(true);
    words.set_margin_top(4);
    for (width, height) in [(120, 13), (220, 22), (160, 13)] {
        let line = inner(width, height);
        line.set_halign(gtk::Align::Start);
        line.add_css_class("home-wait-bar");
        words.append(&line);
    }
    top.append(&words);
    hero.append(&top);
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    buttons.set_margin_start(16);
    buttons.set_margin_end(16);
    buttons.set_margin_bottom(16);
    let play = inner(-1, 48);
    play.set_hexpand(true);
    play.add_css_class("home-wait-pill");
    buttons.append(&play);
    for _ in 0..2 {
        let round = inner(48, 48);
        round.add_css_class("home-wait-pill");
        buttons.append(&round);
    }
    hero.append(&buttons);
    hero
}

fn inner(width: i32, height: i32) -> gtk::Box {
    let inner = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    inner.set_size_request(width, height);
    inner.add_css_class("home-wait-inner");
    inner
}

fn tiles_column() -> gtk::Box {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
    column.append(&title_bar(150));
    let grid = gtk::Grid::builder()
        .column_spacing(TILE_GAP)
        .row_spacing(TILE_GAP)
        .column_homogeneous(true)
        .hexpand(true)
        .build();
    for index in 0..4 {
        let tile = lagged(block(-1, TILE_HEIGHT, &["home-wait-tile"]), index);
        tile.set_hexpand(true);
        grid.attach(&tile, (index % 2) as i32, (index / 2) as i32, 1, 1);
    }
    column.append(&grid);
    column
}

fn shelf_column(side: i32) -> gtk::Box {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
    column.append(&title_bar(128));
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    for index in 0..MIX_BLOCKS {
        row.append(&lagged(block(side, side, &["home-wait-mix"]), index));
    }
    let clip = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::External)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .propagate_natural_width(false)
        .propagate_natural_height(true)
        .can_target(false)
        .child(&row)
        .build();
    column.append(&clip);
    column
}
