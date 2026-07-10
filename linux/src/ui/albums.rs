use crate::events::AppEvent;
use crate::library::{format_time, Album};
use crate::ui::{context, Ui};
use adw::prelude::*;
use gtk::pango;
use std::cell::RefCell;
use std::rc::Rc;

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let flow = gtk::FlowBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .homogeneous(true)
        .column_spacing(18)
        .row_spacing(24)
        .margin_top(24)
        .margin_bottom(24)
        .margin_start(24)
        .margin_end(24)
        .min_children_per_line(2)
        .max_children_per_line(10)
        .valign(gtk::Align::Start)
        .activate_on_single_click(true)
        .build();

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&flow)
        .build();

    let empty = adw::StatusPage::builder()
        .icon_name("emblem-music-symbolic")
        .title("No Music Found")
        .description("Drop FLAC or MP3 files into your music folder, then rescan.\nChoose a different folder in Preferences.")
        .build();
    let empty_button = gtk::Button::with_label("Open Preferences");
    empty_button.add_css_class("pill");
    empty_button.add_css_class("suggested-action");
    empty_button.set_halign(gtk::Align::Center);
    empty_button.set_action_name(Some("app.preferences"));
    empty.set_child(Some(&empty_button));

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&scroll, Some("grid"));

    let albums: Rc<RefCell<Vec<Album>>> = Rc::new(RefCell::new(Vec::new()));

    {
        let albums = Rc::clone(&albums);
        let query = Rc::clone(&ui.query);
        flow.set_filter_func(move |child| {
            let query = query.borrow();
            if query.is_empty() {
                return true;
            }
            let needle = query.to_lowercase();
            let albums = albums.borrow();
            let Some(album) = albums.get(child.index().max(0) as usize) else {
                return true;
            };
            album.title.to_lowercase().contains(&needle)
                || album.artist.to_lowercase().contains(&needle)
        });
    }

    {
        let albums = Rc::clone(&albums);
        let ui = Rc::clone(ui);
        flow.connect_child_activated(move |_, child| {
            let album = albums
                .borrow()
                .get(child.index().max(0) as usize)
                .cloned();
            if let Some(album) = album {
                push_album_detail(&ui, &album);
            }
        });
    }

    let rebuild = {
        let flow = flow.clone();
        let stack = stack.clone();
        let albums = Rc::clone(&albums);
        let ui = Rc::clone(ui);
        move || {
            while let Some(child) = flow.first_child() {
                flow.remove(&child);
            }
            let library = ui.core.library.borrow().clone();
            *albums.borrow_mut() = library.albums.clone();
            for album in library.albums.iter() {
                flow.append(&album_cell(&ui, album));
            }
            stack.set_visible_child_name(if library.albums.is_empty() {
                "empty"
            } else {
                "grid"
            });
        }
    };
    rebuild();

    {
        let flow = flow.clone();
        let rebuild = rebuild.clone();
        ui.core.hub.subscribe_widget(&stack, move |_, event| match event {
            AppEvent::LibraryReloaded => rebuild(),
            AppEvent::SearchChanged(_) => flow.invalidate_filter(),
            _ => {}
        });
    }

    stack.upcast()
}

fn album_cell(ui: &Rc<Ui>, album: &Album) -> gtk::FlowBoxChild {
    let cell = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(8)
        .width_request(168)
        .build();

    let picture = gtk::Picture::builder()
        .width_request(168)
        .height_request(168)
        .content_fit(gtk::ContentFit::Cover)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover");
    picture.set_paintable(Some(&ui.core.artwork.placeholder(&album.key())));
    {
        let weak = picture.downgrade();
        ui.core
            .artwork
            .request(&album.title, &album.artist, 168, move |texture, _| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
            });
    }
    cell.append(&picture);

    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(18)
        .tooltip_text(&album.title)
        .build();
    title.add_css_class("album-title");
    cell.append(&title);

    let subtitle_text = match &album.year {
        Some(year) if !year.is_empty() => format!("{} · {}", album.artist, year),
        _ => album.artist.clone(),
    };
    let subtitle = gtk::Label::builder()
        .label(&subtitle_text)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .max_width_chars(20)
        .build();
    subtitle.add_css_class("dim");
    subtitle.add_css_class("caption");
    cell.append(&subtitle);

    let child = gtk::FlowBoxChild::builder().child(&cell).build();
    context::attach_album_context_menu(&child, album.key());
    child
}

pub fn push_album_detail(ui: &Rc<Ui>, album: &Album) {
    let dominant: Rc<RefCell<Option<(u8, u8, u8)>>> = Rc::new(RefCell::new(None));

    let backdrop = gtk::DrawingArea::new();
    backdrop.set_hexpand(true);
    backdrop.set_vexpand(true);
    {
        let dominant = Rc::clone(&dominant);
        backdrop.set_draw_func(move |_, cr, width, height| {
            let Some((r, g, b)) = *dominant.borrow() else { return };
            let dark = adw::StyleManager::default().is_dark();
            let blend = |channel: u8| {
                let value = channel as f64 / 255.0;
                if dark {
                    value * 0.55
                } else {
                    value * 0.45 + 0.98 * 0.55
                }
            };
            let (r, g, b) = (blend(r), blend(g), blend(b));
            let gradient = gtk::cairo::LinearGradient::new(0.0, 0.0, 0.0, height as f64);
            gradient.add_color_stop_rgba(0.0, r, g, b, 0.85);
            gradient.add_color_stop_rgba(0.7, r, g, b, 0.0);
            let _ = cr.set_source(&gradient);
            cr.rectangle(0.0, 0.0, width as f64, height as f64);
            let _ = cr.fill();
        });
    }
    {
        let weak = backdrop.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(backdrop) = weak.upgrade() {
                backdrop.queue_draw();
            }
        });
    }

    let header = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(24)
        .build();

    let picture = gtk::Picture::builder()
        .width_request(232)
        .height_request(232)
        .content_fit(gtk::ContentFit::Cover)
        .valign(gtk::Align::Start)
        .build();
    picture.set_overflow(gtk::Overflow::Hidden);
    picture.add_css_class("cover-large");
    picture.set_paintable(Some(&ui.core.artwork.placeholder(&album.key())));
    {
        let weak = picture.downgrade();
        let backdrop_weak = backdrop.downgrade();
        let dominant = Rc::clone(&dominant);
        ui.core
            .artwork
            .request(&album.title, &album.artist, 232, move |texture, color| {
                if let (Some(picture), Some(texture)) = (weak.upgrade(), texture) {
                    picture.set_paintable(Some(texture));
                }
                if let Some(color) = color {
                    *dominant.borrow_mut() = Some(color);
                    if let Some(backdrop) = backdrop_weak.upgrade() {
                        backdrop.queue_draw();
                    }
                }
            });
    }
    header.append(&picture);

    let meta = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(6)
        .valign(gtk::Align::Center)
        .build();
    let title = gtk::Label::builder()
        .label(&album.title)
        .xalign(0.0)
        .wrap(true)
        .build();
    title.add_css_class("title-1");
    meta.append(&title);
    let artist = gtk::Label::builder().label(&album.artist).xalign(0.0).build();
    artist.add_css_class("title-4");
    artist.add_css_class("dim");
    meta.append(&artist);

    let mut info_parts: Vec<String> = Vec::new();
    if let Some(year) = album.year.as_ref().filter(|y| !y.is_empty()) {
        info_parts.push(year.clone());
    }
    if let Some(genre) = album.genre.as_ref().filter(|g| !g.is_empty()) {
        info_parts.push(genre.clone());
    }
    info_parts.push(format!(
        "{} songs · {} min",
        album.tracks.len(),
        (album.total_duration() / 60.0).round() as i64
    ));
    let info = gtk::Label::builder()
        .label(info_parts.join(" · "))
        .xalign(0.0)
        .build();
    info.add_css_class("dim");
    info.add_css_class("caption");
    meta.append(&info);

    if let Some(badge_text) = album_quality_summary(album) {
        let badge = gtk::Label::new(Some(&badge_text));
        badge.add_css_class("quality-badge");
        badge.set_halign(gtk::Align::Start);
        badge.set_margin_top(4);
        meta.append(&badge);
    }

    let buttons = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .margin_top(12)
        .build();
    let play = gtk::Button::builder().label("Play").build();
    play.add_css_class("pill");
    play.add_css_class("suggested-action");
    play.set_action_name(Some("win.play-album"));
    play.set_action_target_value(Some(&album.key().to_variant()));
    let shuffle = gtk::Button::builder().label("Shuffle").build();
    shuffle.add_css_class("pill");
    shuffle.set_action_name(Some("win.shuffle-album"));
    shuffle.set_action_target_value(Some(&album.key().to_variant()));
    buttons.append(&play);
    buttons.append(&shuffle);
    meta.append(&buttons);
    header.append(&meta);

    let list = gtk::ListBox::builder()
        .selection_mode(gtk::SelectionMode::None)
        .build();
    list.add_css_class("boxed-list");
    for track in &album.tracks {
        let row_box = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(12)
            .margin_top(10)
            .margin_bottom(10)
            .margin_start(12)
            .margin_end(12)
            .build();
        let number = gtk::Label::builder()
            .label(if track.track_number > 0 {
                track.track_number.to_string()
            } else {
                "·".to_string()
            })
            .width_chars(3)
            .xalign(1.0)
            .build();
        number.add_css_class("track-number");
        row_box.append(&number);
        let track_title = gtk::Label::builder()
            .label(&track.title)
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::End)
            .tooltip_text(&track.title)
            .build();
        row_box.append(&track_title);
        let heart = gtk::Image::from_icon_name("emblem-favorite-symbolic");
        heart.add_css_class("loved-heart");
        heart.set_visible(track.loved);
        row_box.append(&heart);
        if let Some(badge_text) = track.quality_badge() {
            let badge = gtk::Label::new(Some(&badge_text));
            badge.add_css_class("quality-badge");
            row_box.append(&badge);
        }
        let duration = gtk::Label::new(Some(&format_time(track.duration)));
        duration.add_css_class("duration-label");
        row_box.append(&duration);

        let row = gtk::ListBoxRow::builder().child(&row_box).build();
        context::attach_track_context_menu(&row, &ui.core, track.rel_path.clone());
        {
            let rel = track.rel_path.clone();
            ui.core.hub.subscribe_widget(&heart, move |heart, event| {
                if let AppEvent::LovedChanged { rel_path, loved } = event {
                    if rel_path == &rel {
                        heart.set_visible(*loved);
                    }
                }
            });
        }
        list.append(&row);
    }
    {
        let tracks = album.tracks.clone();
        let ui = Rc::clone(ui);
        list.connect_row_activated(move |_, row| {
            let index = row.index().max(0) as usize;
            ui.core.play_tracks(tracks.clone(), index);
        });
    }

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(24)
        .margin_top(32)
        .margin_bottom(32)
        .margin_start(32)
        .margin_end(32)
        .build();
    content.append(&header);
    content.append(&list);

    let clamp = adw::Clamp::builder()
        .maximum_size(920)
        .child(&content)
        .build();
    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&clamp)
        .build();

    let overlay = gtk::Overlay::new();
    overlay.set_child(Some(&backdrop));
    overlay.add_overlay(&scroll);

    let page = adw::NavigationPage::builder()
        .title(album.title.clone())
        .child(&overlay)
        .build();
    ui.nav.push(&page);
}

fn album_quality_summary(album: &Album) -> Option<String> {
    let badges: Vec<String> = album.tracks.iter().filter_map(|t| t.quality_badge()).collect();
    if badges.is_empty() {
        return None;
    }
    let first = &badges[0];
    if badges.iter().all(|b| b == first) {
        Some(first.clone())
    } else {
        Some("Mixed Quality".to_string())
    }
}
