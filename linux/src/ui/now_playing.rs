use crate::events::AppEvent;
use crate::library::format_time;
use crate::ui::controls::{apply_repeat, set_love_appearance};
use crate::ui::lyrics_panel::{self, LyricsOptions};
use crate::ui::queue_panel::{self, QueueOptions};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;

/// Full-window "focus" player pushed onto the outer nav (ui.shell). A blurred,
/// accent-washed cover fills the page; the hero artwork sits centered with
/// Lyrics and Up Next columns that slide in on either side — independently
/// toggled, so any combination of the three can be shown at once — over a
/// single persistent transport dock.
pub fn present(ui: &Rc<Ui>) {
    if ui
        .shell
        .visible_page()
        .and_then(|page| page.tag())
        .as_deref()
        == Some("now-playing")
    {
        return;
    }

    let backdrop = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .vexpand(true)
        .build();
    backdrop.add_css_class("np-backdrop");

    let scrim = gtk::Box::new(gtk::Orientation::Vertical, 0);
    scrim.add_css_class("np-scrim");
    scrim.set_hexpand(true);
    scrim.set_vexpand(true);

    let (art_page, art, title, artist, meta, quality) = build_art_lens();

    let seek_row = SeekRow::new(ui);
    let transport = TransportControls::new(ui);

    let current_rel: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    {
        let ui = Rc::clone(ui);
        let current_rel = Rc::clone(&current_rel);
        transport.love.connect_clicked(move |_| {
            if let Some(rel) = current_rel.borrow().clone() {
                ui.core.toggle_love(&rel);
            }
        });
    }

    let lyrics = lyrics_panel::build(ui, LyricsOptions::in_view());
    lyrics.widget.add_css_class("np-view");
    lyrics.widget.add_css_class("np-side");
    lyrics.widget.set_hexpand(true);
    // Soft floor so a side column can shrink under a phone-width window
    // instead of locking the whole Now Playing page open.
    lyrics.widget.set_size_request(160, -1);
    let lyrics_reveal = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::SlideRight)
        .transition_duration(260)
        .hexpand(false)
        .child(&lyrics.widget)
        .build();

    let queue = queue_panel::build(ui, QueueOptions::in_view());
    queue.widget.add_css_class("np-view");
    queue.widget.add_css_class("np-side");
    queue.widget.set_hexpand(true);
    queue.widget.set_size_request(160, -1);
    let queue_reveal = gtk::Revealer::builder()
        .transition_type(gtk::RevealerTransitionType::SlideLeft)
        .transition_duration(260)
        .hexpand(false)
        .child(&queue.widget)
        .build();

    // Equal thirds when all shown: a horizontal size group equalizes the three
    // columns' widths, and each visible column hexpands to split the row evenly.
    // A collapsed side reveals nothing and (via its toggle) drops hexpand, so
    // the visible columns always share the row equally — art alone, art+one
    // half/half, or all three in thirds.
    let size_group = gtk::SizeGroup::new(gtk::SizeGroupMode::Horizontal);
    size_group.add_widget(&lyrics.widget);
    size_group.add_widget(&art_page);
    size_group.add_widget(&queue.widget);

    let content = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    content.set_hexpand(true);
    content.set_vexpand(true);
    content.append(&lyrics_reveal);
    content.append(&art_page);
    content.append(&queue_reveal);

    let (lyrics_toggle, _lyrics_label) = toggle_button("format-justify-center-symbolic", "Lyrics");
    {
        let lyrics_reveal = lyrics_reveal.clone();
        let set_active = Rc::clone(&lyrics.set_active);
        lyrics_toggle.connect_toggled(move |button| {
            let active = button.is_active();
            lyrics_reveal.set_reveal_child(active);
            lyrics_reveal.set_hexpand(active);
            set_active(active);
        });
    }
    let (queue_toggle, queue_label) = toggle_button("view-list-symbolic", "Up Next");
    {
        let queue_reveal = queue_reveal.clone();
        let set_active = Rc::clone(&queue.set_active);
        queue_toggle.connect_toggled(move |button| {
            let active = button.is_active();
            queue_reveal.set_reveal_child(active);
            queue_reveal.set_hexpand(active);
            set_active(active);
        });
    }
    // Below this width, keep at most one side panel open so art stays readable.
    install_now_playing_width_adaptation(&content, &lyrics_toggle, &queue_toggle);

    let toggles = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    toggles.set_halign(gtk::Align::Center);
    toggles.add_css_class("np-toggles");
    toggles.append(&lyrics_toggle);
    toggles.append(&queue_toggle);

    let np_transport = gtk::Box::new(gtk::Orientation::Vertical, 10);
    np_transport.add_css_class("np-transport");
    np_transport.append(&seek_row.container);
    np_transport.append(&transport.container);

    let header = adw::HeaderBar::builder()
        .title_widget(&toggles)
        .show_end_title_buttons(true)
        .build();
    header.add_css_class("flat");

    let toolbar = adw::ToolbarView::new();
    toolbar.add_css_class("np-toolbar");
    toolbar.set_top_bar_style(adw::ToolbarStyle::Flat);
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&content));
    toolbar.add_bottom_bar(&np_transport);

    let overlay = gtk::Overlay::new();
    overlay.add_css_class("np-root");
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&scrim);
    overlay.add_overlay(&toolbar);

    let update = build_updater(
        ui,
        &art,
        &backdrop,
        &title,
        &artist,
        &meta,
        &quality,
        &transport.love,
        &current_rel,
    );
    update();

    transport.sync_initial(ui);
    if let Some(track) = ui.core.player.current_track() {
        seek_row.seek.set_range(0.0, track.duration.max(1.0));
        seek_row.duration_label.set_label(&format_time(track.duration));
    }
    update_up_next_label(ui, &queue_label);

    wire_events(ui, &overlay, &seek_row, &transport, &current_rel, &queue_label, update);

    if crate::config::demo_mode() {
        if let Ok(which) = std::env::var("FLACCY_DEMO_NP_PANELS") {
            if which == "lyrics" || which == "both" || which == "1" {
                lyrics_toggle.set_active(true);
            }
            if which == "queue" || which == "both" || which == "1" {
                queue_toggle.set_active(true);
            }
        }
    }

    let page = adw::NavigationPage::builder()
        .title("Now Playing")
        .tag("now-playing")
        .child(&overlay)
        .build();
    ui.shell.push(&page);
}

/// The centered player lens: hero art, big title/artist, album line, and a
/// hi-res quality chip. Controls live in the persistent transport dock below.
/// Cover art grows with available width (square) so a tiny window still shows
/// a usable hero instead of locking the page to a 340px floor.
fn build_art_lens() -> (
    gtk::Widget,
    gtk::Picture,
    gtk::Label,
    gtk::Label,
    gtk::Label,
    gtk::Label,
) {
    let art = gtk::Picture::builder()
        .content_fit(gtk::ContentFit::Cover)
        .hexpand(true)
        .vexpand(true)
        .build();
    art.set_overflow(gtk::Overflow::Hidden);
    art.add_css_class("np-art");

    let art_frame = gtk::AspectFrame::builder()
        .ratio(1.0)
        .obey_child(false)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .width_request(140)
        .height_request(140)
        .child(&art)
        .build();
    art_frame.add_css_class("np-art-frame");

    let title = gtk::Label::builder()
        .xalign(0.5)
        .justify(gtk::Justification::Center)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .ellipsize(pango::EllipsizeMode::End)
        .lines(2)
        .build();
    title.add_css_class("np-title");
    let artist = gtk::Label::builder()
        .xalign(0.5)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    artist.add_css_class("np-artist");
    let meta = gtk::Label::builder()
        .xalign(0.5)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    meta.add_css_class("np-meta");
    meta.add_css_class("dim");
    let quality = gtk::Label::new(None);
    quality.add_css_class("np-chip");
    quality.set_halign(gtk::Align::Center);
    quality.set_visible(false);

    let text_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    text_box.set_halign(gtk::Align::Center);
    text_box.set_hexpand(true);
    text_box.append(&title);
    text_box.append(&artist);
    text_box.append(&meta);
    text_box.append(&quality);

    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Center)
        .hexpand(true)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(16)
        .margin_end(16)
        .build();
    column.append(&art_frame);
    column.append(&text_box);

    let clamp = adw::Clamp::builder()
        .maximum_size(480)
        .tightening_threshold(200)
        .child(&column)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .vexpand(true)
        .child(&clamp)
        .build();
    (scroll.upcast(), art, title, artist, meta, quality)
}

/// When Now Playing is squeezed, auto-collapse side panels so the hero art is
/// never crushed between two full columns on a narrow window.
fn install_now_playing_width_adaptation(
    content: &gtk::Box,
    lyrics_toggle: &gtk::ToggleButton,
    queue_toggle: &gtk::ToggleButton,
) {
    let last_width = Rc::new(Cell::new(0i32));
    let lyrics_toggle = lyrics_toggle.clone();
    let queue_toggle = queue_toggle.clone();
    content.connect_realize(move |widget| {
        let lyrics_toggle = lyrics_toggle.clone();
        let queue_toggle = queue_toggle.clone();
        let last_width = Rc::clone(&last_width);
        widget.add_tick_callback(move |widget, _| {
            let width = widget.width();
            if width == last_width.get() || width <= 1 {
                return glib::ControlFlow::Continue;
            }
            last_width.set(width);
            if width < 640 {
                if lyrics_toggle.is_active() && queue_toggle.is_active() {
                    queue_toggle.set_active(false);
                }
            }
            glib::ControlFlow::Continue
        });
    });
}

/// A pill toggle carrying an icon + label, returned with its label so a live
/// count can be appended.
fn toggle_button(icon: &str, text: &str) -> (gtk::ToggleButton, gtk::Label) {
    let image = gtk::Image::from_icon_name(icon);
    let label = gtk::Label::new(Some(text));
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    content.append(&image);
    content.append(&label);
    let button = gtk::ToggleButton::builder().child(&content).build();
    button.add_css_class("np-toggle");
    button.set_tooltip_text(Some(text));
    (button, label)
}

/// The persistent seek scrubber + time labels shared across the view.
struct SeekRow {
    container: gtk::Box,
    seek: gtk::Scale,
    position_label: gtk::Label,
    duration_label: gtk::Label,
    last_user_seek: Rc<Cell<Option<Instant>>>,
}

impl SeekRow {
    fn new(ui: &Rc<Ui>) -> Self {
        let position_label = gtk::Label::new(Some("0:00"));
        position_label.add_css_class("time-label");
        let duration_label = gtk::Label::new(Some("0:00"));
        duration_label.add_css_class("time-label");
        let seek = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 1.0);
        seek.set_hexpand(true);
        seek.set_draw_value(false);
        seek.add_css_class("np-seek");
        let last_user_seek: Rc<Cell<Option<Instant>>> = Rc::new(Cell::new(None));
        {
            let ui = Rc::clone(ui);
            let last_user_seek = Rc::clone(&last_user_seek);
            let position_label = position_label.clone();
            seek.connect_change_value(move |_, _, value| {
                last_user_seek.set(Some(Instant::now()));
                position_label.set_label(&format_time(value));
                ui.core.player.seek(value);
                glib::Propagation::Proceed
            });
        }
        let container = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        container.append(&position_label);
        container.append(&seek);
        container.append(&duration_label);
        Self { container, seek, position_label, duration_label, last_user_seek }
    }
}

/// The persistent transport row: shuffle, prev, play/pause, next, repeat, love.
struct TransportControls {
    container: gtk::Box,
    play: gtk::Button,
    shuffle: gtk::ToggleButton,
    repeat: gtk::Button,
    love: gtk::Button,
}

impl TransportControls {
    fn new(ui: &Rc<Ui>) -> Self {
        let shuffle = gtk::ToggleButton::builder()
            .icon_name("media-playlist-shuffle-symbolic")
            .tooltip_text("Shuffle")
            .build();
        shuffle.add_css_class("flat");
        {
            let ui = Rc::clone(ui);
            shuffle.connect_clicked(move |button| {
                if button.is_active() != ui.core.player.shuffle_enabled() {
                    ui.core.player.toggle_shuffle();
                }
            });
        }
        let previous = icon_button("media-skip-backward-symbolic", "Previous");
        {
            let ui = Rc::clone(ui);
            previous.connect_clicked(move |_| ui.core.previous());
        }
        let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
        play.add_css_class("suggested-action");
        play.add_css_class("circular");
        play.add_css_class("np-play");
        play.set_tooltip_text(Some("Play/Pause"));
        {
            let ui = Rc::clone(ui);
            play.connect_clicked(move |_| ui.core.toggle_play_pause());
        }
        let next = icon_button("media-skip-forward-symbolic", "Next");
        {
            let ui = Rc::clone(ui);
            next.connect_clicked(move |_| ui.core.next());
        }
        let repeat = gtk::Button::from_icon_name("media-playlist-repeat-symbolic");
        repeat.add_css_class("flat");
        repeat.set_opacity(0.5);
        repeat.set_tooltip_text(Some("Repeat"));
        {
            let ui = Rc::clone(ui);
            repeat.connect_clicked(move |_| ui.core.player.cycle_repeat());
        }
        let love = gtk::Button::from_icon_name("emote-love-symbolic");
        love.add_css_class("flat");
        love.set_tooltip_text(Some("Love on Last.fm"));

        let container = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(16)
            .halign(gtk::Align::Center)
            .build();
        container.append(&shuffle);
        container.append(&previous);
        container.append(&play);
        container.append(&next);
        container.append(&repeat);
        container.append(&love);
        Self { container, play, shuffle, repeat, love }
    }

    fn sync_initial(&self, ui: &Rc<Ui>) {
        self.play.set_icon_name(if ui.core.player.is_playing() {
            "media-playback-pause-symbolic"
        } else {
            "media-playback-start-symbolic"
        });
        self.shuffle.set_active(ui.core.player.shuffle_enabled());
        apply_repeat(&self.repeat, ui.core.player.repeat_mode());
    }
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("flat");
    button.add_css_class("np-skip");
    button.set_tooltip_text(Some(tooltip));
    button
}

/// Refreshes the "Up Next" toggle label with the live up-next count.
fn update_up_next_label(ui: &Rc<Ui>, label: &gtk::Label) {
    let snapshot = ui.core.player.queue_snapshot();
    let count = snapshot.queue.len().saturating_sub(snapshot.current + 1);
    if count > 0 {
        label.set_label(&format!("Up Next · {count}"));
    } else {
        label.set_label("Up Next");
    }
}

type Updater = Rc<dyn Fn()>;

/// Repaints the artwork (sharp + blurred backdrop), text, and quality chip for
/// the current track; reused on open and on every TrackChanged.
#[allow(clippy::too_many_arguments)]
fn build_updater(
    ui: &Rc<Ui>,
    art: &gtk::Picture,
    backdrop: &gtk::Picture,
    title: &gtk::Label,
    artist: &gtk::Label,
    meta: &gtk::Label,
    quality: &gtk::Label,
    love: &gtk::Button,
    current_rel: &Rc<RefCell<Option<String>>>,
) -> Updater {
    let ui = Rc::clone(ui);
    let art = art.clone();
    let backdrop = backdrop.clone();
    let title = title.clone();
    let artist = artist.clone();
    let meta = meta.clone();
    let quality = quality.clone();
    let love = love.clone();
    let current_rel = Rc::clone(current_rel);
    Rc::new(move || {
        let Some(track) = ui.core.player.current_track() else {
            title.set_label("Not Playing");
            artist.set_label("");
            meta.set_label("");
            quality.set_visible(false);
            love.set_sensitive(false);
            *current_rel.borrow_mut() = None;
            return;
        };
        title.set_label(&track.title);
        artist.set_label(&track.artist);
        meta.set_label(&track.album);
        match track.quality_badge() {
            Some(badge) => {
                quality.set_label(&badge);
                quality.set_visible(true);
            }
            None => quality.set_visible(false),
        }
        love.set_sensitive(true);
        set_love_appearance(&love, track.loved);
        *current_rel.borrow_mut() = Some(track.rel_path.clone());

        let seed = format!("{}|{}", track.album, track.artist);
        let placeholder = ui.core.artwork.placeholder(&seed);
        art.set_paintable(Some(&placeholder));
        backdrop.set_paintable(Some(&placeholder));
        let art_weak = art.downgrade();
        let backdrop_weak = backdrop.downgrade();
        ui.core
            .artwork
            .request(&track.album, &track.artist, 340, move |texture, _| {
                if let Some(texture) = texture {
                    if let Some(art) = art_weak.upgrade() {
                        art.set_paintable(Some(texture));
                    }
                    if let Some(backdrop) = backdrop_weak.upgrade() {
                        backdrop.set_paintable(Some(texture));
                    }
                }
            });
    })
}

#[allow(clippy::too_many_arguments)]
fn wire_events(
    ui: &Rc<Ui>,
    host: &gtk::Overlay,
    seek_row: &SeekRow,
    transport: &TransportControls,
    current_rel: &Rc<RefCell<Option<String>>>,
    queue_label: &gtk::Label,
    update: Updater,
) {
    let hub = Rc::clone(&ui.core.hub);
    let ui = Rc::clone(ui);
    let play = transport.play.clone();
    let shuffle = transport.shuffle.clone();
    let repeat = transport.repeat.clone();
    let love = transport.love.clone();
    let seek = seek_row.seek.clone();
    let position_label = seek_row.position_label.clone();
    let duration_label = seek_row.duration_label.clone();
    let last_user_seek = Rc::clone(&seek_row.last_user_seek);
    let current_rel = Rc::clone(current_rel);
    let queue_label = queue_label.clone();
    hub.subscribe_widget(host, move |_, event| match event {
        AppEvent::TrackChanged(track) => {
            update();
            if let Some(track) = track {
                seek.set_range(0.0, track.duration.max(1.0));
                seek.set_value(0.0);
                position_label.set_label("0:00");
                duration_label.set_label(&format_time(track.duration));
            }
            update_up_next_label(&ui, &queue_label);
        }
        AppEvent::QueueChanged => update_up_next_label(&ui, &queue_label),
        AppEvent::PlayingChanged(playing) => {
            play.set_icon_name(if *playing {
                "media-playback-pause-symbolic"
            } else {
                "media-playback-start-symbolic"
            });
        }
        AppEvent::Tick { position, duration } => {
            let recent = last_user_seek
                .get()
                .map(|t| t.elapsed().as_millis() < 600)
                .unwrap_or(false);
            if !recent {
                if *duration > 0.0 {
                    seek.set_range(0.0, *duration);
                    duration_label.set_label(&format_time(*duration));
                }
                seek.set_value(*position);
                position_label.set_label(&format_time(*position));
            }
        }
        AppEvent::Seeked(position) => {
            seek.set_value(*position);
            position_label.set_label(&format_time(*position));
        }
        AppEvent::ShuffleChanged(enabled) => shuffle.set_active(*enabled),
        AppEvent::RepeatChanged(mode) => apply_repeat(&repeat, *mode),
        AppEvent::LovedChanged { rel_path, loved } => {
            if current_rel.borrow().as_deref() == Some(rel_path.as_str()) {
                set_love_appearance(&love, *loved);
            }
        }
        _ => {}
    });
}
