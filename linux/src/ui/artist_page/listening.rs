//! "You & the artist": the person's own history with them, which no streaming
//! service's artist page can show from a local library: how often, for how
//! long, where they rank, how much of the catalogue has been heard, and a bar
//! per year from the first play to now, quiet years and all.

use crate::library::{format_last_played, Track};
use crate::recap::MIN_DATED_UNIX;
use adw::prelude::*;
use flaccy_library::artist_listening::ArtistListening;
use flaccy_library::listen_history::title_key;
use flaccy_shared::load_progress::group_digits;
use gtk::pango;
use std::cell::Cell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// Seconds a play stored without a length counts for when the library has no
/// copy of the song to measure.
const FALLBACK_PLAY_SECONDS: i64 = 210;
const CHART_HEIGHT: i32 = 150;
const MAX_BAR_WIDTH: f64 = 44.0;
const BAR_GAP: f64 = 5.0;
const RISE_MS: u32 = 700;
/// Below this width the stats sit above the timeline instead of beside it.
const SIDE_BY_SIDE_WIDTH: i32 = 860;

/// What the card states, worked out from the history and the songs the
/// library owns by the artist.
#[derive(Debug, PartialEq)]
pub struct ListeningFacts {
    pub plays: i64,
    pub seconds: i64,
    pub rank: Option<usize>,
    pub heard: usize,
    pub owned: usize,
}

pub fn facts(listening: &ArtistListening, owned: &[Track]) -> ListeningFacts {
    let lengths: HashMap<String, i64> = owned
        .iter()
        .map(|track| (title_key(&track.title), track.duration.round() as i64))
        .collect();
    let seconds = listening
        .songs
        .iter()
        .map(|song| {
            let length = lengths
                .get(&song.title_key)
                .copied()
                .filter(|seconds| *seconds > 0)
                .unwrap_or(FALLBACK_PLAY_SECONDS);
            song.measured_seconds + song.unmeasured_plays * length
        })
        .sum();
    let played: HashSet<&str> = listening.songs.iter().map(|song| song.title_key.as_str()).collect();
    let owned_keys: HashSet<String> = lengths.into_keys().collect();
    let heard = owned_keys.iter().filter(|key| played.contains(key.as_str())).count();
    ListeningFacts {
        plays: listening.plays,
        seconds,
        rank: listening.rank,
        heard,
        owned: owned_keys.len(),
    }
}

/// "512 hr" past an hour, otherwise minutes.
pub fn listened_text(seconds: i64) -> String {
    let hours = seconds / 3600;
    if hours >= 1 {
        format!("{} hr", group_digits(hours as usize))
    } else {
        format!("{} min", (seconds / 60).max(1))
    }
}

/// The hero's line about the person and the artist, `None` before any play.
pub fn hero_line(listening: &ArtistListening) -> Option<String> {
    if listening.plays <= 0 {
        return None;
    }
    let plays = plays_text(listening.plays);
    Some(match listening.rank {
        Some(1) => format!("Your most played artist  ·  {plays}"),
        Some(rank) if rank <= 100 => format!("Your #{rank} artist  ·  {plays}"),
        _ => plays,
    })
}

pub fn plays_text(plays: i64) -> String {
    match plays {
        1 => "1 play".to_string(),
        plays => format!("{} plays", group_digits(plays.max(0) as usize)),
    }
}

/// The owned songs the history has no play of, in album order, each once.
pub fn unheard(listening: &ArtistListening, owned: &[Track]) -> Vec<Track> {
    let played: HashSet<&str> = listening.songs.iter().map(|song| song.title_key.as_str()).collect();
    let mut seen = HashSet::new();
    owned
        .iter()
        .filter(|track| {
            let key = title_key(&track.title);
            !played.contains(key.as_str()) && seen.insert(key)
        })
        .cloned()
        .collect()
}

pub fn card(
    ui: &Rc<crate::ui::Ui>,
    artist: &str,
    listening: &ArtistListening,
    owned: &[Track],
) -> Option<gtk::Widget> {
    if listening.plays <= 0 {
        return None;
    }
    let facts = facts(listening, owned);
    let card = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .build();
    card.add_css_class("artist-card");
    card.add_css_class("artist-listening");

    let heading_row = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    let heading = gtk::Label::builder()
        .label(format!("You & {artist}"))
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(pango::EllipsizeMode::End)
        .build();
    heading.add_css_class("title-2");
    heading.add_css_class("artist-section-title");
    heading_row.append(&heading);
    if let Some(last) = listening.last_unix {
        let now = chrono::Utc::now().timestamp();
        let last_label = gtk::Label::new(Some(&format!(
            "Last played {}",
            lowercase_relative(&format_last_played(last, now))
        )));
        last_label.add_css_class("dim");
        last_label.add_css_class("caption");
        last_label.set_valign(gtk::Align::Center);
        heading_row.append(&last_label);
    }
    card.append(&heading_row);

    let body = gtk::Box::new(gtk::Orientation::Horizontal, 36);
    let stats = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(18)
        .valign(gtk::Align::Center)
        .build();
    stats.append(&stats_grid(&facts));
    let unheard = unheard(listening, owned);
    if !unheard.is_empty() {
        stats.append(&unheard_button(ui, unheard));
    }
    body.append(&stats);
    let timeline = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(10)
        .hexpand(true)
        .valign(gtk::Align::End)
        .build();
    if !listening.years.is_empty() {
        timeline.append(&year_chart(listening));
    }
    if let Some(story) = story_line(listening) {
        let label = gtk::Label::builder()
            .label(story)
            .xalign(0.0)
            .wrap(true)
            .build();
        label.add_css_class("dim");
        label.add_css_class("caption");
        timeline.append(&label);
    }
    body.append(&timeline);
    {
        let body_weak = body.downgrade();
        crate::ui::resize::watch_width(&card, move |width, _| {
            let Some(body) = body_weak.upgrade() else { return };
            let orientation = if width >= SIDE_BY_SIDE_WIDTH {
                gtk::Orientation::Horizontal
            } else {
                gtk::Orientation::Vertical
            };
            if body.orientation() != orientation {
                body.set_orientation(orientation);
                body.set_spacing(if orientation == gtk::Orientation::Horizontal { 36 } else { 20 });
            }
        });
    }
    card.append(&body);
    Some(card.upcast())
}

/// Plays the artist's songs the person has never played, the deep cuts the
/// "songs heard" figure counts.
fn unheard_button(ui: &Rc<crate::ui::Ui>, songs: Vec<Track>) -> gtk::Button {
    let label = match songs.len() {
        1 => "Play the 1 Unheard Song".to_string(),
        count => format!("Play {} Unheard Songs", group_digits(count)),
    };
    let content = gtk::Box::new(gtk::Orientation::Horizontal, 8);
    content.append(&gtk::Image::from_icon_name("media-playback-start-symbolic"));
    content.append(&gtk::Label::new(Some(&label)));
    let button = gtk::Button::builder().child(&content).halign(gtk::Align::Start).build();
    button.add_css_class("pill");
    button.add_css_class("artist-unheard");
    button.set_tooltip_text(Some("Songs you own by this artist that you have never played"));
    let ui = Rc::clone(ui);
    button.connect_clicked(move |_| ui.core.play_tracks(songs.clone(), 0));
    button
}

fn lowercase_relative(text: &str) -> String {
    match text {
        "Today" => "today".to_string(),
        "Yesterday" => "yesterday".to_string(),
        other if other.ends_with(" ago") => other.to_string(),
        other => format!("on {other}"),
    }
}

/// "First played Enter Sandman in March 2008 · Peak year 2016 with 2,140 plays".
fn story_line(listening: &ArtistListening) -> Option<String> {
    let mut parts = Vec::new();
    if let Some((at, title)) = listening.first.as_ref().filter(|(at, _)| *at >= MIN_DATED_UNIX) {
        use chrono::TimeZone;
        if let Some(when) = chrono::Local.timestamp_opt(*at, 0).single() {
            parts.push(format!("First played “{title}” in {}", when.format("%B %Y")));
        }
    }
    if listening.years.len() > 1 {
        if let Some((year, plays)) = listening.peak_year() {
            parts.push(format!("Peak year {year} with {}", plays_text(plays)));
        }
    }
    (!parts.is_empty()).then(|| parts.join("  ·  "))
}

fn stats_grid(facts: &ListeningFacts) -> gtk::Grid {
    let grid = gtk::Grid::builder()
        .column_spacing(36)
        .row_spacing(18)
        .valign(gtk::Align::Center)
        .build();
    let mut tiles: Vec<(String, &str)> = vec![
        (group_digits(facts.plays.max(0) as usize), "PLAYS"),
        (listened_text(facts.seconds), "LISTENED"),
    ];
    if let Some(rank) = facts.rank {
        tiles.push((format!("#{}", group_digits(rank)), "OF YOUR ARTISTS"));
    }
    if facts.owned > 0 {
        tiles.push((
            format!("{} / {}", group_digits(facts.heard), group_digits(facts.owned)),
            "OF THEIR SONGS HEARD",
        ));
    }
    for (index, (value, caption)) in tiles.iter().enumerate() {
        let tile = gtk::Box::new(gtk::Orientation::Vertical, 2);
        let value_label = gtk::Label::builder().label(value.as_str()).xalign(0.0).build();
        value_label.add_css_class("artist-stat-value");
        let caption_label = gtk::Label::builder().label(*caption).xalign(0.0).build();
        caption_label.add_css_class("stat-caption");
        tile.append(&value_label);
        tile.append(&caption_label);
        grid.attach(&tile, (index % 2) as i32, (index / 2) as i32, 1, 1);
    }
    grid
}

struct Chart {
    years: Vec<(i32, i64)>,
    peak: Option<i32>,
    hovered: Cell<Option<usize>>,
    rise: Cell<f64>,
}

/// One bar per year; the peak year in the accent, the rest softer. Hovering a
/// bar names its year and plays. The bars rise once when the card first shows.
fn year_chart(listening: &ArtistListening) -> gtk::DrawingArea {
    let chart = Rc::new(Chart {
        years: listening.years.clone(),
        peak: listening.peak_year().map(|(year, _)| year),
        hovered: Cell::new(None),
        rise: Cell::new(1.0),
    });
    let area = gtk::DrawingArea::builder()
        .content_height((CHART_HEIGHT as f64 * crate::ui::ui_scale::current()).round() as i32)
        .hexpand(true)
        .has_tooltip(true)
        .build();
    area.add_css_class("artist-year-chart");
    if let (Some((first, _)), Some((last, _))) = (chart.years.first(), chart.years.last()) {
        let summary = match listening.peak_year() {
            Some((peak, plays)) => format!(
                "Plays per year from {first} to {last}; the most in {peak}, {}",
                plays_text(plays)
            ),
            None => format!("Plays per year from {first} to {last}"),
        };
        area.update_property(&[gtk::accessible::Property::Label(&summary)]);
    }
    {
        let chart = Rc::clone(&chart);
        area.set_draw_func(move |area, cr, width, height| {
            draw_chart(area, cr, width as f64, height as f64, &chart);
        });
    }
    {
        let motion = gtk::EventControllerMotion::new();
        let enter_chart = Rc::clone(&chart);
        let enter_area = area.downgrade();
        let track = move |x: f64| {
            let Some(area) = enter_area.upgrade() else { return };
            let hovered = bar_at(x, area.width() as f64, enter_chart.years.len());
            if hovered != enter_chart.hovered.get() {
                enter_chart.hovered.set(hovered);
                area.queue_draw();
            }
        };
        let track = Rc::new(track);
        {
            let track = Rc::clone(&track);
            motion.connect_enter(move |_, x, _| track(x));
        }
        motion.connect_motion(move |_, x, _| track(x));
        let leave_chart = Rc::clone(&chart);
        let leave_area = area.downgrade();
        motion.connect_leave(move |_| {
            leave_chart.hovered.set(None);
            if let Some(area) = leave_area.upgrade() {
                area.queue_draw();
            }
        });
        area.add_controller(motion);
    }
    {
        let chart = Rc::clone(&chart);
        area.connect_query_tooltip(move |area, x, _, _, tooltip| {
            let Some(index) = bar_at(x as f64, area.width() as f64, chart.years.len()) else {
                return false;
            };
            let (year, plays) = chart.years[index];
            tooltip.set_text(Some(&format!("{year}  ·  {}", plays_text(plays))));
            true
        });
    }
    {
        let weak = area.downgrade();
        let handler = adw::StyleManager::default().connect_dark_notify(move |_| {
            if let Some(area) = weak.upgrade() {
                area.queue_draw();
            }
        });
        let handler = std::cell::RefCell::new(Some(handler));
        area.connect_destroy(move |_| {
            if let Some(handler) = handler.borrow_mut().take() {
                adw::StyleManager::default().disconnect(handler);
            }
        });
    }
    if crate::ui::controls::animations_enabled() {
        chart.rise.set(0.0);
        let chart = Rc::clone(&chart);
        let started = Cell::new(false);
        area.connect_map(move |area| {
            if started.replace(true) {
                return;
            }
            let chart = Rc::clone(&chart);
            let weak = area.downgrade();
            let target = adw::CallbackAnimationTarget::new(move |value| {
                chart.rise.set(value);
                if let Some(area) = weak.upgrade() {
                    area.queue_draw();
                }
            });
            let animation = adw::TimedAnimation::new(area, 0.0, 1.0, RISE_MS, target);
            animation.set_easing(adw::Easing::EaseOutCubic);
            animation.play();
        });
    }
    area
}

/// The span of each bar: `(x, width)` for `count` bars across `width`,
/// centred when the bars hit their widest.
fn bar_layout(width: f64, count: usize) -> (f64, f64) {
    if count == 0 {
        return (0.0, 0.0);
    }
    let gaps = BAR_GAP * (count.saturating_sub(1)) as f64;
    let bar = ((width - gaps) / count as f64).clamp(2.0, MAX_BAR_WIDTH);
    let used = bar * count as f64 + gaps;
    (((width - used) / 2.0).max(0.0), bar)
}

fn bar_at(x: f64, width: f64, count: usize) -> Option<usize> {
    let (start, bar) = bar_layout(width, count);
    if count == 0 || x < start {
        return None;
    }
    let index = ((x - start) / (bar + BAR_GAP)).floor() as usize;
    (index < count).then_some(index)
}

fn draw_chart(area: &gtk::DrawingArea, cr: &gtk::cairo::Context, width: f64, height: f64, chart: &Chart) {
    let count = chart.years.len();
    let layout = pangocairo::functions::create_layout(cr);
    let mut font = area.pango_context().font_description().unwrap_or_default();
    font.set_size((font.size() as f64 * 0.82) as i32);
    layout.set_font_description(Some(&font));
    layout.set_text("2026");
    let text_height = layout.pixel_size().1 as f64;
    let max = chart.years.iter().map(|(_, plays)| *plays).max().unwrap_or(0).max(1) as f64;
    let (start, bar) = bar_layout(width, count);
    let plot_top = text_height + 4.0;
    let plot_height = (height - (text_height + 8.0) - plot_top).max(1.0);
    let baseline = plot_top + plot_height;
    let (ar, ag, ab) = crate::theme::accent_tint();
    let fg = area.color();
    let (fr, fg_, fb) = (fg.red() as f64, fg.green() as f64, fg.blue() as f64);
    let rise = chart.rise.get();
    let hovered = chart.hovered.get();

    cr.set_source_rgba(fr, fg_, fb, 0.12);
    cr.rectangle(0.0, baseline + 0.5, width, 1.0);
    let _ = cr.fill();

    for (index, (year, plays)) in chart.years.iter().enumerate() {
        let x = start + index as f64 * (bar + BAR_GAP);
        if *plays <= 0 {
            continue;
        }
        let full = (*plays as f64 / max * plot_height).max(3.0);
        let h = full * rise;
        let emphasis = if Some(index) == hovered {
            1.0
        } else if Some(*year) == chart.peak {
            0.95
        } else if hovered.is_some() {
            0.32
        } else {
            0.5
        };
        cr.set_source_rgba(ar, ag, ab, emphasis);
        rounded_top_bar(cr, x, baseline - h, bar, h);
        let _ = cr.fill();
    }

    let mut taken: Vec<(f64, f64)> = Vec::new();
    let mut labelled: Vec<usize> = Vec::new();
    if let Some(index) = hovered {
        labelled.push(index);
    }
    if let Some(peak) = chart.peak.and_then(|peak| chart.years.iter().position(|(y, _)| *y == peak)) {
        labelled.push(peak);
    }
    labelled.push(0);
    labelled.push(count.saturating_sub(1));
    for index in labelled {
        let (year, _) = chart.years[index];
        layout.set_text(&year.to_string());
        let (text_w, _) = layout.pixel_size();
        let center = start + index as f64 * (bar + BAR_GAP) + bar / 2.0;
        let left = (center - text_w as f64 / 2.0).clamp(0.0, (width - text_w as f64).max(0.0));
        let span = (left - 6.0, left + text_w as f64 + 6.0);
        if taken.iter().any(|(a, b)| span.0 < *b && *a < span.1) {
            continue;
        }
        taken.push(span);
        let strong = Some(index) == hovered || Some(year) == chart.peak;
        cr.set_source_rgba(fr, fg_, fb, if strong { 0.9 } else { 0.5 });
        cr.move_to(left, baseline + 6.0);
        pangocairo::functions::show_layout(cr, &layout);
    }

    if let Some(index) = hovered.or_else(|| chart.peak.and_then(|peak| chart.years.iter().position(|(y, _)| *y == peak))) {
        let (_, plays) = chart.years[index];
        if plays > 0 && rise >= 0.999 {
            layout.set_text(&group_digits(plays as usize));
            let (text_w, text_h) = layout.pixel_size();
            let full = (plays as f64 / max * plot_height).max(3.0);
            let center = start + index as f64 * (bar + BAR_GAP) + bar / 2.0;
            let left = (center - text_w as f64 / 2.0).clamp(0.0, (width - text_w as f64).max(0.0));
            cr.set_source_rgba(fr, fg_, fb, 0.85);
            cr.move_to(left, (baseline - full - text_h as f64 - 3.0).max(0.0));
            pangocairo::functions::show_layout(cr, &layout);
        }
    }
}

fn rounded_top_bar(cr: &gtk::cairo::Context, x: f64, y: f64, width: f64, height: f64) {
    let radius = (width / 2.0).min(5.0).min(height);
    cr.new_sub_path();
    cr.move_to(x, y + height);
    cr.line_to(x, y + radius);
    cr.arc(x + radius, y + radius, radius, std::f64::consts::PI, 1.5 * std::f64::consts::PI);
    cr.line_to(x + width - radius, y);
    cr.arc(x + width - radius, y + radius, radius, 1.5 * std::f64::consts::PI, 0.0);
    cr.line_to(x + width, y + height);
    cr.close_path();
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_library::artist_listening::SongPlays;

    fn track(title: &str, duration: f64) -> Track {
        Track {
            id: 0,
            rel_path: format!("Artist/{title}.flac"),
            title: title.to_string(),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            album_artist: None,
            track_number: 1,
            duration,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            loved: false,
            play_count: 0,
            date_added: 0,
            last_played: None,
            revision: 1,
            revised_at: None,
            file_modified_ms: None,
            disc_number: None,
        }
    }

    fn song(title: &str, plays: i64, measured: i64, unmeasured: i64) -> SongPlays {
        SongPlays {
            title_key: title_key(title),
            title: title.to_string(),
            plays,
            measured_seconds: measured,
            unmeasured_plays: unmeasured,
        }
    }

    #[test]
    fn listening_time_measures_unmeasured_plays_with_the_library_copy() {
        let listening = ArtistListening {
            plays: 6,
            songs: vec![song("One", 4, 800, 2), song("Unowned", 2, 0, 2)],
            rank: Some(3),
            ..ArtistListening::default()
        };
        let owned = vec![track("One", 300.0), track("Two", 200.0), track("Three", 100.0)];
        let facts = facts(&listening, &owned);
        assert_eq!(facts.seconds, 800 + 2 * 300 + 2 * FALLBACK_PLAY_SECONDS);
        assert_eq!((facts.heard, facts.owned), (1, 3));
        assert_eq!(facts.rank, Some(3));
    }

    #[test]
    fn unheard_songs_are_the_owned_ones_without_a_play() {
        let listening = ArtistListening {
            plays: 3,
            songs: vec![song("One", 3, 0, 3)],
            ..ArtistListening::default()
        };
        let owned = vec![
            track("One", 300.0),
            track("Two", 200.0),
            track("One (Live)", 310.0),
            track("Two", 205.0),
        ];
        let titles: Vec<String> = unheard(&listening, &owned).into_iter().map(|t| t.title).collect();
        assert_eq!(titles, vec!["Two".to_string(), "One (Live)".to_string()]);
    }

    #[test]
    fn the_hero_line_names_the_rank_only_near_the_top() {
        let mut listening = ArtistListening {
            plays: 8719,
            rank: Some(2),
            ..ArtistListening::default()
        };
        assert_eq!(hero_line(&listening).as_deref(), Some("Your #2 artist  ·  8\u{202f}719 plays"));
        listening.rank = Some(1);
        assert_eq!(hero_line(&listening).as_deref(), Some("Your most played artist  ·  8\u{202f}719 plays"));
        listening.rank = Some(450);
        listening.plays = 1;
        assert_eq!(hero_line(&listening).as_deref(), Some("1 play"));
        listening.plays = 0;
        assert_eq!(hero_line(&listening), None);
    }

    #[test]
    fn listened_time_reads_in_hours_past_one() {
        assert_eq!(listened_text(59), "1 min");
        assert_eq!(listened_text(45 * 60), "45 min");
        assert_eq!(listened_text(1_843_200), "512 hr");
        assert_eq!(listened_text(3600 * 12_345), "12\u{202f}345 hr");
    }

    #[test]
    fn bars_split_the_width_and_hit_tests_find_them() {
        let (start, bar) = bar_layout(100.0, 4);
        assert_eq!(start, 0.0);
        assert!((bar - 21.25).abs() < 1e-9);
        assert_eq!(bar_at(0.0, 100.0, 4), Some(0));
        assert_eq!(bar_at(99.0, 100.0, 4), Some(3));
        let (start, bar) = bar_layout(1000.0, 2);
        assert_eq!(bar, MAX_BAR_WIDTH);
        assert!(start > 0.0);
        assert_eq!(bar_at(1.0, 1000.0, 2), None);
        assert_eq!(bar_at(10.0, 100.0, 0), None);
    }
}
