use crate::db::{Db, ScrobbleRow};
use crate::events::AppEvent;
use crate::recap::{self, Period, RecapData};
use crate::ui::Ui;
use adw::prelude::*;
use chrono::Datelike;
use gtk::glib;
use gtk::pango;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

const TINT_DARK: (f64, f64, f64) = (0.45, 0.78, 1.0);
const TINT_LIGHT: (f64, f64, f64) = (0.08, 0.42, 0.75);
const HEATMAP_CELL: f64 = 13.0;
const HEATMAP_GAP: f64 = 3.0;
const HEATMAP_TOP: f64 = 18.0;

struct StatsState {
    period: Cell<Period>,
    data: RefCell<Option<Rc<RecapData>>>,
    loading: Cell<bool>,
    reload_wanted: Cell<bool>,
}

pub fn build(ui: &Rc<Ui>) -> gtk::Widget {
    let state = Rc::new(StatsState {
        period: Cell::new(Period::AllTime),
        data: RefCell::new(None),
        loading: Cell::new(false),
        reload_wanted: Cell::new(false),
    });

    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(24)
        .margin_top(28)
        .margin_bottom(28)
        .margin_start(28)
        .margin_end(28)
        .build();

    let empty = adw::StatusPage::builder()
        .icon_name("utilities-system-monitor-symbolic")
        .title("No Listening History")
        .description("Play some music and your stats will build up here — or import your Last.fm history.")
        .build();
    if crate::lastfm::keys_available() {
        let import_button = gtk::Button::with_label("Import Last.fm History");
        import_button.add_css_class("pill");
        import_button.add_css_class("suggested-action");
        import_button.set_halign(gtk::Align::Center);
        {
            let ui = Rc::clone(ui);
            import_button.connect_clicked(move |_| crate::importer::start(&ui.core));
        }
        empty.set_child(Some(&import_button));
    }

    let scroll = gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .child(&adw::Clamp::builder().maximum_size(980).child(&content).build())
        .build();

    let stack = gtk::Stack::new();
    stack.add_named(&empty, Some("empty"));
    stack.add_named(&scroll, Some("stats"));

    let loader: Rc<RefCell<Option<Action>>> = Rc::new(RefCell::new(None));
    let render = build_renderer(ui, &state, &loader, &content, &stack);
    let reload = build_loader(ui, &state, &render);
    *loader.borrow_mut() = Some(Rc::clone(&reload));
    reload();

    let dirty = Rc::new(Cell::new(false));
    {
        let reload = Rc::clone(&reload);
        let dirty = Rc::clone(&dirty);
        let stack_ref = stack.clone();
        ui.core.hub.subscribe_widget(&stack, move |_, event| match event {
            AppEvent::NaturalEnd(_) | AppEvent::LibraryReloaded => {
                if stack_ref.is_mapped() {
                    reload();
                } else {
                    dirty.set(true);
                }
            }
            AppEvent::HistoryImport { done, .. } => {
                if *done && stack_ref.is_mapped() {
                    reload();
                } else if *done {
                    dirty.set(true);
                }
            }
            _ => {}
        });
    }
    {
        let reload = Rc::clone(&reload);
        stack.connect_map(move |_| {
            if dirty.replace(false) {
                reload();
            }
        });
    }

    stack.upcast()
}

type Action = Rc<dyn Fn()>;

/// Loads scrobble rows off the GTK main loop, computes the recap for the
/// selected period on the worker thread, and hands the result to the renderer.
fn build_loader(ui: &Rc<Ui>, state: &Rc<StatsState>, render: &Action) -> Action {
    let ui = Rc::clone(ui);
    let state = Rc::clone(state);
    let render = Rc::clone(render);
    Rc::new(move || {
        if state.loading.get() {
            state.reload_wanted.set(true);
            return;
        }
        state.loading.set(true);
        let db_path = ui.core.db_path.clone();
        let period = state.period.get();
        let (tx, rx) = async_channel::bounded::<Option<RecapData>>(1);
        std::thread::Builder::new()
            .name("flaccy-stats".into())
            .spawn(move || {
                let data = Db::open(&db_path).ok().map(|db| {
                    let rows: Vec<ScrobbleRow> = db.fetch_all_scrobble_rows();
                    recap::compute(&rows, period, chrono::Utc::now().timestamp())
                });
                let _ = tx.send_blocking(data);
            })
            .ok();
        let state = Rc::clone(&state);
        let render = Rc::clone(&render);
        glib::spawn_future_local(async move {
            let data = rx.recv().await.ok().flatten();
            state.loading.set(false);
            *state.data.borrow_mut() = data.map(Rc::new);
            state.reload_wanted.set(false);
            render();
        });
    })
}

fn build_renderer(
    ui: &Rc<Ui>,
    state: &Rc<StatsState>,
    loader: &Rc<RefCell<Option<Action>>>,
    content: &gtk::Box,
    stack: &gtk::Stack,
) -> Action {
    let ui = Rc::clone(ui);
    let state = Rc::clone(state);
    let loader = Rc::clone(loader);
    let content = content.clone();
    let stack = stack.clone();
    let render: Action = Rc::new(move || {
        while let Some(child) = content.first_child() {
            content.remove(&child);
        }
        let Some(data) = state.data.borrow().clone() else {
            stack.set_visible_child_name("empty");
            return;
        };
        let all_time_empty = state.period.get() == Period::AllTime && data.total_plays == 0;
        if all_time_empty {
            stack.set_visible_child_name("empty");
            return;
        }
        stack.set_visible_child_name("stats");

        content.append(&period_picker(&state, &loader));
        let _ = &ui;
        content.append(&tiles_row(&data));
        content.append(&import_row(&ui));

        content.append(&section_title("STREAKS"));
        content.append(&heatmap_widget(&data));

        content.append(&section_title("LISTENING CLOCK"));
        content.append(&clock_widget(&data));

        let lists = gtk::Box::builder()
            .orientation(gtk::Orientation::Horizontal)
            .spacing(24)
            .homogeneous(true)
            .valign(gtk::Align::Start)
            .build();
        lists.append(&top_list("TOP ARTISTS", &data.top_artists));
        lists.append(&top_list("TOP ALBUMS", &data.top_albums));
        lists.append(&top_list("TOP TRACKS", &data.top_tracks));
        content.append(&lists);
    });
    render
}

fn period_picker(state: &Rc<StatsState>, loader: &Rc<RefCell<Option<Action>>>) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(6)
        .halign(gtk::Align::Start)
        .build();
    row.add_css_class("linked");
    for period in recap::ALL_PERIODS {
        let button = gtk::ToggleButton::with_label(period.label());
        button.set_active(state.period.get() == period);
        let state = Rc::clone(state);
        let loader = Rc::clone(loader);
        button.connect_clicked(move |button| {
            if state.period.get() == period {
                button.set_active(true);
                return;
            }
            state.period.set(period);
            crate::logger::info("ui", &format!("stats period: {}", period.label()));
            if let Some(reload) = loader.borrow().clone() {
                reload();
            }
        });
        row.append(&button);
    }
    row.upcast()
}

fn tiles_row(data: &RecapData) -> gtk::Widget {
    let tiles = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(14)
        .homogeneous(true)
        .build();
    tiles.append(&stat_tile(&format_count(data.total_plays), "PLAYS"));
    tiles.append(&stat_tile(&format_count(data.total_minutes), "MINUTES"));
    tiles.append(&stat_tile(&data.streak_days.to_string(), "DAY STREAK"));
    tiles.append(&stat_tile(data.persona, "PERSONA"));
    tiles.upcast()
}

fn import_row(ui: &Rc<Ui>) -> gtk::Widget {
    let row = gtk::Box::builder()
        .orientation(gtk::Orientation::Horizontal)
        .spacing(12)
        .build();
    if !crate::lastfm::keys_available() || ui.core.session.borrow().is_none() {
        return row.upcast();
    }
    let button = gtk::Button::with_label("Import Last.fm History");
    button.add_css_class("pill");
    let progress = gtk::Label::builder().xalign(0.0).build();
    progress.add_css_class("dim");
    progress.add_css_class("caption");
    progress.set_valign(gtk::Align::Center);
    {
        let ui = Rc::clone(ui);
        let progress = progress.clone();
        button.connect_clicked(move |button| {
            button.set_sensitive(false);
            progress.set_label("Starting import…");
            crate::importer::start(&ui.core);
        });
    }
    {
        let button = button.clone();
        let progress_ref = progress.clone();
        ui.core.hub.subscribe_widget(&row, move |_, event| {
            if let AppEvent::HistoryImport {
                imported,
                page,
                total_pages,
                done,
            } = event
            {
                if *done {
                    button.set_sensitive(true);
                    progress_ref.set_label(&format!("Imported {imported} plays"));
                } else {
                    button.set_sensitive(false);
                    progress_ref.set_label(&format!(
                        "Importing… page {page} of {total_pages} · {imported} plays"
                    ));
                }
            }
        });
    }
    row.append(&button);
    row.append(&progress);
    row.upcast()
}

/// GitHub-style streak heatmap: 7 day rows × N week columns with month labels
/// and a hover tooltip showing the per-day play count.
fn heatmap_widget(data: &Rc<RecapData>) -> gtk::Widget {
    let now = chrono::Utc::now().timestamp();
    let Some(grid) = recap::heatmap_grid(&data.heatmap, now) else {
        let label = gtk::Label::builder()
            .label("No plays in this period yet.")
            .xalign(0.0)
            .build();
        label.add_css_class("dim");
        return label.upcast();
    };
    let grid = Rc::new(grid);
    let width = grid.weeks as f64 * (HEATMAP_CELL + HEATMAP_GAP) + 4.0;
    let height = HEATMAP_TOP + 7.0 * (HEATMAP_CELL + HEATMAP_GAP);

    let area = gtk::DrawingArea::builder()
        .content_width(width as i32)
        .content_height(height as i32)
        .halign(gtk::Align::Start)
        .build();
    let max_count = data.heatmap.values().copied().max().unwrap_or(1).max(1);
    {
        let data = Rc::clone(data);
        let grid = Rc::clone(&grid);
        area.set_draw_func(move |area, cr, _, _| {
            let fg = area.color();
            let (fg_r, fg_g, fg_b) = (fg.red() as f64, fg.green() as f64, fg.blue() as f64);
            let tint = if adw::StyleManager::default().is_dark() {
                TINT_DARK
            } else {
                TINT_LIGHT
            };
            let today = chrono::Local::now().date_naive();
            cr.select_font_face(
                "Cantarell",
                gtk::cairo::FontSlant::Normal,
                gtk::cairo::FontWeight::Normal,
            );
            cr.set_font_size(10.0);
            let mut last_month = 0;
            for week in 0..grid.weeks {
                let week_start =
                    grid.start_sunday + chrono::Duration::days(week as i64 * 7);
                if week_start.month() != last_month {
                    last_month = week_start.month();
                    cr.set_source_rgba(fg_r, fg_g, fg_b, 0.5);
                    let x = week as f64 * (HEATMAP_CELL + HEATMAP_GAP);
                    cr.move_to(x, 11.0);
                    let _ = cr.show_text(month_label(last_month));
                }
                for day in 0..7 {
                    let date = week_start + chrono::Duration::days(day as i64);
                    if date > today {
                        continue;
                    }
                    let count = data.heatmap.get(&date).copied().unwrap_or(0);
                    let x = week as f64 * (HEATMAP_CELL + HEATMAP_GAP);
                    let y = HEATMAP_TOP + day as f64 * (HEATMAP_CELL + HEATMAP_GAP);
                    if count == 0 {
                        cr.set_source_rgba(fg_r, fg_g, fg_b, 0.06);
                    } else {
                        let fraction = count as f64 / max_count as f64;
                        cr.set_source_rgba(tint.0, tint.1, tint.2, 0.25 + 0.65 * fraction);
                    }
                    rounded_rect(cr, x, y, HEATMAP_CELL, HEATMAP_CELL, HEATMAP_CELL * 0.28);
                    let _ = cr.fill();
                }
            }
        });
    }
    {
        let weak = area.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(area) = weak.upgrade() {
                area.queue_draw();
            }
        });
    }
    area.set_has_tooltip(true);
    {
        let data = Rc::clone(data);
        let grid = Rc::clone(&grid);
        area.connect_query_tooltip(move |_, x, y, _, tooltip| {
            let week = (x as f64 / (HEATMAP_CELL + HEATMAP_GAP)).floor() as i64;
            let day = ((y as f64 - HEATMAP_TOP) / (HEATMAP_CELL + HEATMAP_GAP)).floor() as i64;
            if week < 0 || day < 0 || day > 6 || week >= grid.weeks as i64 {
                return false;
            }
            let date = grid.start_sunday + chrono::Duration::days(week * 7 + day);
            if date > chrono::Local::now().date_naive() {
                return false;
            }
            let count = data.heatmap.get(&date).copied().unwrap_or(0);
            tooltip.set_text(Some(&format!(
                "{} · {} play{}",
                date.format("%b %-d, %Y"),
                count,
                if count == 1 { "" } else { "s" }
            )));
            true
        });
    }

    let scroll = gtk::ScrolledWindow::builder()
        .vscrollbar_policy(gtk::PolicyType::Never)
        .hscrollbar_policy(gtk::PolicyType::Automatic)
        .min_content_height((height + 16.0) as i32)
        .child(&area)
        .build();
    {
        let hadj = scroll.hadjustment();
        glib::idle_add_local_once(move || {
            hadj.set_value(hadj.upper());
        });
    }
    scroll.upcast()
}

fn month_label(month: u32) -> &'static str {
    match month {
        1 => "Jan",
        2 => "Feb",
        3 => "Mar",
        4 => "Apr",
        5 => "May",
        6 => "Jun",
        7 => "Jul",
        8 => "Aug",
        9 => "Sep",
        10 => "Oct",
        11 => "Nov",
        _ => "Dec",
    }
}

fn rounded_rect(cr: &gtk::cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    use std::f64::consts::FRAC_PI_2;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, FRAC_PI_2, 2.0 * FRAC_PI_2);
    cr.arc(x + r, y + r, r, 2.0 * FRAC_PI_2, 3.0 * FRAC_PI_2);
    cr.close_path();
}

fn clock_widget(data: &Rc<RecapData>) -> gtk::Widget {
    let clock = gtk::DrawingArea::builder()
        .content_height(280)
        .hexpand(true)
        .build();
    let buckets = data.clock;
    clock.set_draw_func(move |area, cr, width, height| {
        draw_listening_clock(area, cr, width as f64, height as f64, &buckets);
    });
    {
        let weak = clock.downgrade();
        adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(clock) = weak.upgrade() {
                clock.queue_draw();
            }
        });
    }
    clock.upcast()
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
    let value_label = gtk::Label::builder()
        .label(value)
        .xalign(0.0)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
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
    if rows.is_empty() {
        let label = gtk::Label::builder().label("No plays yet").xalign(0.0).build();
        label.add_css_class("dim");
        column.append(&label);
    }
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

/// Port of the iOS ListeningClockView radial-spoke drawing.
fn draw_listening_clock(
    area: &gtk::DrawingArea,
    cr: &gtk::cairo::Context,
    width: f64,
    height: f64,
    buckets: &[i64; 24],
) {
    let fg = area.color();
    let (fg_r, fg_g, fg_b) = (fg.red() as f64, fg.green() as f64, fg.blue() as f64);
    let tint = if adw::StyleManager::default().is_dark() {
        TINT_DARK
    } else {
        TINT_LIGHT
    };
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
        cr.set_source_rgba(fg_r, fg_g, fg_b, 0.08);
        cr.set_line_width(3.0);
        cr.move_to(start.0, start.1);
        cr.line_to(track_end.0, track_end.1);
        let _ = cr.stroke();

        if buckets[hour] > 0 {
            let tip = inner + (outer - inner) * fraction;
            let end = (center_x + angle.cos() * tip, center_y + angle.sin() * tip);
            cr.set_source_rgba(tint.0, tint.1, tint.2, 0.45 + 0.55 * fraction);
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
    cr.set_source_rgba(fg_r, fg_g, fg_b, 1.0);
    let text = format!("{:02}:00", peak);
    if let Ok(extents) = cr.text_extents(&text) {
        cr.move_to(center_x - extents.width() / 2.0, center_y + 4.0);
        let _ = cr.show_text(&text);
    }
    cr.set_font_size(10.0);
    cr.set_source_rgba(fg_r, fg_g, fg_b, 0.5);
    if let Ok(extents) = cr.text_extents("PEAK") {
        cr.move_to(center_x - extents.width() / 2.0, center_y + 22.0);
        let _ = cr.show_text("PEAK");
    }
}
