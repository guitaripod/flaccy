use crate::events::AppEvent;
use crate::library::{format_time, Track};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::gdk;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// Rendered queue window sizes — the queue can hold thousands of tracks, so
/// only a bounded slice around the now-playing row becomes widgets (the rest
/// is summarized), keeping every rebuild off the main-thread hot path.
const HISTORY_LIMIT: usize = 20;
const UP_NEXT_LIMIT: usize = 120;

/// Queue side panel with History / Now Playing / Up Next sections: click a
/// history row to jump back, drag-reorder Up Next, per-row remove, Clear Up
/// Next, and a time-remaining summary. Live-updates from player events.
/// Placement options so the sidebar and the in-view (Now Playing lens) share
/// one implementation. The in-view instance drops its own "Queue" title (the
/// ViewStack switcher labels it) and lets Now Playing drive the rebuild after
/// the crossfade instead of rebuilding on its own map.
pub struct QueueOptions {
    pub show_title: bool,
    pub bottom_margin: i32,
    pub self_map_rebuild: bool,
    /// Whether the panel starts live. The sidebar is always live; the in-view
    /// instance starts inactive so it doesn't rebuild ~140 rows on every track
    /// change while its column is collapsed — Now Playing activates it on reveal.
    pub initial_active: bool,
}

impl QueueOptions {
    pub fn sidebar() -> Self {
        Self { show_title: true, bottom_margin: 12, self_map_rebuild: true, initial_active: true }
    }
    pub fn in_view() -> Self {
        Self { show_title: false, bottom_margin: 8, self_map_rebuild: false, initial_active: false }
    }
}

pub struct QueuePanel {
    pub widget: gtk::Widget,
    /// Activate/deactivate the panel: while inactive it ignores queue events;
    /// activating rebuilds and pins the now-playing row. Drive it from the
    /// reveal toggle for the in-view instance.
    pub set_active: Rc<dyn Fn(bool)>,
}

pub fn build(ui: &Rc<Ui>, opts: QueueOptions) -> QueuePanel {
    let root = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(0)
        .build();

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .margin_top(14)
        .margin_bottom(8)
        .margin_start(16)
        .margin_end(16)
        .build();
    let title = gtk::Label::builder().label("Queue").xalign(0.0).hexpand(true).build();
    title.add_css_class("title-4");
    if opts.show_title {
        header.append(&title);
    }
    let clear = gtk::Button::with_label("Clear Up Next");
    clear.set_hexpand(true);
    clear.set_halign(gtk::Align::End);
    clear.add_css_class("flat");
    clear.add_css_class("caption");
    {
        let ui = Rc::clone(ui);
        clear.connect_clicked(move |_| {
            ui.core.player.clear_up_next();
            crate::logger::info("ui", "queue: clear up next");
        });
    }
    header.append(&clear);
    root.append(&header);

    let summary = gtk::Label::builder().xalign(0.0).margin_start(16).margin_end(16).build();
    summary.add_css_class("dim");
    summary.add_css_class("caption");
    root.append(&summary);

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .margin_top(10)
        .margin_bottom(opts.bottom_margin)
        .margin_start(10)
        .margin_end(10)
        .valign(gtk::Align::Start)
        .build();
    list.add_css_class("boxed-list-separate");

    let empty = adw::StatusPage::builder()
        .icon_name("view-list-symbolic")
        .title("Nothing Queued")
        .description("Play an album, playlist or station and the queue shows up here.")
        .build();
    empty.add_css_class("compact");

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vexpand(true)
        .child(&list)
        .build();
    stack.add_named(&scroll, Some("list"));
    root.append(&stack);

    let indices: Rc<RefCell<Vec<usize>>> = Rc::new(RefCell::new(Vec::new()));
    let pinner = Pinner::new(&scroll, &list);
    {
        let pinner = Rc::clone(&pinner);
        let scroll_controller =
            gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
        scroll_controller.connect_scroll(move |_, _, _| {
            pinner.abandon();
            glib::Propagation::Proceed
        });
        scroll.add_controller(scroll_controller);
    }

    let rebuild = {
        let list = list.clone();
        let stack = stack.clone();
        let scroll = scroll.clone();
        let summary = summary.clone();
        let clear = clear.clone();
        let indices = Rc::clone(&indices);
        let pinner = Rc::clone(&pinner);
        let ui = Rc::clone(ui);
        Rc::new(move |pin_now_playing: bool| {
            let keep_offset = (!pin_now_playing && !pinner.is_pending())
                .then(|| scroll.vadjustment().value());
            if pin_now_playing {
                pinner.request();
            }
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            let snapshot = ui.core.player.queue_snapshot();
            if snapshot.queue.is_empty() {
                stack.set_visible_child_name("empty");
                summary.set_label("");
                clear.set_sensitive(false);
                indices.borrow_mut().clear();
                pinner.set_anchor(None);
                return;
            }
            stack.set_visible_child_name("list");
            let current = snapshot.current;
            let up_next_count = snapshot.queue.len().saturating_sub(current + 1);
            clear.set_sensitive(up_next_count > 0);
            let remaining: f64 = snapshot.queue[(current + 1).min(snapshot.queue.len())..]
                .iter()
                .map(|t| t.duration)
                .sum();
            summary.set_label(&format!(
                "{} in history · {} up next · {} min remaining",
                current,
                up_next_count,
                (remaining / 60.0).round() as i64
            ));

            let history_start = current.saturating_sub(HISTORY_LIMIT);
            let up_next_end = (current + 1 + UP_NEXT_LIMIT).min(snapshot.queue.len());

            let mut collected = Vec::new();
            let mut now_playing_anchor: Option<gtk::ListBoxRow> = None;
            if current > 0 {
                if history_start > 0 {
                    list.append(&info_row(&format!("{} earlier", history_start)));
                    collected.push(usize::MAX);
                }
                list.append(&section_row("HISTORY"));
                collected.push(usize::MAX);
            }
            for index in history_start..up_next_end {
                let track = &snapshot.queue[index];
                if index == current {
                    let heading = section_row("NOW PLAYING");
                    now_playing_anchor = Some(heading.clone());
                    list.append(&heading);
                    collected.push(usize::MAX);
                } else if index == current + 1 {
                    list.append(&section_row("UP NEXT"));
                    collected.push(usize::MAX);
                }
                let row = queue_row(&ui, track, index, current);
                if index > current {
                    attach_reorder(&ui, &row, index);
                }
                list.append(&row);
                collected.push(index);
            }
            if up_next_end < snapshot.queue.len() {
                list.append(&info_row(&format!(
                    "{} more up next",
                    snapshot.queue.len() - up_next_end
                )));
                collected.push(usize::MAX);
            }
            list.append(pinner.spacer());
            *indices.borrow_mut() = collected;

            pinner.set_anchor(now_playing_anchor);
            match keep_offset {
                Some(offset) => restore_offset(&scroll, &list, offset),
                None => pinner.drive(),
            }
        })
    };
    rebuild(false);

    {
        let ui_ref = Rc::clone(ui);
        let indices = Rc::clone(&indices);
        list.connect_row_activated(move |_, row| {
            let index = indices
                .borrow()
                .get(row.index().max(0) as usize)
                .copied()
                .unwrap_or(usize::MAX);
            if index == usize::MAX {
                return;
            }
            let snapshot = ui_ref.core.player.queue_snapshot();
            if index != snapshot.current {
                crate::scrobbler::checkpoint_skip(&ui_ref.core);
                ui_ref.core.player.jump_to(index);
            }
        });
    }

    let active = Rc::new(Cell::new(opts.initial_active));
    {
        let rebuild = Rc::clone(&rebuild);
        let active = Rc::clone(&active);
        ui.core.hub.subscribe_widget(&root, move |_, event| {
            if !active.get() {
                return;
            }
            match event {
                AppEvent::TrackChanged(_) => rebuild(true),
                AppEvent::QueueChanged | AppEvent::LovedChanged { .. } => rebuild(false),
                _ => {}
            }
        });
    }

    if opts.self_map_rebuild {
        let rebuild = Rc::clone(&rebuild);
        root.connect_map(move |_| rebuild(true));
    }

    let set_active: Rc<dyn Fn(bool)> = {
        let rebuild = Rc::clone(&rebuild);
        let active = Rc::clone(&active);
        Rc::new(move |now_active: bool| {
            active.set(now_active);
            if now_active {
                rebuild(true);
            }
        })
    };
    QueuePanel { widget: root.upcast(), set_active }
}

fn section_row(text: &str) -> gtk::ListBoxRow {
    let label = gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .margin_top(10)
        .margin_bottom(2)
        .margin_start(6)
        .build();
    label.add_css_class("stat-caption");
    gtk::ListBoxRow::builder()
        .child(&label)
        .activatable(false)
        .selectable(false)
        .build()
}

/// Frames a pin or a restore is allowed to converge over before giving up.
const SETTLE_FRAMES: u8 = 90;

/// Keeps the NOW PLAYING heading at the top of the queue viewport, so what is
/// playing reads first and the history sits just above it, one scroll away.
///
/// The pin is state rather than a one-shot: a freshly rebuilt list has no
/// geometry yet, and the queue can be rebuilt again (a track loved, a row
/// removed) before the first frame ever lands, which would strand a callback
/// attached to a row that no longer exists. So the request outlives any single
/// rebuild — each rebuild hands over the new heading, and the driver keeps
/// working on the list's frame clock until it lands. A hand scroll abandons it
/// rather than fighting the user.
struct Pinner {
    scroll: gtk::ScrolledWindow,
    list: gtk::ListBox,
    /// Grows to whatever is missing below the heading, so it can reach the top
    /// even when the current track is the last one in the queue.
    spacer: gtk::ListBoxRow,
    anchor: RefCell<Option<gtk::ListBoxRow>>,
    pending: Cell<bool>,
    running: Cell<bool>,
    frames: Cell<u8>,
}

impl Pinner {
    fn new(scroll: &gtk::ScrolledWindow, list: &gtk::ListBox) -> Rc<Self> {
        let spacer = gtk::ListBoxRow::builder()
            .child(&gtk::Box::new(gtk::Orientation::Vertical, 0))
            .activatable(false)
            .selectable(false)
            .build();
        spacer.add_css_class("queue-tail-spacer");
        Rc::new(Self {
            scroll: scroll.clone(),
            list: list.clone(),
            spacer,
            anchor: RefCell::new(None),
            pending: Cell::new(false),
            running: Cell::new(false),
            frames: Cell::new(0),
        })
    }

    fn spacer(&self) -> &gtk::ListBoxRow {
        &self.spacer
    }

    fn is_pending(&self) -> bool {
        self.pending.get()
    }

    fn request(&self) {
        self.pending.set(true);
        self.frames.set(0);
    }

    fn abandon(&self) {
        self.pending.set(false);
    }

    fn set_anchor(&self, anchor: Option<gtk::ListBoxRow>) {
        *self.anchor.borrow_mut() = anchor;
    }

    fn drive(self: &Rc<Self>) {
        if !self.pending.get() || self.running.get() {
            return;
        }
        self.running.set(true);
        let pinner = Rc::clone(self);
        self.list.add_tick_callback(move |_, _| {
            if pinner.step() {
                pinner.running.set(false);
                glib::ControlFlow::Break
            } else {
                glib::ControlFlow::Continue
            }
        });
    }

    /// One frame of work; true once the pin is done with (landed, abandoned, or
    /// out of patience).
    fn step(&self) -> bool {
        if !self.pending.get() {
            return true;
        }
        self.frames.set(self.frames.get().saturating_add(1));
        if self.frames.get() > SETTLE_FRAMES {
            self.pending.set(false);
            return true;
        }
        let anchor = self.anchor.borrow().clone();
        let Some(anchor) = anchor.filter(|row| row.parent().is_some()) else {
            return false;
        };
        let adjustment = self.scroll.vadjustment();
        let page = adjustment.page_size();
        let content = self.list.height() as f64;
        if page <= 1.0 || content <= 1.0 {
            return false;
        }
        let origin = gtk::graphene::Point::new(0.0, 0.0);
        let Some(point) = anchor.compute_point(&self.list, &origin) else {
            return false;
        };
        let top = point.y() as f64;
        let below = content - top - self.spacer.height() as f64;
        let needed = (page - below).max(0.0).ceil() as i32;
        if (needed - self.spacer.height_request()).abs() > 1 {
            self.spacer.set_height_request(needed);
            return false;
        }
        adjustment.set_value(top.min((adjustment.upper() - page).max(0.0)));
        self.pending.set(false);
        true
    }
}

/// Puts the viewport back where it was after a rebuild that isn't a track
/// change — removing a row or loving a track shouldn't throw the reader back
/// to the top of the history.
fn restore_offset(scroll: &gtk::ScrolledWindow, list: &gtk::ListBox, offset: f64) {
    if offset <= 0.0 {
        return;
    }
    let scroll = scroll.clone();
    let frames = Cell::new(0u8);
    list.add_tick_callback(move |_, _| {
        frames.set(frames.get() + 1);
        let adjustment = scroll.vadjustment();
        let max = (adjustment.upper() - adjustment.page_size()).max(0.0);
        let wanted = offset.min(max);
        adjustment.set_value(wanted);
        if (adjustment.value() - wanted).abs() < 0.5 || frames.get() >= SETTLE_FRAMES {
            glib::ControlFlow::Break
        } else {
            glib::ControlFlow::Continue
        }
    });
}

/// Non-interactive "N earlier / N more up next" marker for the ends of a
/// queue too large to fully render.
fn info_row(text: &str) -> gtk::ListBoxRow {
    let label = gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(10)
        .build();
    label.add_css_class("dim");
    label.add_css_class("caption");
    gtk::ListBoxRow::builder()
        .child(&label)
        .activatable(false)
        .selectable(false)
        .build()
}

fn queue_row(ui: &Rc<Ui>, track: &Track, index: usize, current: usize) -> gtk::ListBoxRow {
    let row_box = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .margin_top(6)
        .margin_bottom(6)
        .margin_start(6)
        .margin_end(6)
        .build();

    let artwork = gtk::Picture::builder()
        .width_request(36)
        .height_request(36)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    artwork.set_overflow(gtk::Overflow::Hidden);
    artwork.add_css_class("cover");
    artwork.set_paintable(Some(
        &ui.core
            .artwork
            .placeholder(&format!("{}|{}", track.album, track.artist)),
    ));
    {
        let weak = artwork.downgrade();
        ui.core
            .artwork
            .request(&track.album, &track.artist, 36, move |texture, _| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
            });
    }
    row_box.append(&artwork);

    let text_box = gtk::Box::new(gtk::Orientation::Vertical, 1);
    text_box.set_hexpand(true);
    text_box.set_valign(gtk::Align::Center);
    let title = gtk::Label::builder()
        .label(&track.title)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    text_box.append(&title);
    let artist = gtk::Label::builder()
        .label(&track.artist)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    artist.add_css_class("dim");
    artist.add_css_class("caption");
    text_box.append(&artist);
    row_box.append(&text_box);

    if track.loved {
        let heart = gtk::Image::from_icon_name("emote-love-symbolic");
        heart.add_css_class("loved-heart");
        row_box.append(&heart);
    }

    let duration = gtk::Label::new(Some(&format_time(track.duration)));
    duration.add_css_class("duration-label");
    row_box.append(&duration);

    if index != current {
        let remove = gtk::Button::from_icon_name("window-close-symbolic");
        remove.add_css_class("flat");
        remove.add_css_class("circular");
        remove.set_tooltip_text(Some("Remove from queue"));
        let ui_ref = Rc::clone(ui);
        remove.connect_clicked(move |_| {
            ui_ref.core.player.remove_at(index);
        });
        row_box.append(&remove);
    } else {
        let indicator = crate::ui::controls::build_equalizer_indicator();
        indicator.set_valign(gtk::Align::Center);
        crate::ui::controls::drive_equalizer(&indicator, ui.core.player.is_playing());
        ui.core.hub.subscribe_widget(&indicator, |indicator, event| {
            if let AppEvent::PlayingChanged(playing) = event {
                crate::ui::controls::drive_equalizer(indicator, *playing);
            }
        });
        row_box.append(&indicator);
    }

    let row = gtk::ListBoxRow::builder().child(&row_box).build();
    if index < current {
        row.add_css_class("queue-history-row");
    } else if index == current {
        row.add_css_class("queue-current-row");
    }
    crate::ui::context::attach_track_context_menu(&row, &ui.core, track.rel_path.clone());
    row
}

fn attach_reorder(ui: &Rc<Ui>, row: &gtk::ListBoxRow, index: usize) {
    let drag = gtk::DragSource::builder().actions(gdk::DragAction::MOVE).build();
    drag.connect_prepare(move |_, _, _| {
        Some(gdk::ContentProvider::for_value(&(index as i32).to_value()))
    });
    row.add_controller(drag);

    let drop = gtk::DropTarget::new(i32::static_type(), gdk::DragAction::MOVE);
    {
        let ui = Rc::clone(ui);
        drop.connect_drop(move |_, value, _, _| {
            let Ok(source) = value.get::<i32>() else { return false };
            if source < 0 || source as usize == index {
                return false;
            }
            ui.core.player.move_queue_entry(source as usize, index);
            crate::logger::info(
                "ui",
                &format!("queue: reorder {} -> {}", source, index),
            );
            true
        });
    }
    row.add_controller(drop);
}
