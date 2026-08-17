use crate::events::AppEvent;
use crate::library::format_time;
use crate::musicvideo::{self, playback::StageState, Candidate, VideoMatch, VideoState};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

/// How far one press of the nudge buttons shifts the picture against the
/// sound. Small enough to land on a cut, large enough to feel like progress.
const NUDGE_STEP: f64 = 0.25;

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
    let picture = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Contain)
        .hexpand(true)
        .vexpand(true)
        .build();
    picture.add_css_class("mv-picture");

    let frame = gtk::AspectFrame::builder()
        .ratio(16.0 / 9.0)
        .obey_child(false)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .child(&picture)
        .build();
    frame.add_css_class("mv-stage");

    let status = StatusLayer::new(ui);
    let controls = ControlBar::new(ui);

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&frame));
    overlay.add_overlay(&status.widget);
    overlay.add_overlay(&controls.widget);
    reveal_controls_on_hover(&overlay, &controls);

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
            let exhausted = ui
                .core
                .music_video
                .exhausted(ui.core.player.position().unwrap_or(0.0));
            status.render(&state, &stage, exhausted);
            controls.render(&ui, &state);
        })
    };
    render();

    {
        let render = Rc::clone(&render);
        ui.core.hub.subscribe_widget(&scroll, move |_, event| {
            if matches!(
                event,
                AppEvent::MusicVideoChanged | AppEvent::TrackChanged(_)
            ) {
                render();
            }
        });
    }

    let set_active: Rc<dyn Fn(bool)> = {
        let ui = Rc::clone(ui);
        let render = Rc::clone(&render);
        Rc::new(move |active| {
            musicvideo::set_enabled(&ui.core, active);
            musicvideo::set_visible(&ui.core, active);
            render();
        })
    };

    VideoView {
        widget: scroll.upcast(),
        set_active,
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
    action: gtk::Button,
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
        let action = gtk::Button::with_label("Search Again");
        action.add_css_class("pill");
        action.set_halign(gtk::Align::Center);
        {
            let ui = Rc::clone(ui);
            action.connect_clicked(move |_| musicvideo::refresh(&ui.core));
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
        widget.append(&action);

        Self {
            widget,
            spinner,
            icon,
            label,
            detail,
            action,
        }
    }

    fn render(&self, state: &VideoState, stage: &StageState, exhausted: bool) {
        let (busy, icon, headline, detail, action) = describe(state, stage, exhausted);
        let showing = headline.is_some() || busy;
        self.widget.set_visible(showing);
        self.spinner.set_visible(busy);
        self.icon.set_visible(!busy && icon.is_some());
        if let Some(icon) = icon {
            self.icon.set_icon_name(Some(icon));
        }
        match headline {
            Some(text) => {
                self.label.set_label(&text);
                self.label.set_visible(true);
            }
            None => self.label.set_visible(false),
        }
        match detail {
            Some(text) => {
                self.detail.set_label(&text);
                self.detail.set_visible(true);
            }
            None => self.detail.set_visible(false),
        }
        match action {
            Some(text) => {
                self.action.set_label(text);
                self.action.set_visible(true);
            }
            None => self.action.set_visible(false),
        }
    }
}

type Description = (
    bool,
    Option<&'static str>,
    Option<String>,
    Option<String>,
    Option<&'static str>,
);

/// One place that decides what the lens says, so the wording is the same
/// wherever it is shown.
fn describe(state: &VideoState, stage: &StageState, exhausted: bool) -> Description {
    if exhausted && matches!(state, VideoState::Ready(_)) {
        return (
            false,
            Some("media-playback-stop-symbolic"),
            Some("The video ended before the song".to_string()),
            Some("Your audio keeps playing to the end.".to_string()),
            None,
        );
    }
    match state {
        VideoState::Off => (
            false,
            Some("video-display-symbolic"),
            Some("Music video mode is off".to_string()),
            None,
            None,
        ),
        VideoState::Searching => (
            true,
            None,
            Some("Finding a music video…".to_string()),
            None,
            None,
        ),
        VideoState::Missing => (
            false,
            Some("video-display-symbolic"),
            Some("No music video for this song".to_string()),
            Some("Nothing convincing turned up. Your audio keeps playing.".to_string()),
            Some("Search Again"),
        ),
        VideoState::Failed(message) => (
            false,
            Some("network-offline-symbolic"),
            Some(message.clone()),
            None,
            Some("Try Again"),
        ),
        VideoState::Ready(_) => match stage {
            StageState::Failed(message) => (
                false,
                Some("network-offline-symbolic"),
                Some(message.clone()),
                None,
                Some("Try Again"),
            ),
            StageState::Buffering(percent) => (
                true,
                None,
                Some(format!("Buffering… {percent}%")),
                None,
                None,
            ),
            StageState::Opening => (true, None, Some("Opening video…".to_string()), None, None),
            StageState::Idle | StageState::Playing => (false, None, None, None, None),
        },
    }
}

/// The hovering strip along the foot of the picture, plus the caption beneath
/// it naming what is playing and how it was chosen.
#[derive(Clone)]
struct ControlBar {
    widget: gtk::Revealer,
    /// Whether there is anything to control. The bar is revealed by hovering
    /// the picture, so it must never appear over an empty stage.
    available: Rc<Cell<bool>>,
    caption: gtk::Box,
    title: gtk::Label,
    provenance: gtk::Label,
    sync_chip: gtk::Label,
    open: gtk::Button,
}

impl ControlBar {
    fn new(ui: &Rc<Ui>) -> Self {
        let sync_chip = gtk::Label::new(None);
        sync_chip.add_css_class("mv-chip");

        let earlier = icon_button("go-previous-symbolic", "Show the video earlier");
        let later = icon_button("go-next-symbolic", "Show the video later");
        let reset = icon_button("edit-undo-symbolic", "Reset the sync offset");
        let choose = icon_button("view-list-symbolic", "Choose a different video");
        let open = icon_button("external-link-symbolic", "Open on YouTube");
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
            open.connect_clicked(move |_| {
                let Some(found) = ui.core.music_video.state().matched().cloned() else {
                    return;
                };
                let launcher = gtk::UriLauncher::new(&musicvideo::search::watch_url(&found.video_id));
                launcher.launch(Some(&ui.window), gtk::gio::Cancellable::NONE, |_| {});
            });
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
            open,
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
        self.sync_chip.set_label(&sync_line(
            found,
            ui.core.music_video.drift(),
            ui.core.music_video.stream_height(),
        ));
        self.open.set_sensitive(true);
    }
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
/// the offset was arrived at, and whether the picture is currently locked to
/// the sound.
fn sync_line(found: &VideoMatch, drift: Option<f64>, height: Option<i32>) -> String {
    let offset = if found.offset.abs() < 0.05 {
        String::new()
    } else {
        format!(" {:+.2}s", found.offset)
    };
    let lead = if found.aligned {
        "Aligned"
    } else if found.offset.abs() >= 0.05 {
        "Offset"
    } else {
        "Synced"
    };
    let mut line = format!("{lead}{offset}");
    if drift.is_some_and(|drift| drift.abs() >= crate::musicvideo::sync::HARD_SEEK) {
        line.push_str(" · catching up");
    }
    if let Some(height) = height {
        line.push_str(&format!(" · {}", musicvideo::quality_label(height)));
    }
    line
}

/// Keeps the control strip out of the way of the picture until the pointer
/// asks for it, the way a video player should.
fn reveal_controls_on_hover(host: &gtk::Overlay, controls: &ControlBar) {
    let motion = gtk::EventControllerMotion::new();
    {
        let revealer = controls.widget.clone();
        let available = Rc::clone(&controls.available);
        motion.connect_enter(move |_, _, _| revealer.set_reveal_child(available.get()));
    }
    {
        let revealer = controls.widget.clone();
        motion.connect_leave(move |_| revealer.set_reveal_child(false));
    }
    host.add_controller(motion);
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

/// Lists what the search actually turned up, so a wrong automatic pick is one
/// click from being corrected — and the correction is remembered.
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

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(12)
        .margin_top(12)
        .margin_bottom(18)
        .margin_start(16)
        .margin_end(16)
        .build();
    content.append(&loading);
    content.append(&list);
    list.set_visible(false);

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .child(&content)
        .build();

    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::builder().show_end_title_buttons(false).build());
    toolbar.set_content(Some(&scroll));

    let dialog = adw::Dialog::builder()
        .title("Choose a Music Video")
        .content_width(520)
        .content_height(560)
        .child(&toolbar)
        .build();

    let track_duration = ui
        .core
        .player
        .current_track()
        .map(|track| track.duration)
        .unwrap_or(0.0);

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
                    .subtitle("YouTube returned no results for this song")
                    .build();
                list.append(&empty);
                rows.borrow_mut().push(empty.upcast());
            }
            for candidate in candidates {
                let row = candidate_row(&ui, &dialog, &candidate, track_duration);
                list.append(&row);
                rows.borrow_mut().push(row.upcast());
            }
            list.set_visible(true);
        });
    }

    musicvideo::request_candidates(&ui.core);
    dialog.present(Some(&ui.window));
}

fn candidate_row(
    ui: &Rc<Ui>,
    dialog: &adw::Dialog,
    candidate: &Candidate,
    track_duration: f64,
) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(glib::markup_escape_text(&candidate.title))
        .subtitle(glib::markup_escape_text(&candidate_subtitle(
            candidate,
            track_duration,
        )))
        .activatable(true)
        .build();
    let ui = Rc::clone(ui);
    let dialog = dialog.clone();
    let candidate = candidate.clone();
    row.connect_activated(move |_| {
        musicvideo::choose(&ui.core, candidate.clone());
        dialog.close();
    });
    row
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

/// A second window showing the same paintable, so going full screen costs no
/// reload and the sync loop never notices.
fn present_fullscreen(ui: &Rc<Ui>) {
    let Some(paintable) = ui.core.music_video.paintable() else {
        ui.core.toast("No video is playing");
        return;
    };
    let picture = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Contain)
        .paintable(&paintable)
        .hexpand(true)
        .vexpand(true)
        .build();
    let holder = gtk::Box::new(gtk::Orientation::Vertical, 0);
    holder.add_css_class("mv-fullscreen");
    holder.append(&picture);

    let window = gtk::Window::builder()
        .transient_for(&ui.window)
        .title("Music Video")
        .child(&holder)
        .fullscreened(true)
        .build();

    let dismiss = gtk::EventControllerKey::new();
    {
        let window = window.clone();
        dismiss.connect_key_pressed(move |_, key, _, _| {
            if matches!(key, gtk::gdk::Key::Escape | gtk::gdk::Key::f | gtk::gdk::Key::q) {
                window.close();
                return glib::Propagation::Stop;
            }
            glib::Propagation::Proceed
        });
    }
    window.add_controller(dismiss);

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

    window.present();
}

#[cfg(test)]
mod tests {
    use super::*;

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
        }
    }

    #[test]
    fn a_locked_video_reads_as_synced() {
        assert_eq!(sync_line(&found(0.0, false, "", "x"), Some(0.01), None), "Synced");
    }

    #[test]
    fn an_aligned_video_shows_the_offset_it_found() {
        assert_eq!(
            sync_line(&found(12.42, true, "", "x"), Some(0.0), None),
            "Aligned +12.42s"
        );
        assert_eq!(
            sync_line(&found(-3.5, true, "", "x"), Some(0.0), None),
            "Aligned -3.50s"
        );
    }

    #[test]
    fn a_hand_set_offset_is_not_called_an_alignment() {
        assert_eq!(
            sync_line(&found(0.5, false, "", "x"), None, None),
            "Offset +0.50s"
        );
    }

    #[test]
    fn a_large_drift_says_it_is_catching_up() {
        assert_eq!(
            sync_line(&found(0.0, true, "", "x"), Some(2.0), Some(720)),
            "Aligned · catching up · 720p"
        );
    }

    #[test]
    fn the_streamed_height_is_named_when_it_is_known() {
        assert_eq!(
            sync_line(&found(0.0, false, "", "x"), Some(0.0), Some(1080)),
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
        assert_eq!(provenance_line(&found(0.0, false, "", "Daft Punk")), "Daft Punk");
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
        assert_eq!(candidate_subtitle(&candidate, 200.0), "Band · 4:20 · +60s vs your file");
        assert_eq!(candidate_subtitle(&candidate, 259.0), "Band · 4:20");
        candidate.view_count = Some(1_234_567);
        assert_eq!(candidate_subtitle(&candidate, 259.0), "Band · 4:20 · 1.2M views");
    }

    #[test]
    fn the_lens_explains_every_state_it_can_be_in() {
        let (busy, _, headline, _, _) = describe(&VideoState::Searching, &StageState::Idle, false);
        assert!(busy && headline.is_some());
        let (_, _, headline, detail, action) =
            describe(&VideoState::Missing, &StageState::Idle, false);
        assert!(headline.is_some() && detail.is_some() && action.is_some());
        let (_, _, headline, _, action) = describe(
            &VideoState::Failed("Couldn't reach the video".into()),
            &StageState::Idle,
            false,
        );
        assert_eq!(headline.as_deref(), Some("Couldn't reach the video"));
        assert_eq!(action, Some("Try Again"));
        let ready = VideoState::Ready(found(0.0, true, "", "x"));
        let (busy, _, headline, _, _) = describe(&ready, &StageState::Playing, false);
        assert!(!busy && headline.is_none());
        let (busy, _, headline, _, _) = describe(&ready, &StageState::Buffering(42), false);
        assert!(busy);
        assert_eq!(headline.as_deref(), Some("Buffering… 42%"));
    }

    #[test]
    fn a_song_that_outlasts_its_video_is_told_so() {
        let ready = VideoState::Ready(found(0.0, true, "", "x"));
        let (busy, _, headline, detail, _) = describe(&ready, &StageState::Playing, true);
        assert!(!busy);
        assert_eq!(headline.as_deref(), Some("The video ended before the song"));
        assert!(detail.is_some());
        let (_, _, headline, _, _) = describe(&VideoState::Missing, &StageState::Idle, true);
        assert_eq!(headline.as_deref(), Some("No music video for this song"));
    }
}
