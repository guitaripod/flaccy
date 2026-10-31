use crate::events::AppEvent;
use crate::library::format_time;
use crate::musicvideo::{self, playback::StageState, Candidate, Phase, VideoMatch, VideoState};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

/// How far one press of the nudge buttons shifts the picture against the
/// sound. Small enough to land on a cut, large enough to feel like progress.
const NUDGE_STEP: f64 = 0.25;

/// How long the control strip and the pointer stay up after the pointer last
/// moved over the picture.
const CONTROLS_LINGER: Duration = Duration::from_millis(2500);

/// How far the arrow keys move playback in the full-screen window.
const FULLSCREEN_SEEK_STEP: f64 = 5.0;

/// The thumbnail size the chooser asks YouTube for, 320×180.
const THUMBNAIL: &str = "mqdefault.jpg";

pub struct VideoView {
    pub widget: gtk::Widget,
    /// Activating loads and syncs a video for whatever is playing;
    /// deactivating parks the pipeline so nothing streams off screen.
    pub set_active: Rc<dyn Fn(bool)>,
}

/// The music video lens: the picture, streamed from the web and slaved to the
/// lossless file playing from disk, with the controls that matter when the
/// automatic match or its alignment needs a human opinion.
pub fn build(ui: &Rc<Ui>) -> VideoView {
    let picture = video_picture();
    let offload = offloaded(&picture);

    let frame = gtk::AspectFrame::builder()
        .ratio(16.0 / 9.0)
        .obey_child(false)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .child(&offload)
        .build();
    frame.add_css_class("mv-stage");
    frame.set_overflow(gtk::Overflow::Hidden);

    let status = StatusLayer::new(ui);
    let controls = ControlBar::new(ui);

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&frame));
    overlay.add_overlay(&status.widget);
    overlay.add_overlay(&controls.widget);
    reveal_controls_on_motion(&overlay, &controls);
    open_fullscreen_on_double_click(ui, &overlay);

    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(16)
        .margin_end(16)
        .build();
    column.append(&overlay);
    column.append(&controls.caption);

    let clamp = adw::Clamp::builder()
        .maximum_size(900)
        .tightening_threshold(400)
        .child(&column)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .vexpand(true)
        .child(&clamp)
        .build();

    let render: Rc<dyn Fn()> = {
        let ui = Rc::clone(ui);
        let picture = picture.clone();
        let status = status.clone();
        let controls = controls.clone();
        Rc::new(move || {
            if picture.paintable().is_none() {
                if let Some(paintable) = ui.core.music_video.paintable() {
                    picture.set_paintable(Some(&paintable));
                }
            }
            let state = ui.core.music_video.state();
            let stage = ui.core.music_video.stage_state();
            let exhausted = ui.core.music_video.exhausted();
            status.render(&state, &stage, exhausted);
            controls.render(&ui, &state);
        })
    };
    render();

    let inhibitor = IdleInhibitor::new(ui);
    {
        let render = Rc::clone(&render);
        let inhibitor = Rc::clone(&inhibitor);
        ui.core.hub.subscribe_widget(&scroll, move |_, event| {
            if matches!(
                event,
                AppEvent::MusicVideoChanged | AppEvent::TrackChanged(_)
            ) {
                render();
            }
            if matches!(
                event,
                AppEvent::MusicVideoChanged | AppEvent::PlayingChanged(_)
            ) {
                inhibitor.update();
            }
        });
    }

    let set_active: Rc<dyn Fn(bool)> = {
        let ui = Rc::clone(ui);
        let render = Rc::clone(&render);
        let lens = scroll.downgrade();
        Rc::new(move |active| {
            musicvideo::set_enabled(&ui.core, active);
            let on_screen =
                lens.upgrade().is_some_and(|lens| lens.is_mapped()) && !ui.window.is_suspended();
            musicvideo::set_visible(&ui.core, active && on_screen);
            render();
            inhibitor.update();
        })
    };

    VideoView {
        widget: scroll.upcast(),
        set_active,
    }
}

fn video_picture() -> gtk::Picture {
    let picture = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Contain)
        .hexpand(true)
        .vexpand(true)
        .build();
    picture.add_css_class("mv-picture");
    picture
}

/// Lets the compositor show the decoder's frames directly when they arrive as
/// DMA-BUFs, instead of GTK compositing every frame itself; anything else
/// draws as before.
fn offloaded(picture: &gtk::Picture) -> gtk::GraphicsOffload {
    let offload = gtk::GraphicsOffload::new(Some(picture));
    offload.set_enabled(gtk::GraphicsOffloadEnabled::Enabled);
    offload.set_black_background(true);
    offload.set_hexpand(true);
    offload.set_vexpand(true);
    offload
}

/// Keeps the screen awake while a music video plays where someone can watch
/// it, the way any video player does; audio alone never holds it.
struct IdleInhibitor {
    ui: Rc<Ui>,
    cookie: Cell<Option<u32>>,
}

impl IdleInhibitor {
    fn new(ui: &Rc<Ui>) -> Rc<Self> {
        Rc::new(Self {
            ui: Rc::clone(ui),
            cookie: Cell::new(None),
        })
    }

    fn update(&self) {
        let video = &self.ui.core.music_video;
        let wanted = video.is_showing()
            && self.ui.core.player.is_playing()
            && video.state().matched().is_some()
            && matches!(video.stage_state(), StageState::Playing)
            && !video.exhausted();
        let Some(app) = self.ui.window.application() else {
            return;
        };
        match (wanted, self.cookie.get()) {
            (true, None) => {
                let cookie = app.inhibit(
                    Some(&self.ui.window),
                    gtk::ApplicationInhibitFlags::IDLE,
                    Some("Playing a music video"),
                );
                if cookie != 0 {
                    self.cookie.set(Some(cookie));
                }
            }
            (false, Some(cookie)) => {
                app.uninhibit(cookie);
                self.cookie.set(None);
            }
            _ => {}
        }
    }
}

/// What the status layer's button does.
#[derive(Clone, Copy, PartialEq, Debug)]
enum Action {
    /// Search YouTube from scratch: nothing was found last time.
    SearchAgain,
    /// Retry the match already decided with a fresh stream.
    TryAgain,
}

impl Action {
    fn label(self) -> &'static str {
        match self {
            Action::SearchAgain => "Search Again",
            Action::TryAgain => "Try Again",
        }
    }
}

/// The layer that covers the picture whenever there is nothing to show:
/// searching, buffering, no match, or a failure worth explaining.
#[derive(Clone)]
struct StatusLayer {
    widget: gtk::Box,
    spinner: adw::Spinner,
    icon: gtk::Image,
    label: gtk::Label,
    detail: gtk::Label,
    button: gtk::Button,
    action: Rc<Cell<Action>>,
}

impl StatusLayer {
    fn new(ui: &Rc<Ui>) -> Self {
        let spinner = adw::Spinner::new();
        spinner.set_size_request(36, 36);
        let icon = gtk::Image::from_icon_name("video-display-symbolic");
        icon.set_pixel_size(40);
        icon.add_css_class("dim");
        let label = gtk::Label::new(None);
        label.add_css_class("title-4");
        label.set_wrap(true);
        label.set_justify(gtk::Justification::Center);
        let detail = gtk::Label::new(None);
        detail.add_css_class("dim");
        detail.add_css_class("caption");
        detail.set_wrap(true);
        detail.set_justify(gtk::Justification::Center);
        let button = gtk::Button::with_label(Action::SearchAgain.label());
        button.add_css_class("pill");
        button.set_halign(gtk::Align::Center);
        let action = Rc::new(Cell::new(Action::SearchAgain));
        {
            let ui = Rc::clone(ui);
            let action = Rc::clone(&action);
            button.connect_clicked(move |_| match action.get() {
                Action::SearchAgain => musicvideo::refresh(&ui.core),
                Action::TryAgain => musicvideo::retry(&ui.core),
            });
        }

        let widget = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(10)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::Center)
            .build();
        widget.add_css_class("mv-status");
        widget.append(&spinner);
        widget.append(&icon);
        widget.append(&label);
        widget.append(&detail);
        widget.append(&button);

        Self {
            widget,
            spinner,
            icon,
            label,
            detail,
            button,
            action,
        }
    }

    fn render(&self, state: &VideoState, stage: &StageState, exhausted: bool) {
        let description = describe(state, stage, exhausted);
        let showing = description.headline.is_some() || description.busy;
        self.widget.set_visible(showing);
        self.spinner.set_visible(description.busy);
        self.icon
            .set_visible(!description.busy && description.icon.is_some());
        if let Some(icon) = description.icon {
            self.icon.set_icon_name(Some(icon));
        }
        show_text(&self.label, description.headline);
        show_text(&self.detail, description.detail);
        match description.action {
            Some(action) => {
                self.action.set(action);
                self.button.set_label(action.label());
                self.button.set_visible(true);
            }
            None => self.button.set_visible(false),
        }
    }
}

fn show_text(label: &gtk::Label, text: Option<String>) {
    match text {
        Some(text) => {
            label.set_label(&text);
            label.set_visible(true);
        }
        None => label.set_visible(false),
    }
}

#[derive(Default)]
struct Description {
    busy: bool,
    icon: Option<&'static str>,
    headline: Option<String>,
    detail: Option<String>,
    action: Option<Action>,
}

/// One place that decides what the lens says, so the wording is the same
/// wherever it is shown.
fn describe(state: &VideoState, stage: &StageState, exhausted: bool) -> Description {
    if exhausted && matches!(state, VideoState::Ready(_)) {
        return Description {
            icon: Some("media-playback-stop-symbolic"),
            headline: Some("The video ended before the song".to_string()),
            detail: Some("Your audio keeps playing to the end.".to_string()),
            ..Description::default()
        };
    }
    match state {
        VideoState::Off => Description {
            icon: Some("video-display-symbolic"),
            headline: Some("Music video mode is off".to_string()),
            ..Description::default()
        },
        VideoState::Searching(phase) => {
            let (headline, detail) = match phase {
                Phase::Searching => ("Finding a music video…".to_string(), None),
                Phase::Judging(model) => (
                    format!("Asking {model} to choose…"),
                    Some("The closest results were too close to call.".to_string()),
                ),
                Phase::Loading => ("Loading the video…".to_string(), None),
            };
            Description {
                busy: true,
                headline: Some(headline),
                detail,
                ..Description::default()
            }
        }
        VideoState::Missing(reason) => Description {
            icon: Some("video-display-symbolic"),
            headline: Some("No music video for this song".to_string()),
            detail: Some(format!(
                "{reason} Your audio keeps playing — pick or paste a video from the list button if you know one."
            )),
            action: Some(Action::SearchAgain),
            ..Description::default()
        },
        VideoState::Failed(message) => Description {
            icon: Some("network-offline-symbolic"),
            headline: Some(message.clone()),
            action: Some(Action::TryAgain),
            ..Description::default()
        },
        VideoState::Ready(_) => match stage {
            StageState::Failed(message) => Description {
                icon: Some("network-offline-symbolic"),
                headline: Some(message.clone()),
                detail: Some("Your audio keeps playing.".to_string()),
                action: Some(Action::TryAgain),
                ..Description::default()
            },
            StageState::Buffering(percent) => Description {
                busy: true,
                headline: Some(format!("Buffering… {percent}%")),
                ..Description::default()
            },
            StageState::Opening => Description {
                busy: true,
                headline: Some("Opening video…".to_string()),
                ..Description::default()
            },
            StageState::Idle | StageState::Playing => Description::default(),
        },
    }
}

/// The hovering strip along the foot of the picture, plus the caption beneath
/// it naming what is playing and how it was chosen.
#[derive(Clone)]
struct ControlBar {
    widget: gtk::Revealer,
    /// Whether there is anything to control. The bar is revealed by moving
    /// the pointer over the picture, so it must never appear over an empty
    /// stage.
    available: Rc<Cell<bool>>,
    caption: gtk::Box,
    title: gtk::Label,
    provenance: gtk::Label,
    sync_chip: gtk::Label,
    reset: gtk::Button,
}

impl ControlBar {
    fn new(ui: &Rc<Ui>) -> Self {
        let sync_chip = gtk::Label::new(None);
        sync_chip.add_css_class("mv-chip");

        let earlier = icon_button("go-previous-symbolic", "Show the video earlier");
        let later = icon_button("go-next-symbolic", "Show the video later");
        let reset = icon_button("edit-undo-symbolic", "Back to the automatic sync");
        let choose = icon_button("view-list-symbolic", "Choose a different video");
        let open = icon_button("external-link-symbolic", "Open on YouTube at this moment");
        let fullscreen = icon_button("view-fullscreen-symbolic", "Full screen");

        {
            let ui = Rc::clone(ui);
            earlier.connect_clicked(move |_| musicvideo::nudge_offset(&ui.core, -NUDGE_STEP));
        }
        {
            let ui = Rc::clone(ui);
            later.connect_clicked(move |_| musicvideo::nudge_offset(&ui.core, NUDGE_STEP));
        }
        {
            let ui = Rc::clone(ui);
            reset.connect_clicked(move |_| musicvideo::reset_offset(&ui.core));
        }
        {
            let ui = Rc::clone(ui);
            choose.connect_clicked(move |_| present_chooser(&ui));
        }
        {
            let ui = Rc::clone(ui);
            open.connect_clicked(move |_| open_on_youtube(&ui));
        }
        {
            let ui = Rc::clone(ui);
            fullscreen.connect_clicked(move |_| present_fullscreen(&ui));
        }

        let bar = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        bar.add_css_class("mv-controls");
        bar.set_halign(gtk::Align::Center);
        bar.append(&sync_chip);
        bar.append(&separator());
        bar.append(&earlier);
        bar.append(&reset);
        bar.append(&later);
        bar.append(&separator());
        bar.append(&choose);
        bar.append(&open);
        bar.append(&fullscreen);

        let widget = gtk::Revealer::builder()
            .transition_type(gtk::RevealerTransitionType::Crossfade)
            .transition_duration(160)
            .halign(gtk::Align::Center)
            .valign(gtk::Align::End)
            .margin_bottom(14)
            .child(&bar)
            .build();

        let title = gtk::Label::builder()
            .ellipsize(pango::EllipsizeMode::End)
            .justify(gtk::Justification::Center)
            .build();
        title.add_css_class("mv-title");
        let provenance = gtk::Label::builder()
            .ellipsize(pango::EllipsizeMode::End)
            .justify(gtk::Justification::Center)
            .build();
        provenance.add_css_class("dim");
        provenance.add_css_class("caption");

        let caption = gtk::Box::builder()
            .orientation(gtk::Orientation::Vertical)
            .spacing(3)
            .halign(gtk::Align::Center)
            .build();
        caption.append(&title);
        caption.append(&provenance);

        Self {
            widget,
            available: Rc::new(Cell::new(false)),
            caption,
            title,
            provenance,
            sync_chip,
            reset,
        }
    }

    fn render(&self, ui: &Rc<Ui>, state: &VideoState) {
        let Some(found) = state.matched() else {
            self.available.set(false);
            self.widget.set_reveal_child(false);
            self.caption.set_visible(false);
            return;
        };
        self.available.set(true);
        self.caption.set_visible(true);
        self.title.set_label(&found.title);
        self.provenance.set_label(&provenance_line(found));
        let video = &ui.core.music_video;
        self.sync_chip.set_label(&sync_line(
            found,
            video.drift(),
            video.stream_height(),
            video.stream_codec().map(|codec| codec.label()),
        ));
        self.reset.set_sensitive(found.trim.abs() >= 0.005);
    }
}

/// Opens the video on YouTube at the moment the picture is showing.
fn open_on_youtube(ui: &Rc<Ui>) {
    let Some(found) = ui.core.music_video.state().matched().cloned() else {
        return;
    };
    let at = ui.core.music_video.video_position().unwrap_or(0.0);
    let launcher = gtk::UriLauncher::new(&musicvideo::search::watch_url_at(&found.video_id, at));
    let ui = Rc::clone(ui);
    launcher.launch(
        Some(&ui.window.clone()),
        gtk::gio::Cancellable::NONE,
        move |result| {
            if let Err(err) = result {
                ui.core.toast(&format!(
                    "Couldn't open YouTube — no browser answered ({err})"
                ));
            }
        },
    );
}

/// Names the channel and says, in one clause, why this video was picked — a
/// hand-picked match, a model's opinion, or the scorer's.
fn provenance_line(found: &VideoMatch) -> String {
    let channel = if found.channel.is_empty() {
        "YouTube".to_string()
    } else {
        found.channel.clone()
    };
    if found.reason.is_empty() {
        channel
    } else {
        format!("{channel} · {}", found.reason)
    }
}

/// Reports the state of the sync in the fewest words that are still true: how
/// the timeline was arrived at, any hand trim on top, whether the picture is
/// locked to the sound right now, and what is being streamed.
fn sync_line(
    found: &VideoMatch,
    drift: Option<f64>,
    height: Option<i32>,
    codec: Option<&str>,
) -> String {
    let mut line = if found.aligned {
        match found.map.cuts() {
            0 if found.offset.abs() < 0.05 => "Aligned".to_string(),
            0 => format!("Aligned {:+.2}s", found.offset),
            1 => "Aligned across 1 cut".to_string(),
            cuts => format!("Aligned across {cuts} cuts"),
        }
    } else if found.offset.abs() >= 0.05 {
        format!("Offset {:+.2}s", found.offset)
    } else {
        "Synced".to_string()
    };
    if found.trim.abs() >= 0.005 {
        line.push_str(&format!(" · nudged {:+.2}s", found.trim));
    }
    if drift.is_some_and(|drift| drift.abs() >= crate::musicvideo::sync::HARD_SEEK) {
        line.push_str(" · catching up");
    }
    match (height, codec) {
        (Some(height), Some(codec)) => {
            line.push_str(&format!(" · {} {codec}", musicvideo::quality_label(height)))
        }
        (Some(height), None) => line.push_str(&format!(" · {}", musicvideo::quality_label(height))),
        _ => {}
    }
    line
}

/// Shows the control strip while the pointer moves over the picture and
/// hides it once the pointer rests, the way a video player does.
fn reveal_controls_on_motion(host: &gtk::Overlay, controls: &ControlBar) {
    let motion = gtk::EventControllerMotion::new();
    let hide: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
    let show = {
        let revealer = controls.widget.clone();
        let available = Rc::clone(&controls.available);
        let hide = Rc::clone(&hide);
        move |hover: &gtk::EventControllerMotion| {
            revealer.set_reveal_child(available.get());
            if let Some(source) = hide.borrow_mut().take() {
                source.remove();
            }
            let revealer = revealer.clone();
            let controller = hover.clone();
            let slot = Rc::clone(&hide);
            let source = glib::timeout_add_local_once(CONTROLS_LINGER, move || {
                slot.borrow_mut().take();
                if !pointer_over_controls(&controller, &revealer) {
                    revealer.set_reveal_child(false);
                }
            });
            *hide.borrow_mut() = Some(source);
        }
    };
    {
        let show = show.clone();
        motion.connect_enter(move |hover, _, _| show(hover));
    }
    motion.connect_motion(move |hover, _, _| show(hover));
    {
        let revealer = controls.widget.clone();
        let hide = Rc::clone(&hide);
        motion.connect_leave(move |_| {
            if let Some(source) = hide.borrow_mut().take() {
                source.remove();
            }
            revealer.set_reveal_child(false);
        });
    }
    host.add_controller(motion);
}

/// The strip stays up while the pointer rests on one of its own buttons.
fn pointer_over_controls(motion: &gtk::EventControllerMotion, revealer: &gtk::Revealer) -> bool {
    motion.contains_pointer()
        && revealer
            .child()
            .is_some_and(|bar| bar.state_flags().contains(gtk::StateFlags::PRELIGHT))
}

fn open_fullscreen_on_double_click(ui: &Rc<Ui>, host: &gtk::Overlay) {
    let click = gtk::GestureClick::new();
    let ui = Rc::clone(ui);
    click.connect_pressed(move |gesture, presses, _, _| {
        if presses == 2 && ui.core.music_video.state().matched().is_some() {
            gesture.set_state(gtk::EventSequenceState::Claimed);
            present_fullscreen(&ui);
        }
    });
    host.add_controller(click);
}

fn separator() -> gtk::Separator {
    let separator = gtk::Separator::new(gtk::Orientation::Vertical);
    separator.add_css_class("mv-sep");
    separator
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("flat");
    button.add_css_class("mv-button");
    button.set_tooltip_text(Some(tooltip));
    button
}

/// Lists what the search turned up, best match first and the playing video
/// marked, with thumbnails so a lyric video is told from the real one at a
/// glance — plus a field for pasting the right video when the search missed
/// it. The correction is remembered.
fn present_chooser(ui: &Rc<Ui>) {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");

    let spinner = adw::Spinner::new();
    spinner.set_size_request(28, 28);
    let loading = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .margin_top(28)
        .margin_bottom(28)
        .build();
    loading.append(&spinner);
    loading.append(&gtk::Label::new(Some("Searching YouTube…")));

    let dialog = adw::Dialog::builder()
        .title("Choose a Music Video")
        .content_width(560)
        .content_height(600)
        .build();

    let link = link_entry(ui, &dialog);
    let pasted = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    pasted.add_css_class("boxed-list");
    pasted.append(&link);

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(12)
        .margin_bottom(18)
        .margin_start(16)
        .margin_end(16)
        .build();
    content.append(&pasted);
    content.append(&loading);
    content.append(&list);
    list.set_visible(false);

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .child(&content)
        .build();

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(
        &adw::HeaderBar::builder()
            .show_end_title_buttons(false)
            .build(),
    );
    toolbar.set_content(Some(&scroll));
    dialog.set_child(Some(&toolbar));

    let track_duration = ui
        .core
        .player
        .current_track()
        .map(|track| track.duration)
        .unwrap_or(0.0);
    let playing = ui
        .core
        .music_video
        .state()
        .matched()
        .map(|found| found.video_id.clone());

    let rows: Rc<RefCell<Vec<gtk::Widget>>> = Rc::new(RefCell::new(Vec::new()));
    {
        let hub = Rc::clone(&ui.core.hub);
        let ui = Rc::clone(ui);
        let dialog = dialog.clone();
        let list = list.clone();
        let loading = loading.clone();
        let rows = Rc::clone(&rows);
        hub.subscribe_widget(&scroll, move |_, event| {
            if !matches!(event, AppEvent::MusicVideoCandidates) {
                return;
            }
            for row in rows.borrow_mut().drain(..) {
                list.remove(&row);
            }
            let candidates = ui.core.music_video.candidates();
            loading.set_visible(false);
            if candidates.is_empty() {
                let empty = adw::ActionRow::builder()
                    .title("Nothing turned up")
                    .subtitle("YouTube returned no results for this song — paste a link above if you know the video")
                    .build();
                list.append(&empty);
                rows.borrow_mut().push(empty.upcast());
            }
            let mut thumbnails = Vec::new();
            for candidate in candidates {
                let current = playing.as_deref() == Some(candidate.id.as_str());
                let (row, image) = candidate_row(&ui, &dialog, &candidate, track_duration, current);
                list.append(&row);
                rows.borrow_mut().push(row.upcast());
                thumbnails.push((candidate.id.clone(), image));
            }
            load_thumbnails(thumbnails);
            list.set_visible(true);
        });
    }

    musicvideo::request_candidates(&ui.core);
    dialog.present(Some(&ui.window));
}

/// The row that takes a pasted YouTube link: the way to the right video when
/// the search never surfaced it.
fn link_entry(ui: &Rc<Ui>, dialog: &adw::Dialog) -> adw::EntryRow {
    let entry = adw::EntryRow::builder()
        .title("Paste a YouTube link")
        .show_apply_button(true)
        .input_purpose(gtk::InputPurpose::Url)
        .build();
    let ui = Rc::clone(ui);
    let dialog = dialog.clone();
    entry.connect_apply(move |entry| {
        let text = entry.text();
        if musicvideo::choose_link(&ui.core, &text) {
            dialog.close();
        } else {
            entry.add_css_class("error");
            entry.set_title(
                "That isn't a YouTube video link — paste a watch, youtu.be or Shorts link",
            );
        }
    });
    entry.connect_changed(|entry| {
        if entry.has_css_class("error") {
            entry.remove_css_class("error");
            entry.set_title("Paste a YouTube link");
        }
    });
    entry
}

fn candidate_row(
    ui: &Rc<Ui>,
    dialog: &adw::Dialog,
    candidate: &Candidate,
    track_duration: f64,
    current: bool,
) -> (adw::ActionRow, gtk::Picture) {
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&candidate.title))
        .subtitle(glib::markup_escape_text(&candidate_subtitle(
            candidate,
            track_duration,
        )))
        .activatable(!current)
        .build();
    let thumbnail = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .width_request(96)
        .height_request(54)
        .overflow(gtk::Overflow::Hidden)
        .build();
    thumbnail.add_css_class("mv-thumb");
    let slot = adw::Clamp::builder()
        .maximum_size(96)
        .tightening_threshold(96)
        .valign(gtk::Align::Center)
        .child(&thumbnail)
        .build();
    row.add_prefix(&slot);
    if current {
        let mark = gtk::Image::from_icon_name("object-select-symbolic");
        mark.set_tooltip_text(Some("Playing now"));
        mark.add_css_class("accent");
        row.add_suffix(&mark);
    }
    let ui = Rc::clone(ui);
    let dialog = dialog.clone();
    let candidate = candidate.clone();
    row.connect_activated(move |_| {
        musicvideo::choose(&ui.core, candidate.clone());
        dialog.close();
    });
    (row, thumbnail)
}

/// Fetches the chooser's thumbnails off the main thread and fills each one in
/// as it lands. A thumbnail that fails to load leaves its slot empty; the row
/// still says everything that matters.
fn load_thumbnails(slots: Vec<(String, gtk::Picture)>) {
    if slots.is_empty() {
        return;
    }
    let ids: Vec<String> = slots.iter().map(|(id, _)| id.clone()).collect();
    let (tx, rx) = async_channel::unbounded::<(usize, Vec<u8>)>();
    std::thread::Builder::new()
        .name("flaccy-mv-thumbs".into())
        .spawn(move || {
            for (index, id) in ids.iter().enumerate() {
                let url = format!("https://i.ytimg.com/vi/{id}/{THUMBNAIL}");
                let Ok(response) = ureq::get(&url).timeout(Duration::from_secs(8)).call() else {
                    continue;
                };
                let mut bytes = Vec::new();
                if std::io::Read::read_to_end(&mut response.into_reader(), &mut bytes).is_ok()
                    && tx.send_blocking((index, bytes)).is_err()
                {
                    return;
                }
            }
        })
        .ok();
    glib::spawn_future_local(async move {
        while let Ok((index, bytes)) = rx.recv().await {
            let Some((_, picture)) = slots.get(index) else {
                continue;
            };
            if let Ok(texture) = gtk::gdk::Texture::from_bytes(&glib::Bytes::from_owned(bytes)) {
                picture.set_paintable(Some(&texture));
            }
        }
    });
}

/// The channel, the runtime, how far that runtime sits from the song, and how
/// many people have watched it — between them these tell a lyric video from
/// the real one at a glance.
fn candidate_subtitle(candidate: &Candidate, track_duration: f64) -> String {
    let mut parts = Vec::new();
    if !candidate.channel.is_empty() {
        parts.push(candidate.channel.clone());
    }
    if candidate.duration > 0.0 {
        parts.push(format_time(candidate.duration));
        if track_duration > 0.0 {
            let drift = candidate.duration - track_duration;
            if drift.abs() >= 2.0 {
                parts.push(format!("{drift:+.0}s vs your file"));
            }
        }
    }
    if let Some(views) = candidate.view_count {
        parts.push(format!("{} views", compact_count(views)));
    }
    parts.join(" · ")
}

/// Watch counts run to ten digits; nobody reads those, so they are rounded to
/// one significant decimal and given a suffix.
fn compact_count(value: u64) -> String {
    for (limit, suffix) in [(1_000_000_000u64, "B"), (1_000_000, "M"), (1_000, "K")] {
        if value >= limit {
            let scaled = value as f64 / limit as f64;
            return if scaled < 10.0 {
                format!("{scaled:.1}{suffix}")
            } else {
                format!("{scaled:.0}{suffix}")
            };
        }
    }
    value.to_string()
}

thread_local! {
    static FULLSCREEN: RefCell<Option<gtk::Window>> = const { RefCell::new(None) };
}

/// A second window showing the same paintable, so going full screen costs no
/// reload and the sync loop never notices. One at a time: asking again brings
/// the open one forward. Space plays and pauses, the arrows seek, and the
/// pointer hides while it rests.
fn present_fullscreen(ui: &Rc<Ui>) {
    if let Some(open) = FULLSCREEN.with(|slot| slot.borrow().clone()) {
        open.present();
        return;
    }
    let Some(paintable) = ui.core.music_video.paintable() else {
        ui.core
            .toast("No video is playing yet — wait for the picture, then go full screen");
        return;
    };
    let picture = video_picture();
    picture.set_paintable(Some(&paintable));
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    holder.add_css_class("mv-fullscreen");
    holder.append(&offloaded(&picture));

    let window = gtk::Window::builder()
        .transient_for(&ui.window)
        .title("Music Video")
        .child(&holder)
        .fullscreened(true)
        .build();

    let keys = gtk::EventControllerKey::new();
    {
        let window = window.clone();
        let ui = Rc::clone(ui);
        keys.connect_key_pressed(move |_, key, _, _| {
            match key {
                gtk::gdk::Key::Escape | gtk::gdk::Key::f | gtk::gdk::Key::q => window.close(),
                gtk::gdk::Key::space => ui.core.player.toggle_play_pause(),
                gtk::gdk::Key::Left => seek_by(&ui, -FULLSCREEN_SEEK_STEP),
                gtk::gdk::Key::Right => seek_by(&ui, FULLSCREEN_SEEK_STEP),
                _ => return glib::Propagation::Proceed,
            }
            glib::Propagation::Stop
        });
    }
    window.add_controller(keys);

    let click = gtk::GestureClick::new();
    {
        let window = window.clone();
        click.connect_pressed(move |_, presses, _, _| {
            if presses >= 2 {
                window.close();
            }
        });
    }
    holder.add_controller(click);
    hide_resting_pointer(&holder);

    {
        let ui = Rc::clone(ui);
        window.connect_close_request(move |_| {
            FULLSCREEN.with(|slot| slot.borrow_mut().take());
            musicvideo::set_fullscreen(&ui.core, false);
            glib::Propagation::Proceed
        });
    }
    FULLSCREEN.with(|slot| *slot.borrow_mut() = Some(window.clone()));
    musicvideo::set_fullscreen(&ui.core, true);
    window.present();
}

fn seek_by(ui: &Rc<Ui>, delta: f64) {
    let Some(position) = ui.core.player.position() else {
        return;
    };
    let duration = ui.core.player.duration().unwrap_or(f64::MAX);
    ui.core
        .player
        .seek((position + delta).clamp(0.0, (duration - 1.0).max(0.0)));
}

/// Hides the pointer over the full-screen picture once it stops moving, and
/// brings it back on the next motion.
fn hide_resting_pointer(surface: &gtk::Box) {
    let motion = gtk::EventControllerMotion::new();
    let pending: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
    let last = Rc::new(Cell::new((f64::NAN, f64::NAN)));
    let surface_weak = surface.downgrade();
    motion.connect_motion(move |_, x, y| {
        if last.replace((x, y)) == (x, y) {
            return;
        }
        let Some(surface) = surface_weak.upgrade() else {
            return;
        };
        surface.set_cursor(None);
        if let Some(source) = pending.borrow_mut().take() {
            source.remove();
        }
        let slot = Rc::clone(&pending);
        let resting = surface.downgrade();
        let source = glib::timeout_add_local_once(CONTROLS_LINGER, move || {
            slot.borrow_mut().take();
            if let Some(surface) = resting.upgrade() {
                surface.set_cursor_from_name(Some("none"));
            }
        });
        *pending.borrow_mut() = Some(source);
    });
    surface.add_controller(motion);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_library::music_video::{Segment, TimeMap};

    fn found(offset: f64, aligned: bool, reason: &str, channel: &str) -> VideoMatch {
        VideoMatch {
            video_id: "abc".into(),
            title: "Song (Official Video)".into(),
            channel: channel.into(),
            duration: 200.0,
            offset,
            aligned,
            chosen_by_user: false,
            reason: reason.into(),
            map: TimeMap::default(),
            trim: 0.0,
            align_version: 0,
        }
    }

    #[test]
    fn a_locked_video_reads_as_synced() {
        assert_eq!(
            sync_line(&found(0.0, false, "", "x"), Some(0.01), None, None),
            "Synced"
        );
    }

    #[test]
    fn an_aligned_video_shows_the_offset_it_found() {
        assert_eq!(
            sync_line(&found(12.42, true, "", "x"), Some(0.0), None, None),
            "Aligned +12.42s"
        );
        assert_eq!(
            sync_line(&found(-3.5, true, "", "x"), Some(0.0), None, None),
            "Aligned -3.50s"
        );
    }

    #[test]
    fn an_edit_says_how_many_cuts_it_follows() {
        let mut edit = found(10.57, true, "", "x");
        edit.map = TimeMap::new(vec![
            Segment {
                start: 0.0,
                offset: 10.57,
                rate: 1.0,
            },
            Segment {
                start: 71.9,
                offset: 5.25,
                rate: 1.0,
            },
        ]);
        assert_eq!(sync_line(&edit, None, None, None), "Aligned across 1 cut");
    }

    #[test]
    fn a_hand_set_offset_is_not_called_an_alignment() {
        assert_eq!(
            sync_line(&found(0.5, false, "", "x"), None, None, None),
            "Offset +0.50s"
        );
        let mut nudged = found(8.0, true, "", "x");
        nudged.trim = -0.25;
        assert_eq!(
            sync_line(&nudged, None, None, None),
            "Aligned +8.00s · nudged -0.25s"
        );
    }

    #[test]
    fn a_large_drift_says_it_is_catching_up() {
        assert_eq!(
            sync_line(
                &found(0.0, true, "", "x"),
                Some(2.0),
                Some(720),
                Some("AV1")
            ),
            "Aligned · catching up · 720p AV1"
        );
    }

    #[test]
    fn the_streamed_height_is_named_when_it_is_known() {
        assert_eq!(
            sync_line(&found(0.0, false, "", "x"), Some(0.0), Some(1080), None),
            "Synced · 1080p"
        );
    }

    #[test]
    fn watch_counts_are_shortened() {
        assert_eq!(compact_count(999), "999");
        assert_eq!(compact_count(1_500), "1.5K");
        assert_eq!(compact_count(12_000), "12K");
        assert_eq!(compact_count(1_234_567), "1.2M");
        assert_eq!(compact_count(430_000_000), "430M");
        assert_eq!(compact_count(2_100_000_000), "2.1B");
    }

    #[test]
    fn provenance_names_the_channel_and_the_reason() {
        assert_eq!(
            provenance_line(&found(0.0, false, "Chosen by qwen3", "Daft Punk")),
            "Daft Punk · Chosen by qwen3"
        );
        assert_eq!(
            provenance_line(&found(0.0, false, "", "Daft Punk")),
            "Daft Punk"
        );
        assert_eq!(provenance_line(&found(0.0, false, "", "")), "YouTube");
    }

    #[test]
    fn a_candidate_subtitle_flags_a_runtime_that_does_not_match() {
        let mut candidate = Candidate {
            id: "x".into(),
            title: "Song".into(),
            channel: "Band".into(),
            duration: 260.0,
            view_count: None,
            live_now: false,
        };
        assert_eq!(
            candidate_subtitle(&candidate, 200.0),
            "Band · 4:20 · +60s vs your file"
        );
        assert_eq!(candidate_subtitle(&candidate, 259.0), "Band · 4:20");
        candidate.view_count = Some(1_234_567);
        assert_eq!(
            candidate_subtitle(&candidate, 259.0),
            "Band · 4:20 · 1.2M views"
        );
    }

    #[test]
    fn the_lens_explains_every_state_it_can_be_in() {
        let searching = describe(
            &VideoState::Searching(Phase::Searching),
            &StageState::Idle,
            false,
        );
        assert!(searching.busy && searching.headline.is_some());
        let judging = describe(
            &VideoState::Searching(Phase::Judging("qwen3:4b".into())),
            &StageState::Idle,
            false,
        );
        assert_eq!(
            judging.headline.as_deref(),
            Some("Asking qwen3:4b to choose…")
        );
        let missing = describe(
            &VideoState::Missing("No results.".into()),
            &StageState::Idle,
            false,
        );
        assert!(missing.headline.is_some() && missing.detail.is_some());
        assert_eq!(missing.action, Some(Action::SearchAgain));
        let failed = describe(
            &VideoState::Failed("Couldn't reach the video's server".into()),
            &StageState::Idle,
            false,
        );
        assert_eq!(
            failed.headline.as_deref(),
            Some("Couldn't reach the video's server")
        );
        assert_eq!(failed.action, Some(Action::TryAgain));
        let ready = VideoState::Ready(found(0.0, true, "", "x"));
        let playing = describe(&ready, &StageState::Playing, false);
        assert!(!playing.busy && playing.headline.is_none());
        let buffering = describe(&ready, &StageState::Buffering(42), false);
        assert!(buffering.busy);
        assert_eq!(buffering.headline.as_deref(), Some("Buffering… 42%"));
        let broken = describe(&ready, &StageState::Failed("No decoder".into()), false);
        assert_eq!(broken.action, Some(Action::TryAgain));
    }

    #[test]
    fn a_song_that_outlasts_its_video_is_told_so() {
        let ready = VideoState::Ready(found(0.0, true, "", "x"));
        let ended = describe(&ready, &StageState::Playing, true);
        assert!(!ended.busy);
        assert_eq!(
            ended.headline.as_deref(),
            Some("The video ended before the song")
        );
        assert!(ended.detail.is_some());
        let missing = describe(
            &VideoState::Missing("No results.".into()),
            &StageState::Idle,
            true,
        );
        assert_eq!(
            missing.headline.as_deref(),
            Some("No music video for this song")
        );
    }
}
