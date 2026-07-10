use crate::db::Db;
use crate::recap::{self, YearData};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use gtk::{gio, pango};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

pub fn present(ui: &Rc<Ui>, years: Vec<i32>) {
    if years.is_empty() {
        ui.core.toast("No listening history yet for a Year in Music");
        return;
    }

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(20)
        .margin_top(20)
        .margin_bottom(28)
        .margin_start(28)
        .margin_end(28)
        .build();

    let year_labels: Vec<String> = years.iter().map(|y| y.to_string()).collect();
    let year_refs: Vec<&str> = year_labels.iter().map(String::as_str).collect();
    let dropdown = gtk::DropDown::from_strings(&year_refs);
    dropdown.set_halign(gtk::Align::Start);

    let summary = gtk::Box::new(gtk::Orientation::Vertical, 16);
    content.append(&dropdown);
    content.append(&summary);

    let export_row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(10)
        .halign(gtk::Align::Center)
        .margin_top(6)
        .build();
    let export_story = gtk::Button::with_label("Export Story PNG");
    export_story.add_css_class("pill");
    export_story.add_css_class("suggested-action");
    let export_post = gtk::Button::with_label("Export Post PNG");
    export_post.add_css_class("pill");
    export_row.append(&export_story);
    export_row.append(&export_post);
    content.append(&export_row);

    let data: Rc<RefCell<Option<Rc<YearData>>>> = Rc::new(RefCell::new(None));

    let load = {
        let ui = Rc::clone(ui);
        let summary = summary.clone();
        let data = Rc::clone(&data);
        let years = years.clone();
        Rc::new(move |index: usize| {
            let Some(year) = years.get(index).copied() else { return };
            let db_path = ui.core.db_path.clone();
            let durations: HashMap<String, i64> = ui
                .core
                .library
                .borrow()
                .tracks
                .iter()
                .filter(|t| t.duration > 0.0)
                .map(|t| (recap::track_key(&t.title, &t.artist), t.duration.round() as i64))
                .collect();
            let (tx, rx) = async_channel::bounded::<YearData>(1);
            std::thread::Builder::new()
                .name("flaccy-yim".into())
                .spawn(move || {
                    let rows = Db::open(&db_path)
                        .map(|db| db.fetch_all_scrobble_rows())
                        .unwrap_or_default();
                    let _ = tx.send_blocking(recap::compute_year(&rows, year, &durations));
                })
                .ok();
            let summary = summary.clone();
            let data = Rc::clone(&data);
            glib::spawn_future_local(async move {
                let Ok(computed) = rx.recv().await else { return };
                let computed = Rc::new(computed);
                *data.borrow_mut() = Some(Rc::clone(&computed));
                render_summary(&summary, &computed);
            });
        })
    };
    load(0);
    {
        let load = Rc::clone(&load);
        dropdown.connect_selected_notify(move |dropdown| {
            load(dropdown.selected() as usize);
        });
    }

    {
        let ui = Rc::clone(ui);
        let data = Rc::clone(&data);
        export_story.connect_clicked(move |_| export(&ui, &data, true));
    }
    {
        let ui = Rc::clone(ui);
        let data = Rc::clone(&data);
        export_post.connect_clicked(move |_| export(&ui, &data, false));
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .propagate_natural_height(true)
        .child(&content)
        .build();
    let toolbar = adw::ToolbarView::new();
    toolbar.add_top_bar(
        &adw::HeaderBar::builder()
            .title_widget(&adw::WindowTitle::new("Year in Music", ""))
            .build(),
    );
    toolbar.set_content(Some(&scroll));
    let dialog = adw::Dialog::builder()
        .content_width(560)
        .content_height(720)
        .child(&toolbar)
        .build();
    dialog.present(Some(&ui.window));
}

fn render_summary(summary: &gtk::Box, data: &YearData) {
    while let Some(child) = summary.first_child() {
        summary.remove(&child);
    }

    let hero = gtk::Label::builder()
        .label(format!("{}", data.year))
        .xalign(0.0)
        .build();
    hero.add_css_class("title-1");
    summary.append(&hero);

    let tiles = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .homogeneous(true)
        .build();
    tiles.append(&tile(&data.total_plays.to_string(), "PLAYS"));
    tiles.append(&tile(&data.total_minutes.to_string(), "MINUTES"));
    tiles.append(&tile(&data.longest_streak.to_string(), "DAY STREAK"));
    tiles.append(&tile(data.persona, "PERSONA"));
    summary.append(&tiles);

    let distinct = gtk::Label::builder()
        .label(format!(
            "{} artists · {} albums · {} tracks",
            data.distinct_artists, data.distinct_albums, data.distinct_tracks
        ))
        .xalign(0.0)
        .build();
    distinct.add_css_class("dim");
    summary.append(&distinct);

    let mut facts: Vec<String> = Vec::new();
    if let Some(day) = data.peak_day {
        facts.push(format!(
            "Biggest day: {} with {} plays",
            day.format("%B %-d"),
            data.peak_day_plays
        ));
    }
    if let Some(hour) = data.peak_hour {
        facts.push(format!("Peak listening hour: {hour:02}:00"));
    }
    for fact in facts {
        let label = gtk::Label::builder().label(&fact).xalign(0.0).build();
        label.add_css_class("dim");
        summary.append(&label);
    }

    summary.append(&top_section("TOP ARTISTS", &data.top_artists));
    let albums: Vec<(String, i64)> = data
        .top_albums
        .iter()
        .map(|(album, artist, count)| (format!("{album} — {artist}"), *count))
        .collect();
    summary.append(&top_section("TOP ALBUMS", &albums));
    let tracks: Vec<(String, i64)> = data
        .top_tracks
        .iter()
        .map(|(title, artist, count)| (format!("{title} — {artist}"), *count))
        .collect();
    summary.append(&top_section("TOP TRACKS", &tracks));
}

fn tile(value: &str, caption: &str) -> gtk::Widget {
    let tile = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(2)
        .build();
    tile.add_css_class("stat-tile");
    let value_label = gtk::Label::builder()
        .label(value)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    value_label.add_css_class("yim-value");
    tile.append(&value_label);
    let caption_label = gtk::Label::builder().label(caption).xalign(0.0).build();
    caption_label.add_css_class("stat-caption");
    tile.append(&caption_label);
    tile.upcast()
}

fn top_section(title: &str, rows: &[(String, i64)]) -> gtk::Widget {
    let section = gtk::Box::new(gtk::Orientation::Vertical, 6);
    let heading = gtk::Label::builder().label(title).xalign(0.0).build();
    heading.add_css_class("stat-caption");
    section.append(&heading);
    for (index, (name, count)) in rows.iter().enumerate() {
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        let rank = gtk::Label::builder()
            .label(format!("{}", index + 1))
            .width_chars(2)
            .xalign(1.0)
            .build();
        rank.add_css_class("top-list-rank");
        row.append(&rank);
        let name_label = gtk::Label::builder()
            .label(name)
            .xalign(0.0)
            .hexpand(true)
            .ellipsize(pango::EllipsizeMode::End)
            .tooltip_text(name)
            .build();
        row.append(&name_label);
        let count_label = gtk::Label::new(Some(&count.to_string()));
        count_label.add_css_class("duration-label");
        row.append(&count_label);
        section.append(&row);
    }
    section.upcast()
}

fn export(ui: &Rc<Ui>, data: &Rc<RefCell<Option<Rc<YearData>>>>, story: bool) {
    let Some(data) = data.borrow().clone() else { return };
    let Some(card) = crate::render::year_in_music_card(&data, story) else {
        ui.core.toast("Couldn't render the card");
        return;
    };
    let kind = if story { "story" } else { "post" };
    let suggested = format!("flaccy-year-in-music-{}-{}.png", data.year, kind);
    save_card(ui, card, &suggested);
}

/// Presents a save dialog and writes the rendered card as PNG.
pub fn save_card(ui: &Rc<Ui>, card: crate::render::Card, suggested_name: &str) {
    let dialog = gtk::FileDialog::builder()
        .title("Export PNG")
        .initial_name(suggested_name)
        .build();
    if let Some(pictures) = dirs::picture_dir().or_else(dirs::home_dir) {
        dialog.set_initial_folder(Some(&gio::File::for_path(pictures)));
    }
    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.save(Some(&window), None::<&gio::Cancellable>, move |result| {
        let Ok(file) = result else { return };
        let Some(path) = file.path() else { return };
        match card.write_png(&path) {
            Ok(()) => {
                crate::logger::info("ui", &format!("card exported to {}", path.display()));
                ui.core.toast(&format!("Saved {}", path.display()));
            }
            Err(err) => {
                crate::logger::error("ui", &format!("card export failed: {err}"));
                ui.core.toast("Export failed");
            }
        }
    });
}
