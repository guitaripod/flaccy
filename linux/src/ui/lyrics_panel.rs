use crate::events::AppEvent;
use crate::library::Track;
use crate::lyrics::{Lyrics, LyricsResult, Pace};
use crate::ui::lyric_line::LyricLine;
use crate::ui::screen::is_watched;
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::lyrics::{
    failure_status, idle_status, instrumental_status, missing_status, searching_status,
    timing_note, Document, Line, LineProgress, LyricsStatus, TimingNote, INTERLUDE_BEATS,
};
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::{Duration, Instant};

/// How long the view stays out of the way after the user scrolls by hand.
const USER_SCROLL_GRACE: f64 = 6.0;
/// Where the active line sits in the viewport — slightly above center, the way
/// every good lyrics view frames the line you are about to sing.
const ACTIVE_LINE_ANCHOR: f64 = 0.42;
/// A leading spacer row pads the top of the list, so ListBox row N holds
/// synced line N - 1.
const LINE_ROW_OFFSET: i32 = 1;
/// How far a tap on a line seeks before the line's own start, so the first
/// syllable is not clipped.
const SEEK_LEAD_IN: f64 = 0.15;
/// One press of Earlier or Later, and the most the correction may reach.
const OFFSET_STEP_MS: i64 = 100;
const OFFSET_LIMIT_MS: i64 = 10_000;
/// How far ahead of the clock a line lights up. The audio sink reports the
/// position it has rendered, not the one you are hearing, and CSS still has to
/// fade the highlight in — without a lead the line always arrives late.
const LYRIC_LEAD: f64 = 0.22;
/// Angular frequency of the critically damped auto-scroll spring, in rad/s.
/// ~0.35 s to settle: fast enough to keep up with a busy verse, slow enough to
/// read as a glide rather than a jump.
const SCROLL_RESPONSE: f64 = 15.0;
/// Frame deltas are clamped before integrating so a stalled frame can't blow
/// the spring up.
const MAX_FRAME_DELTA: f64 = 1.0 / 30.0;
/// The longest a settled column sleeps between looks at the clock, the least
/// it ever does, and the margin past a boundary it wakes at so the boundary
/// has really passed.
const LONGEST_NAP: f64 = 1.0;
const SHORTEST_NAP: f64 = 0.008;
const NAP_SLACK: f64 = 0.002;

/// Placement options so the sidebar and the in-view (Now Playing lens) share
/// one implementation instead of forking. The in-view instance hides its own
/// header (the ViewStack switcher labels it) and ignores the global
/// `LyricsToggled` event so it doesn't double-fetch with the sidebar instance.
pub struct LyricsOptions {
    pub show_header: bool,
    pub bottom_margin: i32,
    pub react_to_global_toggle: bool,
}

impl LyricsOptions {
    pub fn sidebar() -> Self {
        Self {
            show_header: true,
            bottom_margin: 120,
            react_to_global_toggle: true,
        }
    }
    pub fn in_view() -> Self {
        Self {
            show_header: false,
            bottom_margin: 8,
            react_to_global_toggle: false,
        }
    }
}

pub struct LyricsPanel {
    pub widget: gtk::Widget,
    /// Activate/deactivate the panel: activating fetches lyrics for the current
    /// track. Drive it from the ViewStack lens switch for the in-view instance.
    pub set_active: Rc<dyn Fn(bool)>,
}

fn show_status(page: &adw::StatusPage, status: &LyricsStatus) {
    page.set_title(&status.title);
    page.set_description(Some(&status.body));
}

pub fn build(ui: &Rc<Ui>, opts: LyricsOptions) -> LyricsPanel {
    let header = gtk::Label::builder()
        .label("Lyrics")
        .xalign(0.0)
        .hexpand(true)
        .build();
    header.add_css_class("title-4");
    let subtitle = gtk::Label::builder()
        .label("")
        .xalign(0.0)
        .margin_start(16)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .margin_top(8)
        .margin_bottom(opts.bottom_margin)
        .margin_start(12)
        .margin_end(12)
        .build();
    list.add_css_class("lyrics-list");

    let plain_view = gtk::Label::builder()
        .xalign(0.0)
        .wrap(true)
        .margin_top(8)
        .margin_bottom(24)
        .margin_start(16)
        .margin_end(16)
        .selectable(true)
        .build();
    plain_view.add_css_class("lyric-line");
    plain_view.add_css_class("lyric-line-current");

    let idle = idle_status();
    let status = adw::StatusPage::builder()
        .icon_name("format-justify-center-symbolic")
        .title(idle.title)
        .description(idle.body)
        .build();
    let retry = gtk::Button::with_label("Try Again");
    retry.add_css_class("pill");
    retry.add_css_class("suggested-action");
    retry.set_halign(gtk::Align::Center);
    retry.set_visible(false);
    status.set_child(Some(&retry));

    let synced_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&list)
        .vexpand(true)
        .build();
    let plain_scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&plain_view)
        .vexpand(true)
        .build();

    let head_spacer = spacer_row();
    let tail_spacer = spacer_row();
    {
        let head_spacer = head_spacer.clone();
        let tail_spacer = tail_spacer.clone();
        synced_scroll
            .vadjustment()
            .connect_page_size_notify(move |adjustment| {
                let page = adjustment.page_size();
                head_spacer.set_height_request(spacer_height(page * ACTIVE_LINE_ANCHOR));
                tail_spacer.set_height_request(spacer_height(page * (1.0 - ACTIVE_LINE_ANCHOR)));
            });
    }

    let resume = gtk::Button::builder()
        .child(
            &adw::ButtonContent::builder()
                .icon_name("go-down-symbolic")
                .label("Jump to Current")
                .build(),
        )
        .halign(gtk::Align::Center)
        .valign(gtk::Align::End)
        .margin_bottom(14)
        .build();
    resume.add_css_class("pill");
    resume.add_css_class("osd");
    let resume_reveal = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::Crossfade)
        .transition_duration(180)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::End)
        .can_target(true)
        .child(&resume)
        .build();

    let timing = Timing::new();
    let synced_note = NoteChip::new();
    let plain_note = NoteChip::new();
    let synced_overlay = gtk::Overlay::new();
    synced_overlay.set_child(Some(&synced_scroll));
    synced_overlay.add_overlay(&resume_reveal);
    synced_overlay.add_overlay(&corner_cluster(&[
        synced_note.button.upcast_ref(),
        timing.button.upcast_ref(),
    ]));
    let plain_overlay = gtk::Overlay::new();
    plain_overlay.set_child(Some(&plain_scroll));
    plain_overlay.add_overlay(&corner_cluster(&[plain_note.button.upcast_ref()]));

    let stack = gtk::Stack::new();
    stack.add_named(&status, Some("status"));
    stack.add_named(&synced_overlay, Some("synced"));
    stack.add_named(&plain_overlay, Some("plain"));
    stack.set_vexpand(true);

    let panel = gtk::Box::new(gtk::Orientation::Vertical, 4);
    if opts.show_header {
        let header_row = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(4)
            .margin_top(14)
            .margin_start(16)
            .margin_end(10)
            .build();
        header_row.append(&header);
        header_row.append(&font_size_controls(ui));
        panel.append(&header_row);
        panel.append(&subtitle);
    }
    panel.append(&stack);

    let state: Rc<RefCell<PanelState>> = Rc::new(RefCell::new(PanelState::default()));
    let visible = Rc::new(Cell::new(false));
    let last_user_scroll: Rc<Cell<Option<Instant>>> = Rc::new(Cell::new(None));
    let scroller = Rc::new(SmoothScroller::new(&synced_scroll));
    let refresh = Rc::new(Cell::new(false));
    let follower = Rc::new(Follower {
        ui: Rc::clone(ui),
        list: list.clone(),
        panel: panel.downgrade(),
        state: Rc::clone(&state),
        visible: Rc::clone(&visible),
        last_user_scroll: Rc::clone(&last_user_scroll),
        resume_reveal: resume_reveal.clone(),
        scroller: Rc::clone(&scroller),
        refresh: Rc::clone(&refresh),
        driver: FrameDriver::default(),
        nap: RefCell::new(None),
    });
    let sync_driver: Rc<dyn Fn()> = {
        let follower = Rc::clone(&follower);
        Rc::new(move || follower.sync())
    };

    {
        let last_user_scroll = Rc::clone(&last_user_scroll);
        let resume_reveal = resume_reveal.clone();
        let scroller = Rc::clone(&scroller);
        let scroll_controller =
            gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
        scroll_controller.connect_scroll(move |_, _, _| {
            last_user_scroll.set(Some(Instant::now()));
            scroller.cancel();
            resume_reveal.set_reveal_child(true);
            glib::Propagation::Proceed
        });
        synced_scroll.add_controller(scroll_controller);
    }

    let follow_now: Rc<dyn Fn()> = {
        let last_user_scroll = Rc::clone(&last_user_scroll);
        let resume_reveal = resume_reveal.clone();
        let state = Rc::clone(&state);
        let list = list.clone();
        let scroller = Rc::clone(&scroller);
        let sync_driver = Rc::clone(&sync_driver);
        Rc::new(move || {
            last_user_scroll.set(None);
            resume_reveal.set_reveal_child(false);
            if let Some(index) = state.borrow().current_line {
                if let Some(row) = line_row(&list, index) {
                    scroller.aim_at(&list, &row);
                }
            }
            sync_driver();
        })
    };
    {
        let follow_now = Rc::clone(&follow_now);
        resume.connect_clicked(move |_| follow_now());
    }

    {
        let ui = Rc::clone(ui);
        let state = Rc::clone(&state);
        let follow_now = Rc::clone(&follow_now);
        list.connect_row_activated(move |_, row| {
            let index = (row.index() - LINE_ROW_OFFSET).max(0) as usize;
            let target = {
                let state = state.borrow();
                state
                    .lyrics
                    .document
                    .lines
                    .get(index)
                    .map(|line| line.start + state.lyrics.offset_seconds())
            };
            if let Some(target) = target {
                ui.core.player.seek((target - SEEK_LEAD_IN).max(0.0));
                follow_now();
            }
        });
    }

    let apply_offset: Rc<dyn Fn(i64)> = {
        let ui = Rc::clone(ui);
        let state = Rc::clone(&state);
        let refresh = Rc::clone(&refresh);
        let sync_driver = Rc::clone(&sync_driver);
        let label = timing.value.clone();
        Rc::new(move |offset_ms: i64| {
            let offset_ms = offset_ms.clamp(-OFFSET_LIMIT_MS, OFFSET_LIMIT_MS);
            let track = {
                let mut state = state.borrow_mut();
                state.lyrics.offset_ms = offset_ms;
                state.track.clone()
            };
            label.set_label(&offset_text(offset_ms));
            ui.core.set_lyric_offset_ms(offset_ms);
            if let Some(track) = track {
                let db_path = ui.core.db_path.clone();
                std::thread::spawn(move || crate::lyrics::save_offset(&db_path, &track, offset_ms));
            }
            refresh.set(true);
            sync_driver();
        })
    };
    {
        let state = Rc::clone(&state);
        let apply_offset = Rc::clone(&apply_offset);
        timing.earlier.connect_clicked(move |_| {
            let current = state.borrow().lyrics.offset_ms;
            apply_offset(current - OFFSET_STEP_MS);
        });
    }
    {
        let state = Rc::clone(&state);
        let apply_offset = Rc::clone(&apply_offset);
        timing.later.connect_clicked(move |_| {
            let current = state.borrow().lyrics.offset_ms;
            apply_offset(current + OFFSET_STEP_MS);
        });
    }
    {
        let apply_offset = Rc::clone(&apply_offset);
        timing.reset.connect_clicked(move |_| apply_offset(0));
    }

    let apply_lyrics = {
        let list = list.clone();
        let stack = stack.clone();
        let plain_view = plain_view.clone();
        let status = status.clone();
        let retry = retry.clone();
        let state = Rc::clone(&state);
        let resume_reveal = resume_reveal.clone();
        let scroller = Rc::clone(&scroller);
        let refresh = Rc::clone(&refresh);
        let sync_driver = Rc::clone(&sync_driver);
        let offset_label = timing.value.clone();
        let timing_button = timing.button.clone();
        let synced_note = synced_note.clone();
        let plain_note = plain_note.clone();
        Rc::new(move |result: &LyricsResult| {
            refresh.set(true);
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            {
                let mut state = state.borrow_mut();
                state.current_line = None;
                state.highlighted.clear();
                state.rows.clear();
            }
            resume_reveal.set_reveal_child(false);
            scroller.reset();
            retry.set_visible(false);
            timing_button.set_visible(false);
            let song = state
                .borrow()
                .track
                .as_ref()
                .map(|track| track.title.clone())
                .unwrap_or_default();
            synced_note.show(None);
            plain_note.show(None);
            let lyrics = match result {
                LyricsResult::Found(lyrics) => lyrics,
                LyricsResult::Missing => {
                    show_status(&status, &missing_status(&song));
                    stack.set_visible_child_name("status");
                    sync_driver();
                    return;
                }
                LyricsResult::Failed(failure) => {
                    show_status(&status, &failure_status(*failure));
                    retry.set_visible(true);
                    stack.set_visible_child_name("status");
                    sync_driver();
                    return;
                }
            };
            let document = &lyrics.document;
            if document.instrumental {
                show_status(&status, &instrumental_status());
                stack.set_visible_child_name("status");
            } else if document.has_synced() {
                list.append(&head_spacer);
                let rows: Vec<LineRow> = document.lines.iter().map(LineRow::new).collect();
                for row in &rows {
                    list.append(&row.row);
                }
                list.append(&tail_spacer);
                state.borrow_mut().rows = rows;
                offset_label.set_label(&offset_text(lyrics.offset_ms));
                timing_button.set_visible(true);
                synced_note.show(timing_note(document));
                stack.set_visible_child_name("synced");
            } else if let Some(plain) = document.plain.as_deref() {
                plain_view.set_label(plain);
                plain_note.show(timing_note(document));
                stack.set_visible_child_name("plain");
            } else {
                show_status(&status, &missing_status(&song));
                stack.set_visible_child_name("status");
            }
            sync_driver();
        })
    };

    let fetch_for = {
        let ui = Rc::clone(ui);
        let state = Rc::clone(&state);
        let apply_lyrics = Rc::clone(&apply_lyrics);
        let subtitle = subtitle.clone();
        let status = status.clone();
        let stack = stack.clone();
        let retry = retry.clone();
        Rc::new(move |track: &Track, pace: Pace| {
            let generation = {
                let mut state = state.borrow_mut();
                state.generation += 1;
                state.lyrics = Lyrics::default();
                state.generation
            };
            subtitle.set_label(&format!("{} — {}", track.title, track.artist));
            show_status(&status, &searching_status());
            retry.set_visible(false);
            stack.set_visible_child_name("status");

            crate::lyrics::want(track);
            let ui = Rc::clone(&ui);
            let state = Rc::clone(&state);
            let apply_lyrics = Rc::clone(&apply_lyrics);
            let track = track.clone();
            glib::spawn_future_local(async move {
                let mut pace = pace;
                loop {
                    let rx = lookup_channel(&ui, &track, pace);
                    let Ok(outcome) = rx.recv().await else { return };
                    if state.borrow().generation != generation {
                        return;
                    }
                    let Some(result) = outcome else {
                        if !ui.core.player.is_current_path(&track.rel_path) {
                            return;
                        }
                        pace = Pace::Immediate;
                        continue;
                    };
                    if let LyricsResult::Found(lyrics) = &result {
                        state.borrow_mut().lyrics = lyrics.clone();
                    }
                    apply_lyrics(&result);
                    return;
                }
            });
        })
    };
    {
        let fetch_for = Rc::clone(&fetch_for);
        let state = Rc::clone(&state);
        let ui = Rc::clone(ui);
        retry.connect_clicked(move |_| {
            let track = state
                .borrow()
                .track
                .clone()
                .or_else(|| ui.core.player.current_track());
            if let Some(track) = track {
                fetch_for(&track, Pace::Immediate);
            }
        });
    }

    let set_active: Rc<dyn Fn(bool)> = {
        let visible = Rc::clone(&visible);
        let state = Rc::clone(&state);
        let fetch_for = Rc::clone(&fetch_for);
        let sync_driver = Rc::clone(&sync_driver);
        let ui = Rc::clone(ui);
        Rc::new(move |active: bool| {
            visible.set(active);
            if active {
                let track = state
                    .borrow()
                    .track
                    .clone()
                    .or_else(|| ui.core.player.current_track());
                if let Some(track) = track {
                    state.borrow_mut().track = Some(track.clone());
                    fetch_for(&track, Pace::Settled);
                }
            }
            sync_driver();
        })
    };

    {
        let sync_driver = Rc::clone(&sync_driver);
        panel.connect_map(move |_| sync_driver());
    }
    {
        let follower = Rc::clone(&follower);
        panel.connect_unmap(move |_| follower.stop());
    }

    {
        let state = Rc::clone(&state);
        let visible = Rc::clone(&visible);
        let fetch_for = Rc::clone(&fetch_for);
        let sync_driver = Rc::clone(&sync_driver);
        let refresh = Rc::clone(&refresh);
        let react_to_global_toggle = opts.react_to_global_toggle;
        let toggle_set_active = Rc::clone(&set_active);
        let panel_map = panel.clone();
        ui.core
            .hub
            .subscribe_widget(&panel, move |_, event| match event {
                AppEvent::TrackChanged(track) => {
                    state.borrow_mut().track = track.clone();
                    if visible.get() && panel_map.is_mapped() {
                        if let Some(track) = track {
                            fetch_for(track, Pace::Settled);
                        }
                    }
                }
                AppEvent::LyricsToggled(shown) => {
                    if react_to_global_toggle {
                        toggle_set_active(*shown);
                    }
                }
                AppEvent::PlayingChanged(_) | AppEvent::WindowSuspended(_) => sync_driver(),
                AppEvent::Seeked(_) => {
                    refresh.set(true);
                    sync_driver();
                }
                _ => {}
            });
    }

    LyricsPanel {
        widget: panel.upcast(),
        set_active,
    }
}

/// Starts a lookup for the track on its own thread, joining one that is
/// already running for it, and returns the channel its answer arrives on
/// (`None` when the track was skipped away from before the network was used).
fn lookup_channel(
    ui: &Rc<Ui>,
    track: &Track,
    pace: Pace,
) -> async_channel::Receiver<Option<LyricsResult>> {
    let (tx, rx) = async_channel::bounded::<Option<LyricsResult>>(1);
    let db_path = ui.core.db_path.clone();
    let music_root = ui.core.music_root();
    let track = track.clone();
    std::thread::spawn(move || {
        let outcome = crate::lyrics::fetch_shared(&db_path, &music_root, &track, pace);
        let _ = tx.send_blocking(outcome);
    });
    rx
}

/// The timing control: a small button over the lines that opens a popover with
/// Earlier and Later, the current correction and a reset.
struct Timing {
    button: gtk::MenuButton,
    earlier: gtk::Button,
    later: gtk::Button,
    reset: gtk::Button,
    value: gtk::Label,
}

impl Timing {
    fn new() -> Self {
        let earlier = gtk::Button::with_label("Earlier");
        let later = gtk::Button::with_label("Later");
        let value = gtk::Label::builder()
            .label(offset_text(0))
            .width_chars(9)
            .build();
        value.add_css_class("numeric");
        let stepper = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        stepper.append(&earlier);
        stepper.append(&value);
        stepper.append(&later);
        let reset = gtk::Button::with_label("Reset");
        reset.add_css_class("flat");
        let caption = gtk::Label::builder()
            .label("Shift the lyrics if they run ahead of or behind the singing.")
            .wrap(true)
            .max_width_chars(30)
            .xalign(0.0)
            .build();
        caption.add_css_class("dim");
        caption.add_css_class("caption");
        let content = gtk::Box::new(gtk::Orientation::Vertical, 10);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        let title = gtk::Label::builder()
            .label("Lyrics Timing")
            .xalign(0.0)
            .build();
        title.add_css_class("heading");
        content.append(&title);
        content.append(&stepper);
        content.append(&caption);
        content.append(&reset);
        let popover = gtk::Popover::builder().child(&content).build();
        let button = gtk::MenuButton::builder()
            .icon_name("preferences-system-time-symbolic")
            .tooltip_text("Lyrics timing")
            .popover(&popover)
            .valign(gtk::Align::Center)
            .visible(false)
            .build();
        button.add_css_class("flat");
        button.add_css_class("circular");
        button.add_css_class("lyrics-timing");
        Self {
            button,
            earlier,
            later,
            reset,
            value,
        }
    }
}

/// The quiet chip beside the timing control that names why a song's lyrics are
/// not filled in word by word, and opens a popover with the reason.
#[derive(Clone)]
struct NoteChip {
    button: gtk::MenuButton,
    label: gtk::Label,
    title: gtk::Label,
    body: gtk::Label,
}

impl NoteChip {
    fn new() -> Self {
        let label = gtk::Label::new(None);
        label.add_css_class("caption");
        let face = gtk::Box::new(gtk::Orientation::Horizontal, 5);
        face.append(&gtk::Image::from_icon_name("dialog-information-symbolic"));
        face.append(&label);
        let title = gtk::Label::builder().xalign(0.0).wrap(true).build();
        title.add_css_class("heading");
        let body = gtk::Label::builder()
            .xalign(0.0)
            .wrap(true)
            .max_width_chars(34)
            .build();
        let content = gtk::Box::new(gtk::Orientation::Vertical, 8);
        content.set_margin_top(12);
        content.set_margin_bottom(12);
        content.set_margin_start(12);
        content.set_margin_end(12);
        content.append(&title);
        content.append(&body);
        let button = gtk::MenuButton::builder()
            .child(&face)
            .popover(&gtk::Popover::builder().child(&content).build())
            .valign(gtk::Align::Center)
            .visible(false)
            .build();
        button.add_css_class("flat");
        button.add_css_class("lyrics-note");
        Self {
            button,
            label,
            title,
            body,
        }
    }

    /// Words the chip for `note`, or hides it when the document needs none.
    fn show(&self, note: Option<TimingNote>) {
        if let Some(note) = note {
            self.label.set_label(note.label);
            self.title.set_label(note.title);
            self.body.set_label(note.body);
            self.button.set_tooltip_text(Some(note.title));
        }
        self.button.set_visible(note.is_some());
    }
}

/// The top-end corner of a lyrics page: its small controls side by side, taking
/// only the room they need so a click anywhere else still reaches the lines.
fn corner_cluster(children: &[&gtk::Widget]) -> gtk::Box {
    let cluster = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(4)
        .halign(gtk::Align::End)
        .valign(gtk::Align::Start)
        .margin_top(6)
        .margin_end(6)
        .build();
    for child in children {
        cluster.append(*child);
    }
    cluster
}

/// "In sync", or the correction as a signed number of seconds.
fn offset_text(offset_ms: i64) -> String {
    if offset_ms == 0 {
        return "In sync".to_string();
    }
    let sign = if offset_ms > 0 { "+" } else { "\u{2212}" };
    format!("{sign}{:.1} s", offset_ms.abs() as f64 / 1000.0)
}

/// A–/A+ buttons on the panel header. Same config key as the Preferences
/// spinner, so both surfaces stay in step and every open lyrics view resizes at
/// once.
fn font_size_controls(ui: &Rc<Ui>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    row.add_css_class("linked");
    row.set_valign(gtk::Align::Center);
    let step = |ui: &Rc<Ui>, delta: i32| {
        let size = {
            let mut config = ui.core.config.borrow_mut();
            config.lyrics_font_size = (config.lyrics_font_size + delta).clamp(
                crate::config::LYRICS_FONT_MIN,
                crate::config::LYRICS_FONT_MAX,
            );
            config.lyrics_font_size
        };
        ui.core.save_config();
        crate::ui::lyrics_style::apply(size);
    };
    for (icon, tooltip, delta) in [
        ("zoom-out-symbolic", "Smaller lyrics", -1),
        ("zoom-in-symbolic", "Larger lyrics", 1),
    ] {
        let button = gtk::Button::from_icon_name(icon);
        button.add_css_class("flat");
        button.set_tooltip_text(Some(tooltip));
        let ui = Rc::clone(ui);
        button.connect_clicked(move |_| step(&ui, delta));
        row.append(&button);
    }
    row
}

/// What a row of the list holds for one line of the document.
enum Body {
    Text(LyricLine),
    Beats(Vec<gtk::Label>),
}

/// One row of the lyrics list, with the widget inside it kept to hand so the
/// follower can light it without searching the list.
struct LineRow {
    row: gtk::ListBoxRow,
    body: Body,
}

impl LineRow {
    fn new(line: &Line) -> Self {
        let (child, body): (gtk::Widget, Body) = if line.is_interlude() {
            let beats = interlude_beats();
            let holder = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(14)
                .halign(gtk::Align::Start)
                .margin_start(4)
                .build();
            holder.add_css_class("lyric-beats");
            for beat in &beats {
                holder.append(beat);
            }
            (holder.upcast(), Body::Beats(beats))
        } else {
            let text = LyricLine::new(&line.text, &line.words);
            if line.background {
                text.add_css_class("lyric-line-backing");
            }
            (text.clone().upcast(), Body::Text(text))
        };
        let row = gtk::ListBoxRow::builder().child(&child).build();
        row.set_cursor_from_name(Some("pointer"));
        Self { row, body }
    }

    fn widget(&self) -> gtk::Widget {
        self.row.child().expect("every lyrics row has a child")
    }

    fn set_state(&self, lit: bool, near: bool) {
        let widget = self.widget();
        widget.remove_css_class("lyric-line-current");
        widget.remove_css_class("lyric-line-near");
        if lit {
            widget.add_css_class("lyric-line-current");
        } else if near {
            widget.add_css_class("lyric-line-near");
        }
    }

    fn show(&self, line: &Line, time: f64) {
        match &self.body {
            Body::Text(text) => text.set_progress(line.progress(time)),
            Body::Beats(beats) => set_lit_beats(beats, line.lit_beats(time)),
        }
    }

    fn clear(&self) {
        match &self.body {
            Body::Text(text) => text.set_progress(None),
            Body::Beats(beats) => set_lit_beats(beats, 0),
        }
    }
}

fn interlude_beats() -> Vec<gtk::Label> {
    (0..INTERLUDE_BEATS)
        .map(|_| {
            let beat = gtk::Label::new(Some("\u{25CF}"));
            beat.add_css_class("lyric-beat");
            beat
        })
        .collect()
}

fn set_lit_beats(beats: &[gtk::Label], lit: usize) {
    for (index, beat) in beats.iter().enumerate() {
        if index < lit {
            beat.add_css_class("lyric-beat-lit");
        } else {
            beat.remove_css_class("lyric-beat-lit");
        }
    }
}

/// The ListBox row holding line `index`, past the leading spacer.
fn line_row(list: &gtk::ListBox, index: usize) -> Option<gtk::ListBoxRow> {
    list.row_at_index(index as i32 + LINE_ROW_OFFSET)
}

/// Padding at both ends so the first and last lines can actually reach the
/// anchor point instead of being pinned to an edge. Sized from the viewport at
/// runtime; the constant is only what shows before the first allocation.
fn spacer_row() -> gtk::ListBoxRow {
    let filler = gtk::Box::new(gtk::Orientation::Vertical, 0);
    filler.add_css_class("lyrics-spacer");
    let row = gtk::ListBoxRow::builder()
        .child(&filler)
        .activatable(false)
        .selectable(false)
        .build();
    row.set_height_request(96);
    row
}

fn spacer_height(request: f64) -> i32 {
    (request.max(24.0)) as i32
}

/// Repaints the depth ramp: every lit line at full weight, the neighbours of
/// the primary line part-way, everything else receded. Only rows whose state
/// can have changed are touched.
fn repaint_depth(
    rows: &[LineRow],
    document: &Document,
    previous: (&[usize], Option<usize>),
    current: (&[usize], Option<usize>),
    time: f64,
) {
    let mut touched: Vec<usize> = Vec::new();
    for (lit, primary) in [previous, current] {
        touched.extend_from_slice(lit);
        if let Some(anchor) = primary {
            for offset in -1i64..=1 {
                let index = anchor as i64 + offset;
                if index >= 0 && (index as usize) < rows.len() {
                    touched.push(index as usize);
                }
            }
        }
    }
    touched.sort_unstable();
    touched.dedup();
    let (lit, primary) = current;
    for index in touched {
        let Some(row) = rows.get(index) else { continue };
        let near = primary.is_some_and(|anchor| anchor.abs_diff(index) == 1);
        let is_lit = lit.contains(&index);
        row.set_state(is_lit, near);
        match document.lines.get(index) {
            Some(line) if is_lit => row.show(line, time),
            _ => row.clear(),
        }
    }
}

/// Keeps the lyrics column on the line being sung. The line is looked up when
/// it can change, not on every frame: a settled column sleeps until the next
/// boundary is due, and a frame callback only runs while a word is being filled
/// or a scroll is finishing. Leaving a frame callback on for the whole song
/// held the window's frame clock running at the display's full rate for as
/// long as the lyrics were on screen.
struct Follower {
    ui: Rc<Ui>,
    list: gtk::ListBox,
    panel: glib::WeakRef<gtk::Box>,
    state: Rc<RefCell<PanelState>>,
    visible: Rc<Cell<bool>>,
    last_user_scroll: Rc<Cell<Option<Instant>>>,
    resume_reveal: gtk::Revealer,
    scroller: Rc<SmoothScroller>,
    /// A seek or a fresh set of lyrics has to re-find the line even when
    /// nothing is playing, so the next frame runs one more pass.
    refresh: Rc<Cell<bool>>,
    driver: FrameDriver,
    nap: RefCell<Option<glib::SourceId>>,
}

impl Follower {
    fn wanted(&self) -> bool {
        let idle =
            !self.ui.core.player.is_playing() && !self.scroller.is_busy() && !self.refresh.get();
        self.visible.get()
            && self.panel.upgrade().is_some_and(|panel| is_watched(&panel))
            && self.state.borrow().lyrics.document.has_synced()
            && !idle
    }

    /// Re-evaluates what the column should be doing after anything that could
    /// change it: the panel shown or hidden, a play state change, a seek, new
    /// lyrics. A frame is enough to find the line; the callback stops itself
    /// as soon as nothing is moving.
    fn sync(self: &Rc<Self>) {
        self.cancel_nap();
        if !self.wanted() {
            self.driver.stop();
            return;
        }
        let weak = Rc::downgrade(self);
        self.driver.start(&self.list, move |delta| {
            if let Some(follower) = weak.upgrade() {
                follower.step(delta);
            }
        });
    }

    fn stop(&self) {
        self.driver.stop();
        self.cancel_nap();
    }

    fn cancel_nap(&self) {
        if let Some(id) = self.nap.borrow_mut().take() {
            id.remove();
        }
    }

    fn step(self: &Rc<Self>, delta: f64) {
        if !self.visible.get() {
            self.driver.stop();
            return;
        }
        let playing = self.ui.core.player.is_playing();
        let stale = self.refresh.replace(false);
        let mut filling = false;
        if playing || stale {
            filling = self.follow_clock();
        }
        self.scroller.advance(delta);
        let busy = self.scroller.is_busy() || (filling && playing);
        if !busy {
            self.driver.stop();
            if playing {
                self.nap_until_next_change();
            }
        }
    }

    /// The moment of the song the clock is on, with the listener's correction
    /// applied and a small lead so the line arrives with the singer.
    fn song_time(&self) -> f64 {
        let position = self.ui.core.player.position().unwrap_or(0.0) + LYRIC_LEAD;
        self.state.borrow().lyrics.song_time(position)
    }

    /// Lights the lines the clock is on, advances the fill inside them, and
    /// aims the scroll at the primary line unless the person has scrolled by
    /// hand a moment ago. Returns whether a fill is mid-word and needs frames.
    fn follow_clock(&self) -> bool {
        let time = self.song_time();
        let (primary, lit) = {
            let state = self.state.borrow();
            let document = &state.lyrics.document;
            (document.primary_index(time), document.highlighted(time))
        };
        let (primary_changed, lit_changed) = {
            let state = self.state.borrow();
            (state.current_line != primary, state.highlighted != lit)
        };
        if primary_changed || lit_changed {
            {
                let state = self.state.borrow();
                repaint_depth(
                    &state.rows,
                    &state.lyrics.document,
                    (&state.highlighted, state.current_line),
                    (&lit, primary),
                    time,
                );
            }
            let mut state = self.state.borrow_mut();
            state.current_line = primary;
            state.highlighted = lit.clone();
        }
        let filling = {
            let state = self.state.borrow();
            let document = &state.lyrics.document;
            let mut filling = false;
            for index in &lit {
                let (Some(line), Some(row)) = (document.lines.get(*index), state.rows.get(*index))
                else {
                    continue;
                };
                row.show(line, time);
                if matches!(line.progress(time), Some(LineProgress::Singing { .. })) {
                    filling = true;
                }
            }
            filling
        };
        if primary_changed {
            if let Some(current) = primary {
                let user_recent = self
                    .last_user_scroll
                    .get()
                    .is_some_and(|at| at.elapsed().as_secs_f64() < USER_SCROLL_GRACE);
                if user_recent {
                    self.resume_reveal.set_reveal_child(true);
                } else if let Some(row) = line_row(&self.list, current) {
                    self.scroller.aim_at(&self.list, &row);
                }
            }
        }
        filling
    }

    fn nap_until_next_change(self: &Rc<Self>) {
        let time = self.song_time();
        let delay = next_delay(&self.state.borrow().lyrics.document, time);
        let weak = Rc::downgrade(self);
        let id = glib::timeout_add_local_once(delay, move || {
            let Some(follower) = weak.upgrade() else {
                return;
            };
            follower.nap.borrow_mut().take();
            follower.sync();
        });
        *self.nap.borrow_mut() = Some(id);
    }
}

/// How long a settled column can sleep: until anything on screen next changes,
/// never longer than a second, so a position that jumped for a reason nobody
/// told the panel about is still caught.
fn next_delay(document: &Document, time: f64) -> Duration {
    let until = document
        .next_boundary(time)
        .map_or(LONGEST_NAP, |at| at - time);
    Duration::from_secs_f64((until + NAP_SLACK).clamp(SHORTEST_NAP, LONGEST_NAP))
}

#[derive(Default)]
struct PanelState {
    track: Option<Track>,
    lyrics: Lyrics,
    generation: u64,
    current_line: Option<usize>,
    highlighted: Vec<usize>,
    rows: Vec<LineRow>,
}

/// Runs a closure on the widget's frame clock — every frame the compositor
/// draws, so 60 Hz or whatever the display actually is, rather than the 250 ms
/// player tick. Started and stopped on demand so an idle panel forces no
/// wakeups; the closure hands back the seconds elapsed since the last frame.
#[derive(Default)]
struct FrameDriver {
    handle: RefCell<Option<gtk::TickCallbackId>>,
}

impl FrameDriver {
    fn start(&self, widget: &impl IsA<gtk::Widget>, step: impl Fn(f64) + 'static) {
        if self.handle.borrow().is_some() {
            return;
        }
        let previous: Cell<i64> = Cell::new(0);
        let handle = widget.as_ref().add_tick_callback(move |_, clock| {
            let now = clock.frame_time();
            let last = previous.replace(now);
            let delta = if last == 0 {
                MAX_FRAME_DELTA
            } else {
                ((now - last) as f64 / 1_000_000.0).clamp(0.0, MAX_FRAME_DELTA)
            };
            step(delta);
            glib::ControlFlow::Continue
        });
        *self.handle.borrow_mut() = Some(handle);
    }

    fn stop(&self) {
        if let Some(handle) = self.handle.borrow_mut().take() {
            handle.remove();
        }
    }
}

/// Frame-clock auto-scroll: a critically damped spring integrated once per
/// frame toward the anchor. Targets come from real row geometry rather than an
/// index fraction — wrapped lines make every line a different height, so a
/// fractional estimate drifts further out of step the longer a song runs.
/// Retargeting mid-flight keeps the existing velocity, so consecutive lines
/// read as one continuous glide instead of a restart per line.
struct SmoothScroller {
    adjustment: gtk::Adjustment,
    target: Cell<Option<f64>>,
    velocity: Cell<f64>,
}

impl SmoothScroller {
    fn new(scroll: &gtk::ScrolledWindow) -> Self {
        Self {
            adjustment: scroll.vadjustment(),
            target: Cell::new(None),
            velocity: Cell::new(0.0),
        }
    }

    fn is_busy(&self) -> bool {
        self.target.get().is_some()
    }

    fn cancel(&self) {
        self.target.set(None);
        self.velocity.set(0.0);
    }

    fn reset(&self) {
        self.cancel();
        self.adjustment.set_value(0.0);
    }

    fn aim_at(&self, list: &gtk::ListBox, row: &gtk::ListBoxRow) {
        let Some(bounds) = row.compute_bounds(list) else {
            return;
        };
        let page = self.adjustment.page_size();
        if page <= 1.0 {
            return;
        }
        let target = bounds.y() as f64 + bounds.height() as f64 / 2.0 - page * ACTIVE_LINE_ANCHOR;
        let max = (self.adjustment.upper() - page).max(0.0);
        self.target.set(Some(target.clamp(0.0, max)));
    }

    fn advance(&self, delta: f64) {
        let Some(target) = self.target.get() else {
            return;
        };
        let value = self.adjustment.value();
        let distance = target - value;
        let velocity = self.velocity.get();
        if distance.abs() < 0.5 && velocity.abs() < 4.0 {
            self.adjustment.set_value(target);
            self.cancel();
            return;
        }
        let response = SCROLL_RESPONSE;
        let velocity =
            velocity + (response * response * distance - 2.0 * response * velocity) * delta;
        self.velocity.set(velocity);
        self.adjustment.set_value(value + velocity * delta);
    }
}

#[cfg(test)]
mod tests {
    use super::{next_delay, offset_text, LONGEST_NAP, NAP_SLACK, SHORTEST_NAP};
    use flaccy_shared::lyrics::{parse_lrc, Document};

    fn song() -> Document {
        parse_lrc("[00:01.00]one\n[00:11.00]two\n[00:21.00]three")
    }

    #[test]
    fn a_settled_column_sleeps_until_the_next_change_is_due() {
        let delay = next_delay(&song(), 4.0).as_secs_f64();
        assert!((delay - (7.0 + NAP_SLACK).min(LONGEST_NAP)).abs() < 1e-9);
        let delay = next_delay(&song(), 10.5).as_secs_f64();
        assert!((delay - (0.5 + NAP_SLACK)).abs() < 1e-9);
    }

    #[test]
    fn the_nap_never_outlasts_the_ceiling_or_dips_under_the_floor() {
        assert_eq!(next_delay(&song(), 999.0).as_secs_f64(), LONGEST_NAP);
        assert_eq!(
            next_delay(&song(), 11.0 - 0.001).as_secs_f64(),
            SHORTEST_NAP
        );
        assert_eq!(
            next_delay(&Document::default(), 5.0).as_secs_f64(),
            LONGEST_NAP
        );
    }

    #[test]
    fn the_offset_reads_as_a_signed_number_of_seconds() {
        assert_eq!(offset_text(0), "In sync");
        assert_eq!(offset_text(300), "+0.3 s");
        assert_eq!(offset_text(-1200), "\u{2212}1.2 s");
    }
}
