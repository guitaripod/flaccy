use crate::db::ScrobbleRow;
use chrono::{Datelike, Local, NaiveDate, TimeZone};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Period {
    Week,
    Month,
    ThreeMonths,
    SixMonths,
    Year,
    AllTime,
}

pub const ALL_PERIODS: [Period; 6] = [
    Period::Week,
    Period::Month,
    Period::ThreeMonths,
    Period::SixMonths,
    Period::Year,
    Period::AllTime,
];

impl Period {
    pub fn label(self) -> &'static str {
        match self {
            Period::Week => "7D",
            Period::Month => "1M",
            Period::ThreeMonths => "3M",
            Period::SixMonths => "6M",
            Period::Year => "12M",
            Period::AllTime => "All",
        }
    }

    /// Last.fm user.getTop* period parameter for this recap scope.
    pub fn api_value(self) -> &'static str {
        match self {
            Period::Week => "7day",
            Period::Month => "1month",
            Period::ThreeMonths => "3month",
            Period::SixMonths => "6month",
            Period::Year => "12month",
            Period::AllTime => "overall",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Period::Week => "Last 7 Days",
            Period::Month => "Last Month",
            Period::ThreeMonths => "Last 3 Months",
            Period::SixMonths => "Last 6 Months",
            Period::Year => "Last 12 Months",
            Period::AllTime => "All Time",
        }
    }

    pub fn cutoff_unix(self, now_unix: i64) -> Option<i64> {
        let days = match self {
            Period::Week => 7,
            Period::Month => 30,
            Period::ThreeMonths => 90,
            Period::SixMonths => 180,
            Period::Year => 365,
            Period::AllTime => return None,
        };
        Some(now_unix - days * 86_400)
    }
}

pub struct RecapData {
    pub total_plays: i64,
    pub total_minutes: i64,
    pub top_artists: Vec<(String, i64)>,
    pub top_albums: Vec<(String, i64)>,
    pub top_tracks: Vec<(String, i64)>,
    pub clock: [i64; 24],
    pub streak_days: i64,
    pub persona: &'static str,
    pub heatmap: HashMap<NaiveDate, i64>,
}

pub fn compute(all_rows: &[ScrobbleRow], period: Period, now_unix: i64) -> RecapData {
    let scoped: Vec<&ScrobbleRow> = match period.cutoff_unix(now_unix) {
        Some(cutoff) => all_rows.iter().filter(|r| r.timestamp_unix >= cutoff).collect(),
        None => all_rows.iter().collect(),
    };
    let clock = listening_clock(&scoped);
    RecapData {
        total_plays: scoped.len() as i64,
        total_minutes: scoped.iter().map(|r| r.duration).sum::<i64>() / 60,
        top_artists: top_by(&scoped, |r| r.artist.clone(), 10),
        top_albums: top_by(&scoped, |r| format!("{} — {}", r.album, r.artist), 10),
        top_tracks: top_by(&scoped, |r| format!("{} — {}", r.title, r.artist), 10),
        clock,
        streak_days: streak_days(all_rows, now_unix),
        persona: persona(&scoped, &clock),
        heatmap: day_heatmap(&scoped),
    }
}

fn top_by(
    rows: &[&ScrobbleRow],
    key: impl Fn(&ScrobbleRow) -> String,
    limit: usize,
) -> Vec<(String, i64)> {
    let mut counts: HashMap<String, i64> = HashMap::new();
    for row in rows {
        *counts.entry(key(row)).or_insert(0) += 1;
    }
    let mut entries: Vec<(String, i64)> = counts.into_iter().collect();
    entries.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    entries.truncate(limit);
    entries
}

fn local_date(unix: i64) -> NaiveDate {
    Local
        .timestamp_opt(unix, 0)
        .single()
        .map(|dt| dt.date_naive())
        .unwrap_or_else(|| NaiveDate::from_ymd_opt(1970, 1, 1).expect("epoch date"))
}

fn local_hour(unix: i64) -> usize {
    use chrono::Timelike;
    Local
        .timestamp_opt(unix, 0)
        .single()
        .map(|dt| dt.hour() as usize)
        .unwrap_or(0)
}

fn listening_clock(rows: &[&ScrobbleRow]) -> [i64; 24] {
    let mut buckets = [0i64; 24];
    for row in rows {
        buckets[local_hour(row.timestamp_unix) % 24] += 1;
    }
    buckets
}

pub fn streak_days(rows: &[ScrobbleRow], now_unix: i64) -> i64 {
    if rows.is_empty() {
        return 0;
    }
    let days: HashSet<NaiveDate> = rows.iter().map(|r| local_date(r.timestamp_unix)).collect();
    let mut streak = 0;
    let mut day = local_date(now_unix);
    while days.contains(&day) {
        streak += 1;
        match day.pred_opt() {
            Some(previous) => day = previous,
            None => break,
        }
    }
    streak
}

fn day_heatmap(rows: &[&ScrobbleRow]) -> HashMap<NaiveDate, i64> {
    let mut map = HashMap::new();
    for row in rows {
        *map.entry(local_date(row.timestamp_unix)).or_insert(0) += 1;
    }
    map
}

/// Persona formula matching iOS LastFMStatsService.persona: night ratio (00–05
/// plus 23) > 0.35 → Night Owl; artist diversity > 0.6 → Explorer; < 0.2 →
/// Loyalist; else Devotee. Empty history → Newcomer.
pub fn persona(rows: &[&ScrobbleRow], clock: &[i64; 24]) -> &'static str {
    if rows.is_empty() {
        return "Newcomer";
    }
    let distinct_artists = rows
        .iter()
        .map(|r| r.artist.to_lowercase())
        .collect::<HashSet<_>>()
        .len();
    let plays = rows.len();
    let diversity = distinct_artists as f64 / plays as f64;
    let night_plays: i64 = (0..6).map(|h| clock[h]).sum::<i64>() + clock[23];
    let night_ratio = night_plays as f64 / plays.max(1) as f64;
    if night_ratio > 0.35 {
        return "Night Owl";
    }
    if diversity > 0.6 {
        return "Explorer";
    }
    if diversity < 0.2 {
        return "Loyalist";
    }
    "Devotee"
}

/// Heatmap grid layout: 7 day-of-week rows (Sunday first) × week columns from
/// the earliest datum to the current week, GitHub-style.
pub struct HeatmapGrid {
    pub start_sunday: NaiveDate,
    pub weeks: usize,
}

pub fn heatmap_grid(heatmap: &HashMap<NaiveDate, i64>, now_unix: i64) -> Option<HeatmapGrid> {
    let earliest = heatmap.keys().min().copied()?;
    let today = local_date(now_unix);
    let start_sunday = earliest
        - chrono::Duration::days(earliest.weekday().num_days_from_sunday() as i64);
    let end_sunday =
        today - chrono::Duration::days(today.weekday().num_days_from_sunday() as i64);
    let weeks = ((end_sunday - start_sunday).num_days() / 7 + 1).max(1) as usize;
    Some(HeatmapGrid {
        start_sunday,
        weeks,
    })
}

/// One year of listening, computed in a single pass over the year's scrobbles
/// (iOS YearInMusicService semantics): imported rows with duration 0 fall back
/// to the owned track's real duration, else 210 seconds.
pub struct YearData {
    pub year: i32,
    pub total_plays: i64,
    pub total_minutes: i64,
    pub distinct_artists: usize,
    pub distinct_albums: usize,
    pub distinct_tracks: usize,
    pub top_artists: Vec<(String, i64)>,
    pub top_albums: Vec<(String, String, i64)>,
    pub top_tracks: Vec<(String, String, i64)>,
    pub peak_day: Option<NaiveDate>,
    pub peak_day_plays: i64,
    pub peak_hour: Option<usize>,
    pub longest_streak: i64,
    pub persona: &'static str,
}

const FALLBACK_TRACK_SECONDS: i64 = 210;

pub fn track_key(title: &str, artist: &str) -> String {
    format!("{}\u{0}{}", title.to_lowercase(), artist.to_lowercase())
}

pub fn scrobble_years(rows: &[ScrobbleRow]) -> Vec<i32> {
    let mut years: Vec<i32> = rows
        .iter()
        .map(|r| local_date(r.timestamp_unix).year())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    years.sort_by(|a, b| b.cmp(a));
    years
}

pub fn compute_year(
    rows: &[ScrobbleRow],
    year: i32,
    library_durations: &HashMap<String, i64>,
) -> YearData {
    let scoped: Vec<&ScrobbleRow> = rows
        .iter()
        .filter(|r| local_date(r.timestamp_unix).year() == year)
        .collect();

    let mut total_seconds = 0i64;
    let mut artist_counts: HashMap<String, i64> = HashMap::new();
    let mut album_counts: HashMap<(String, String), i64> = HashMap::new();
    let mut track_counts: HashMap<(String, String), i64> = HashMap::new();
    let mut day_counts: HashMap<NaiveDate, i64> = HashMap::new();
    let mut hour_counts = [0i64; 24];

    for row in &scoped {
        if row.duration > 0 {
            total_seconds += row.duration;
        } else {
            total_seconds += library_durations
                .get(&track_key(&row.title, &row.artist))
                .copied()
                .unwrap_or(FALLBACK_TRACK_SECONDS);
        }
        *artist_counts.entry(row.artist.clone()).or_insert(0) += 1;
        *album_counts
            .entry((row.album.clone(), row.artist.clone()))
            .or_insert(0) += 1;
        *track_counts
            .entry((row.title.clone(), row.artist.clone()))
            .or_insert(0) += 1;
        *day_counts.entry(local_date(row.timestamp_unix)).or_insert(0) += 1;
        hour_counts[local_hour(row.timestamp_unix) % 24] += 1;
    }

    let mut top_artists: Vec<(String, i64)> = artist_counts.clone().into_iter().collect();
    top_artists.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    top_artists.truncate(5);
    let mut top_albums: Vec<(String, String, i64)> = album_counts
        .iter()
        .map(|((album, artist), count)| (album.clone(), artist.clone(), *count))
        .collect();
    top_albums.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(&b.0)));
    top_albums.truncate(5);
    let mut top_tracks: Vec<(String, String, i64)> = track_counts
        .iter()
        .map(|((title, artist), count)| (title.clone(), artist.clone(), *count))
        .collect();
    top_tracks.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(&b.0)));
    top_tracks.truncate(5);

    let peak = day_counts.iter().max_by_key(|(_, count)| **count);
    let peak_hour = if hour_counts.iter().any(|c| *c > 0) {
        hour_counts
            .iter()
            .enumerate()
            .max_by_key(|(_, count)| **count)
            .map(|(hour, _)| hour)
    } else {
        None
    };

    let persona = year_persona(scoped.len(), artist_counts.len(), &hour_counts);

    YearData {
        year,
        total_plays: scoped.len() as i64,
        total_minutes: total_seconds / 60,
        distinct_artists: artist_counts.len(),
        distinct_albums: album_counts.len(),
        distinct_tracks: track_counts.len(),
        top_artists,
        top_albums,
        top_tracks,
        peak_day: peak.map(|(date, _)| *date),
        peak_day_plays: peak.map(|(_, count)| *count).unwrap_or(0),
        peak_hour,
        longest_streak: longest_streak(&day_counts.keys().copied().collect()),
        persona,
    }
}

fn year_persona(plays: usize, distinct_artists: usize, hour_counts: &[i64; 24]) -> &'static str {
    if plays == 0 {
        return "Newcomer";
    }
    let diversity = distinct_artists as f64 / plays as f64;
    let night_plays: i64 = (0..6).map(|h| hour_counts[h]).sum::<i64>() + hour_counts[23];
    let night_ratio = night_plays as f64 / plays as f64;
    if night_ratio > 0.35 {
        return "Night Owl";
    }
    if diversity > 0.6 {
        return "Explorer";
    }
    if diversity < 0.2 {
        return "Loyalist";
    }
    "Devotee"
}

/// Longest run of consecutive listening days: scan each day that has no
/// predecessor and walk forward (iOS longestStreak).
fn longest_streak(days: &HashSet<NaiveDate>) -> i64 {
    let mut longest = 0i64;
    for day in days {
        let Some(previous) = day.pred_opt() else { continue };
        if days.contains(&previous) {
            continue;
        }
        let mut length = 1i64;
        let mut cursor = *day;
        while let Some(next) = cursor.succ_opt() {
            if !days.contains(&next) {
                break;
            }
            length += 1;
            cursor = next;
        }
        longest = longest.max(length);
    }
    longest
}

/// Deduplication key for imported scrobbles: unix timestamp + lowercased title,
/// matching iOS importHistory.
pub fn import_key(timestamp_unix: i64, title: &str) -> String {
    format!("{}\u{0}{}", timestamp_unix, title.to_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(title: &str, artist: &str, ts: i64) -> ScrobbleRow {
        ScrobbleRow {
            title: title.to_string(),
            artist: artist.to_string(),
            album: "A".to_string(),
            timestamp_unix: ts,
            duration: 240,
        }
    }

    #[test]
    fn persona_newcomer_on_empty() {
        assert_eq!(persona(&[], &[0; 24]), "Newcomer");
    }

    #[test]
    fn persona_night_owl() {
        let rows: Vec<ScrobbleRow> = (0..10).map(|i| row(&format!("t{i}"), &format!("a{i}"), 0)).collect();
        let refs: Vec<&ScrobbleRow> = rows.iter().collect();
        let mut clock = [0i64; 24];
        clock[1] = 6;
        clock[14] = 4;
        assert_eq!(persona(&refs, &clock), "Night Owl");
    }

    #[test]
    fn persona_explorer_loyalist_devotee() {
        let make = |artists: usize, plays: usize| -> Vec<ScrobbleRow> {
            (0..plays)
                .map(|i| row(&format!("t{i}"), &format!("a{}", i % artists), 0))
                .collect()
        };
        let clock = [0i64; 24];
        let explorer = make(10, 10);
        let refs: Vec<&ScrobbleRow> = explorer.iter().collect();
        assert_eq!(persona(&refs, &clock), "Explorer");
        let loyalist = make(1, 10);
        let refs: Vec<&ScrobbleRow> = loyalist.iter().collect();
        assert_eq!(persona(&refs, &clock), "Loyalist");
        let devotee = make(4, 10);
        let refs: Vec<&ScrobbleRow> = devotee.iter().collect();
        assert_eq!(persona(&refs, &clock), "Devotee");
    }

    #[test]
    fn streak_counts_consecutive_days_ending_today() {
        let now = chrono::Utc::now().timestamp();
        let rows = vec![
            row("a", "x", now),
            row("b", "x", now - 86_400),
            row("c", "x", now - 2 * 86_400),
            row("d", "x", now - 5 * 86_400),
        ];
        assert_eq!(streak_days(&rows, now), 3);
    }

    #[test]
    fn streak_zero_when_not_today() {
        let now = chrono::Utc::now().timestamp();
        let rows = vec![row("a", "x", now - 3 * 86_400)];
        assert_eq!(streak_days(&rows, now), 0);
    }

    #[test]
    fn period_scoping_filters_rows() {
        let now = 1_800_000_000;
        let rows = vec![
            row("new", "x", now - 86_400),
            row("old", "x", now - 400 * 86_400),
        ];
        let week = compute(&rows, Period::Week, now);
        assert_eq!(week.total_plays, 1);
        let all = compute(&rows, Period::AllTime, now);
        assert_eq!(all.total_plays, 2);
        assert_eq!(all.total_minutes, 8);
    }

    #[test]
    fn import_key_dedupes_by_timestamp_and_title() {
        assert_eq!(import_key(100, "Song"), import_key(100, "song"));
        assert_ne!(import_key(100, "Song"), import_key(101, "Song"));
    }

    #[test]
    fn period_api_values_match_lastfm() {
        let expected = ["7day", "1month", "3month", "6month", "12month", "overall"];
        for (period, value) in ALL_PERIODS.iter().zip(expected) {
            assert_eq!(period.api_value(), value);
        }
    }

    fn ts(year: i32, month: u32, day: u32, hour: u32) -> i64 {
        Local
            .with_ymd_and_hms(year, month, day, hour, 0, 0)
            .single()
            .expect("valid local time")
            .timestamp()
    }

    fn year_row(title: &str, artist: &str, album: &str, unix: i64, duration: i64) -> ScrobbleRow {
        ScrobbleRow {
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            timestamp_unix: unix,
            duration,
        }
    }

    #[test]
    fn year_compute_scopes_totals_and_tops() {
        let rows = vec![
            year_row("A", "X", "AL", ts(2025, 3, 1, 12), 120),
            year_row("A", "X", "AL", ts(2025, 3, 2, 12), 120),
            year_row("B", "Y", "BL", ts(2025, 3, 3, 12), 60),
            year_row("Old", "Z", "ZL", ts(2024, 6, 1, 12), 600),
        ];
        let data = compute_year(&rows, 2025, &HashMap::new());
        assert_eq!(data.total_plays, 3);
        assert_eq!(data.total_minutes, 5);
        assert_eq!(data.distinct_artists, 2);
        assert_eq!(data.distinct_albums, 2);
        assert_eq!(data.distinct_tracks, 2);
        assert_eq!(data.top_artists[0], ("X".to_string(), 2));
        assert_eq!(data.top_tracks[0].0, "A");
        assert_eq!(data.longest_streak, 3);
        assert_eq!(data.peak_hour, Some(12));
    }

    #[test]
    fn year_compute_duration_fallbacks() {
        let rows = vec![
            year_row("Known", "X", "AL", ts(2025, 5, 1, 10), 0),
            year_row("Unknown", "X", "AL", ts(2025, 5, 1, 11), 0),
        ];
        let mut durations = HashMap::new();
        durations.insert(track_key("Known", "X"), 300i64);
        let data = compute_year(&rows, 2025, &durations);
        assert_eq!(data.total_minutes, (300 + 210) / 60);
    }

    #[test]
    fn year_compute_peak_day() {
        let rows = vec![
            year_row("a", "x", "l", ts(2025, 7, 4, 9), 60),
            year_row("b", "x", "l", ts(2025, 7, 4, 10), 60),
            year_row("c", "x", "l", ts(2025, 7, 5, 10), 60),
        ];
        let data = compute_year(&rows, 2025, &HashMap::new());
        assert_eq!(data.peak_day, NaiveDate::from_ymd_opt(2025, 7, 4));
        assert_eq!(data.peak_day_plays, 2);
    }

    #[test]
    fn scrobble_years_descending_distinct() {
        let rows = vec![
            year_row("a", "x", "l", ts(2024, 1, 5, 9), 60),
            year_row("b", "x", "l", ts(2025, 1, 5, 9), 60),
            year_row("c", "x", "l", ts(2025, 6, 5, 9), 60),
        ];
        assert_eq!(scrobble_years(&rows), vec![2025, 2024]);
    }

    #[test]
    fn heatmap_grid_spans_weeks() {
        let now = 1_800_000_000;
        let mut map = HashMap::new();
        map.insert(local_date(now - 30 * 86_400), 3);
        map.insert(local_date(now), 1);
        let grid = heatmap_grid(&map, now).expect("grid");
        assert!(grid.weeks >= 5 && grid.weeks <= 6, "weeks = {}", grid.weeks);
        assert_eq!(grid.start_sunday.weekday().num_days_from_sunday(), 0);
    }
}
