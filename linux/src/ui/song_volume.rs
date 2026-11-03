//! A song's own volume: the dialog that sets it and the pill beside the volume
//! slider that shows it for the song playing. Mirrors the Apple clients'
//! Song Volume sheet; the level lives in `songGains` and syncs through Flaccy
//! Server as `gain/<songKey>`.

use crate::events::AppEvent;
use crate::library::Track;
use crate::ui::Ui;
use adw::prelude::*;
use flaccy_shared::equalizer::song_gain::{self, MAX_TENTHS, STEP_TENTHS};
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::time::Duration;

const SAVE_DELAY: Duration = Duration::from_millis(350);

const EXPLANATION: &str = "Plays this song louder or quieter on every Flaccy you sync with your Flaccy Server. A raised song is held back from clipping.";

/// Opens the dialog for `track`. While the slider moves the song plays at the
/// new level at once; the level is saved when the slider rests.
pub fn present(ui: &Rc<Ui>, track: &Track) {
    let initial = ui.core.song_gain(track);
    let dialog = adw::Dialog::builder()
        .title("Song Volume")
        .content_width(420)
        .build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(&adw::HeaderBar::new());

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(14)
        .margin_top(6)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .build();

    let title = gtk::Label::builder()
        .label(&track.title)
        .wrap(true)
        .justify(gtk::Justification::Center)
        .build();
    title.add_css_class("title-3");
    let artist = gtk::Label::builder()
        .label(&track.artist)
        .wrap(true)
        .justify(gtk::Justification::Center)
        .build();
    artist.add_css_class("dim-label");
    let heading = gtk::Box::new(gtk::Orientation::Vertical, 2);
    heading.append(&title);
    heading.append(&artist);
    content.append(&heading);

    let readout = gtk::Label::new(Some(&song_gain::label(initial)));
    readout.add_css_class("title-1");
    readout.add_css_class("numeric");
    readout.add_css_class("song-volume-readout");
    content.append(&readout);

    let limit = song_gain::decibels(MAX_TENTHS);
    let scale = gtk::Scale::with_range(
        gtk::Orientation::Horizontal,
        -limit,
        limit,
        song_gain::decibels(STEP_TENTHS),
    );
    scale.set_hexpand(true);
    scale.set_has_origin(false);
    scale.set_draw_value(false);
    scale.set_round_digits(1);
    for mark in [-limit, -limit / 2.0, 0.0, limit / 2.0, limit] {
        scale.add_mark(mark, gtk::PositionType::Bottom, Some(&song_gain::label((mark * 10.0) as i32)));
    }
    scale.set_value(song_gain::decibels(initial));
    scale.update_property(&[gtk::accessible::Property::Label("Song volume")]);

    let lower = step_button("list-remove-symbolic", "Quieter by 0.5 dB");
    let raise = step_button("list-add-symbolic", "Louder by 0.5 dB");
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    row.append(&lower);
    row.append(&scale);
    row.append(&raise);
    content.append(&row);

    let explanation = gtk::Label::builder()
        .label(EXPLANATION)
        .wrap(true)
        .justify(gtk::Justification::Center)
        .build();
    explanation.add_css_class("dim-label");
    explanation.add_css_class("caption");
    content.append(&explanation);

    let reset = gtk::Button::with_label("Reset to 0 dB");
    reset.add_css_class("pill");
    reset.set_halign(gtk::Align::Center);
    reset.set_sensitive(initial != 0);
    content.append(&reset);

    let level = Rc::new(Cell::new(initial));
    let pending_save: Rc<RefCell<Option<glib::SourceId>>> = Rc::new(RefCell::new(None));
    let save_now = {
        let ui = Rc::clone(ui);
        let track = track.clone();
        let level = Rc::clone(&level);
        let pending_save = Rc::clone(&pending_save);
        Rc::new(move || {
            if let Some(source) = pending_save.borrow_mut().take() {
                source.remove();
            }
            if ui.core.song_gain(&track) != level.get() {
                level.set(ui.core.set_song_gain(&track, level.get()));
            }
        })
    };
    let changed = {
        let ui = Rc::clone(ui);
        let track = track.clone();
        let level = Rc::clone(&level);
        let readout = readout.clone();
        let reset = reset.clone();
        let save_now = Rc::clone(&save_now);
        let pending_save = Rc::clone(&pending_save);
        Rc::new(move |tenths: i32| {
            if level.replace(tenths) == tenths {
                return;
            }
            readout.set_label(&song_gain::label(tenths));
            reset.set_sensitive(tenths != 0);
            ui.core.preview_song_gain(&track, tenths);
            if let Some(source) = pending_save.borrow_mut().take() {
                source.remove();
            }
            let save_now = Rc::clone(&save_now);
            let pending = Rc::clone(&pending_save);
            *pending_save.borrow_mut() = Some(glib::timeout_add_local_once(SAVE_DELAY, move || {
                pending.borrow_mut().take();
                save_now();
            }));
        })
    };
    {
        let changed = Rc::clone(&changed);
        scale.connect_value_changed(move |scale| changed(song_gain::snapped(scale.value())));
    }
    for (button, steps) in [(&lower, -1), (&raise, 1)] {
        let scale = scale.clone();
        let level = Rc::clone(&level);
        button.connect_clicked(move |_| {
            scale.set_value(song_gain::decibels(song_gain::stepped(level.get(), steps)));
        });
    }
    {
        let scale = scale.clone();
        reset.connect_clicked(move |_| scale.set_value(0.0));
    }
    dialog.connect_closed(move |_| save_now());

    toolbar.set_content(Some(&content));
    dialog.set_child(Some(&toolbar));
    dialog.present(Some(&ui.window));
}

fn step_button(icon: &str, label: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("circular");
    button.add_css_class("flat");
    button.set_valign(gtk::Align::Center);
    button.set_tooltip_text(Some(label));
    button.update_property(&[gtk::accessible::Property::Label(label)]);
    button
}

/// The pill beside the volume slider: hidden at 0 dB, otherwise the playing
/// song's own level, which opens the dialog.
pub fn level_pill(ui: &Rc<Ui>) -> gtk::Button {
    let pill = gtk::Button::new();
    pill.add_css_class("song-volume-pill");
    pill.set_valign(gtk::Align::Center);
    pill.set_visible(false);
    {
        let ui = Rc::clone(ui);
        pill.connect_clicked(move |_| {
            if let Some(track) = ui.core.player.current_track() {
                present(&ui, &track);
            }
        });
    }
    let refresh = {
        let ui = Rc::clone(ui);
        let pill = pill.downgrade();
        move || {
            let Some(pill) = pill.upgrade() else { return };
            let level = ui
                .core
                .player
                .current_track()
                .map(|track| ui.core.song_gain(&track))
                .unwrap_or(0);
            pill.set_visible(level != 0);
            pill.set_label(&song_gain::label(level));
            let description = format!("Song volume {}", song_gain::label(level));
            pill.set_tooltip_text(Some(&description));
            pill.update_property(&[gtk::accessible::Property::Label(&description)]);
        }
    };
    refresh();
    ui.core.hub.subscribe_widget(&pill, move |_, event| {
        if matches!(event, AppEvent::SongGainChanged | AppEvent::TrackChanged(_)) {
            refresh();
        }
    });
    pill
}
