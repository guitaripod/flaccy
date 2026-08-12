use crate::events::AppEvent;
use crate::library::Track;
use crate::lyrics::{Lyrics, LyricsResult};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;

/// How long the view stays out of the way after the user scrolls by hand.
const USER_SCROLL_GRACE: f64 = 6.0;
/// Where the active line sits in the viewport — slightly above center, the way
/// every good lyrics view frames the line you are about to sing.
const ACTIVE_LINE_ANCHOR: f64 = 0.42;
/// A leading spacer row pads the top of the list, so ListBox row N holds
/// synced line N - 1.
const LINE_ROW_OFFSET: i32 = 1;
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
        Self { show_header: true, bottom_margin: 120, react_to_global_toggle: true }
    }
    pub fn in_view() -> Self {
        Self { show_header: false, bottom_margin: 8, react_to_global_toggle: false }
    }
}

pub struct LyricsPanel {
    pub widget: gtk::Widget,
    /// Activate/deactivate the panel: activating fetches lyrics for the current
    /// track. Drive it from the ViewStack lens switch for the in-view instance.
    pub set_active: Rc<dyn Fn(bool)>,
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

    let status = adw::StatusPage::builder()
        .icon_name("format-justify-center-symbolic")
        .title("No Lyrics")
        .description("Play a track to look up lyrics on lrclib.net.")
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
        synced_scroll.vadjustment().connect_page_size_notify(move |adjustment| {
            let page = adjustment.page_size();
            head_spacer.set_height_request(spacer_height(page * ACTIVE_LINE_ANCHOR));
            tail_spacer.set_height_request(spacer_height(page * (1.0 - ACTIVE_LINE_ANCHOR)));
        });
    }

    // "Jump to current line" — the only way back once the user has scrolled
    // away, which is otherwise an invisible and unrecoverable state.
    let resume = gtk::Button::builder()
        .child(&adw::ButtonContent::builder()
            .icon_name("go-down-symbolic")
            .label("Jump to Current")
            .build())
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
    let synced_overlay = gtk::Overlay::new();
    synced_overlay.set_child(Some(&synced_scroll));
    synced_overlay.add_overlay(&resume_reveal);

    let stack = gtk::Stack::new();
    stack.add_named(&status, Some("status"));
    stack.add_named(&synced_overlay, Some("synced"));
    stack.add_named(&plain_scroll, Some("plain"));
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
    let driver = Rc::new(FrameDriver::default());
    // A seek or a fresh set of lyrics has to re-find the line even when nothing
    // is playing, so the driver runs one more pass instead of staying asleep.
    let refresh = Rc::new(Cell::new(false));

    let sync_driver: Rc<dyn Fn()> = {
        let driver = Rc::clone(&driver);
        let scroller = Rc::clone(&scroller);
        let state = Rc::clone(&state);
        let visible = Rc::clone(&visible);
        let last_user_scroll = Rc::clone(&last_user_scroll);
        let resume_reveal = resume_reveal.clone();
        let refresh = Rc::clone(&refresh);
        let list = list.clone();
        let panel = panel.downgrade();
        let ui = Rc::clone(ui);
        Rc::new(move || {
            let idle =
                !ui.core.player.is_playing() && !scroller.is_busy() && !refresh.get();
            let wanted = visible.get()
                && panel.upgrade().is_some_and(|panel| panel.is_mapped())
                && !state.borrow().lyrics.synced.is_empty()
                && !idle;
            if !wanted {
                driver.stop();
                return;
            }
            let step = {
                let driver = Rc::clone(&driver);
                let scroller = Rc::clone(&scroller);
                let state = Rc::clone(&state);
                let visible = Rc::clone(&visible);
                let last_user_scroll = Rc::clone(&last_user_scroll);
                let resume_reveal = resume_reveal.clone();
                let refresh = Rc::clone(&refresh);
                let list = list.clone();
                let ui = Rc::clone(&ui);
                move |delta: f64| {
                    if !visible.get() {
                        driver.stop();
                        return;
                    }
                    let playing = ui.core.player.is_playing();
                    let stale = refresh.replace(false);
                    if playing || stale {
                        let position = ui.core.player.position().unwrap_or(0.0) + LYRIC_LEAD;
                        let changed = {
                            let state = state.borrow();
                            let line = active_line(&state.lyrics.synced, position);
                            (state.current_line != line).then_some(line)
                        };
                        if let Some(line) = changed {
                            let previous = state.borrow().current_line;
                            let total = {
                                let mut state = state.borrow_mut();
                                state.current_line = line;
                                state.lyrics.synced.len()
                            };
                            repaint_depth(&list, previous, line, total);
                            if let Some(current) = line {
                                let user_recent = last_user_scroll
                                    .get()
                                    .map(|t| t.elapsed().as_secs_f64() < USER_SCROLL_GRACE)
                                    .unwrap_or(false);
                                if user_recent {
                                    resume_reveal.set_reveal_child(true);
                                } else if let Some(row) = line_row(&list, current) {
                                    scroller.aim_at(&list, &row);
                                }
                            }
                        }
                    }
                    scroller.advance(delta);
                    if !playing && !scroller.is_busy() {
                        driver.stop();
                    }
                }
            };
            driver.start(&list, step);
        })
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
            let time = state.borrow().lyrics.synced.get(index).map(|(t, _)| *t);
            if let Some(time) = time {
                // Nudge back a beat so the first syllable isn't clipped.
                ui.core.player.seek((time - 0.15).max(0.0));
                follow_now();
            }
        });
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
        Rc::new(move |result: &LyricsResult| {
            refresh.set(true);
            while let Some(child) = list.first_child() {
                list.remove(&child);
            }
            state.borrow_mut().current_line = None;
            resume_reveal.set_reveal_child(false);
            scroller.reset();
            retry.set_visible(false);
            let lyrics = match result {
                LyricsResult::Found(lyrics) => lyrics,
                LyricsResult::Missing => {
                    status.set_title("No Lyrics Found");
                    status.set_description(Some("lrclib.net has no lyrics for this track."));
                    stack.set_visible_child_name("status");
                    sync_driver();
                    return;
                }
                LyricsResult::Failed => {
                    status.set_title("Couldn't Reach lrclib.net");
                    status.set_description(Some("Check your connection and try again."));
                    retry.set_visible(true);
                    stack.set_visible_child_name("status");
                    sync_driver();
                    return;
                }
            };
            if lyrics.instrumental {
                status.set_title("Instrumental");
                status.set_description(Some("This track has no lyrics."));
                stack.set_visible_child_name("status");
            } else if !lyrics.synced.is_empty() {
                list.append(&head_spacer);
                for (_, text) in &lyrics.synced {
                    list.append(&lyric_row(text));
                }
                list.append(&tail_spacer);
                stack.set_visible_child_name("synced");
            } else if let Some(plain) = lyrics.plain.as_deref().filter(|p| !p.trim().is_empty()) {
                plain_view.set_label(plain);
                stack.set_visible_child_name("plain");
            } else {
                status.set_title("No Lyrics Found");
                status.set_description(Some("lrclib.net has no lyrics for this track."));
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
        Rc::new(move |track: &Track| {
            let generation = {
                let mut state = state.borrow_mut();
                state.generation += 1;
                state.generation
            };
            subtitle.set_label(&format!("{} — {}", track.title, track.artist));
            status.set_title("Looking Up Lyrics…");
            status.set_description(Some(""));
            retry.set_visible(false);
            stack.set_visible_child_name("status");

            let (tx, rx) = async_channel::bounded::<LyricsResult>(1);
            let db_path = ui.core.db_path.clone();
            let music_root = ui.core.music_root();
            let track_for_thread = track.clone();
            std::thread::spawn(move || {
                let result =
                    crate::lyrics::fetch_blocking(&db_path, &music_root, &track_for_thread);
                let _ = tx.send_blocking(result);
            });
            let state = Rc::clone(&state);
            let apply_lyrics = Rc::clone(&apply_lyrics);
            glib::spawn_future_local(async move {
                let Ok(result) = rx.recv().await else { return };
                if state.borrow().generation != generation {
                    return;
                }
                if let LyricsResult::Found(lyrics) = &result {
                    state.borrow_mut().lyrics = lyrics.clone();
                } else {
                    state.borrow_mut().lyrics = Lyrics::default();
                }
                apply_lyrics(&result);
            });
        })
    };
    {
        let fetch_for = Rc::clone(&fetch_for);
        let state = Rc::clone(&state);
        let ui = Rc::clone(ui);
        retry.connect_clicked(move |_| {
            let track = state.borrow().track.clone().or_else(|| ui.core.player.current_track());
            if let Some(track) = track {
                fetch_for(&track);
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
                    fetch_for(&track);
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
        let driver = Rc::clone(&driver);
        panel.connect_unmap(move |_| driver.stop());
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
        ui.core.hub.subscribe_widget(&panel, move |_, event| match event {
            AppEvent::TrackChanged(track) => {
                state.borrow_mut().track = track.clone();
                if visible.get() && panel_map.is_mapped() {
                    if let Some(track) = track {
                        fetch_for(track);
                    }
                }
            }
            AppEvent::LyricsToggled(shown) => {
                if react_to_global_toggle {
                    toggle_set_active(*shown);
                }
            }
            AppEvent::PlayingChanged(_) => sync_driver(),
            AppEvent::Seeked(_) => {
                refresh.set(true);
                sync_driver();
            }
            _ => {}
        });
    }

    LyricsPanel { widget: panel.upcast(), set_active }
}

/// A- / A+ buttons on the panel header. Same config key as the Preferences
/// spinner, so both surfaces stay in step and every open lyrics view resizes at
/// once.
fn font_size_controls(ui: &Rc<Ui>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    row.add_css_class("linked");
    row.set_valign(gtk::Align::Center);
    let step = |ui: &Rc<Ui>, delta: i32| {
        let size = {
            let mut config = ui.core.config.borrow_mut();
            config.lyrics_font_size = (config.lyrics_font_size + delta)
                .clamp(crate::config::LYRICS_FONT_MIN, crate::config::LYRICS_FONT_MAX);
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

/// Blank LRC lines mark an instrumental break; render them as a breathing glyph
/// rather than an empty row so the pause reads as part of the song.
fn lyric_row(text: &str) -> gtk::ListBoxRow {
    let interlude = text.trim().is_empty();
    let label = gtk::Label::builder()
        .label(if interlude { "♪" } else { text })
        .xalign(0.0)
        .wrap(true)
        .build();
    label.add_css_class("lyric-line");
    if interlude {
        label.add_css_class("lyric-line-interlude");
    }
    let row = gtk::ListBoxRow::builder().child(&label).build();
    row.set_cursor_from_name(Some("pointer"));
    row
}

/// The ListBox row holding synced line `index`, past the leading spacer.
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

fn active_line(synced: &[(f64, String)], position: f64) -> Option<usize> {
    let mut index = None;
    for (i, (time, _)) in synced.iter().enumerate() {
        if *time <= position {
            index = Some(i);
        } else {
            break;
        }
    }
    index
}

/// Repaints the depth ramp around the active line: the current line at full
/// weight, its immediate neighbours part-way, everything else receded.
fn repaint_depth(
    list: &gtk::ListBox,
    previous: Option<usize>,
    current: Option<usize>,
    total: usize,
) {
    let mut touched: Vec<usize> = Vec::new();
    for anchor in [previous, current].into_iter().flatten() {
        for offset in -1i64..=1 {
            let index = anchor as i64 + offset;
            if index >= 0 && (index as usize) < total {
                touched.push(index as usize);
            }
        }
    }
    touched.sort_unstable();
    touched.dedup();
    for index in touched {
        let Some(row) = line_row(list, index) else { continue };
        let Some(label) = row.child() else { continue };
        label.remove_css_class("lyric-line-current");
        label.remove_css_class("lyric-line-near");
        match current {
            Some(active) if active == index => label.add_css_class("lyric-line-current"),
            Some(active) if active.abs_diff(index) == 1 => label.add_css_class("lyric-line-near"),
            _ => {}
        }
    }
}

#[derive(Default)]
struct PanelState {
    track: Option<Track>,
    lyrics: Lyrics,
    generation: u64,
    current_line: Option<usize>,
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
        let Some(bounds) = row.compute_bounds(list) else { return };
        let page = self.adjustment.page_size();
        if page <= 1.0 {
            return;
        }
        let target = bounds.y() as f64 + bounds.height() as f64 / 2.0 - page * ACTIVE_LINE_ANCHOR;
        let max = (self.adjustment.upper() - page).max(0.0);
        self.target.set(Some(target.clamp(0.0, max)));
    }

    fn advance(&self, delta: f64) {
        let Some(target) = self.target.get() else { return };
        let value = self.adjustment.value();
        let distance = target - value;
        let velocity = self.velocity.get();
        if distance.abs() < 0.5 && velocity.abs() < 4.0 {
            self.adjustment.set_value(target);
            self.cancel();
            return;
        }
        let response = SCROLL_RESPONSE;
        let velocity = velocity + (response * response * distance - 2.0 * response * velocity) * delta;
        self.velocity.set(velocity);
        self.adjustment.set_value(value + velocity * delta);
    }
}

#[cfg(test)]
mod tests {
    use super::active_line;

    fn lines() -> Vec<(f64, String)> {
        vec![
            (0.0, "one".into()),
            (10.0, "two".into()),
            (20.0, "three".into()),
        ]
    }

    #[test]
    fn holds_the_last_line_whose_stamp_has_passed() {
        assert_eq!(active_line(&lines(), 0.0), Some(0));
        assert_eq!(active_line(&lines(), 9.9), Some(0));
        assert_eq!(active_line(&lines(), 10.0), Some(1));
        assert_eq!(active_line(&lines(), 999.0), Some(2));
    }

    #[test]
    fn nothing_is_active_before_the_first_stamp() {
        let late = vec![(5.0, "late".to_string())];
        assert_eq!(active_line(&late, 1.0), None);
    }
}
