use crate::db::{Db, ScrobbleRow};
use chrono::{Datelike, Local, NaiveDate, TimeZone};
use std::collections::{HashMap, HashSet};

/// Scrobbles stamped before this (2002-01-01 UTC, the year Last.fm launched)
/// carry no real date: an old scrobbler submitted a zero timestamp, so the
/// plays count but they belong on no calendar, clock face or streak.
pub const MIN_DATED_UNIX: i64 = 1_009_843_200;

/// Weeks the streak calendar spans when a period is selected.
const HEATMAP_WEEKS: i64 = 53;

/// How far back a period's rows are fetched so the calendar can fill its full
/// width: the 53 weeks plus the days of the current week already past.
const HEATMAP_FETCH_DAYS: i64 = HEATMAP_WEEKS * 7 + 6;

/// Scrobble times read per round while walking back through a streak.
const STREAK_CHUNK: usize = 2_000;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
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

    pub fn span_days(self) -> Option<i64> {
        match self {
            Period::Week => Some(7),
            Period::Month => Some(30),
            Period::ThreeMonths => Some(90),
            Period::SixMonths => Some(180),
            Period::Year => Some(365),
            Period::AllTime => None,
        }
    }

    pub fn cutoff_unix(self, now_unix: i64) -> Option<i64> {
        self.span_days().map(|days| now_unix - days * 86_400)
    }

    /// The window the tile deltas compare against, as the tooltip names it.
    pub fn previous_label(self) -> Option<String> {
        self.span_days().map(|days| format!("previous {days} days"))
    }
}

/// What the preceding window of equal length held, for the tile deltas.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PreviousTotals {
    pub plays: i64,
    pub minutes: i64,
}

#[derive(Clone)]
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
    /// The Sunday the streak calendar starts on: 53 weeks back for a period,
    /// the first dated play for All Time. `None` when there is nothing dated.
    pub heatmap_start: Option<NaiveDate>,
    /// Cells before this day fall outside the selected period and are drawn
    /// dimmed. `None` for the periods that fill the whole calendar.
    pub period_start: Option<NaiveDate>,
    pub previous: Option<PreviousTotals>,
    /// Whether any scrobble exists at all, so a quiet week can read as a quiet
    /// week and only a library that has never been listened to gets the
    /// first-run page.
    pub has_history: bool,
}

/// Everything the Stats tab shows for one period, read with as little of the
/// history as the period needs: a period seeks its index range, the streak
/// walks back only to its first gap, and only All Time reads every row.
pub fn load(db: &Db, period: Period, now: i64) -> RecapData {
    let rows = match fetch_floor(period, now) {
        Some(floor) => db.fetch_scrobble_rows_since(floor),
        None => db.fetch_all_scrobble_rows(),
    };
    let streak = current_streak(|before| db.scrobble_times_before(before, STREAK_CHUNK), now);
    let previous = period
        .cutoff_unix(now)
        .zip(period.span_days())
        .map(|(cutoff, days)| {
            let (plays, seconds) = db.scrobble_totals_between(cutoff - days * 86_400, cutoff);
            PreviousTotals {
                plays,
                minutes: seconds / 60,
            }
        });
    let mut data = compute(&rows, period, now, streak, previous);
    data.has_history = data.has_history || db.has_scrobbles();
    data
}

/// The oldest scrobble a period's recap has to read, `None` for All Time.
fn fetch_floor(period: Period, now: i64) -> Option<i64> {
    period.span_days()?;
    Some(now - HEATMAP_FETCH_DAYS * 86_400)
}

/// Builds the recap from `rows`, which must reach back at least as far as
/// `fetch_floor` and run oldest first. `streak_days` and `previous` come from
/// the database because neither can be read off a period's rows.
pub fn compute(
    rows: &[ScrobbleRow],
    period: Period,
    now_unix: i64,
    streak_days: i64,
    previous: Option<PreviousTotals>,
) -> RecapData {
    let scoped: Vec<&ScrobbleRow> = match period.cutoff_unix(now_unix) {
        Some(cutoff) => rows.iter().filter(|r| r.timestamp_unix >= cutoff).collect(),
        None => rows.iter().collect(),
    };
    let dated: Vec<&ScrobbleRow> = scoped
        .iter()
        .copied()
        .filter(|r| r.timestamp_unix >= MIN_DATED_UNIX)
        .collect();
    let clock = listening_clock(&dated);
    let heatmap_start = heatmap_start(period, rows, now_unix);
    RecapData {
        total_plays: scoped.len() as i64,
        total_minutes: scoped.iter().map(|r| r.duration).sum::<i64>() / 60,
        top_artists: top_by(&scoped, |r| r.artist.clone(), 10),
        top_albums: top_by(&scoped, |r| format!("{} — {}", r.album, r.artist), 10),
        top_tracks: top_by(&scoped, |r| format!("{} — {}", r.title, r.artist), 10),
        clock,
        streak_days,
        persona: persona(&scoped, &clock),
        heatmap: day_heatmap(rows, heatmap_start),
        heatmap_start,
        period_start: dimmed_before(period, now_unix),
        previous,
        has_history: !rows.is_empty(),
    }
}

fn sunday_on_or_before(date: NaiveDate) -> NaiveDate {
    date - chrono::Duration::days(date.weekday().num_days_from_sunday() as i64)
}

fn heatmap_start(period: Period, rows: &[ScrobbleRow], now_unix: i64) -> Option<NaiveDate> {
    if period == Period::AllTime {
        let first = rows.iter().find(|r| r.timestamp_unix >= MIN_DATED_UNIX)?;
        return Some(sunday_on_or_before(local_date(first.timestamp_unix)));
    }
    Some(sunday_on_or_before(local_date(now_unix)) - chrono::Duration::weeks(HEATMAP_WEEKS - 1))
}

/// The first day inside the period, when the calendar shows days outside it.
fn dimmed_before(period: Period, now_unix: i64) -> Option<NaiveDate> {
    match period {
        Period::Year | Period::AllTime => None,
        _ => period.cutoff_unix(now_unix).map(local_date),
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

/// Consecutive listening days ending today, read newest first in rounds of
/// `times_before(t)` (the newest scrobble times strictly before `t`) so a streak
/// costs the plays inside it rather than the whole history. No play today means
/// no streak.
pub fn current_streak(mut times_before: impl FnMut(i64) -> Vec<i64>, now_unix: i64) -> i64 {
    let today = local_date(now_unix);
    let mut streak = 0;
    let mut last: Option<NaiveDate> = None;
    let mut before = now_unix + 1;
    loop {
        let chunk = times_before(before);
        for &time in &chunk {
            if time < MIN_DATED_UNIX {
                return streak;
            }
            let day = local_date(time);
            if day > today {
                continue;
            }
            match last {
                None if day == today => {
                    streak = 1;
                    last = Some(day);
                }
                None => return 0,
                Some(counted) if day == counted => {}
                Some(counted) if counted.pred_opt() == Some(day) => {
                    streak += 1;
                    last = Some(day);
                }
                Some(_) => return streak,
            }
        }
        match chunk.last() {
            Some(&oldest) if chunk.len() >= STREAK_CHUNK => before = oldest,
            _ => return streak,
        }
    }
}

/// Plays per local day for every dated row from `start` on.
fn day_heatmap(rows: &[ScrobbleRow], start: Option<NaiveDate>) -> HashMap<NaiveDate, i64> {
    let mut map = HashMap::new();
    let Some(start) = start else {
        return map;
    };
    for row in rows.iter().filter(|r| r.timestamp_unix >= MIN_DATED_UNIX) {
        let day = local_date(row.timestamp_unix);
        if day >= start {
            *map.entry(day).or_insert(0) += 1;
        }
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
    let dated_plays: i64 = clock.iter().sum();
    let night_ratio = night_plays as f64 / dated_plays.max(1) as f64;
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
/// the calendar's start to the current week, GitHub-style.
pub struct HeatmapGrid {
    pub start_sunday: NaiveDate,
    pub weeks: usize,
}

pub fn heatmap_grid(start_sunday: Option<NaiveDate>, now_unix: i64) -> Option<HeatmapGrid> {
    let start_sunday = start_sunday?;
    let end_sunday = sunday_on_or_before(local_date(now_unix));
    let weeks = ((end_sunday - start_sunday).num_days() / 7 + 1).max(1) as usize;
    Some(HeatmapGrid {
        start_sunday,
        weeks,
    })
}

/// One year of listening, computed in a single pass over the year's scrobbles
/// (iOS YearInMusicService semantics): imported rows with duration 0 fall back
/// to the owned track's real duration, else 210 seconds.
#[derive(Clone)]
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

#[cfg(test)]
pub fn scrobble_years(rows: &[ScrobbleRow]) -> Vec<i32> {
    let mut years: Vec<i32> = rows
        .iter()
        .filter(|r| r.timestamp_unix >= MIN_DATED_UNIX)
        .map(|r| local_date(r.timestamp_unix).year())
        .collect::<HashSet<_>>()
        .into_iter()
        .collect();
    years.sort_by(|a, b| b.cmp(a));
    years
}

/// The latest instant `string_from_unix` can still format, past every scrobble.
const END_OF_TIME_UNIX: i64 = 253_402_300_799;

/// Every local calendar year that holds a dated play, newest first, found by
/// hopping from year to year over the timestamp index instead of reading the
/// whole history: one indexed lookup per year with plays.
pub fn dated_years(db: &Db) -> Vec<i32> {
    let mut years = Vec::new();
    let mut before = END_OF_TIME_UNIX;
    while let Some(newest) = db.scrobble_times_before(before, 1).first().copied() {
        if newest < MIN_DATED_UNIX {
            break;
        }
        let year = local_date(newest).year();
        if years.last() != Some(&year) {
            years.push(year);
        }
        before = local_year_start(year).map_or(newest, |start| start.min(newest));
    }
    years
}

/// The first instant of local calendar year `year`, `None` when the calendar
/// cannot name it.
fn local_year_start(year: i32) -> Option<i64> {
    let midnight = NaiveDate::from_ymd_opt(year, 1, 1)?.and_hms_opt(0, 0, 0)?;
    Local
        .from_local_datetime(&midnight)
        .earliest()
        .map(|start| start.timestamp())
}

/// The scrobbles of local calendar year `year`, oldest first: the only rows
/// `compute_year` reads, fetched from the year's start on rather than from the
/// beginning of the history.
pub fn year_rows(db: &Db, year: i32) -> Vec<ScrobbleRow> {
    let from = local_year_start(year).map_or(0, |start| start - 86_400);
    let mut rows = db.fetch_scrobble_rows_since(from);
    rows.retain(|row| local_date(row.timestamp_unix).year() == year);
    rows
}

/// How much play history there is, cheap enough to ask whether a cached recap
/// is still current: the number of scrobbles and the newest one's time. Plays
/// are only ever added (the scrobbler appends at the present, an import adds
/// history), so either number moves whenever the history does.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct HistoryStamp {
    count: i64,
    newest_unix: i64,
}

pub fn history_stamp(db: &Db) -> HistoryStamp {
    HistoryStamp {
        count: db.scrobble_count(),
        newest_unix: db
            .scrobble_times_before(END_OF_TIME_UNIX, 1)
            .first()
            .copied()
            .unwrap_or(0),
    }
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
        *day_counts
            .entry(local_date(row.timestamp_unix))
            .or_insert(0) += 1;
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
        let Some(previous) = day.pred_opt() else {
            continue;
        };
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
        let rows: Vec<ScrobbleRow> = (0..10)
            .map(|i| row(&format!("t{i}"), &format!("a{i}"), 0))
            .collect();
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

    fn streak_over(times: &[i64], now: i64) -> i64 {
        let mut sorted = times.to_vec();
        sorted.sort_unstable_by(|a, b| b.cmp(a));
        current_streak(
            |before| {
                sorted
                    .iter()
                    .copied()
                    .filter(|t| *t < before)
                    .take(STREAK_CHUNK)
                    .collect()
            },
            now,
        )
    }

    fn noon() -> i64 {
        ts(2026, 6, 15, 12)
    }

    fn noon_days_ago(days: u32) -> i64 {
        ts(2026, 6, 15 - days, 12)
    }

    #[test]
    fn streak_counts_consecutive_days_ending_today() {
        let times = [noon(), noon_days_ago(1), noon_days_ago(2), noon_days_ago(5)];
        assert_eq!(streak_over(&times, noon()), 3);
    }

    #[test]
    fn streak_zero_when_not_today() {
        assert_eq!(streak_over(&[noon_days_ago(3)], noon()), 0);
    }

    #[test]
    fn streak_counts_a_day_once_however_many_plays_it_holds() {
        let times = [
            noon(),
            noon() - 60,
            noon() - 120,
            noon_days_ago(1),
            noon_days_ago(1) - 60,
        ];
        assert_eq!(streak_over(&times, noon()), 2);
    }

    #[test]
    fn streak_reads_across_rounds_and_stops_at_the_first_gap() {
        let now = noon();
        let times: Vec<i64> = (0..STREAK_CHUNK as i64 * 2 + 50)
            .map(|i| now - i * 43_200)
            .collect();
        let days = streak_over(&times, now);
        assert!(days > 1_000, "the streak spans several rounds, got {days}");
        let mut with_gap = times.clone();
        with_gap.retain(|t| *t > now - 10 * 86_400 || *t < now - 12 * 86_400);
        assert!(streak_over(&with_gap, now) <= 10);
    }

    #[test]
    fn streak_ignores_undated_plays_and_a_future_clock() {
        let now = noon();
        let times = [now + 3 * 86_400, now, 5, 4, 3];
        assert_eq!(streak_over(&times, now), 1);
    }

    #[test]
    fn period_scoping_filters_rows() {
        let now = 1_800_000_000;
        let rows = vec![
            row("old", "x", now - 400 * 86_400),
            row("new", "x", now - 86_400),
        ];
        let week = compute(&rows, Period::Week, now, 0, None);
        assert_eq!(week.total_plays, 1);
        let all = compute(&rows, Period::AllTime, now, 0, None);
        assert_eq!(all.total_plays, 2);
        assert_eq!(all.total_minutes, 8);
    }

    #[test]
    fn undated_plays_count_but_never_reach_the_calendar_or_the_clock() {
        let now = 1_800_000_000;
        let rows = vec![
            row("a", "x", 1),
            row("b", "x", 2),
            row("c", "x", now - 86_400),
        ];
        let all = compute(&rows, Period::AllTime, now, 0, None);
        assert_eq!(all.total_plays, 3, "Last.fm counts them, so do the totals");
        assert_eq!(all.top_tracks.len(), 3);
        assert_eq!(
            all.clock.iter().sum::<i64>(),
            1,
            "only the dated play is on the clock"
        );
        assert_eq!(all.heatmap.values().sum::<i64>(), 1);
        let grid = heatmap_grid(all.heatmap_start, now).expect("grid");
        assert!(
            grid.weeks <= 2,
            "the calendar starts at the first dated play, got {}",
            grid.weeks
        );
    }

    #[test]
    fn a_period_calendar_spans_53_weeks_and_dims_what_the_period_excludes() {
        let now = 1_800_000_000;
        let rows = vec![
            row("old", "x", now - 200 * 86_400),
            row("new", "x", now - 86_400),
        ];
        let week = compute(&rows, Period::Week, now, 0, None);
        let grid = heatmap_grid(week.heatmap_start, now).expect("grid");
        assert_eq!(grid.weeks, 53);
        assert_eq!(grid.start_sunday.weekday().num_days_from_sunday(), 0);
        assert_eq!(
            week.heatmap.values().sum::<i64>(),
            2,
            "plays outside the period still fill the calendar"
        );
        assert_eq!(week.total_plays, 1);
        assert_eq!(week.period_start, Some(local_date(now - 7 * 86_400)));
        let year = compute(&rows, Period::Year, now, 0, None);
        assert_eq!(
            year.period_start, None,
            "12 months fills the calendar, nothing to dim"
        );
        let all = compute(&rows, Period::AllTime, now, 0, None);
        assert_eq!(all.period_start, None);
    }

    #[test]
    fn fetch_floor_only_exists_for_a_period() {
        let now = 1_800_000_000;
        assert_eq!(fetch_floor(Period::AllTime, now), None);
        let floor = fetch_floor(Period::Week, now).expect("floor");
        let start = heatmap_start(Period::Week, &[], now).expect("start");
        assert!(
            local_date(floor) <= start,
            "the floor reaches the calendar's first day"
        );
        assert!(floor < Period::Year.cutoff_unix(now).expect("cutoff"));
    }

    #[test]
    fn previous_label_names_the_window_in_days() {
        assert_eq!(
            Period::Week.previous_label().as_deref(),
            Some("previous 7 days")
        );
        assert_eq!(
            Period::Year.previous_label().as_deref(),
            Some("previous 365 days")
        );
        assert_eq!(Period::AllTime.previous_label(), None);
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
        let start = sunday_on_or_before(local_date(now - 30 * 86_400));
        let grid = heatmap_grid(Some(start), now).expect("grid");
        assert!(grid.weeks >= 5 && grid.weeks <= 6, "weeks = {}", grid.weeks);
        assert_eq!(grid.start_sunday.weekday().num_days_from_sunday(), 0);
        assert!(heatmap_grid(None, now).is_none());
    }

    struct TempDb {
        path: std::path::PathBuf,
        db: Db,
    }

    impl TempDb {
        fn with_scrobbles(unix_times: &[i64]) -> Self {
            static SEQUENCE: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let unique = SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let path = std::env::temp_dir().join(format!(
                "flaccy-recap-test-{}-{unique}.sqlite",
                std::process::id()
            ));
            let db = Db::open(&path).expect("temp db opens");
            let rows: Vec<(String, String, String, i64, i64, bool)> = unix_times
                .iter()
                .enumerate()
                .map(|(at, unix)| {
                    (format!("t{at}"), "A".into(), "Alb".into(), *unix, 200, true)
                })
                .collect();
            db.insert_scrobbles_batch(&rows).expect("seed scrobbles");
            Self { path, db }
        }
    }

    impl Drop for TempDb {
        fn drop(&mut self) {
            for suffix in ["", "-wal", "-shm"] {
                let _ = std::fs::remove_file(format!("{}{suffix}", self.path.display()));
            }
        }
    }

    fn boundary_times() -> Vec<i64> {
        let mut times = vec![0, 5, MIN_DATED_UNIX - 1, MIN_DATED_UNIX, MIN_DATED_UNIX + 3_600];
        for year in [2003, 2010, 2024, 2025, 2026] {
            let start = local_year_start(year).expect("year start");
            times.extend([start - 1, start, start + 1, start + 86_400 * 200]);
        }
        times
    }

    fn counts_of(ranked: &[(String, String, i64)]) -> Vec<i64> {
        ranked.iter().map(|(_, _, count)| *count).collect()
    }

    #[test]
    fn dated_years_match_reading_every_row() {
        let temp = TempDb::with_scrobbles(&boundary_times());
        assert_eq!(
            dated_years(&temp.db),
            scrobble_years(&temp.db.fetch_all_scrobble_rows())
        );
    }

    #[test]
    fn dated_years_of_an_empty_history_are_empty() {
        let temp = TempDb::with_scrobbles(&[]);
        assert!(dated_years(&temp.db).is_empty());
    }

    #[test]
    fn dated_years_skip_undated_plays() {
        let temp = TempDb::with_scrobbles(&[0, 1_000, MIN_DATED_UNIX - 1]);
        assert!(dated_years(&temp.db).is_empty());
    }

    #[test]
    fn year_rows_feed_the_same_year_as_the_whole_history() {
        let temp = TempDb::with_scrobbles(&boundary_times());
        let everything = temp.db.fetch_all_scrobble_rows();
        let durations = HashMap::new();
        for year in dated_years(&temp.db) {
            let narrowed = compute_year(&year_rows(&temp.db, year), year, &durations);
            let whole = compute_year(&everything, year, &durations);
            assert_eq!(narrowed.total_plays, whole.total_plays, "{year}");
            assert_eq!(narrowed.total_minutes, whole.total_minutes, "{year}");
            assert_eq!(
                counts_of(&narrowed.top_tracks),
                counts_of(&whole.top_tracks),
                "{year}"
            );
            assert_eq!(narrowed.peak_day_plays, whole.peak_day_plays, "{year}");
            assert_eq!(narrowed.longest_streak, whole.longest_streak, "{year}");
        }
    }

    #[test]
    fn the_history_stamp_moves_when_plays_are_added() {
        let temp = TempDb::with_scrobbles(&[MIN_DATED_UNIX + 10]);
        let before = history_stamp(&temp.db);
        assert_eq!(before, history_stamp(&temp.db));
        temp.db
            .insert_scrobbles_batch(&[("x".into(), "A".into(), "Alb".into(), MIN_DATED_UNIX + 5, 1, true)])
            .expect("older play");
        assert_ne!(before, history_stamp(&temp.db));
        let middle = history_stamp(&temp.db);
        temp.db
            .insert_scrobbles_batch(&[("y".into(), "A".into(), "Alb".into(), MIN_DATED_UNIX + 99, 1, true)])
            .expect("newer play");
        assert_ne!(middle, history_stamp(&temp.db));
    }

    #[test]
    #[ignore]
    fn dated_years_match_reading_every_row_on_the_real_history() {
        let db = crate::library::perf_fixture::open();
        let started = std::time::Instant::now();
        let stamp = history_stamp(&db);
        println!("history_stamp {stamp:?}: {:?}", started.elapsed());
        let started = std::time::Instant::now();
        let hopped = dated_years(&db);
        println!("dated_years: {:?}", started.elapsed());
        let started = std::time::Instant::now();
        let rows = db.fetch_all_scrobble_rows();
        println!("fetch_all_scrobble_rows {} rows: {:?}", rows.len(), started.elapsed());
        assert_eq!(hopped, scrobble_years(&rows));
        let durations = HashMap::new();
        for year in hopped {
            let started = std::time::Instant::now();
            let narrowed = year_rows(&db, year);
            println!("year_rows {year} {} rows: {:?}", narrowed.len(), started.elapsed());
            let a = compute_year(&narrowed, year, &durations);
            let b = compute_year(&rows, year, &durations);
            assert_eq!(a.total_plays, b.total_plays, "{year}");
            assert_eq!(a.total_minutes, b.total_minutes, "{year}");
            assert_eq!(a.top_artists, b.top_artists, "{year}");
            assert_eq!(a.distinct_artists, b.distinct_artists, "{year}");
            assert_eq!(a.distinct_albums, b.distinct_albums, "{year}");
            assert_eq!(a.distinct_tracks, b.distinct_tracks, "{year}");
            assert_eq!(counts_of(&a.top_albums), counts_of(&b.top_albums), "{year}");
            assert_eq!(counts_of(&a.top_tracks), counts_of(&b.top_tracks), "{year}");
            assert_eq!(a.peak_day_plays, b.peak_day_plays, "{year}");
            assert_eq!(a.peak_hour, b.peak_hour, "{year}");
            assert_eq!(a.longest_streak, b.longest_streak, "{year}");
            assert_eq!(a.persona, b.persona, "{year}");
        }
    }
}
