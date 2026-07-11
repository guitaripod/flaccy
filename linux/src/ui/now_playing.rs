use crate::events::AppEvent;
use crate::library::{format_time, Track};
use crate::player::RepeatMode;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;

/// Full-window "focus" player: a blurred, accent-washed cover fills the page,
/// with large artwork, big type, a seek bar, and full transport controls.
/// Pushed onto the navigation stack from the mini-player artwork.
pub fn present(ui: &Rc<Ui>) {
    if ui
        .nav
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

    let art = gtk::Picture::builder()
        .width_request(340)
        .height_request(340)
        .content_fit(gtk::ContentFit::Cover)
        .halign(gtk::Align::Center)
        .build();
    art.set_overflow(gtk::Overflow::Hidden);
    art.add_css_class("np-art");

    let title = gtk::Label::builder()
        .xalign(0.5)
        .justify(gtk::Justification::Center)
        .wrap(true)
        .ellipsize(pango::EllipsizeMode::End)
        .lines(2)
        .build();
    title.add_css_class("np-title");
    let artist = gtk::Label::builder().xalign(0.5).build();
    artist.add_css_class("np-artist");
    let meta = gtk::Label::builder().xalign(0.5).build();
    meta.add_css_class("np-meta");
    meta.add_css_class("dim");

    let text_box = gtk::Box::new(gtk::Orientation::Vertical, 6);
    text_box.set_halign(gtk::Align::Center);
    text_box.append(&title);
    text_box.append(&artist);
    text_box.append(&meta);

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
    let seek_row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    seek_row.append(&position_label);
    seek_row.append(&seek);
    seek_row.append(&duration_label);

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
    let controls = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(16)
        .halign(gtk::Align::Center)
        .build();
    controls.append(&shuffle);
    controls.append(&previous);
    controls.append(&play);
    controls.append(&next);
    controls.append(&repeat);

    let love = gtk::Button::from_icon_name("emote-love-symbolic");
    love.add_css_class("flat");
    love.set_tooltip_text(Some("Love on Last.fm"));
    let current_rel: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    {
        let ui = Rc::clone(ui);
        let current_rel = Rc::clone(&current_rel);
        love.connect_clicked(move |_| {
            if let Some(rel) = current_rel.borrow().clone() {
                ui.core.toggle_love(&rel);
            }
        });
    }
    let lyrics = gtk::Button::from_icon_name("format-justify-center-symbolic");
    lyrics.add_css_class("flat");
    lyrics.set_tooltip_text(Some("Lyrics"));
    {
        let ui = Rc::clone(ui);
        lyrics.connect_clicked(move |_| ui.core.hub.emit(&AppEvent::LyricsToggled(true)));
    }
    let queue = gtk::Button::from_icon_name("view-list-symbolic");
    queue.add_css_class("flat");
    queue.set_tooltip_text(Some("Queue"));
    {
        let ui = Rc::clone(ui);
        queue.connect_clicked(move |_| ui.core.hub.emit(&AppEvent::QueueToggled(true)));
    }
    let secondary = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(18)
        .halign(gtk::Align::Center)
        .build();
    secondary.append(&love);
    secondary.append(&lyrics);
    secondary.append(&queue);

    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(22)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .margin_top(36)
        .margin_bottom(36)
        .margin_start(28)
        .margin_end(28)
        .build();
    column.append(&art);
    column.append(&text_box);
    column.append(&seek_row);
    column.append(&controls);
    column.append(&secondary);

    let clamp = adw::Clamp::builder().maximum_size(560).child(&column).build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&clamp)
        .build();

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&scrim);
    overlay.add_overlay(&scroll);

    let header = adw::HeaderBar::builder()
        .title_widget(&adw::WindowTitle::new("Now Playing", ""))
        .show_end_title_buttons(false)
        .build();
    header.add_css_class("flat");
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&header);
    toolbar.set_content(Some(&overlay));
    toolbar.set_top_bar_style(adw::ToolbarStyle::Flat);

    let update = build_updater(
        ui, &art, &backdrop, &title, &artist, &meta, &love, &current_rel,
    );
    update();

    play.set_icon_name(if ui.core.player.is_playing() {
        "media-playback-pause-symbolic"
    } else {
        "media-playback-start-symbolic"
    });
    shuffle.set_active(ui.core.player.shuffle_enabled());
    apply_repeat(&repeat, ui.core.player.repeat_mode());
    if let Some(track) = ui.core.player.current_track() {
        seek.set_range(0.0, track.duration.max(1.0));
        duration_label.set_label(&format_time(track.duration));
    }

    wire_events(
        ui,
        &overlay,
        &play,
        &seek,
        &position_label,
        &duration_label,
        &shuffle,
        &repeat,
        &love,
        &current_rel,
        &last_user_seek,
        update,
    );

    let page = adw::NavigationPage::builder()
        .title("Now Playing")
        .tag("now-playing")
        .child(&toolbar)
        .build();
    ui.nav.push(&page);
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("flat");
    button.add_css_class("np-skip");
    button.set_tooltip_text(Some(tooltip));
    button
}

type Updater = Rc<dyn Fn()>;

/// Repaints the artwork (sharp + blurred backdrop) and text for the current
/// track; reused on open and on every TrackChanged.
#[allow(clippy::too_many_arguments)]
fn build_updater(
    ui: &Rc<Ui>,
    art: &gtk::Picture,
    backdrop: &gtk::Picture,
    title: &gtk::Label,
    artist: &gtk::Label,
    meta: &gtk::Label,
    love: &gtk::Button,
    current_rel: &Rc<RefCell<Option<String>>>,
) -> Updater {
    let ui = Rc::clone(ui);
    let art = art.clone();
    let backdrop = backdrop.clone();
    let title = title.clone();
    let artist = artist.clone();
    let meta = meta.clone();
    let love = love.clone();
    let current_rel = Rc::clone(current_rel);
    Rc::new(move || {
        let Some(track) = ui.core.player.current_track() else {
            title.set_label("Not Playing");
            artist.set_label("");
            meta.set_label("");
            love.set_sensitive(false);
            *current_rel.borrow_mut() = None;
            return;
        };
        title.set_label(&track.title);
        artist.set_label(&track.artist);
        meta.set_label(&now_playing_meta(&track));
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
    play: &gtk::Button,
    seek: &gtk::Scale,
    position_label: &gtk::Label,
    duration_label: &gtk::Label,
    shuffle: &gtk::ToggleButton,
    repeat: &gtk::Button,
    love: &gtk::Button,
    current_rel: &Rc<RefCell<Option<String>>>,
    last_user_seek: &Rc<Cell<Option<Instant>>>,
    update: Updater,
) {
    let play = play.clone();
    let seek = seek.clone();
    let position_label = position_label.clone();
    let duration_label = duration_label.clone();
    let shuffle = shuffle.clone();
    let repeat = repeat.clone();
    let love = love.clone();
    let current_rel = Rc::clone(current_rel);
    let last_user_seek = Rc::clone(last_user_seek);
    ui.core.hub.subscribe_widget(host, move |_, event| match event {
        AppEvent::TrackChanged(track) => {
            update();
            if let Some(track) = track {
                seek.set_range(0.0, track.duration.max(1.0));
                seek.set_value(0.0);
                position_label.set_label("0:00");
                duration_label.set_label(&format_time(track.duration));
            }
        }
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

fn apply_repeat(repeat: &gtk::Button, mode: RepeatMode) {
    match mode {
        RepeatMode::Off => {
            repeat.set_icon_name("media-playlist-repeat-symbolic");
            repeat.set_opacity(0.5);
            repeat.remove_css_class("accent-toggle");
        }
        RepeatMode::All => {
            repeat.set_icon_name("media-playlist-repeat-symbolic");
            repeat.set_opacity(1.0);
            repeat.add_css_class("accent-toggle");
        }
        RepeatMode::One => {
            repeat.set_icon_name("media-playlist-repeat-song-symbolic");
            repeat.set_opacity(1.0);
            repeat.add_css_class("accent-toggle");
        }
    }
}

fn now_playing_meta(track: &Track) -> String {
    let mut parts: Vec<String> = vec![track.album.clone()];
    if let Some(badge) = track.quality_badge() {
        parts.push(badge);
    }
    parts.join("  ·  ")
}

fn set_love_appearance(button: &gtk::Button, loved: bool) {
    if loved {
        button.add_css_class("loved-heart");
        button.set_tooltip_text(Some("Unlove"));
    } else {
        button.remove_css_class("loved-heart");
        button.set_tooltip_text(Some("Love on Last.fm"));
    }
}
