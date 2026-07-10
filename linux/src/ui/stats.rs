use crate::events::AppEvent;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const CLOCK_TINT: (f64, f64, f64) = (0.45, 0.78, 1.0);

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(28)
        .margin_top(28)
        .margin_bottom(28)
        .margin_start(28)
        .margin_end(28)
        .build();

    let empty = adw::StatusPage::builder()
        .icon_name("utilities-system-monitor-symbolic")
        .title("No Listening History")
        .description("Play some music and your stats will build up here.")
        .build();

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&adw::Clamp::builder().maximum_size(880).child(&content).build())
        .build();

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&scroll, Some("stats"));

    let buckets: Rc<RefCell<[i64; 24]>> = Rc::new(RefCell::new([0; 24]));

    let rebuild = {
        let content = content.clone();
        let stack = stack.clone();
        let ui = Rc::clone(ui);
        let buckets = Rc::clone(&buckets);
        Rc::new(move || {
            while let Some(child) = content.first_child() {
                content.remove(&child);
            }
            let stats = ui.core.db.scrobble_stats();
            if stats.total_plays == 0 {
                stack.set_visible_child_name("empty");
                return;
            }
            stack.set_visible_child_name("stats");
            *buckets.borrow_mut() = stats.clock;

            let tiles = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(14)
                .homogeneous(true)
                .build();
            tiles.append(&stat_tile(&format_count(stats.total_plays), "PLAYS"));
            tiles.append(&stat_tile(&format_count(stats.total_minutes), "MINUTES"));
            content.append(&tiles);

            let clock_title = section_title("LISTENING CLOCK");
            content.append(&clock_title);
            let clock = gtk::DrawingArea::builder()
                .content_height(280)
                .hexpand(true)
                .build();
            {
                let buckets = Rc::clone(&buckets);
                clock.set_draw_func(move |_, cr, width, height| {
                    draw_listening_clock(cr, width as f64, height as f64, &buckets.borrow());
                });
            }
            content.append(&clock);

            let lists = gtk::Box::builder()
                .orientation(gtk::Orientation::Horizontal)
                .spacing(24)
                .homogeneous(true)
                .valign(gtk::Align::Start)
                .build();
            lists.append(&top_list("TOP ARTISTS", &stats.top_artists));
            lists.append(&top_list("TOP ALBUMS", &stats.top_albums));
            lists.append(&top_list("TOP TRACKS", &stats.top_tracks));
            content.append(&lists);
        })
    };
    rebuild();

    let dirty = Rc::new(Cell::new(false));
    {
        let rebuild = Rc::clone(&rebuild);
        let dirty = Rc::clone(&dirty);
        let stack_ref = stack.clone();
        ui.core.hub.subscribe_widget(&stack, move |_, event| match event {
            AppEvent::LibraryReloaded | AppEvent::NaturalEnd(_) | AppEvent::TrackChanged(_) => {
                if stack_ref.is_mapped() {
                    rebuild();
                } else {
                    dirty.set(true);
                }
            }
            _ => {}
        });
    }
    {
        let rebuild = Rc::clone(&rebuild);
        stack.connect_map(move |_| {
            if dirty.replace(false) {
                rebuild();
            }
        });
    }

    stack.upcast()
}

fn format_count(value: i64) -> String {
    if value >= 10_000 {
        format!("{:.1}k", value as f64 / 1000.0)
    } else {
        value.to_string()
    }
}

fn stat_tile(value: &str, caption: &str) -> gtk::Widget {
    let tile = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .build();
    tile.add_css_class("stat-tile");
    let value_label = gtk::Label::builder().label(value).xalign(0.0).build();
    value_label.add_css_class("stat-value");
    tile.append(&value_label);
    let caption_label = gtk::Label::builder().label(caption).xalign(0.0).build();
    caption_label.add_css_class("stat-caption");
    tile.append(&caption_label);
    tile.upcast()
}

fn section_title(text: &str) -> gtk::Widget {
    let label = gtk::Label::builder().label(text).xalign(0.0).build();
    label.add_css_class("stat-caption");
    label.upcast()
}

fn top_list(title: &str, rows: &[(String, i64)]) -> gtk::Widget {
    let column = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .build();
    column.append(&section_title(title));
    for (index, (name, count)) in rows.iter().enumerate() {
        let row = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(10)
            .build();
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
        column.append(&row);
    }
    column.upcast()
}

/// Port of the iOS ListeningClockView radial-spoke drawing: 24 spokes starting
/// at −π/2, base track spokes at 8% white width 3, data spokes tinted with
/// alpha .45+.55×fraction width 5, tip radius proportional between inner
/// (0.42×outer) and outer, peak hour label centered.
fn draw_listening_clock(cr: &gtk::cairo::Context, width: f64, height: f64, buckets: &[i64; 24]) {
    let center_x = width / 2.0;
    let center_y = height / 2.0;
    let outer = (width.min(height)) / 2.0 - 6.0;
    let inner = outer * 0.42;
    let max_count = buckets.iter().copied().max().unwrap_or(0).max(1) as f64;

    cr.set_line_cap(gtk::cairo::LineCap::Round);
    for hour in 0..24 {
        let angle = hour as f64 / 24.0 * std::f64::consts::TAU - std::f64::consts::FRAC_PI_2;
        let fraction = buckets[hour] as f64 / max_count;
        let start = (
            center_x + angle.cos() * inner,
            center_y + angle.sin() * inner,
        );
        let track_end = (
            center_x + angle.cos() * outer,
            center_y + angle.sin() * outer,
        );
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.08);
        cr.set_line_width(3.0);
        cr.move_to(start.0, start.1);
        cr.line_to(track_end.0, track_end.1);
        let _ = cr.stroke();

        if buckets[hour] > 0 {
            let tip = inner + (outer - inner) * fraction;
            let end = (center_x + angle.cos() * tip, center_y + angle.sin() * tip);
            cr.set_source_rgba(
                CLOCK_TINT.0,
                CLOCK_TINT.1,
                CLOCK_TINT.2,
                0.45 + 0.55 * fraction,
            );
            cr.set_line_width(5.0);
            cr.move_to(start.0, start.1);
            cr.line_to(end.0, end.1);
            let _ = cr.stroke();
        }
    }

    let total: i64 = buckets.iter().sum();
    if total == 0 {
        return;
    }
    let peak = buckets
        .iter()
        .enumerate()
        .max_by_key(|(_, count)| **count)
        .map(|(hour, _)| hour)
        .unwrap_or(0);

    cr.select_font_face(
        "Cantarell",
        gtk::cairo::FontSlant::Normal,
        gtk::cairo::FontWeight::Bold,
    );
    cr.set_font_size(24.0);
    cr.set_source_rgba(1.0, 1.0, 1.0, 1.0);
    let text = format!("{:02}:00", peak);
    if let Ok(extents) = cr.text_extents(&text) {
        cr.move_to(center_x - extents.width() / 2.0, center_y + 4.0);
        let _ = cr.show_text(&text);
    }
    cr.set_font_size(10.0);
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.5);
    if let Ok(extents) = cr.text_extents("PEAK") {
        cr.move_to(center_x - extents.width() / 2.0, center_y + 22.0);
        let _ = cr.show_text("PEAK");
    }
}
