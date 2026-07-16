use crate::events::AppEvent;
use crate::library::format_time;
use crate::ui::controls::{apply_repeat, set_adaptive_accent, set_love_appearance};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::pango;
use gtk::gio;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Instant;

/// Bottom transport: classic three-column strip (meta | controls | extras)
/// with a full-width seek row underneath. Left and right share a size group so
/// the play cluster stays optically centered; width tiers hide extras without
/// breaking that balance.
pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let root = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .build();
    root.add_css_class("transport");

    let artwork = gtk::Picture::builder()
        .width_request(44)
        .height_request(44)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    artwork.set_overflow(gtk::Overflow::Hidden);
    artwork.add_css_class("cover");
    artwork.set_visible(false);

    let equalizer = build_equalizer();
    let art_overlay = gtk::Overlay::new();
    art_overlay.set_child(Some(&artwork));
    art_overlay.add_overlay(&equalizer);
    art_overlay.add_css_class("mini-art");
    art_overlay.set_cursor_from_name(Some("pointer"));
    art_overlay.set_tooltip_text(Some("Now Playing"));
    {
        let ui = Rc::clone(ui);
        let click = gtk::GestureClick::new();
        click.connect_released(move |_, _, _, _| {
            if ui.core.player.current_track().is_some() {
                crate::ui::now_playing::present(&ui);
            }
        });
        art_overlay.add_controller(click);
    }

    let title = gtk::Label::builder()
        .label("Not Playing")
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(22)
        .build();
    title.add_css_class("transport-title");
    let artist = gtk::Label::builder()
        .label("")
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(24)
        .build();
    artist.add_css_class("dim");
    artist.add_css_class("caption");

    let labels = gtk::Box::new(gtk::Orientation::Vertical, 1);
    labels.set_valign(gtk::Align::Center);
    labels.set_hexpand(true);
    // Allow labels to shrink inside the left column instead of inflating it.
    labels.set_overflow(gtk::Overflow::Hidden);
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

    // Left column: track meta. Clamped so a long title never steals the
    // center; does not expand — center owns free space so play stays put.
    let left_inner = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .halign(gtk::Align::Start)
        .valign(gtk::Align::Center)
        .build();
    left_inner.add_css_class("transport-left");
    left_inner.append(&art_overlay);
    left_inner.append(&labels);
    left_inner.append(&love);
    let left = adw::Clamp::builder()
        .maximum_size(260)
        .tightening_threshold(140)
        .halign(gtk::Align::Start)
        .hexpand(false)
        .child(&left_inner)
        .build();
    left.add_css_class("transport-left-clamp");

    let shuffle = gtk::ToggleButton::builder()
        .icon_name("media-playlist-shuffle-symbolic")
        .tooltip_text("Shuffle")
        .build();
    shuffle.add_css_class("flat");
    shuffle.add_css_class("transport-extra");
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
    repeat.add_css_class("transport-extra");
    repeat.set_tooltip_text(Some("Repeat"));
    repeat.set_opacity(0.5);
    {
        let ui = Rc::clone(ui);
        repeat.connect_clicked(move |_| ui.core.player.cycle_repeat());
    }

    let buttons = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(2)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .build();
    buttons.add_css_class("transport-buttons");
    buttons.append(&shuffle);
    buttons.append(&previous);
    buttons.append(&play);
    buttons.append(&next);
    buttons.append(&repeat);

    // Center column expands; buttons stay centered inside it.
    let center = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .hexpand(true)
        .halign(gtk::Align::Fill)
        .valign(gtk::Align::Center)
        .build();
    center.add_css_class("transport-center");
    center.append(&buttons);
    // Center the button cluster within the expanding center column.
    buttons.set_hexpand(true);
    buttons.set_halign(gtk::Align::Center);

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
        .hexpand(true)
        .build();
    seek_row.add_css_class("transport-seek");
    seek_row.append(&position_label);
    seek_row.append(&seek);
    seek_row.append(&duration_label);

    let quality = gtk::Label::new(None);
    quality.add_css_class("quality-badge");
    quality.add_css_class("transport-wide-only");
    quality.set_visible(false);

    let lyrics_toggle = gtk::ToggleButton::builder()
        .icon_name("format-justify-center-symbolic")
        .tooltip_text("Lyrics")
        .build();
    lyrics_toggle.add_css_class("flat");
    lyrics_toggle.add_css_class("transport-extra");
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
    sleep_button.add_css_class("transport-extra");
    let sleep_label = gtk::Label::new(None);
    sleep_label.add_css_class("time-label");
    sleep_label.add_css_class("transport-wide-only");
    sleep_label.set_visible(false);

    let volume_icon = gtk::Image::from_icon_name("audio-volume-high-symbolic");
    volume_icon.add_css_class("dim");
    volume_icon.add_css_class("transport-volume-icon");
    let volume = gtk::Scale::with_range(gtk::Orientation::Horizontal, 0.0, 1.0, 0.02);
    volume.set_tooltip_text(Some("Volume (scroll to adjust)"));
    volume.set_width_request(88);
    volume.set_draw_value(false);
    volume.add_css_class("transport-volume");
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
        .spacing(4)
        .hexpand(false)
        .valign(gtk::Align::Center)
        .halign(gtk::Align::End)
        .build();
    right.add_css_class("transport-right");
    right.append(&quality);
    right.append(&sleep_label);
    right.append(&sleep_button);
    right.append(&queue_toggle);
    right.append(&lyrics_toggle);
    right.append(&volume_icon);
    right.append(&volume);

    // Equalize left/right so the play cluster sits in the true visual center.
    let wings = gtk::SizeGroup::new(gtk::SizeGroupMode::Horizontal);
    wings.add_widget(&left);
    wings.add_widget(&right);

    let top = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(8)
        .build();
    top.add_css_class("transport-top");
    top.append(&left);
    top.append(&center);
    top.append(&right);

    root.append(&top);
    root.append(&seek_row);

    install_width_adaptation(
        &root,
        &left,
        &right,
        &artist,
        &title,
        &love,
        &shuffle,
        &repeat,
        &lyrics_toggle,
        &sleep_button,
        &queue_toggle,
        &volume,
        &volume_icon,
        &quality,
        &sleep_label,
    );

    {
        let ui_ref = Rc::clone(ui);
        let artwork = artwork.clone();
        let equalizer = equalizer.clone();
        let bar_ref = root.clone();
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
        ui.core.hub.subscribe_widget(&root, move |_, event| match event {
            AppEvent::TrackChanged(track) => match track {
                Some(track) => {
                    title.set_label(&track.title);
                    title.set_tooltip_text(Some(&track.title));
                    artist.set_label(&track.artist);
                    artist.set_tooltip_text(Some(&track.artist));
                    match track.quality_badge() {
                        Some(badge) => {
                            quality.set_label(&badge);
                            if !bar_ref.has_css_class("transport-compact")
                                && !bar_ref.has_css_class("transport-slim")
                            {
                                quality.set_visible(true);
                            }
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
                    let seed_color =
                        crate::palette::placeholder_colors(&format!("{}|{}", track.album, track.artist)).0;
                    if ui_ref.core.player.is_playing() {
                        bar_ref.add_css_class("playing");
                        equalizer.set_visible(true);
                    }
                    let weak = artwork.downgrade();
                    ui_ref.core.artwork.request(
                        &track.album,
                        &track.artist,
                        52,
                        move |texture, color| {
                            if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                                picture.set_paintable(Some(texture));
                            }
                            set_adaptive_accent(Some(color.unwrap_or(seed_color)));
                        },
                    );
                }
                None => {
                    title.set_label("Not Playing");
                    artist.set_label("");
                    quality.set_visible(false);
                    love.set_sensitive(false);
                    artwork.set_visible(false);
                    equalizer.set_visible(false);
                    bar_ref.remove_css_class("playing");
                    set_adaptive_accent(None);
                    *current_rel.borrow_mut() = None;
                }
            },
            AppEvent::PlayingChanged(playing) => {
                play.set_icon_name(if *playing {
                    "media-playback-pause-symbolic"
                } else {
                    "media-playback-start-symbolic"
                });
                if *playing {
                    bar_ref.add_css_class("playing");
                    equalizer.set_visible(current_rel.borrow().is_some());
                } else {
                    bar_ref.remove_css_class("playing");
                    equalizer.set_visible(false);
                }
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
            AppEvent::RepeatChanged(mode) => apply_repeat(&repeat, *mode),
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
                    if !bar_ref.has_css_class("transport-compact")
                        && !bar_ref.has_css_class("transport-slim")
                    {
                        sleep_label.set_visible(true);
                    }
                    sleep_button.add_css_class("accent-toggle");
                }
                (None, true) => {
                    sleep_label.set_label("EOT");
                    if !bar_ref.has_css_class("transport-compact")
                        && !bar_ref.has_css_class("transport-slim")
                    {
                        sleep_label.set_visible(true);
                    }
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

    root.upcast()
}

/// Progressive chrome reduction. Keeps the three-column skeleton intact so
/// the play cluster never drifts off-center as widgets hide.
fn install_width_adaptation(
    root: &gtk::Box,
    left: &adw::Clamp,
    right: &gtk::Box,
    artist: &gtk::Label,
    title: &gtk::Label,
    love: &gtk::Button,
    shuffle: &gtk::ToggleButton,
    repeat: &gtk::Button,
    lyrics_toggle: &gtk::ToggleButton,
    sleep_button: &gtk::MenuButton,
    queue_toggle: &gtk::ToggleButton,
    volume: &gtk::Scale,
    volume_icon: &gtk::Image,
    quality: &gtk::Label,
    sleep_label: &gtk::Label,
) {
    let left = left.clone();
    let right = right.clone();
    let artist = artist.clone();
    let title = title.clone();
    let love = love.clone();
    let shuffle = shuffle.clone();
    let repeat = repeat.clone();
    let lyrics_toggle = lyrics_toggle.clone();
    let sleep_button = sleep_button.clone();
    let queue_toggle = queue_toggle.clone();
    let volume = volume.clone();
    let volume_icon = volume_icon.clone();
    let quality = quality.clone();
    let sleep_label = sleep_label.clone();
    let quality_has_text = Rc::new(Cell::new(false));
    {
        let quality_has_text = Rc::clone(&quality_has_text);
        quality.connect_notify_local(Some("label"), move |label, _| {
            quality_has_text.set(!label.label().is_empty());
        });
    }

    let adapt = {
        let root = root.clone();
        let left = left.clone();
        let right = right.clone();
        let artist = artist.clone();
        let title = title.clone();
        let love = love.clone();
        let shuffle = shuffle.clone();
        let repeat = repeat.clone();
        let lyrics_toggle = lyrics_toggle.clone();
        let sleep_button = sleep_button.clone();
        let queue_toggle = queue_toggle.clone();
        let volume = volume.clone();
        let volume_icon = volume_icon.clone();
        let quality = quality.clone();
        let sleep_label = sleep_label.clone();
        let quality_has_text = Rc::clone(&quality_has_text);
        Rc::new(move || {
            let width = root.width();
            if width <= 1 {
                return;
            }
            // Tiers:
            //   wide     ≥ 900  — full chrome
            //   compact  ≥ 620  — drop volume slider + quality/sleep labels
            //   slim     ≥ 420  — core transport only (prev/play/next + queue)
            //   tiny     < 420  — meta collapses to title only
            let tiny = width < 420;
            let slim = width < 620;
            let compact = width < 900;

            root.remove_css_class("transport-slim");
            root.remove_css_class("transport-compact");
            root.remove_css_class("transport-tiny");
            if tiny {
                root.add_css_class("transport-tiny");
            } else if slim {
                root.add_css_class("transport-slim");
            } else if compact {
                root.add_css_class("transport-compact");
            }

            // Derive every flag from width tiers first. Never read is_visible()
            // after a hide — that checks the parent chain, so a hidden right
            // wing would keep volume "invisible" forever when growing again.
            let show_artist = !tiny && !slim;
            let show_love = !tiny;
            let show_shuffle = !slim;
            let show_repeat = !slim;
            let show_lyrics = !slim;
            let show_sleep = !slim;
            let show_queue = !tiny;
            let show_volume = !compact;
            let show_quality = !compact && quality_has_text.get();
            // Label text survives compact hide — restore when wide again.
            let show_sleep_label = !compact && !sleep_label.label().is_empty();

            artist.set_visible(show_artist);
            love.set_visible(show_love);
            title.set_max_width_chars(if tiny { 10 } else if slim { 14 } else { 22 });
            left.set_maximum_size(if tiny {
                120
            } else if slim {
                160
            } else if compact {
                200
            } else {
                260
            });

            shuffle.set_visible(show_shuffle);
            repeat.set_visible(show_repeat);
            lyrics_toggle.set_visible(show_lyrics);
            sleep_button.set_visible(show_sleep);
            queue_toggle.set_visible(show_queue);
            volume.set_visible(show_volume);
            volume_icon.set_visible(show_volume);
            quality.set_visible(show_quality);
            sleep_label.set_visible(show_sleep_label);

            let right_has_visible = show_queue
                || show_lyrics
                || show_sleep
                || show_volume
                || show_quality
                || show_sleep_label;
            right.set_visible(right_has_visible);
            left.set_visible(true);
        })
    };

    let last_width = Rc::new(Cell::new(0i32));
    {
        let adapt = Rc::clone(&adapt);
        let last_width = Rc::clone(&last_width);
        root.connect_realize(move |widget| {
            adapt();
            let adapt = Rc::clone(&adapt);
            let last_width = Rc::clone(&last_width);
            widget.add_tick_callback(move |widget, _| {
                let width = widget.width();
                if width != last_width.get() {
                    last_width.set(width);
                    adapt();
                }
                glib::ControlFlow::Continue
            });
        });
    }
}

/// Three-bar now-playing indicator overlaid bottom-trailing on the mini
/// artwork; the bars only animate while the transport carries the `.playing`
/// class, so paused playback triggers no idle repaint.
fn build_equalizer() -> gtk::Box {
    let bars = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(2)
        .halign(gtk::Align::End)
        .valign(gtk::Align::End)
        .build();
    bars.add_css_class("equalizer");
    for _ in 0..3 {
        let bar = gtk::Box::new(gtk::Orientation::Vertical, 0);
        bar.add_css_class("eq-bar");
        bar.set_valign(gtk::Align::End);
        bars.append(&bar);
    }
    bars.set_visible(false);
    bars
}
