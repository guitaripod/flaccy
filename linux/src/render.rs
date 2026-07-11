use crate::recap::{RecapData, YearData};
use gtk::cairo::{Context, Format, ImageSurface, LinearGradient};

const FONT: &str = "Cantarell";

pub struct Card {
    pub surface: ImageSurface,
}

impl Card {
    fn new(width: i32, height: i32) -> Option<(Self, Context)> {
        let surface = ImageSurface::create(Format::ARgb32, width, height).ok()?;
        let cr = Context::new(&surface).ok()?;
        Some((Self { surface }, cr))
    }

    pub fn png_bytes(&self) -> Option<Vec<u8>> {
        let mut bytes = Vec::new();
        self.surface.clone().write_to_png(&mut bytes).ok()?;
        Some(bytes)
    }
}

fn darken(color: (u8, u8, u8), factor: f64) -> (f64, f64, f64) {
    (
        color.0 as f64 / 255.0 * factor,
        color.1 as f64 / 255.0 * factor,
        color.2 as f64 / 255.0 * factor,
    )
}

/// Diagonal 3-stop gradient over black, matching the iOS share-card backdrop:
/// seed color darkened 0.55 → second color darkened 0.7 → black.
fn gradient_background(cr: &Context, width: f64, height: f64, seed: &str) {
    let (first, second) = crate::palette::placeholder_colors(seed);
    cr.set_source_rgb(0.0, 0.0, 0.0);
    cr.rectangle(0.0, 0.0, width, height);
    let _ = cr.fill();
    let gradient = LinearGradient::new(0.0, 0.0, width, height);
    let (r1, g1, b1) = darken(first, 0.55);
    let (r2, g2, b2) = darken(second, 0.7);
    gradient.add_color_stop_rgb(0.0, r1, g1, b1);
    gradient.add_color_stop_rgb(0.6, r2, g2, b2);
    gradient.add_color_stop_rgb(1.0, 0.02, 0.02, 0.03);
    let _ = cr.set_source(&gradient);
    cr.rectangle(0.0, 0.0, width, height);
    let _ = cr.fill();
}

fn set_font(cr: &Context, size: f64, bold: bool) {
    cr.select_font_face(
        FONT,
        gtk::cairo::FontSlant::Normal,
        if bold {
            gtk::cairo::FontWeight::Bold
        } else {
            gtk::cairo::FontWeight::Normal
        },
    );
    cr.set_font_size(size);
}

fn text(cr: &Context, x: f64, y: f64, value: &str) {
    cr.move_to(x, y);
    let _ = cr.show_text(value);
}

fn text_width(cr: &Context, value: &str) -> f64 {
    cr.text_extents(value).map(|e| e.width()).unwrap_or(0.0)
}

fn text_centered(cr: &Context, center_x: f64, y: f64, value: &str) {
    text(cr, center_x - text_width(cr, value) / 2.0, y, value);
}

fn rounded_rect(cr: &Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    use std::f64::consts::FRAC_PI_2;
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -FRAC_PI_2, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, FRAC_PI_2);
    cr.arc(x + r, y + h - r, r, FRAC_PI_2, 2.0 * FRAC_PI_2);
    cr.arc(x + r, y + r, r, 2.0 * FRAC_PI_2, 3.0 * FRAC_PI_2);
    cr.close_path();
}

fn persona_badge(cr: &Context, center_x: f64, y: f64, persona: &str) {
    set_font(cr, 34.0, true);
    let label = persona.to_uppercase();
    let width = text_width(cr, &label) + 88.0;
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.14);
    rounded_rect(cr, center_x - width / 2.0, y, width, 76.0, 38.0);
    let _ = cr.fill();
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.95);
    text_centered(cr, center_x, y + 50.0, &label);
}

fn stat_column(cr: &Context, center_x: f64, y: f64, value: &str, caption: &str) {
    cr.set_source_rgb(1.0, 1.0, 1.0);
    set_font(cr, 92.0, true);
    text_centered(cr, center_x, y, value);
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.55);
    set_font(cr, 28.0, true);
    text_centered(cr, center_x, y + 46.0, caption);
}

fn ranked_list(cr: &Context, x: f64, mut y: f64, width: f64, rows: &[(String, i64)]) -> f64 {
    for (index, (name, count)) in rows.iter().enumerate() {
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.4);
        set_font(cr, 34.0, true);
        text(cr, x, y, &format!("{}", index + 1));
        cr.set_source_rgb(1.0, 1.0, 1.0);
        set_font(cr, 36.0, true);
        let mut display = name.clone();
        while text_width(cr, &display) > width - 200.0 && display.chars().count() > 4 {
            display = display.chars().take(display.chars().count() - 2).collect::<String>();
            display.push('…');
        }
        text(cr, x + 56.0, y, &display);
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.5);
        set_font(cr, 30.0, false);
        let count_text = format!("{count}");
        text(cr, x + width - text_width(cr, &count_text), y, &count_text);
        y += 64.0;
    }
    y
}

fn format_count(value: i64) -> String {
    if value >= 100_000 {
        format!("{:.0}k", value as f64 / 1000.0)
    } else if value >= 10_000 {
        format!("{:.1}k", value as f64 / 1000.0)
    } else {
        value.to_string()
    }
}

fn footer(cr: &Context, width: f64, height: f64, label: &str) {
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.35);
    set_font(cr, 26.0, true);
    text_centered(cr, width / 2.0, height - 52.0, label);
}

/// 1080×1350 recap share card: period, plays/minutes, top-5 artists, persona
/// badge, flaccy footer over a palette gradient.
pub fn recap_share_card(data: &RecapData, period_name: &str, username: Option<&str>) -> Option<Card> {
    let (width, height) = (1080, 1350);
    let (card, cr) = Card::new(width, height)?;
    let (w, h) = (width as f64, height as f64);
    let seed = data
        .top_artists
        .first()
        .map(|(name, _)| name.as_str())
        .unwrap_or("flaccy-recap");
    gradient_background(&cr, w, h, seed);

    cr.set_source_rgb(1.0, 1.0, 1.0);
    set_font(&cr, 68.0, true);
    text_centered(&cr, w / 2.0, 150.0, username.unwrap_or("Your Recap"));
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.6);
    set_font(&cr, 32.0, true);
    text_centered(&cr, w / 2.0, 208.0, &format!("{period_name} · flaccy Recap"));

    stat_column(&cr, w * 0.3, 380.0, &format_count(data.total_plays), "PLAYS");
    stat_column(&cr, w * 0.7, 380.0, &format_count(data.total_minutes), "MINUTES");

    cr.set_source_rgba(1.0, 1.0, 1.0, 0.55);
    set_font(&cr, 28.0, true);
    text(&cr, 120.0, 560.0, "TOP ARTISTS");
    let top: Vec<(String, i64)> = data.top_artists.iter().take(5).cloned().collect();
    let end = ranked_list(&cr, 120.0, 624.0, w - 240.0, &top);

    persona_badge(&cr, w / 2.0, end + 60.0, data.persona);
    footer(&cr, w, h, "flaccy · Recap");
    Some(card)
}

/// Year in Music export. `story` renders 1080×1920 (9:16); otherwise 1080×1350
/// (4:5 post). Story-style editorial layout with the theme gradient.
pub fn year_in_music_card(data: &YearData, story: bool) -> Option<Card> {
    let (width, height) = if story { (1080, 1920) } else { (1080, 1350) };
    let (card, cr) = Card::new(width, height)?;
    let (w, h) = (width as f64, height as f64);
    let seed = format!("flaccy-yim-{}", data.year);
    gradient_background(&cr, w, h, &seed);

    cr.set_source_rgba(1.0, 1.0, 1.0, 0.6);
    set_font(&cr, 30.0, true);
    text(&cr, 96.0, 130.0, "FLACCY");
    let year_text = data.year.to_string();
    text(&cr, w - 96.0 - text_width(&cr, &year_text), 130.0, &year_text);

    cr.set_source_rgb(1.0, 1.0, 1.0);
    set_font(&cr, 96.0, true);
    text(&cr, 96.0, 280.0, "YEAR IN");
    text(&cr, 96.0, 380.0, "MUSIC");

    stat_column(&cr, w * 0.28, 540.0, &format_count(data.total_plays), "PLAYS");
    stat_column(&cr, w * 0.72, 540.0, &format_count(data.total_minutes), "MINUTES");

    cr.set_source_rgba(1.0, 1.0, 1.0, 0.7);
    set_font(&cr, 30.0, false);
    text_centered(
        &cr,
        w / 2.0,
        660.0,
        &format!(
            "{} artists · {} albums · {} tracks",
            data.distinct_artists, data.distinct_albums, data.distinct_tracks
        ),
    );

    cr.set_source_rgba(1.0, 1.0, 1.0, 0.55);
    set_font(&cr, 28.0, true);
    text(&cr, 96.0, 760.0, "TOP ARTISTS");
    let artists: Vec<(String, i64)> = data.top_artists.clone();
    let mut y = ranked_list(&cr, 96.0, 820.0, w - 192.0, &artists);

    if story {
        cr.set_source_rgba(1.0, 1.0, 1.0, 0.55);
        set_font(&cr, 28.0, true);
        y += 50.0;
        text(&cr, 96.0, y, "TOP TRACKS");
        let tracks: Vec<(String, i64)> = data
            .top_tracks
            .iter()
            .map(|(title, artist, count)| (format!("{title} — {artist}"), *count))
            .collect();
        y = ranked_list(&cr, 96.0, y + 60.0, w - 192.0, &tracks);
    }

    let mut facts: Vec<String> = Vec::new();
    if let Some(day) = data.peak_day {
        facts.push(format!(
            "Biggest day: {} · {} plays",
            day.format("%b %-d"),
            data.peak_day_plays
        ));
    }
    if let Some(hour) = data.peak_hour {
        facts.push(format!("Peak hour: {hour:02}:00"));
    }
    if data.longest_streak > 1 {
        facts.push(format!("Longest streak: {} days", data.longest_streak));
    }
    cr.set_source_rgba(1.0, 1.0, 1.0, 0.75);
    set_font(&cr, 30.0, false);
    y += 40.0;
    for fact in facts {
        text(&cr, 96.0, y, &fact);
        y += 52.0;
    }

    persona_badge(&cr, w / 2.0, (h - 210.0).max(y + 30.0), data.persona);
    footer(&cr, w, h, &format!("flaccy · Year in Music {}", data.year));
    Some(card)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn recap_fixture() -> RecapData {
        RecapData {
            total_plays: 1234,
            total_minutes: 5678,
            top_artists: vec![
                ("Meridian Wolde".to_string(), 210),
                ("Marisol Vane".to_string(), 180),
                ("Kestrel Vale".to_string(), 140),
                ("Juno Falls".to_string(), 90),
                ("Cassia Reef".to_string(), 60),
            ],
            top_albums: vec![("Parallax Hours — Meridian Wolde".to_string(), 88)],
            top_tracks: vec![("Slow Machine — Meridian Wolde".to_string(), 44)],
            clock: [3; 24],
            streak_days: 12,
            persona: "Devotee",
            heatmap: HashMap::new(),
        }
    }

    fn year_fixture() -> YearData {
        YearData {
            year: 2026,
            total_plays: 4321,
            total_minutes: 15678,
            distinct_artists: 87,
            distinct_albums: 130,
            distinct_tracks: 700,
            top_artists: vec![
                ("Meridian Wolde".to_string(), 300),
                ("Marisol Vane".to_string(), 250),
            ],
            top_albums: vec![("Parallax Hours".to_string(), "Meridian Wolde".to_string(), 120)],
            top_tracks: vec![("Slow Machine".to_string(), "Meridian Wolde".to_string(), 60)],
            peak_day: chrono::NaiveDate::from_ymd_opt(2026, 3, 14),
            peak_day_plays: 42,
            peak_hour: Some(21),
            longest_streak: 19,
            persona: "Night Owl",
        }
    }

    fn assert_not_blank(card: &Card, min_colors: usize) {
        let bytes = card.png_bytes().expect("png bytes");
        assert!(bytes.len() > 10_000, "png suspiciously small: {} bytes", bytes.len());
        let decoded = image::load_from_memory(&bytes).expect("decodable png").to_rgba8();
        let mut colors = std::collections::HashSet::new();
        for pixel in decoded.pixels() {
            colors.insert(pixel.0);
            if colors.len() >= min_colors {
                return;
            }
        }
        panic!("rendered card is near-blank: only {} distinct colors", colors.len());
    }

    #[test]
    fn recap_share_card_renders_non_blank() {
        let card = recap_share_card(&recap_fixture(), "All Time", Some("marcus")).expect("card");
        assert_eq!(card.surface.width(), 1080);
        assert_eq!(card.surface.height(), 1350);
        assert_not_blank(&card, 64);
    }

    #[test]
    fn year_in_music_story_and_post_render_non_blank() {
        let story = year_in_music_card(&year_fixture(), true).expect("story");
        assert_eq!(story.surface.width(), 1080);
        assert_eq!(story.surface.height(), 1920);
        assert_not_blank(&story, 64);
        let post = year_in_music_card(&year_fixture(), false).expect("post");
        assert_eq!(post.surface.height(), 1350);
        assert_not_blank(&post, 64);
    }
}
