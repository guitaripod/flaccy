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
