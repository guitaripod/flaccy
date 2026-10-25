//! The pieces Home is put together from: the hero in its four shapes, Jump
//! Back In rows, the strip cards, and the tiles of the two horizontal shelves.
//! Nothing here animates by itself: hover reveals are CSS opacity changes, the
//! progress bar and the spark are drawn once, and no tick callback is ever
//! added, so a resting Home costs the frame clock nothing.

use crate::home_data::{
    AlbumCard, Cover, DayOneHero, JumpItem, MixCard, MixHero, MixKind, OtdCard, ResumeHero, Target,
};
use crate::ui::mosaic::{Mosaic, OnColor};
use crate::ui::playlist_cover::PlaylistArt;
use crate::ui::{albums, context, controls, playlists, Ui};
use adw::prelude::*;
use flaccy_shared::home::{ContextKind, PlaybackContext, WeekGlance};
use flaccy_shared::home_copy;
use flaccy_shared::track_page_layout::PageMode;
use gtk::{gdk, glib, pango};
use std::f64::consts::PI;
use std::rc::Rc;

pub const HERO_COVER_WIDE: i32 = 248;
pub const HERO_COVER_REGULAR: i32 = 200;
pub const HERO_COVER_COMPACT: i32 = 148;
pub const JUMP_ROW_COVER: i32 = 36;
pub const MIX_TILE: i32 = 160;
pub const MIX_TILE_COMPACT: i32 = 150;
pub const ALBUM_TILE: i32 = 136;
pub const JUMP_BACK_IN_WIDTH: i32 = 380;
const COMPACT_JUMP_ROWS: usize = 3;

fn text(label: &str, classes: &[&str]) -> gtk::Label {
    let label = gtk::Label::builder()
        .label(label)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    for class in classes {
        label.add_css_class(class);
    }
    label
}

/// A label that never asks for more room than it is given: it takes the width
/// of whatever holds it and ellipsizes, instead of stretching a tile or a row
/// to fit its text.
fn fitted(label: &str, classes: &[&str]) -> gtk::Label {
    let label = text(label, classes);
    label.set_max_width_chars(1);
    label.set_width_chars(1);
    label
}

fn icon_button(icon: &str, tooltip: &str) -> gtk::Button {
    let button = gtk::Button::from_icon_name(icon);
    button.add_css_class("circular");
    button.add_css_class("home-round");
    button.set_tooltip_text(Some(tooltip));
    button.update_property(&[gtk::accessible::Property::Label(tooltip)]);
    button.set_valign(gtk::Align::Center);
    button
}

fn pill(icon: Option<&str>, label: &str, suggested: bool) -> gtk::Button {
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    content.set_halign(gtk::Align::Center);
    if let Some(icon) = icon {
        content.append(&gtk::Image::from_icon_name(icon));
    }
    content.append(&gtk::Label::new(Some(label)));
    let button = gtk::Button::builder().child(&content).build();
    button.add_css_class("pill");
    if suggested {
        button.add_css_class("suggested-action");
    }
    button.set_valign(gtk::Align::Center);
    button
}

/// Makes a plain widget behave like a button: it takes focus, Enter and Space
/// activate it, and so does a click.
fn make_activatable(widget: &impl IsA<gtk::Widget>, activate: impl Fn() + 'static) {
    let widget = widget.as_ref();
    widget.set_focusable(true);
    widget.set_cursor_from_name(Some("pointer"));
    let activate = Rc::new(activate);
    let click = gtk::GestureClick::new();
    {
        let activate = Rc::clone(&activate);
        click.connect_released(move |gesture, _, _, _| {
            gesture.set_state(gtk::EventSequenceState::Claimed);
            activate();
        });
    }
    widget.add_controller(click);
    let keys = gtk::EventControllerKey::new();
    keys.connect_key_pressed(move |_, key, _, _| {
        if matches!(key, gdk::Key::Return | gdk::Key::KP_Enter | gdk::Key::space) {
            activate();
            glib::Propagation::Stop
        } else {
            glib::Propagation::Proceed
        }
    });
    widget.add_controller(keys);
}

pub fn artist_station_name(context: &PlaybackContext) -> String {
    context
        .title
        .strip_suffix(&format!(" {}", home_copy::RADIO))
        .unwrap_or(&context.title)
        .to_string()
}

/// Opens where a row or card leads: the album or playlist page, and for a
/// mix or radio, which have no page of their own, plays it.
pub fn open(ui: &Rc<Ui>, target: &Target, context: &PlaybackContext) {
    match target {
        Target::Album(album) => albums::push_album_detail(ui, album),
        Target::Playlist(id) => playlists::push_playlist_detail(ui, *id),
        Target::Mix { .. } | Target::Radio(_) => play(ui, target, context),
    }
}

pub fn play(ui: &Rc<Ui>, target: &Target, context: &PlaybackContext) {
    match target {
        Target::Album(album) => ui.core.play_album_key(&album.key(), false),
        Target::Playlist(id) => playlists::play_playlist(ui, *id, false),
        Target::Mix { id, tracks } => {
            ui.core
                .play_list_in(tracks.clone(), false, id, Some(context.clone()));
        }
        Target::Radio(radio) => {
            if radio.id == home_copy::LIBRARY_RADIO_ID {
                ui.core.start_library_radio();
            } else {
                ui.core.start_artist_station(&artist_station_name(radio));
            }
        }
    }
}

/// A cover of `side` points in the shape its kind wants, wearing the page's
/// shared cover style. `on_color` hears the first album's dominant color.
pub fn cover(ui: &Rc<Ui>, cover: &Cover, side: i32, on_color: Option<OnColor>) -> gtk::Widget {
    match cover {
        Cover::Album((title, artist)) => {
            let picture = gtk::Picture::builder()
                .width_request(side)
                .height_request(side)
                .content_fit(gtk::ContentFit::Cover)
                .halign(gtk::Align::Start)
                .valign(gtk::Align::Start)
                .build();
            picture.set_overflow(gtk::Overflow::Hidden);
            picture.add_css_class("cover");
            picture.set_paintable(Some(
                &ui.core.artwork.placeholder(&format!("{title}|{artist}")),
            ));
            crate::ui::artwork::follow_picture(&ui.core, &picture, title, artist, side as u32);
            if let Some(on_color) = on_color {
                ui.core
                    .artwork
                    .request(title, artist, side as u32, move |_, color| {
                        if let Some(color) = color {
                            on_color(color);
                        }
                    });
            }
            picture.upcast()
        }
        Cover::Playlist { id, name, albums } => {
            let art = PlaylistArt::new(ui, *id, name, side, "cover", albums.clone());
            if let Some(on_color) = on_color {
                art.set_on_color(on_color);
            }
            art.widget().upcast()
        }
        Cover::Mosaic { seed, albums } => {
            let mosaic = Mosaic::new();
            mosaic.set_fixed_size(side);
            mosaic.widget().add_css_class("cover");
            mosaic.widget().set_halign(gtk::Align::Start);
            mosaic.widget().set_valign(gtk::Align::Start);
            mosaic.set_covers(ui, seed, albums, on_color);
            mosaic.widget().clone().upcast()
        }
    }
}

fn rounded_rectangle(cr: &gtk::cairo::Context, x: f64, y: f64, width: f64, height: f64) {
    let radius = (height / 2.0).min(width / 2.0);
    cr.new_sub_path();
    cr.arc(x + width - radius, y + radius, radius, -PI / 2.0, 0.0);
    cr.arc(
        x + width - radius,
        y + height - radius,
        radius,
        0.0,
        PI / 2.0,
    );
    cr.arc(x + radius, y + height - radius, radius, PI / 2.0, PI);
    cr.arc(x + radius, y + radius, radius, PI, 3.0 * PI / 2.0);
    cr.close_path();
}

fn repaint_on_theme_change(area: &gtk::DrawingArea) {
    if let Some(controller) = crate::theme::ThemeController::current() {
        controller.connect_changed_widget(area, |area| area.queue_draw());
    }
}

/// The track-by-track progress through a queue: one segment per song with the
/// played share filled in the accent, or one continuous bar for a queue too
/// long to segment. Drawn once; it never ticks.
pub fn segmented_bar(segments: &[f64]) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_height(6)
        .hexpand(true)
        .valign(gtk::Align::Center)
        .build();
    let segments = segments.to_vec();
    area.set_draw_func(move |area, cr, width, height| {
        let (red, green, blue) = crate::theme::accent_tint();
        let ink = area.color();
        let (width, height) = (width as f64, height as f64);
        let count = segments.len().max(1);
        let gap = 3.0;
        let each = if count == 1 {
            width
        } else {
            (width - gap * (count - 1) as f64) / count as f64
        };
        for (position, fill) in segments.iter().enumerate() {
            let left = position as f64 * (each + gap);
            rounded_rectangle(cr, left, 0.0, each, height);
            cr.set_source_rgba(
                ink.red() as f64,
                ink.green() as f64,
                ink.blue() as f64,
                0.18,
            );
            let _ = cr.fill_preserve();
            if *fill > 0.0 {
                let _ = cr.save();
                cr.clip();
                cr.rectangle(left, 0.0, each * fill.clamp(0.0, 1.0), height);
                cr.set_source_rgb(red, green, blue);
                let _ = cr.fill();
                let _ = cr.restore();
            } else {
                cr.new_path();
            }
        }
    });
    repaint_on_theme_change(&area);
    area
}

/// Seven bars of plays per day, today's in the accent.
pub fn spark(week: &WeekGlance) -> gtk::DrawingArea {
    let area = gtk::DrawingArea::builder()
        .content_width(53)
        .content_height(28)
        .valign(gtk::Align::Center)
        .build();
    let daily = week.daily;
    let peak = daily.iter().copied().max().unwrap_or(0).max(1) as f64;
    area.set_draw_func(move |area, cr, width, height| {
        let (red, green, blue) = crate::theme::accent_tint();
        let ink = area.color();
        let (width, height) = (width as f64, height as f64);
        let gap = 3.0;
        let each = (width - gap * 6.0) / 7.0;
        for (position, value) in daily.iter().enumerate() {
            let bar = (height * *value as f64 / peak).max(3.0);
            rounded_rectangle(cr, position as f64 * (each + gap), height - bar, each, bar);
            if position == 6 {
                cr.set_source_rgb(red, green, blue);
            } else {
                cr.set_source_rgba(
                    ink.red() as f64,
                    ink.green() as f64,
                    ink.blue() as f64,
                    0.35,
                );
            }
            let _ = cr.fill();
        }
    });
    repaint_on_theme_change(&area);
    area
}

struct HeroText {
    column: gtk::Box,
}

/// Kicker, big title, the line under it, and an optional badge and meta line.
fn hero_text(
    ui: &Rc<Ui>,
    kicker: &str,
    title: &str,
    line: &str,
    artist_link: Option<String>,
    badge: Option<&str>,
    meta: Option<&str>,
    compact: bool,
) -> HeroText {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 4);
    column.set_valign(gtk::Align::Center);
    column.set_hexpand(true);
    column.append(&text(kicker, &["home-kicker"]));
    let title = gtk::Label::builder()
        .label(title)
        .xalign(0.0)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .lines(2)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    title.add_css_class("home-title");
    if compact {
        title.add_css_class("home-title-compact");
    }
    column.append(&title);
    if !line.is_empty() {
        let artist = text(line, &["home-artist"]);
        match artist_link {
            Some(name) => {
                artist.set_halign(gtk::Align::Start);
                controls::attach_label_nav(ui, &artist, "Go to Artist", move |ui| {
                    crate::ui::goto_artist(ui, &name);
                });
            }
            None => artist.add_css_class("dim"),
        }
        column.append(&artist);
    }
    if badge.is_some() || meta.is_some() {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        row.set_margin_top(2);
        if let Some(badge) = badge {
            let chip = gtk::Label::new(Some(badge));
            chip.add_css_class("quality-badge");
            chip.set_valign(gtk::Align::Center);
            row.append(&chip);
        }
        if let Some(meta) = meta {
            row.append(&text(meta, &["dim", "caption"]));
        }
        column.append(&row);
    }
    HeroText { column }
}

fn track_time_line(left: &str, right: &str) -> gtk::Box {
    let line = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let left = text(left, &["home-track-line"]);
    left.set_hexpand(true);
    line.append(&left);
    let right = gtk::Label::new(Some(right));
    right.add_css_class("dim");
    right.add_css_class("caption");
    line.append(&right);
    line
}

fn cover_side(mode: PageMode) -> i32 {
    match mode {
        PageMode::Wide => HERO_COVER_WIDE,
        PageMode::Regular => HERO_COVER_REGULAR,
        PageMode::Compact => HERO_COVER_COMPACT,
    }
}

/// Lays a hero out for the room it has: cover beside the text, with the
/// compact arrangement moving the progress and buttons under both.
fn arrange_hero(
    cover: gtk::Widget,
    text: HeroText,
    body: Vec<gtk::Widget>,
    mode: PageMode,
) -> gtk::Widget {
    if mode == PageMode::Compact {
        let top = gtk::Box::new(gtk::Orientation::Horizontal, 16);
        top.append(&cover);
        top.append(&text.column);
        let hero = gtk::Box::new(gtk::Orientation::Vertical, 14);
        hero.append(&top);
        for widget in body {
            hero.append(&widget);
        }
        hero.add_css_class("home-hero");
        return hero.upcast();
    }
    for widget in body {
        text.column.append(&widget);
    }
    cover.set_hexpand(false);
    let hero = gtk::Box::new(gtk::Orientation::Horizontal, 28);
    hero.append(&cover);
    hero.append(&text.column);
    hero.add_css_class("home-hero");
    hero.upcast()
}

pub fn resume_hero(
    ui: &Rc<Ui>,
    hero: &ResumeHero,
    mode: PageMode,
    on_color: OnColor,
) -> gtk::Widget {
    let compact = mode == PageMode::Compact;
    let cover = cover(ui, &hero.cover, cover_side(mode), Some(on_color));
    let text_column = hero_text(
        ui,
        &hero.kicker,
        &hero.title,
        &hero.subtitle,
        hero.artist.clone(),
        hero.quality.as_deref(),
        hero.meta.as_deref(),
        compact,
    );

    let bar = segmented_bar(&hero.segments);
    bar.set_margin_top(if compact { 0 } else { 10 });
    let line = track_time_line(&hero.track_line, &hero.remaining);

    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    buttons.set_margin_top(if compact { 0 } else { 8 });
    let resume = pill(
        Some("media-playback-start-symbolic"),
        home_copy::RESUME,
        true,
    );
    resume.set_hexpand(compact);
    {
        let ui = Rc::clone(ui);
        resume.connect_clicked(move |_| {
            ui.core.resume_session(false);
        });
    }
    buttons.append(&resume);
    let shuffle = icon_button("media-playlist-shuffle-symbolic", home_copy::SHUFFLE);
    {
        let ui = Rc::clone(ui);
        shuffle.connect_clicked(move |_| {
            ui.core.resume_session(true);
        });
    }
    buttons.append(&shuffle);
    if let Some(menu) = hero_menu(&hero.target) {
        let more = icon_button("view-more-symbolic", "More");
        more.connect_clicked(move |button| {
            context::popup_menu_at(
                button,
                &menu,
                button.width() as f64 / 2.0,
                button.height() as f64,
            );
        });
        buttons.append(&more);
    }
    arrange_hero(
        cover,
        text_column,
        vec![bar.upcast(), line.upcast(), buttons.upcast()],
        mode,
    )
}

fn hero_menu(target: &Target) -> Option<gtk::gio::Menu> {
    match target {
        Target::Album(album) => Some(context::album_menu(&album.key())),
        Target::Playlist(id) => Some(playlists::playlist_list_menu(*id, false)),
        Target::Mix { .. } | Target::Radio(_) => None,
    }
}

pub fn mix_hero(ui: &Rc<Ui>, hero: &MixHero, mode: PageMode, on_color: OnColor) -> gtk::Widget {
    let compact = mode == PageMode::Compact;
    let cover = cover(ui, &hero.cover, cover_side(mode), Some(on_color));
    let text_column = hero_text(
        ui,
        &hero.kicker,
        &hero.title,
        &hero.subtitle,
        None,
        None,
        Some(&hero.meta),
        compact,
    );
    let mut body: Vec<gtk::Widget> = Vec::new();
    if let Some(starts) = &hero.starts_with {
        let starts = text(starts, &["dim", "caption"]);
        starts.set_margin_top(if compact { 0 } else { 6 });
        body.push(starts.upcast());
    }
    let context = mix_context(&hero.id, &hero.title, &hero.subtitle);
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    buttons.set_margin_top(if compact { 0 } else { 10 });
    let play = pill(Some("media-playback-start-symbolic"), home_copy::PLAY, true);
    play.set_hexpand(compact);
    {
        let ui = Rc::clone(ui);
        let tracks = hero.tracks.clone();
        let id = hero.id.clone();
        let context = context.clone();
        play.connect_clicked(move |_| {
            ui.core
                .play_list_in(tracks.clone(), false, &id, Some(context.clone()));
        });
    }
    buttons.append(&play);
    let next = icon_button("list-add-symbolic", home_copy::PLAY_NEXT_TOOLTIP);
    {
        let ui = Rc::clone(ui);
        let tracks = hero.tracks.clone();
        next.connect_clicked(move |_| {
            for track in tracks.iter().rev() {
                ui.core.player.insert_next(track.clone());
            }
        });
    }
    buttons.append(&next);
    let shuffle = icon_button("media-playlist-shuffle-symbolic", home_copy::SHUFFLE);
    {
        let ui = Rc::clone(ui);
        let tracks = hero.tracks.clone();
        let id = hero.id.clone();
        shuffle.connect_clicked(move |_| {
            ui.core
                .play_list_in(tracks.clone(), true, &id, Some(context.clone()));
        });
    }
    buttons.append(&shuffle);
    body.push(buttons.upcast());
    arrange_hero(cover, text_column, body, mode)
}

pub fn mix_context(id: &str, title: &str, subtitle: &str) -> PlaybackContext {
    PlaybackContext {
        kind: ContextKind::Mix,
        id: id.to_string(),
        title: title.to_string(),
        subtitle: subtitle.to_string(),
    }
}

pub fn day_one_hero(
    ui: &Rc<Ui>,
    hero: &DayOneHero,
    mode: PageMode,
    on_color: OnColor,
) -> gtk::Widget {
    let compact = mode == PageMode::Compact;
    let cover = cover(ui, &hero.cover, cover_side(mode), Some(on_color));
    let text_column = hero_text(
        ui,
        home_copy::DAY_ONE_KICKER,
        home_copy::DAY_ONE_TITLE,
        &hero.counts,
        None,
        None,
        hero.hi_res.as_deref(),
        compact,
    );
    let buttons = gtk::Box::new(gtk::Orientation::Horizontal, 10);
    buttons.set_margin_top(if compact { 0 } else { 12 });
    let shuffle = pill(
        Some("media-playlist-shuffle-symbolic"),
        home_copy::SHUFFLE_LIBRARY,
        true,
    );
    shuffle.set_hexpand(compact);
    {
        let ui = Rc::clone(ui);
        shuffle.connect_clicked(move |_| {
            let tracks = ui.core.library.borrow().tracks.clone();
            ui.core.play_list(tracks, true, "library");
        });
    }
    buttons.append(&shuffle);
    let radio = pill(Some("network-wireless-symbolic"), home_copy::RADIO, false);
    {
        let ui = Rc::clone(ui);
        radio.connect_clicked(move |_| ui.core.start_library_radio());
    }
    buttons.append(&radio);
    arrange_hero(cover, text_column, vec![buttons.upcast()], mode)
}

pub fn section_heading(title: &str, link: Option<(&str, Box<dyn Fn()>)>) -> gtk::Box {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let heading = text(title, &["title-2", "home-heading"]);
    heading.set_hexpand(true);
    row.append(&heading);
    if let Some((label, activate)) = link {
        let button = gtk::Button::with_label(label);
        button.add_css_class("flat");
        button.add_css_class("home-link");
        button.set_valign(gtk::Align::Center);
        button.connect_clicked(move |_| activate());
        row.append(&button);
    }
    row
}

/// The Jump Back In list. Compact shows three rows and "Show N More" until
/// the person expands it.
pub fn jump_list(
    ui: &Rc<Ui>,
    items: &[JumpItem],
    mode: PageMode,
    expanded: bool,
    on_expand: Rc<dyn Fn()>,
) -> gtk::Widget {
    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    list.add_css_class("home-jump");
    let hidden = if mode == PageMode::Compact && !expanded && items.len() > COMPACT_JUMP_ROWS + 1 {
        items.len() - COMPACT_JUMP_ROWS
    } else {
        0
    };
    let shown = items.len() - hidden;
    for item in &items[..shown] {
        list.append(&jump_row(ui, item));
    }
    if hidden > 0 {
        let more = text(&home_copy::show_more(hidden), &["home-show-more"]);
        more.set_margin_top(14);
        more.set_margin_bottom(14);
        more.set_halign(gtk::Align::Center);
        let row = gtk::ListBoxRow::builder().child(&more).build();
        row.set_activatable(true);
        list.append(&row);
    }
    {
        let ui = Rc::clone(ui);
        let items: Vec<JumpItem> = items[..shown].to_vec();
        list.connect_row_activated(move |_, row| {
            let index = row.index().max(0) as usize;
            match items.get(index) {
                Some(item) => open(&ui, &item.target, &item.context),
                None => on_expand(),
            }
        });
    }
    list.upcast()
}

fn jump_row(ui: &Rc<Ui>, item: &JumpItem) -> gtk::ListBoxRow {
    let row_box = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    row_box.set_margin_top(8);
    row_box.set_margin_bottom(8);
    row_box.set_margin_start(12);
    row_box.set_margin_end(12);
    let art = cover(ui, &item.cover, JUMP_ROW_COVER, None);
    art.add_css_class("home-jump-cover");
    art.set_valign(gtk::Align::Center);
    row_box.append(&art);
    let labels = gtk::Box::new(gtk::Orientation::Vertical, 1);
    labels.set_valign(gtk::Align::Center);
    labels.set_hexpand(true);
    labels.append(&fitted(&item.title, &["home-row-title"]));
    labels.append(&fitted(&item.subtitle, &["dim", "caption"]));
    row_box.append(&labels);
    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.add_css_class("circular");
    play.add_css_class("suggested-action");
    play.add_css_class("home-row-play");
    play.set_valign(gtk::Align::Center);
    play.set_tooltip_text(Some(&format!("Play {}", item.title)));
    play.update_property(&[gtk::accessible::Property::Label(&format!(
        "Play {}",
        item.title
    ))]);
    {
        let ui = Rc::clone(ui);
        let target = item.target.clone();
        let context = item.context.clone();
        play.connect_clicked(move |_| play_target(&ui, &target, &context));
    }
    row_box.append(&play);
    let row = gtk::ListBoxRow::builder().child(&row_box).build();
    row.add_css_class("home-row");
    row
}

fn play_target(ui: &Rc<Ui>, target: &Target, context: &PlaybackContext) {
    play(ui, target, context);
}

/// A square cover over a title and subtitle: clicking opens, the round button
/// that appears on hover or focus plays.
fn tile(
    ui: &Rc<Ui>,
    cover_model: &Cover,
    side: i32,
    title: &str,
    subtitle: &str,
    badge: Option<&str>,
    open_it: impl Fn() + 'static,
    play_it: impl Fn() + 'static,
) -> gtk::Overlay {
    let art = cover(ui, cover_model, side, None);
    let art_host = gtk::Overlay::new();
    art_host.set_child(Some(&art));
    art_host.set_halign(gtk::Align::Start);
    if let Some(badge) = badge {
        let chip = gtk::Label::new(Some(badge));
        chip.add_css_class("quality-badge");
        chip.add_css_class("home-tile-badge");
        chip.set_halign(gtk::Align::Start);
        chip.set_valign(gtk::Align::End);
        chip.set_margin_start(8);
        chip.set_margin_bottom(8);
        art_host.add_overlay(&chip);
    }
    let content = gtk::Box::new(gtk::Orientation::Vertical, 2);
    content.set_size_request(side, -1);
    content.append(&art_host);
    let title_label = fitted(title, &["home-tile-title"]);
    title_label.set_margin_top(6);
    content.append(&title_label);
    content.append(&fitted(subtitle, &["dim", "caption"]));

    let open_button = gtk::Button::builder().child(&content).build();
    open_button.add_css_class("flat");
    open_button.add_css_class("home-tile");
    open_button.update_property(&[gtk::accessible::Property::Label(title)]);
    open_button.connect_clicked(move |_| open_it());

    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.add_css_class("circular");
    play.add_css_class("suggested-action");
    play.add_css_class("home-tile-play");
    play.set_halign(gtk::Align::End);
    play.set_valign(gtk::Align::Start);
    play.set_margin_end(14);
    play.set_margin_top(side - 36);
    play.set_tooltip_text(Some(&format!("Play {title}")));
    play.update_property(&[gtk::accessible::Property::Label(&format!("Play {title}"))]);
    play.connect_clicked(move |_| play_it());

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&open_button));
    overlay.add_overlay(&play);
    overlay.set_halign(gtk::Align::Start);
    overlay.set_valign(gtk::Align::Start);
    overlay.add_css_class("home-tile-host");
    overlay
}

pub fn mix_tile(ui: &Rc<Ui>, card: &MixCard, side: i32) -> gtk::Widget {
    let (target, context) = match &card.kind {
        MixKind::Mix(id) => (
            Target::Mix {
                id: id.clone(),
                tracks: card.tracks.clone(),
            },
            mix_context(id, &card.title, &card.subtitle),
        ),
        MixKind::LibraryRadio => {
            let context = PlaybackContext {
                kind: ContextKind::Radio,
                id: home_copy::LIBRARY_RADIO_ID.to_string(),
                title: home_copy::LIBRARY_RADIO_TITLE.to_string(),
                subtitle: String::new(),
            };
            (Target::Radio(context.clone()), context)
        }
    };
    let subtitle = card.subtitle.clone();
    let tile = tile(
        ui,
        &card.cover,
        side,
        &card.title,
        &subtitle,
        None,
        {
            let (ui, target, context) = (Rc::clone(ui), target.clone(), context.clone());
            move || open(&ui, &target, &context)
        },
        {
            let ui = Rc::clone(ui);
            move || play(&ui, &target, &context)
        },
    );
    tile.upcast()
}

/// The dashed card that stands in while there are too few mixes to fill a shelf.
pub fn placeholder_tile(side: i32) -> gtk::Widget {
    let label = gtk::Label::builder()
        .label(home_copy::MORE_MIXES_PLACEHOLDER)
        .wrap(true)
        .wrap_mode(pango::WrapMode::WordChar)
        .justify(gtk::Justification::Center)
        .halign(gtk::Align::Center)
        .valign(gtk::Align::Center)
        .build();
    label.add_css_class("dim");
    label.add_css_class("caption");
    let card = gtk::Box::new(gtk::Orientation::Vertical, 0);
    card.set_size_request(side, side);
    card.set_margin_top(8);
    card.set_margin_start(8);
    card.set_valign(gtk::Align::Start);
    card.set_halign(gtk::Align::Start);
    card.add_css_class("home-placeholder");
    card.append(&label);
    label.set_vexpand(true);
    label.set_margin_start(14);
    label.set_margin_end(14);
    card.upcast()
}

pub fn album_tile(ui: &Rc<Ui>, card: &AlbumCard) -> gtk::Widget {
    let album = card.album.clone();
    let key = album.key();
    let tile = tile(
        ui,
        &Cover::Album((album.title.clone(), album.artist.clone())),
        ALBUM_TILE,
        &album.title,
        &album.artist,
        card.badge.as_deref(),
        {
            let (ui, album) = (Rc::clone(ui), album.clone());
            move || albums::push_album_detail(&ui, &album)
        },
        {
            let (ui, key) = (Rc::clone(ui), key.clone());
            move || ui.core.play_album_key(&key, false)
        },
    );
    context::attach_album_context_menu(&tile, key);
    tile.upcast()
}

/// A row of tiles that scrolls sideways when it overflows. The wheel keeps
/// scrolling the page: a ScrolledWindow would otherwise turn every vertical
/// notch over it into a sideways move and trap the pointer.
pub fn shelf(tiles: Vec<gtk::Widget>, page: &gtk::ScrolledWindow) -> gtk::Widget {
    let row = gtk::Box::new(gtk::Orientation::Horizontal, 6);
    for tile in tiles {
        row.append(&tile);
    }
    let scroller = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .vscrollbar_policy(gtk::PolicyType::Never)
        .hexpand(true)
        .propagate_natural_width(false)
        .propagate_natural_height(true)
        .child(&row)
        .build();
    scroller.add_css_class("home-shelf");
    let forward = gtk::EventControllerScroll::new(gtk::EventControllerScrollFlags::VERTICAL);
    forward.set_propagation_phase(gtk::PropagationPhase::Capture);
    let page = page.clone();
    forward.connect_scroll(move |_, _, dy| {
        let adjustment = page.vadjustment();
        let step = adjustment.page_size().powf(2.0 / 3.0);
        adjustment.set_value(adjustment.value() + dy * step);
        glib::Propagation::Stop
    });
    scroller.add_controller(forward);
    scroller.upcast()
}

fn strip_card() -> gtk::Box {
    let card = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    card.add_css_class("card");
    card.add_css_class("activatable");
    card.add_css_class("home-strip-card");
    card.set_size_request(250, 60);
    card.set_valign(gtk::Align::Start);
    card
}

fn card_text(title: &str, subtitle: &str) -> gtk::Box {
    let column = gtk::Box::new(gtk::Orientation::Vertical, 1);
    column.set_valign(gtk::Align::Center);
    column.set_hexpand(true);
    column.append(&fitted(title, &["home-card-title"]));
    column.append(&fitted(subtitle, &["dim", "caption"]));
    column
}

pub fn on_this_day_card(ui: &Rc<Ui>, card: &OtdCard) -> gtk::Widget {
    let strip = strip_card();
    strip.append(&card_text(&card.title, &card.subtitle));
    let play = gtk::Button::from_icon_name("media-playback-start-symbolic");
    play.add_css_class("circular");
    play.add_css_class("suggested-action");
    play.set_valign(gtk::Align::Center);
    play.set_tooltip_text(Some(&format!("Play {}", card.album.title)));
    {
        let ui = Rc::clone(ui);
        let key = card.album.key();
        play.connect_clicked(move |_| ui.core.play_album_key(&key, false));
    }
    strip.append(&play);
    let (open_ui, album) = (Rc::clone(ui), card.album.clone());
    make_activatable(&strip, move || albums::push_album_detail(&open_ui, &album));
    strip.upcast()
}

pub fn this_week_card(ui: &Rc<Ui>, week: &WeekGlance) -> gtk::Widget {
    let strip = strip_card();
    let column = gtk::Box::new(gtk::Orientation::Vertical, 1);
    column.set_valign(gtk::Align::Center);
    column.set_hexpand(true);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    top.append(&text(home_copy::THIS_WEEK, &["home-card-title"]));
    column.append(&top);
    let figures = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    figures.append(&text(
        &home_copy::week_value(week.seconds),
        &["home-week-value"],
    ));
    figures.append(&text(
        &home_copy::week_delta_line(week.plays_delta(), week.plays),
        &["dim", "caption"],
    ));
    column.append(&figures);
    strip.append(&column);
    strip.append(&spark(week));
    strip.set_tooltip_text(Some(home_copy::OPEN_STATS));
    strip.update_property(&[gtk::accessible::Property::Label(home_copy::OPEN_STATS)]);
    let ui = Rc::clone(ui);
    make_activatable(&strip, move || {
        let _ = gtk::prelude::WidgetExt::activate_action(
            &ui.window,
            "win.show-page",
            Some(&"stats".to_variant()),
        );
    });
    strip.upcast()
}

/// The Downloads card and the two labels a progress event rewrites in place.
pub struct DownloadsCard {
    pub widget: gtk::Widget,
    pub percent: gtk::Label,
    pub bar: gtk::ProgressBar,
}

pub fn downloads_card(ui: &Rc<Ui>, count: usize, fraction: f64) -> DownloadsCard {
    let strip = strip_card();
    let column = gtk::Box::new(gtk::Orientation::Vertical, 6);
    column.set_valign(gtk::Align::Center);
    column.set_hexpand(true);
    let top = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    let title = text(&home_copy::downloading(count), &["home-card-title"]);
    title.set_hexpand(true);
    top.append(&title);
    let percent = text(&percent_text(fraction), &["dim", "caption"]);
    top.append(&percent);
    column.append(&top);
    let bar = gtk::ProgressBar::new();
    bar.set_fraction(fraction);
    bar.add_css_class("home-download-bar");
    column.append(&bar);
    strip.append(&column);
    let ui = Rc::clone(ui);
    make_activatable(&strip, move || {
        let _ = gtk::prelude::WidgetExt::activate_action(
            &ui.window,
            "win.show-page",
            Some(&"downloads".to_variant()),
        );
    });
    DownloadsCard {
        widget: strip.upcast(),
        percent,
        bar,
    }
}

pub fn percent_text(fraction: f64) -> String {
    format!("{}%", (fraction.clamp(0.0, 1.0) * 100.0).round() as i32)
}
