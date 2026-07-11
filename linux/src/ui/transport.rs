use crate::events::AppEvent;
use crate::library::format_time;
use crate::player::RepeatMode;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use gtk::gio;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let bar = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(14)
        .build();
    bar.add_css_class("transport");

    let artwork = gtk::Picture::builder()
        .width_request(52)
        .height_request(52)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    artwork.set_overflow(gtk::Overflow::Hidden);
    artwork.add_css_class("cover");
    artwork.set_visible(false);

    let title = gtk::Label::builder()
        .label("Not Playing")
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("transport-title");
    let artist = gtk::Label::builder()
        .label("")
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    artist.add_css_class("dim");
    artist.add_css_class("caption");

    let labels = gtk::Box::new(gtk::Orientation::Vertical, 2);
    labels.set_valign(gtk::Align::Center);
    labels.append(&title);
    labels.append(&artist);

    let love = gtk::Button::from_icon_name("emote-love-symbolic");
    love.add_css_class("flat");
    love.set_valign(gtk::Align::Center);
    love.set_tooltip_text(Some("Love on Last.fm"));
    love.set_sensitive(false);
    let current_rel: Rc<RefCell<Option<String>>> = Rc::new(RefCell::new(None));
    {
        let ui = Rc::clone(ui);
        let current_rel = Rc::clone(&current_rel);
        love.connect_clicked(move |_| {
            let rel = current_rel.borrow().clone();
            if let Some(rel) = rel {
                ui.core.toggle_love(&rel);
            }
        });
    }

    let left = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .width_request(280)
        .build();
    left.append(&artwork);
    left.append(&labels);
    left.append(&love);

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

    let previous = gtk::Button::from_icon_name("media-skip-backward-symbolic");
    previous.add_css_class("flat");
    previous.set_tooltip_text(Some("Previous"));
    {
        let ui = Rc::clone(ui);
        previous.connect_clicked(move |_| ui.core.previous());
    }

    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.set_tooltip_text(Some("Play/Pause"));
    play.add_css_class("suggested-action");
    play.add_css_class("circular");
    play.add_css_class("play-pill");
    {
        let ui = Rc::clone(ui);
        play.connect_clicked(move |_| ui.core.toggle_play_pause());
    }

    let next = gtk::Button::from_icon_name("media-skip-forward-symbolic");
    next.add_css_class("flat");
    next.set_tooltip_text(Some("Next"));
    {
        let ui = Rc::clone(ui);
        next.connect_clicked(move |_| ui.core.next());
    }

    let repeat = gtk::Button::from_icon_name("media-playlist-repeat-symbolic");
    repeat.add_css_class("flat");
    repeat.set_tooltip_text(Some("Repeat"));
    repeat.set_opacity(0.5);
    {
        let ui = Rc::clone(ui);
        repeat.connect_clicked(move |_| ui.core.player.cycle_repeat());
    }

    let buttons = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .halign(gtk::Align::Center)
        .build();
    buttons.append(&shuffle);
    buttons.append(&previous);
    buttons.append(&play);
    buttons.append(&next);
    buttons.append(&repeat);

    let position_label = gtk::Label::new(Some("0:00"));
    position_label.add_css_class("time-label");
    let duration_label = gtk::Label::new(Some("0:00"));
    duration_label.add_css_class("time-label");

    let seek = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 1.0);
    seek.set_hexpand(true);
    seek.set_draw_value(false);
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

    let seek_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    seek_row.append(&position_label);
    seek_row.append(&seek);
    seek_row.append(&duration_label);

    let center = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .hexpand(true)
        .valign(gtk::Align::Center)
        .build();
    center.append(&buttons);
    center.append(&seek_row);

    let quality = gtk::Label::new(None);
    quality.add_css_class("quality-badge");
    quality.set_visible(false);

    let lyrics_toggle = gtk::ToggleButton::builder()
        .icon_name("format-justify-center-symbolic")
        .tooltip_text("Lyrics")
        .build();
    lyrics_toggle.add_css_class("flat");
    {
        let ui = Rc::clone(ui);
        lyrics_toggle.connect_toggled(move |button| {
            ui.core.hub.emit(&AppEvent::LyricsToggled(button.is_active()));
        });
    }

    let queue_toggle = gtk::ToggleButton::builder()
        .icon_name("view-list-symbolic")
        .tooltip_text("Queue")
        .build();
    queue_toggle.add_css_class("flat");
    {
        let ui = Rc::clone(ui);
        queue_toggle.connect_toggled(move |button| {
            ui.core.hub.emit(&AppEvent::QueueToggled(button.is_active()));
        });
    }

    let sleep_menu = gio::Menu::new();
    for minutes in [15, 30, 45, 60, 90] {
        let item = gio::MenuItem::new(Some(&format!("{minutes} minutes")), None);
        item.set_action_and_target_value(Some("app.sleep-minutes"), Some(&(minutes as i32).to_variant()));
        sleep_menu.append_item(&item);
    }
    sleep_menu.append(Some("End of Track"), Some("app.sleep-end-of-track"));
    sleep_menu.append(Some("Cancel Timer"), Some("app.sleep-cancel"));
    let sleep_button = gtk::MenuButton::builder()
        .icon_name("alarm-symbolic")
        .tooltip_text("Sleep Timer")
        .menu_model(&sleep_menu)
        .build();
    sleep_button.add_css_class("flat");
    let sleep_label = gtk::Label::new(None);
    sleep_label.add_css_class("time-label");
    sleep_label.set_visible(false);

    let volume_icon = gtk::Image::from_icon_name("audio-volume-high-symbolic");
    volume_icon.add_css_class("dim");
    let volume = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 0.02);
    volume.set_tooltip_text(Some("Volume (scroll to adjust)"));
    volume.set_width_request(110);
    volume.set_draw_value(false);
    volume.set_value(ui.core.config.borrow().volume);
    let volume_guard = Rc::new(Cell::new(false));
    {
        let ui = Rc::clone(ui);
        let volume_guard = Rc::clone(&volume_guard);
        volume.connect_value_changed(move |scale| {
            if volume_guard.get() {
                return;
            }
            ui.core.set_volume(scale.value());
        });
    }
    {
        let scroll = gtk::EventControllerScroll::new(
            gtk::EventControllerScrollFlags::VERTICAL | gtk::EventControllerScrollFlags::DISCRETE,
        );
        let volume_ref = volume.clone();
        scroll.connect_scroll(move |_, _, dy| {
            let next = (volume_ref.value() - dy * 0.05).clamp(0.0, 1.0);
            volume_ref.set_value(next);
            glib::Propagation::Stop
        });
        volume.add_controller(scroll);
    }

    let right = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .valign(gtk::Align::Center)
        .build();
    right.append(&quality);
    right.append(&sleep_label);
    right.append(&sleep_button);
    right.append(&queue_toggle);
    right.append(&lyrics_toggle);
    right.append(&volume_icon);
    right.append(&volume);

    bar.append(&left);
    bar.append(&center);
    bar.append(&right);

    {
        let ui_ref = Rc::clone(ui);
        let artwork = artwork.clone();
        let title = title.clone();
        let artist = artist.clone();
        let quality = quality.clone();
        let love = love.clone();
        let play = play.clone();
        let seek = seek.clone();
        let position_label = position_label.clone();
        let duration_label = duration_label.clone();
        let shuffle = shuffle.clone();
        let repeat = repeat.clone();
        let volume = volume.clone();
        let sleep_label = sleep_label.clone();
        let sleep_button = sleep_button.clone();
        let queue_toggle = queue_toggle.clone();
        let lyrics_toggle = lyrics_toggle.clone();
        let current_rel = Rc::clone(&current_rel);
        let last_user_seek = Rc::clone(&last_user_seek);
        ui.core.hub.subscribe_widget(&bar, move |_, event| match event {
            AppEvent::TrackChanged(track) => match track {
                Some(track) => {
                    title.set_label(&track.title);
                    title.set_tooltip_text(Some(&track.title));
                    artist.set_label(&track.artist);
                    artist.set_tooltip_text(Some(&track.artist));
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
                    seek.set_range(0.0, track.duration.max(1.0));
                    seek.set_value(0.0);
                    position_label.set_label("0:00");
                    duration_label.set_label(&format_time(track.duration));
                    artwork.set_visible(true);
                    artwork.set_paintable(Some(
                        &ui_ref
                            .core
                            .artwork
                            .placeholder(&format!("{}|{}", track.album, track.artist)),
                    ));
                    let weak = artwork.downgrade();
                    ui_ref.core.artwork.request(
                        &track.album,
                        &track.artist,
                        52,
                        move |texture, _| {
                            if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                                picture.set_paintable(Some(texture));
                            }
                        },
                    );
                }
                None => {
                    title.set_label("Not Playing");
                    artist.set_label("");
                    quality.set_visible(false);
                    love.set_sensitive(false);
                    artwork.set_visible(false);
                    *current_rel.borrow_mut() = None;
                }
            },
            AppEvent::PlayingChanged(playing) => {
                play.set_icon_name(if *playing {
                    "media-playback-pause-symbolic"
                } else {
                    "media-playback-start-symbolic"
                });
            }
            AppEvent::Tick { position, duration } => {
                let user_recent = last_user_seek
                    .get()
                    .map(|t| t.elapsed().as_millis() < 600)
                    .unwrap_or(false);
                if !user_recent {
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
            AppEvent::ShuffleChanged(enabled) => {
                shuffle.set_active(*enabled);
            }
            AppEvent::RepeatChanged(mode) => match mode {
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
            },
            AppEvent::VolumeChanged(value) => {
                if (volume.value() - value).abs() > 0.001 {
                    volume_guard.set(true);
                    volume.set_value(*value);
                    volume_guard.set(false);
                }
            }
            AppEvent::LovedChanged { rel_path, loved } => {
                if current_rel.borrow().as_deref() == Some(rel_path.as_str()) {
                    set_love_appearance(&love, *loved);
                }
            }
            AppEvent::SleepTimerChanged {
                remaining_seconds,
                end_of_track,
            } => match (remaining_seconds, end_of_track) {
                (Some(seconds), _) => {
                    sleep_label.set_label(&format_time(*seconds as f64));
                    sleep_label.set_visible(true);
                    sleep_button.add_css_class("accent-toggle");
                }
                (None, true) => {
                    sleep_label.set_label("EOT");
                    sleep_label.set_visible(true);
                    sleep_button.add_css_class("accent-toggle");
                }
                (None, false) => {
                    sleep_label.set_visible(false);
                    sleep_button.remove_css_class("accent-toggle");
                }
            },
            AppEvent::QueueToggled(shown) => {
                if queue_toggle.is_active() != *shown {
                    queue_toggle.set_active(*shown);
                }
            }
            AppEvent::LyricsToggled(shown) => {
                if lyrics_toggle.is_active() != *shown {
                    lyrics_toggle.set_active(*shown);
                }
            }
            _ => {}
        });
    }

    bar.upcast()
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
