//! The Home page: what to listen to next, built on this device from the
//! library, the play history and what the person started.
//!
//! The page is a function of a `HomeModel` (see `home_data`) and the width it
//! has. It rebuilds its widgets only when the model or the arrangement
//! changes, never on a playback tick, and it holds no timer or tick callback:
//! with nothing playing and nothing downloading it asks the frame clock for
//! nothing at all.

use crate::events::AppEvent;
use crate::home_data::{self, AlbumIndex, Fetched, HeroModel, HomeModel, Inputs};
use crate::library::Library;
use crate::ui::home_backdrop::HomeBackdrop;
use crate::ui::home_parts as parts;
use crate::ui::mosaic::AlbumRef;
use crate::ui::{albums, controls, playlists, resize, Ui};
use adw::prelude::*;
use flaccy_shared::home::{Block, Layout, Section};
use flaccy_shared::home_copy;
use flaccy_shared::track_page_layout::{page_mode, PageMode};
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::rc::Rc;

/// How tall the wash of the hero's colors behind the top of the page is.
const BACKDROP_HEIGHT: i32 = 460;
const CONTENT_MAX_WIDTH: i32 = 1240;

struct State {
    ui: Rc<Ui>,
    scroll: gtk::ScrolledWindow,
    body: gtk::Box,
    backdrop: HomeBackdrop,
    mode: Cell<Option<PageMode>>,
    fetched: RefCell<Fetched>,
    index: RefCell<(Rc<Library>, Rc<AlbumIndex>)>,
    fetching: Cell<bool>,
    fetch_again: Cell<Option<bool>>,
    render_queued: Cell<bool>,
    dirty: Cell<bool>,
    fingerprint: RefCell<String>,
    jump_expanded: Cell<bool>,
    backdrop_for: RefCell<Option<AlbumRef>>,
    download_fractions: RefCell<HashMap<i64, f64>>,
    downloads_live: RefCell<Option<(gtk::Label, gtk::ProgressBar)>>,
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let body = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(28)
        .build();
    body.add_css_class("home-body");
    let clamp = adw::Clamp::builder()
        .maximum_size(CONTENT_MAX_WIDTH)
        .tightening_threshold(CONTENT_MAX_WIDTH)
        .valign(gtk::Align::Start)
        .child(&body)
        .build();

    let backdrop = HomeBackdrop::new();
    backdrop.set_height_request(BACKDROP_HEIGHT);
    backdrop.set_hexpand(true);
    backdrop.set_valign(gtk::Align::Start);
    backdrop.set_can_target(false);
    backdrop.add_css_class("home-backdrop");
    backdrop.set_visible(false);
    let wash = backdrop.clone();

    let page = gtk::Overlay::new();
    page.set_child(Some(&wash));
    page.add_overlay(&clamp);
    page.set_measure_overlay(&clamp, true);

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .vexpand(true)
        .child(&page)
        .build();
    scroll.add_css_class("home-page");
    ui.register_scroller(&scroll);

    let library = ui.core.library.borrow().clone();
    let state = Rc::new(State {
        ui: Rc::clone(ui),
        scroll: scroll.clone(),
        body,
        backdrop,
        mode: Cell::new(None),
        fetched: RefCell::new(Fetched::default()),
        index: RefCell::new((Rc::clone(&library), Rc::new(AlbumIndex::new(&library)))),
        fetching: Cell::new(false),
        fetch_again: Cell::new(None),
        render_queued: Cell::new(false),
        dirty: Cell::new(true),
        fingerprint: RefCell::new(String::new()),
        jump_expanded: Cell::new(false),
        backdrop_for: RefCell::new(None),
        download_fractions: RefCell::new(HashMap::new()),
        downloads_live: RefCell::new(None),
    });

    {
        let state = Rc::clone(&state);
        resize::watch_width(&scroll, move |width, _| {
            let mode = page_mode(width);
            if state.mode.replace(Some(mode)) != Some(mode) {
                state.render();
            }
        });
    }
    {
        let state = Rc::clone(&state);
        scroll.connect_map(move |_| state.render());
    }
    {
        let state = Rc::clone(&state);
        ui.core
            .hub
            .subscribe_widget(&scroll, move |_, event| match event {
                AppEvent::LibraryReloaded | AppEvent::HistoryImport { done: true, .. } => {
                    state.refresh(true)
                }
                AppEvent::NaturalEnd(_) => state.refresh(false),
                AppEvent::TrackChanged(_)
                | AppEvent::PlayingChanged(_)
                | AppEvent::HomeChanged
                | AppEvent::DownloadsChanged
                | AppEvent::ScanFinished { .. } => state.render_soon(),
                AppEvent::DownloadProgress { id, fraction } => {
                    state.note_download_progress(*id, *fraction)
                }
                _ => {}
            });
    }
    state.refresh(true);
    schedule_demo(ui);
    scroll.upcast()
}

impl State {
    /// Asks the database for what the cards need, off the main thread, then
    /// draws. `with_mixes` is only true when the library or the history changed
    /// underneath the mixes: they read the whole scrobble table.
    fn refresh(self: &Rc<Self>, with_mixes: bool) {
        if self.fetching.replace(true) {
            let wants = self.fetch_again.get().unwrap_or(false) || with_mixes;
            self.fetch_again.set(Some(wants));
            return;
        }
        let library = self.ui.core.library.borrow().clone();
        let pool = if with_mixes {
            library.tracks.clone()
        } else {
            Vec::new()
        };
        let previous = self.fetched.borrow().mixes.clone();
        let db_path = self.ui.core.db_path.clone();
        let now = chrono::Utc::now().timestamp();
        let offset = local_offset();
        let (tx, rx) = async_channel::bounded::<Fetched>(1);
        std::thread::Builder::new()
            .name("flaccy-home".into())
            .spawn(move || {
                let _ = tx.send_blocking(home_data::fetch(
                    &db_path, pool, previous, with_mixes, now, offset,
                ));
            })
            .ok();
        let state = Rc::clone(self);
        glib::spawn_future_local(async move {
            let fetched = rx.recv().await.ok();
            state.fetching.set(false);
            if let Some(fetched) = fetched {
                *state.fetched.borrow_mut() = fetched;
            }
            state.render();
            if let Some(with_mixes) = state.fetch_again.take() {
                state.refresh(with_mixes);
            }
        });
    }

    fn render_soon(self: &Rc<Self>) {
        if self.render_queued.replace(true) {
            return;
        }
        let state = Rc::clone(self);
        glib::idle_add_local_once(move || {
            state.render_queued.set(false);
            state.render();
        });
    }

    fn album_index(&self, library: &Rc<Library>) -> Rc<AlbumIndex> {
        let mut slot = self.index.borrow_mut();
        if !Rc::ptr_eq(&slot.0, library) {
            *slot = (Rc::clone(library), Rc::new(AlbumIndex::new(library)));
        }
        Rc::clone(&slot.1)
    }

    fn layout(&self) -> Layout {
        let config = self.ui.core.config.borrow();
        Layout::decode(Some(&config.home_layout))
    }

    fn compose(&self, layout: &Layout) -> HomeModel {
        let ui = &self.ui;
        let library = ui.core.library.borrow().clone();
        let index = self.album_index(&library);
        let playlists = playlists::load_cards(ui);
        let session = ui.core.last_session.borrow().clone();
        let recents = ui.core.recents.borrow().clone();
        let fetched = self.fetched.borrow();
        home_data::compose(&Inputs {
            library: &library,
            index: &index,
            fetched: &fetched,
            session: session.as_ref(),
            recents: &recents,
            playlists: &playlists,
            layout,
            has_history: ui.core.db.has_scrobbles(),
            is_playing: ui.core.player.is_playing(),
            downloads: ui.core.db.active_download_count().max(0) as usize,
            now: chrono::Utc::now().timestamp(),
            offset: local_offset(),
        })
    }

    fn render(self: &Rc<Self>) {
        if !self.scroll.is_mapped() {
            self.dirty.set(true);
            return;
        }
        let Some(mode) = self.mode.get() else { return };
        self.dirty.set(false);
        let layout = self.layout();
        let model = self.compose(&layout);
        let fingerprint = format!(
            "{mode:?}|{}|{}|{}",
            layout.encoded(),
            self.jump_expanded.get(),
            model.fingerprint()
        );
        if *self.fingerprint.borrow() == fingerprint {
            return;
        }
        *self.fingerprint.borrow_mut() = fingerprint;
        self.rebuild(&model, mode);
    }

    fn rebuild(self: &Rc<Self>, model: &HomeModel, mode: PageMode) {
        while let Some(child) = self.body.first_child() {
            self.body.remove(&child);
        }
        self.downloads_live.borrow_mut().take();
        let (edge, gap) = match mode {
            PageMode::Compact => (16, 22),
            PageMode::Regular => (32, 26),
            PageMode::Wide => (32, 28),
        };
        self.body.set_margin_start(edge);
        self.body.set_margin_end(edge);
        self.body
            .set_margin_top(if mode == PageMode::Compact { 20 } else { 32 });
        self.body.set_margin_bottom(32);
        self.body.set_spacing(gap);

        if model.facts.library_track_count == 0 {
            self.set_backdrop(None);
            self.body.append(&albums::build_empty_state(&self.ui));
            return;
        }

        let mut sections = self.sections(model, mode);
        let hero_shown = model
            .blocks
            .iter()
            .any(|block| matches!(block, Block::Single(Section::Resume)));
        if model.downloads > 0 {
            let card = self.downloads_card(model.downloads);
            let strip_beside_hero = sections
                .iter_mut()
                .take(2)
                .find(|section| section.is_strip);
            match strip_beside_hero {
                Some(strip) => strip.cards.push(card),
                None => {
                    let at = sections.len().min(1);
                    sections.insert(
                        at,
                        Slot {
                            is_strip: true,
                            cards: vec![card],
                            widget: None,
                        },
                    );
                }
            }
        }
        for section in sections {
            self.body.append(&section.into_widget(mode));
        }
        let lead = hero_shown.then(|| model.hero_lead.clone()).flatten();
        self.set_backdrop(lead);
    }

    fn downloads_card(self: &Rc<Self>, count: usize) -> gtk::Widget {
        let fraction = self.download_fraction();
        let card = parts::downloads_card(&self.ui, count, fraction);
        *self.downloads_live.borrow_mut() = Some((card.percent.clone(), card.bar.clone()));
        card.widget
    }

    fn download_fraction(&self) -> f64 {
        let fractions = self.download_fractions.borrow();
        if fractions.is_empty() {
            return 0.0;
        }
        fractions.values().sum::<f64>() / fractions.len() as f64
    }

    /// A download moved: the card's percent and bar are rewritten in place, so
    /// a progress event never rebuilds the page.
    fn note_download_progress(&self, id: i64, fraction: f64) {
        {
            let mut fractions = self.download_fractions.borrow_mut();
            if fraction >= 1.0 {
                fractions.remove(&id);
            } else {
                fractions.insert(id, fraction);
            }
        }
        let overall = self.download_fraction();
        if let Some((percent, bar)) = self.downloads_live.borrow().as_ref() {
            percent.set_label(&parts::percent_text(overall));
            bar.set_fraction(overall);
        }
    }

    /// The wash behind the top of the page: the hero's album, blurred once off
    /// the main thread into a small texture and drawn as one textured
    /// rectangle, the same way Now Playing does it.
    fn set_backdrop(&self, lead: Option<AlbumRef>) {
        let Some((title, artist)) = lead else {
            self.backdrop.set_visible(false);
            *self.backdrop_for.borrow_mut() = None;
            return;
        };
        self.backdrop.set_visible(true);
        if self.backdrop_for.borrow().as_ref() != Some(&(title.clone(), artist.clone())) {
            self.backdrop.set_paintable(Some(
                self.ui
                    .core
                    .artwork
                    .placeholder(&format!("{title}|{artist}"))
                    .upcast_ref(),
            ));
        }
        *self.backdrop_for.borrow_mut() = Some((title.clone(), artist.clone()));
        let weak = self.backdrop.downgrade();
        self.ui
            .core
            .artwork
            .request_backdrop(&title, &artist, move |texture| {
                if let (Some(texture), Some(backdrop)) = (texture, weak.upgrade()) {
                    backdrop.set_paintable(Some(texture.upcast_ref()));
                }
            });
    }

    fn accent_hearing(&self) -> crate::ui::mosaic::OnColor {
        let ui = Rc::clone(&self.ui);
        Rc::new(move |color| {
            if !ui.core.player.is_playing() {
                controls::set_adaptive_accent(Some(color));
            }
        })
    }

    fn hero_widget(self: &Rc<Self>, model: &HomeModel, mode: PageMode) -> Option<gtk::Widget> {
        let on_color = self.accent_hearing();
        match &model.hero {
            HeroModel::Resume(hero) => Some(parts::resume_hero(&self.ui, hero, mode, on_color)),
            HeroModel::UpNext(hero) => Some(parts::mix_hero(&self.ui, hero, mode, on_color)),
            HeroModel::DayOne(hero) => Some(parts::day_one_hero(&self.ui, hero, mode, on_color)),
            HeroModel::Empty => None,
        }
    }

    fn jump_widget(self: &Rc<Self>, model: &HomeModel, mode: PageMode) -> gtk::Widget {
        let state = Rc::clone(self);
        parts::jump_list(
            &self.ui,
            &model.jump,
            mode,
            self.jump_expanded.get(),
            Rc::new(move || {
                state.jump_expanded.set(true);
                state.render();
            }),
        )
    }

    fn jump_section(self: &Rc<Self>, model: &HomeModel, mode: PageMode) -> gtk::Widget {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 12);
        column.append(&parts::section_heading(home_copy::JUMP_BACK_IN, None));
        column.append(&self.jump_widget(model, mode));
        column.upcast()
    }

    /// The page as a list of sections in the person's order: the hero (with
    /// Jump Back In beside it when there is room), strips of small cards, and
    /// the two shelves.
    fn sections(self: &Rc<Self>, model: &HomeModel, mode: PageMode) -> Vec<Slot> {
        let mut sections = Vec::new();
        let mut position = 0;
        while position < model.blocks.len() {
            let block = model.blocks[position];
            position += 1;
            match block {
                Block::Single(Section::Resume) => {
                    let Some(hero) = self.hero_widget(model, mode) else {
                        continue;
                    };
                    let beside = mode == PageMode::Wide
                        && !model.jump.is_empty()
                        && model.blocks.get(position) == Some(&Block::Single(Section::JumpBackIn));
                    if beside {
                        position += 1;
                        let row = gtk::Box::new(gtk::Orientation::Horizontal, 32);
                        hero.set_hexpand(true);
                        hero.set_valign(gtk::Align::Start);
                        row.append(&hero);
                        let jump = self.jump_section(model, mode);
                        jump.set_size_request(parts::JUMP_BACK_IN_WIDTH, -1);
                        jump.set_valign(gtk::Align::Start);
                        row.append(&jump);
                        sections.push(Slot::widget(row.upcast()));
                    } else {
                        sections.push(Slot::widget(hero));
                    }
                }
                Block::Single(Section::JumpBackIn) => {
                    sections.push(Slot::widget(self.jump_section(model, mode)));
                }
                Block::Single(Section::MadeForYou) => {
                    sections.push(Slot::widget(self.made_for_you(model, mode)));
                }
                Block::Single(Section::RecentlyAdded) => {
                    sections.push(Slot::widget(self.recently_added(model)));
                }
                Block::Single(section) => {
                    if let Some(card) = self.strip_card(model, section) {
                        sections.push(Slot::strip(vec![card]));
                    }
                }
                Block::Pair(first, second) => {
                    let cards: Vec<gtk::Widget> = [first, second]
                        .into_iter()
                        .filter_map(|section| self.strip_card(model, section))
                        .collect();
                    if !cards.is_empty() {
                        sections.push(Slot::strip(cards));
                    }
                }
            }
        }
        sections
    }

    fn strip_card(&self, model: &HomeModel, section: Section) -> Option<gtk::Widget> {
        match section {
            Section::OnThisDay => model
                .otd
                .as_ref()
                .map(|card| parts::on_this_day_card(&self.ui, card)),
            Section::ThisWeek => Some(parts::this_week_card(&self.ui, &model.week)),
            _ => None,
        }
    }

    fn made_for_you(self: &Rc<Self>, model: &HomeModel, mode: PageMode) -> gtk::Widget {
        let side = if mode == PageMode::Compact {
            parts::MIX_TILE_COMPACT
        } else {
            parts::MIX_TILE
        };
        let column = gtk::Box::new(gtk::Orientation::Vertical, 8);
        let ui = Rc::clone(&self.ui);
        column.append(&parts::section_heading(
            home_copy::MADE_FOR_YOU,
            Some((
                home_copy::SEE_ALL,
                Box::new(move || {
                    let _ = gtk::prelude::WidgetExt::activate_action(
                        &ui.window,
                        "win.show-page",
                        Some(&"playlists".to_variant()),
                    );
                }),
            )),
        ));
        let mut tiles: Vec<gtk::Widget> = model
            .mixes
            .iter()
            .map(|card| parts::mix_tile(&self.ui, card, side))
            .collect();
        let mixes = model
            .mixes
            .iter()
            .filter(|card| matches!(card.kind, home_data::MixKind::Mix(_)))
            .count();
        if mixes < 2 {
            tiles.push(parts::placeholder_tile(side));
        }
        column.append(&parts::shelf(tiles, &self.scroll));
        column.upcast()
    }

    fn recently_added(self: &Rc<Self>, model: &HomeModel) -> gtk::Widget {
        let column = gtk::Box::new(gtk::Orientation::Vertical, 8);
        column.append(&parts::section_heading(home_copy::RECENTLY_ADDED, None));
        let tiles: Vec<gtk::Widget> = model
            .recent
            .iter()
            .map(|card| parts::album_tile(&self.ui, card))
            .collect();
        column.append(&parts::shelf(tiles, &self.scroll));
        column.upcast()
    }
}

/// One entry in the page's vertical flow: a finished widget, or a strip of
/// small cards that is laid out once the cards (the Downloads one may join
/// late) are all known.
struct Slot {
    is_strip: bool,
    cards: Vec<gtk::Widget>,
    widget: Option<gtk::Widget>,
}

impl Slot {
    fn widget(widget: gtk::Widget) -> Slot {
        Slot {
            is_strip: false,
            cards: Vec::new(),
            widget: Some(widget),
        }
    }

    fn strip(cards: Vec<gtk::Widget>) -> Slot {
        Slot {
            is_strip: true,
            cards,
            widget: None,
        }
    }

    /// Cards sit in equal columns: up to three across when wide, two when
    /// regular, wrapping to one at phone width.
    fn into_widget(self, mode: PageMode) -> gtk::Widget {
        if let Some(widget) = self.widget {
            return widget;
        }
        let flow = gtk::FlowBox::builder()
            .selection_mode(gtk::SelectionMode::None)
            .homogeneous(true)
            .min_children_per_line(1)
            .max_children_per_line(match mode {
                PageMode::Wide => self.cards.len().clamp(1, 3) as u32,
                PageMode::Regular => 2,
                PageMode::Compact => 1,
            })
            .column_spacing(12)
            .row_spacing(12)
            .valign(gtk::Align::Start)
            .build();
        for card in self.cards {
            card.set_hexpand(true);
            let child = gtk::FlowBoxChild::builder().child(&card).build();
            child.set_focusable(false);
            flow.append(&child);
        }
        flow.upcast()
    }
}

/// Seconds east of UTC for the local zone, now.
fn local_offset() -> i32 {
    use chrono::Offset;
    chrono::Local::now().offset().fix().local_minus_utc()
}

/// Opens Home in the state `FLACCY_DEMO_HOME` names (wide, narrow, dayone,
/// playing, customize), for screenshots without input automation.
fn schedule_demo(ui: &Rc<Ui>) {
    if !crate::config::demo_mode() {
        return;
    }
    let Ok(mode) = std::env::var("FLACCY_DEMO_HOME") else {
        return;
    };
    if mode == "customize" {
        let ui = Rc::clone(ui);
        glib::timeout_add_local_once(std::time::Duration::from_millis(1800), move || {
            crate::ui::home_customize::present(&ui);
        });
    }
}
