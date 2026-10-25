//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Home/` (`HomeLayout.swift`,
//! `HomeComposer.swift`, `PlaybackContext.swift`, `ResumePoint.swift`,
//! `RecentContexts.swift`, `ListeningGlance.swift`).
//!
//! Home's rules: which sections exist and in what order the person keeps
//! them, what leads the page, how a paused session is described, what Jump
//! Back In offers, and the On This Day and This Week cards. Times are unix
//! seconds and every calendar question takes the local UTC offset, so the
//! same vectors prove both languages.

use chrono::{DateTime, Datelike, FixedOffset, NaiveDate, TimeZone, Timelike};
use std::collections::{BTreeMap, HashMap, HashSet};

use crate::library_filter::PeriodDelta;

pub const DAY: i64 = 86_400;

/// The sections Home can show, in their default order. `id` is the persisted
/// identifier, shared with the Apple clients.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Section {
    Resume,
    JumpBackIn,
    MadeForYou,
    RecentlyAdded,
    OnThisDay,
    ThisWeek,
}

impl Section {
    pub const ALL: [Section; 6] = [
        Section::Resume,
        Section::JumpBackIn,
        Section::OnThisDay,
        Section::ThisWeek,
        Section::MadeForYou,
        Section::RecentlyAdded,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Section::Resume => "continue",
            Section::JumpBackIn => "jumpBackIn",
            Section::MadeForYou => "madeForYou",
            Section::RecentlyAdded => "recentlyAdded",
            Section::OnThisDay => "onThisDay",
            Section::ThisWeek => "thisWeek",
        }
    }

    pub fn from_id(id: &str) -> Option<Section> {
        Section::ALL.into_iter().find(|section| section.id() == id)
    }

    /// Sections small enough to sit side by side when they are neighbours.
    pub fn is_compact(self) -> bool {
        matches!(self, Section::OnThisDay | Section::ThisWeek)
    }
}

/// The person's arrangement of Home: every section in their order, and the
/// ones they switched off. Hidden sections keep their place.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Layout {
    order: Vec<Section>,
    hidden: HashSet<Section>,
}

impl Default for Layout {
    fn default() -> Self {
        Layout::standard()
    }
}

impl Layout {
    pub fn standard() -> Layout {
        Layout::new(Section::ALL.to_vec(), HashSet::new())
    }

    pub fn new(order: Vec<Section>, hidden: HashSet<Section>) -> Layout {
        Layout {
            order: completed(order),
            hidden,
        }
    }

    pub fn order(&self) -> &[Section] {
        &self.order
    }

    pub fn hidden(&self) -> &HashSet<Section> {
        &self.hidden
    }

    pub fn visible(&self) -> Vec<Section> {
        self.order
            .iter()
            .copied()
            .filter(|section| !self.hidden.contains(section))
            .collect()
    }

    pub fn is_standard(&self) -> bool {
        *self == Layout::standard()
    }

    pub fn is_visible(&self, section: Section) -> bool {
        !self.hidden.contains(&section)
    }

    /// Moves the section at `source` to `destination`, clamping both so a
    /// drag past either end lands on it.
    pub fn moving(&self, source: usize, destination: isize) -> Layout {
        if source >= self.order.len() {
            return self.clone();
        }
        let mut reordered = self.order.clone();
        let section = reordered.remove(source);
        let target = destination.clamp(0, reordered.len() as isize) as usize;
        reordered.insert(target, section);
        Layout::new(reordered, self.hidden.clone())
    }

    pub fn setting(&self, section: Section, visible: bool) -> Layout {
        let mut hidden = self.hidden.clone();
        if visible {
            hidden.remove(&section);
        } else {
            hidden.insert(section);
        }
        Layout::new(self.order.clone(), hidden)
    }

    /// `continue,jumpBackIn,…|thisWeek`: the order, then the hidden sections
    /// in that order. The same text on every client.
    pub fn encoded(&self) -> String {
        let order: Vec<&str> = self.order.iter().map(|s| s.id()).collect();
        let hidden: Vec<&str> = self
            .order
            .iter()
            .filter(|s| self.hidden.contains(s))
            .map(|s| s.id())
            .collect();
        format!("{}|{}", order.join(","), hidden.join(","))
    }

    /// Reads `encoded` back. Unknown identifiers are dropped, duplicates keep
    /// their first place, and a section the text does not mention joins at
    /// the end, visible.
    pub fn decode(text: Option<&str>) -> Layout {
        let Some(text) = text.filter(|t| !t.trim().is_empty()) else {
            return Layout::standard();
        };
        let mut parts = text.splitn(2, '|');
        let order = sections_in(parts.next().unwrap_or(""));
        let hidden = parts.next().map(sections_in).unwrap_or_default();
        Layout::new(order, hidden.into_iter().collect())
    }
}

fn sections_in(list: &str) -> Vec<Section> {
    list.split(',')
        .filter_map(|id| Section::from_id(id.trim()))
        .collect()
}

fn completed(order: Vec<Section>) -> Vec<Section> {
    let mut seen = HashSet::new();
    order
        .into_iter()
        .chain(Section::ALL)
        .filter(|section| seen.insert(*section))
        .collect()
}

/// What leads Home. See `HomeHero` in Swift.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hero {
    Resume,
    UpNext,
    DayOne,
    Empty,
}

/// The facts Home is composed from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Availability {
    pub library_track_count: usize,
    pub has_listening_history: bool,
    pub is_playing: bool,
    pub can_resume: bool,
    pub jump_back_in_count: usize,
    pub recently_added_count: usize,
    pub has_on_this_day: bool,
    pub has_week_plays: bool,
}

/// One row of Home: a section on its own, or two neighbouring compact
/// sections side by side.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Block {
    Single(Section),
    Pair(Section, Section),
}

pub const JUMP_BACK_IN_LIMIT: usize = 6;
pub const MINIMUM_JUMP_BACK_IN: usize = 2;
pub const RECENTLY_ADDED_LIMIT: usize = 12;

/// The suggested-playlist identifiers in the order the hero prefers them.
pub const HERO_MIX_PREFERENCE: [&str; 5] = [
    "tonights-spin",
    "heavy-rotation",
    "on-repeat",
    "rediscover",
    "crate-dig",
];

pub fn hero(facts: &Availability) -> Hero {
    if facts.library_track_count == 0 {
        return Hero::Empty;
    }
    if !facts.is_playing && facts.can_resume {
        return Hero::Resume;
    }
    if facts.has_listening_history {
        Hero::UpNext
    } else {
        Hero::DayOne
    }
}

pub fn shows(section: Section, facts: &Availability) -> bool {
    match section {
        Section::Resume => hero(facts) != Hero::Empty,
        Section::JumpBackIn => facts.jump_back_in_count >= MINIMUM_JUMP_BACK_IN,
        Section::MadeForYou => facts.library_track_count > 0,
        Section::RecentlyAdded => facts.recently_added_count > 0,
        Section::OnThisDay => facts.has_on_this_day,
        Section::ThisWeek => facts.has_week_plays,
    }
}

/// The visible sections that have something to show, neighbouring compact
/// sections paired from the top down.
pub fn blocks(layout: &Layout, facts: &Availability) -> Vec<Block> {
    let sections: Vec<Section> = layout
        .visible()
        .into_iter()
        .filter(|section| shows(*section, facts))
        .collect();
    let mut blocks = Vec::new();
    let mut index = 0;
    while index < sections.len() {
        let section = sections[index];
        if section.is_compact() && index + 1 < sections.len() && sections[index + 1].is_compact() {
            blocks.push(Block::Pair(section, sections[index + 1]));
            index += 2;
        } else {
            blocks.push(Block::Single(section));
            index += 1;
        }
    }
    blocks
}

/// The first of `available` in `HERO_MIX_PREFERENCE` order, else the first
/// one offered.
pub fn hero_mix<'a>(available: &[&'a str]) -> Option<&'a str> {
    HERO_MIX_PREFERENCE
        .iter()
        .find_map(|preferred| available.iter().find(|id| *id == preferred).copied())
        .or_else(|| available.first().copied())
}

/// What a queue was started from. See `PlaybackContext` in Swift.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ContextKind {
    Album,
    Playlist,
    Mix,
    Radio,
    Queue,
}

impl ContextKind {
    pub fn id(self) -> &'static str {
        match self {
            ContextKind::Album => "album",
            ContextKind::Playlist => "playlist",
            ContextKind::Mix => "mix",
            ContextKind::Radio => "radio",
            ContextKind::Queue => "queue",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, serde::Serialize, serde::Deserialize)]
pub struct PlaybackContext {
    pub kind: ContextKind,
    pub id: String,
    pub title: String,
    pub subtitle: String,
}

impl PlaybackContext {
    pub fn anonymous_queue() -> PlaybackContext {
        PlaybackContext {
            kind: ContextKind::Queue,
            id: String::new(),
            title: String::new(),
            subtitle: String::new(),
        }
    }

    /// Unique across kinds.
    pub fn key(&self) -> String {
        format!("{}:{}", self.kind.id(), self.id)
    }

    /// An album when every `(album, credit)` entry shares one album title and
    /// credit (case-insensitively, ignoring surrounding space), otherwise a
    /// plain queue.
    pub fn derived(queue: &[(String, String)]) -> PlaybackContext {
        let Some((album, credit)) = queue.first() else {
            return PlaybackContext::anonymous_queue();
        };
        if fold(album).is_empty() {
            return PlaybackContext::anonymous_queue();
        }
        let key = album_key(album, credit);
        if !queue.iter().all(|(a, c)| album_key(a, c) == key) {
            return PlaybackContext::anonymous_queue();
        }
        PlaybackContext {
            kind: ContextKind::Album,
            id: key,
            title: album.clone(),
            subtitle: credit.clone(),
        }
    }
}

pub const KEY_SEPARATOR: char = '\u{1F}';

pub fn fold(text: &str) -> String {
    text.trim().to_lowercase()
}

pub fn album_key(title: &str, credit: &str) -> String {
    format!("{}{}{}", fold(title), KEY_SEPARATOR, fold(credit))
}

/// Where a paused session stands inside its queue.
#[derive(Clone, Debug, PartialEq)]
pub struct ResumePoint {
    pub track_index: usize,
    pub elapsed: f64,
    pub durations: Vec<f64>,
    pub saved_at: i64,
}

pub const RESUME_MAXIMUM_AGE: i64 = 14 * DAY;
pub const RESUME_FINISH_MARGIN: f64 = 10.0;
pub const RESUME_MAXIMUM_SEGMENTS: usize = 24;

impl ResumePoint {
    pub fn track_count(&self) -> usize {
        self.durations.len()
    }

    pub fn current_duration(&self) -> f64 {
        self.durations.get(self.track_index).copied().unwrap_or(0.0)
    }

    pub fn fraction_in_track(&self) -> f64 {
        let duration = self.current_duration();
        if duration <= 0.0 {
            return 0.0;
        }
        (self.elapsed / duration).clamp(0.0, 1.0)
    }

    pub fn remaining_seconds(&self) -> f64 {
        if self.track_index >= self.durations.len() {
            return 0.0;
        }
        let rest: f64 = self.durations[self.track_index + 1..].iter().sum();
        (self.current_duration() - self.elapsed).max(0.0) + rest
    }

    pub fn is_finished(&self) -> bool {
        if self.track_index >= self.durations.len() {
            return true;
        }
        self.track_index == self.durations.len() - 1
            && self.current_duration() - self.elapsed < RESUME_FINISH_MARGIN
    }

    pub fn is_resumable(&self, now: i64) -> bool {
        !self.is_finished() && now - self.saved_at <= RESUME_MAXIMUM_AGE
    }

    /// One fill fraction per track, or one segment holding the share of time
    /// already played when the queue is too long to segment.
    pub fn segments(&self) -> Vec<f64> {
        if self.track_index >= self.durations.len() {
            return Vec::new();
        }
        if self.durations.len() > RESUME_MAXIMUM_SEGMENTS {
            let total: f64 = self.durations.iter().sum();
            if total <= 0.0 {
                return vec![0.0];
            }
            return vec![((total - self.remaining_seconds()) / total).clamp(0.0, 1.0)];
        }
        (0..self.durations.len())
            .map(|index| match index.cmp(&self.track_index) {
                std::cmp::Ordering::Less => 1.0,
                std::cmp::Ordering::Greater => 0.0,
                std::cmp::Ordering::Equal => self.fraction_in_track(),
            })
            .collect()
    }
}

/// How long ago a session was paused. `Weekday` follows Foundation's
/// numbering: 1 is Sunday.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Recency {
    JustNow,
    EarlierToday,
    LastNight,
    Yesterday,
    Weekday(u32),
    Date(i64),
}

pub const JUST_NOW_WINDOW: i64 = 15 * 60;
pub const EVENING_STARTS_HOUR: u32 = 18;
pub const NIGHT_ENDS_HOUR: u32 = 5;

pub fn local(unix: i64, offset_seconds: i32) -> DateTime<FixedOffset> {
    let offset = FixedOffset::east_opt(offset_seconds).unwrap_or_else(|| FixedOffset::east_opt(0).unwrap());
    offset.timestamp_opt(unix, 0).single().unwrap_or_else(|| offset.timestamp_opt(0, 0).unwrap())
}

fn day_offset(from: NaiveDate, to: NaiveDate) -> i64 {
    (to - from).num_days()
}

pub fn recency(saved_at: i64, now: i64, offset_seconds: i32) -> Recency {
    if now - saved_at < JUST_NOW_WINDOW {
        return Recency::JustNow;
    }
    let saved = local(saved_at, offset_seconds);
    let current = local(now, offset_seconds);
    let days = day_offset(saved.date_naive(), current.date_naive());
    match days {
        i64::MIN..=0 => {
            if saved.hour() < NIGHT_ENDS_HOUR && current.hour() >= NIGHT_ENDS_HOUR {
                Recency::LastNight
            } else {
                Recency::EarlierToday
            }
        }
        1 => {
            if saved.hour() >= EVENING_STARTS_HOUR {
                Recency::LastNight
            } else {
                Recency::Yesterday
            }
        }
        2..=6 => Recency::Weekday(saved.weekday().number_from_sunday()),
        _ => Recency::Date(saved_at),
    }
}

/// The albums, playlists, mixes and radios the person started, newest first.
#[derive(Clone, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RecentContexts {
    pub entries: Vec<RecentEntry>,
    /// Things the person took off Jump Back In, by key, with when (unix). A
    /// play after that moment brings the thing back.
    #[serde(default)]
    pub dismissed: BTreeMap<String, i64>,
}

#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct RecentEntry {
    pub context: PlaybackContext,
    pub played_at: i64,
}

pub const RECENT_CAPACITY: usize = 24;

impl RecentContexts {
    /// Puts `context` first, dropping an older entry for the same thing and
    /// any dismissal of it. A plain queue names nothing to go back to and is
    /// ignored.
    pub fn recording(&self, context: PlaybackContext, at: i64) -> RecentContexts {
        if context.kind == ContextKind::Queue {
            return self.clone();
        }
        let key = context.key();
        let mut entries = vec![RecentEntry {
            context,
            played_at: at,
        }];
        entries.extend(self.entries.iter().filter(|e| e.context.key() != key).cloned());
        entries.truncate(RECENT_CAPACITY);
        let mut dismissed = self.dismissed.clone();
        dismissed.remove(&key);
        RecentContexts { entries, dismissed }
    }

    /// Takes the thing off Jump Back In until it is played again.
    pub fn dismissing(&self, key: &str, at: i64) -> RecentContexts {
        let mut dismissed = self.dismissed.clone();
        dismissed.insert(key.to_string(), at);
        RecentContexts {
            entries: self
                .entries
                .iter()
                .filter(|e| e.context.key() != key)
                .cloned()
                .collect(),
            dismissed,
        }
    }
}

/// Distinct contexts by `played_at`, newest first (a recorded entry wins a tie
/// with a history album), without the keys in `excluding` or played no later
/// than their dismissal, at most `limit`.
pub fn jump_back_in(
    recents: &[RecentEntry],
    history: &[RecentEntry],
    excluding: &HashSet<String>,
    dismissed: &BTreeMap<String, i64>,
    limit: usize,
) -> Vec<PlaybackContext> {
    let mut merged: Vec<(usize, u8, &RecentEntry)> = recents
        .iter()
        .map(|e| (0u8, e))
        .chain(history.iter().map(|e| (1u8, e)))
        .enumerate()
        .map(|(offset, (source, entry))| (offset, source, entry))
        .collect();
    merged.sort_by(|a, b| {
        b.2.played_at
            .cmp(&a.2.played_at)
            .then(a.1.cmp(&b.1))
            .then(a.0.cmp(&b.0))
    });
    let mut seen = excluding.clone();
    let mut picked = Vec::new();
    for (_, _, entry) in merged {
        if picked.len() >= limit {
            break;
        }
        let key = entry.context.key();
        if dismissed.get(&key).is_some_and(|at| entry.played_at <= *at) {
            continue;
        }
        if entry.context.kind == ContextKind::Queue || !seen.insert(key) {
            continue;
        }
        picked.push(entry.context.clone());
    }
    picked
}

/// One play as Home's history cards read it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HomePlay {
    pub album: String,
    pub artist: String,
    pub at: i64,
    pub seconds: i64,
}

/// Plays stamped before 2002-01-01 UTC belong to no day.
pub const EARLIEST_DATED: i64 = 1_009_843_200;

impl HomePlay {
    pub fn is_dated(&self) -> bool {
        self.at >= EARLIEST_DATED
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OnThisDayKind {
    SameDay,
    YearAgoThisWeek,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct OnThisDayPick {
    pub kind: OnThisDayKind,
    pub album: String,
    pub artist: String,
    pub year: i32,
    pub plays: usize,
    pub last_played_at: i64,
}

pub const ON_THIS_DAY_MINIMUM_PLAYS: usize = 3;
pub const ON_THIS_DAY_WEEK_SPAN_DAYS: i64 = 3;

/// The album played most on today's date in an earlier year, or failing that
/// around this date a year ago.
pub fn on_this_day(plays: &[HomePlay], now: i64, offset_seconds: i32) -> Option<OnThisDayPick> {
    let today = local(now, offset_seconds);
    let same_day: Vec<&HomePlay> = plays
        .iter()
        .filter(|play| {
            if !play.is_dated() || fold(&play.album).is_empty() {
                return false;
            }
            let at = local(play.at, offset_seconds);
            at.month() == today.month() && at.day() == today.day() && at.year() < today.year()
        })
        .collect();
    if let Some(best) = strongest(&same_day, OnThisDayKind::SameDay, true, offset_seconds) {
        return Some(best);
    }
    let anchor = year_ago(today.date_naive());
    let week: Vec<&HomePlay> = plays
        .iter()
        .filter(|play| {
            if !play.is_dated() || fold(&play.album).is_empty() {
                return false;
            }
            let day = local(play.at, offset_seconds).date_naive();
            day_offset(anchor, day).abs() <= ON_THIS_DAY_WEEK_SPAN_DAYS
        })
        .collect();
    strongest(&week, OnThisDayKind::YearAgoThisWeek, false, offset_seconds)
}

fn year_ago(date: NaiveDate) -> NaiveDate {
    date.with_year(date.year() - 1)
        .or_else(|| NaiveDate::from_ymd_opt(date.year() - 1, date.month(), 28))
        .unwrap_or(date)
}

fn strongest(
    plays: &[&HomePlay],
    kind: OnThisDayKind,
    by_year: bool,
    offset_seconds: i32,
) -> Option<OnThisDayPick> {
    let mut groups: HashMap<String, (usize, &HomePlay)> = HashMap::new();
    for play in plays {
        let year = local(play.at, offset_seconds).year();
        let prefix = if by_year { year.to_string() } else { String::new() };
        let key = format!("{}{}{}", prefix, KEY_SEPARATOR, album_key(&play.album, &play.artist));
        groups
            .entry(key)
            .and_modify(|(count, latest)| {
                *count += 1;
                if play.at > latest.at {
                    *latest = play;
                }
            })
            .or_insert((1, play));
    }
    let mut ranked: Vec<(String, usize, &HomePlay)> = groups
        .into_iter()
        .filter(|(_, (count, _))| *count >= ON_THIS_DAY_MINIMUM_PLAYS)
        .map(|(key, (count, latest))| (key, count, latest))
        .collect();
    ranked.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then(b.2.at.cmp(&a.2.at))
            .then(a.0.cmp(&b.0))
    });
    let (_, count, latest) = ranked.into_iter().next()?;
    Some(OnThisDayPick {
        kind,
        album: latest.album.clone(),
        artist: latest.artist.clone(),
        year: local(latest.at, offset_seconds).year(),
        plays: count,
        last_played_at: latest.at,
    })
}

/// This Week on Home: the rolling seven days against the seven before, and
/// plays per calendar day for the spark, today last.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WeekGlance {
    pub plays: i64,
    pub seconds: i64,
    pub previous_plays: i64,
    pub previous_seconds: i64,
    pub daily: [i64; 7],
}

pub const WEEK_WINDOW: i64 = 7 * DAY;

impl WeekGlance {
    pub fn plays_delta(&self) -> PeriodDelta {
        PeriodDelta::compare(self.plays, self.previous_plays)
    }

    pub fn seconds_delta(&self) -> PeriodDelta {
        PeriodDelta::compare(self.seconds, self.previous_seconds)
    }

    pub fn has_plays(&self) -> bool {
        self.plays > 0 || self.previous_plays > 0
    }

    /// The busiest day of the spark, the latest when days tie.
    pub fn peak_index(&self) -> Option<usize> {
        let peak = *self.daily.iter().max()?;
        if peak <= 0 {
            return None;
        }
        self.daily.iter().rposition(|value| *value == peak)
    }

    /// Current window `[now - 7 d, now]`, previous `[now - 14 d, now - 7 d)`.
    pub fn compute(plays: &[HomePlay], now: i64, offset_seconds: i32) -> WeekGlance {
        let current_start = now - WEEK_WINDOW;
        let previous_start = now - 2 * WEEK_WINDOW;
        let today = local(now, offset_seconds).date_naive();
        let mut glance = WeekGlance {
            plays: 0,
            seconds: 0,
            previous_plays: 0,
            previous_seconds: 0,
            daily: [0; 7],
        };
        for play in plays.iter().filter(|p| p.is_dated() && p.at <= now) {
            if play.at >= current_start {
                glance.plays += 1;
                glance.seconds += play.seconds.max(0);
            } else if play.at >= previous_start {
                glance.previous_plays += 1;
                glance.previous_seconds += play.seconds.max(0);
            }
            let offset = day_offset(local(play.at, offset_seconds).date_naive(), today);
            if (0..7).contains(&offset) {
                glance.daily[(6 - offset) as usize] += 1;
            }
        }
        glance
    }
}

/// Whole hours and the minutes after them, both truncated.
pub fn hours_and_minutes(seconds: i64) -> (i64, i64) {
    let clamped = seconds.max(0);
    (clamped / 3600, (clamped % 3600) / 60)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;

    fn date(y: i32, m: u32, d: u32, h: u32, min: u32) -> i64 {
        Utc.with_ymd_and_hms(y, m, d, h, min, 0).unwrap().timestamp()
    }

    fn now() -> i64 {
        date(2026, 10, 25, 12, 0)
    }

    fn layout(text: &str) -> Layout {
        Layout::decode(Some(text))
    }

    #[test]
    fn l1_standard_encodes_every_section_and_nothing_hidden() {
        assert_eq!(
            Layout::standard().encoded(),
            "continue,jumpBackIn,onThisDay,thisWeek,madeForYou,recentlyAdded|"
        );
        assert!(Layout::standard().is_standard());
    }

    #[test]
    fn l2_missing_or_blank_text_is_the_standard_layout() {
        assert_eq!(Layout::decode(None), Layout::standard());
        assert_eq!(Layout::decode(Some("")), Layout::standard());
        assert_eq!(Layout::decode(Some("  ")), Layout::standard());
    }

    #[test]
    fn l3_decode_keeps_the_order_and_appends_unmentioned_sections() {
        let l = layout("thisWeek,continue|thisWeek");
        assert_eq!(
            l.order(),
            &[
                Section::ThisWeek,
                Section::Resume,
                Section::JumpBackIn,
                Section::OnThisDay,
                Section::MadeForYou,
                Section::RecentlyAdded
            ]
        );
        assert_eq!(l.hidden(), &HashSet::from([Section::ThisWeek]));
        assert_eq!(
            l.visible(),
            vec![
                Section::Resume,
                Section::JumpBackIn,
                Section::OnThisDay,
                Section::MadeForYou,
                Section::RecentlyAdded
            ]
        );
    }

    #[test]
    fn l4_unknown_identifiers_and_duplicates_are_dropped() {
        let l = layout("bogus,madeForYou,madeForYou|bogus,continue");
        assert_eq!(
            l.order(),
            &[
                Section::MadeForYou,
                Section::Resume,
                Section::JumpBackIn,
                Section::OnThisDay,
                Section::ThisWeek,
                Section::RecentlyAdded
            ]
        );
        assert_eq!(l.hidden(), &HashSet::from([Section::Resume]));
    }

    #[test]
    fn l5_moves_clamp_to_either_end() {
        assert_eq!(Layout::standard().moving(0, 99).order().last(), Some(&Section::Resume));
        assert_eq!(Layout::standard().moving(5, -3).order().first(), Some(&Section::RecentlyAdded));
        assert_eq!(Layout::standard().moving(9, 0), Layout::standard());
    }

    #[test]
    fn l6_hiding_round_trips_and_showing_again_restores_the_standard() {
        let hidden = Layout::standard().setting(Section::OnThisDay, false);
        assert_eq!(
            hidden.encoded(),
            "continue,jumpBackIn,onThisDay,thisWeek,madeForYou,recentlyAdded|onThisDay"
        );
        assert_eq!(Layout::decode(Some(&hidden.encoded())), hidden);
        assert_eq!(hidden.setting(Section::OnThisDay, true), Layout::standard());
    }

    fn facts() -> Availability {
        Availability {
            library_track_count: 100,
            has_listening_history: true,
            is_playing: false,
            can_resume: true,
            jump_back_in_count: 6,
            recently_added_count: 12,
            has_on_this_day: true,
            has_week_plays: true,
        }
    }

    #[test]
    fn c1_an_empty_library_has_no_hero() {
        let f = Availability {
            library_track_count: 0,
            ..facts()
        };
        assert_eq!(hero(&f), Hero::Empty);
        assert!(!shows(Section::Resume, &f));
        assert!(!shows(Section::MadeForYou, &f));
    }

    #[test]
    fn c2_playing_offers_the_next_decision() {
        assert_eq!(hero(&Availability { is_playing: true, ..facts() }), Hero::UpNext);
        assert_eq!(
            hero(&Availability {
                is_playing: true,
                has_listening_history: false,
                ..facts()
            }),
            Hero::DayOne
        );
    }

    #[test]
    fn c3_a_paused_resumable_session_leads() {
        assert_eq!(hero(&facts()), Hero::Resume);
    }

    #[test]
    fn c4_nothing_to_resume_falls_back_on_history() {
        assert_eq!(hero(&Availability { can_resume: false, ..facts() }), Hero::UpNext);
        assert_eq!(
            hero(&Availability {
                can_resume: false,
                has_listening_history: false,
                ..facts()
            }),
            Hero::DayOne
        );
    }

    #[test]
    fn c5_the_standard_layout_pairs_on_this_day_with_this_week() {
        assert_eq!(
            blocks(&Layout::standard(), &facts()),
            vec![
                Block::Single(Section::Resume),
                Block::Single(Section::JumpBackIn),
                Block::Pair(Section::OnThisDay, Section::ThisWeek),
                Block::Single(Section::MadeForYou),
                Block::Single(Section::RecentlyAdded),
            ]
        );
    }

    #[test]
    fn c6_sections_with_nothing_to_show_stay_out() {
        let f = Availability {
            jump_back_in_count: 1,
            recently_added_count: 0,
            has_on_this_day: false,
            ..facts()
        };
        assert_eq!(
            blocks(&Layout::standard(), &f),
            vec![
                Block::Single(Section::Resume),
                Block::Single(Section::ThisWeek),
                Block::Single(Section::MadeForYou),
            ]
        );
    }

    #[test]
    fn c7_compact_sections_pair_only_when_neighbours() {
        let l = layout("onThisDay,recentlyAdded,thisWeek,continue,jumpBackIn,madeForYou|");
        assert_eq!(
            blocks(&l, &facts()),
            vec![
                Block::Single(Section::OnThisDay),
                Block::Single(Section::RecentlyAdded),
                Block::Single(Section::ThisWeek),
                Block::Single(Section::Resume),
                Block::Single(Section::JumpBackIn),
                Block::Single(Section::MadeForYou),
            ]
        );
        let between = layout("onThisDay,recentlyAdded,thisWeek|recentlyAdded");
        assert_eq!(
            blocks(&between, &facts()).first(),
            Some(&Block::Pair(Section::OnThisDay, Section::ThisWeek))
        );
    }

    #[test]
    fn c8_hero_mix_follows_the_preference() {
        assert_eq!(hero_mix(&["crate-dig", "heavy-rotation"]), Some("heavy-rotation"));
        assert_eq!(hero_mix(&["tonights-spin", "crate-dig"]), Some("tonights-spin"));
        assert_eq!(hero_mix(&["something-new"]), Some("something-new"));
        assert_eq!(hero_mix(&[]), None);
    }

    fn entry(album: &str, credit: &str) -> (String, String) {
        (album.to_string(), credit.to_string())
    }

    #[test]
    fn p1_a_queue_from_one_album_names_the_album() {
        let context = PlaybackContext::derived(&[
            entry("Field Lines", "Meridian Wolde"),
            entry(" field lines ", "MERIDIAN WOLDE"),
        ]);
        assert_eq!(context.kind, ContextKind::Album);
        assert_eq!(context.id, "field lines\u{1F}meridian wolde");
        assert_eq!(context.title, "Field Lines");
        assert_eq!(context.subtitle, "Meridian Wolde");
        assert_eq!(context.key(), "album:field lines\u{1F}meridian wolde");
    }

    #[test]
    fn p2_anything_else_is_an_anonymous_queue() {
        assert_eq!(
            PlaybackContext::derived(&[entry("Field Lines", "Meridian Wolde"), entry("Statuary", "Ashgrove")]),
            PlaybackContext::anonymous_queue()
        );
        assert_eq!(PlaybackContext::derived(&[]), PlaybackContext::anonymous_queue());
        assert_eq!(
            PlaybackContext::derived(&[entry("  ", "Someone")]),
            PlaybackContext::anonymous_queue()
        );
    }

    fn point(index: usize, elapsed: f64, durations: Vec<f64>, saved_at: i64) -> ResumePoint {
        ResumePoint {
            track_index: index,
            elapsed,
            durations,
            saved_at,
        }
    }

    #[test]
    fn r1_remaining_time_and_segments() {
        let p = point(1, 120.0, vec![200.0, 300.0, 100.0], now());
        assert!((p.remaining_seconds() - 280.0).abs() < 1e-4);
        assert!((p.fraction_in_track() - 0.4).abs() < 1e-4);
        assert_eq!(p.segments(), vec![1.0, 0.4, 0.0]);
        assert_eq!(p.track_count(), 3);
    }

    #[test]
    fn r2_the_last_seconds_of_the_last_track_count_as_finished() {
        assert!(point(2, 95.0, vec![200.0, 300.0, 100.0], now()).is_finished());
        assert!(!point(2, 80.0, vec![200.0, 300.0, 100.0], now()).is_finished());
        assert!(!point(2, 95.0, vec![200.0, 300.0, 100.0], now()).is_resumable(now()));
    }

    #[test]
    fn r3_a_session_older_than_fourteen_days_is_history() {
        assert!(point(0, 10.0, vec![200.0, 300.0], now() - 14 * DAY).is_resumable(now()));
        assert!(!point(0, 10.0, vec![200.0, 300.0], now() - 15 * DAY).is_resumable(now()));
    }

    #[test]
    fn r4_a_long_queue_draws_one_continuous_segment() {
        let p = point(10, 50.0, vec![100.0; 25], now());
        let segments = p.segments();
        assert_eq!(segments.len(), 1);
        assert!((segments[0] - 0.42).abs() < 1e-4);
    }

    #[test]
    fn r5_an_index_outside_the_queue_has_nothing_to_resume() {
        let p = point(4, 0.0, vec![100.0, 100.0], now());
        assert!(p.segments().is_empty());
        assert_eq!(p.remaining_seconds(), 0.0);
        assert!(p.is_finished());
    }

    #[test]
    fn t1_recency_words() {
        assert_eq!(recency(now() - 600, now(), 0), Recency::JustNow);
        assert_eq!(recency(date(2026, 10, 25, 8, 0), now(), 0), Recency::EarlierToday);
        assert_eq!(recency(date(2026, 10, 25, 2, 0), now(), 0), Recency::LastNight);
        assert_eq!(recency(date(2026, 10, 24, 23, 40), now(), 0), Recency::LastNight);
        assert_eq!(recency(date(2026, 10, 24, 14, 0), now(), 0), Recency::Yesterday);
        assert_eq!(recency(date(2026, 10, 21, 10, 0), now(), 0), Recency::Weekday(4));
        let old = date(2026, 10, 10, 9, 0);
        assert_eq!(recency(old, now(), 0), Recency::Date(old));
        assert_eq!(
            recency(date(2026, 10, 25, 1, 0), date(2026, 10, 25, 3, 0), 0),
            Recency::EarlierToday
        );
    }

    fn album(name: &str) -> PlaybackContext {
        PlaybackContext {
            kind: ContextKind::Album,
            id: name.to_string(),
            title: name.to_string(),
            subtitle: String::new(),
        }
    }

    fn at(seconds: i64) -> i64 {
        1_800_000_000 + seconds
    }

    #[test]
    fn rc1_recording_puts_the_context_first_once_and_ignores_plain_queues() {
        let recents = RecentContexts::default()
            .recording(album("a"), at(1))
            .recording(album("b"), at(2))
            .recording(album("a"), at(3))
            .recording(PlaybackContext::anonymous_queue(), at(4));
        let ids: Vec<&str> = recents.entries.iter().map(|e| e.context.id.as_str()).collect();
        assert_eq!(ids, vec!["a", "b"]);
        assert_eq!(recents.entries[0].played_at, at(3));
        let removed = recents.dismissing("album:a", at(5));
        assert_eq!(removed.entries.len(), 1);
        assert_eq!(removed.entries[0].context.id, "b");
    }

    #[test]
    fn rc3_a_dismissal_hides_older_plays_until_the_next_one() {
        let recents = RecentContexts::default()
            .recording(album("b"), at(2))
            .dismissing("album:c", at(90));
        let history = vec![recent("c", 80), recent("d", 70)];
        let ids = |picked: Vec<PlaybackContext>| picked.into_iter().map(|c| c.id).collect::<Vec<_>>();
        assert_eq!(
            ids(jump_back_in(&recents.entries, &history, &HashSet::new(), &recents.dismissed, JUMP_BACK_IN_LIMIT)),
            vec!["d", "b"]
        );
        let later = vec![recent("c", 95)];
        assert_eq!(
            ids(jump_back_in(&recents.entries, &later, &HashSet::new(), &recents.dismissed, JUMP_BACK_IN_LIMIT)),
            vec!["c", "b"]
        );
        assert!(!recents.recording(album("c"), at(100)).dismissed.contains_key("album:c"));
    }

    #[test]
    fn rc4_lists_saved_before_dismissals_existed_still_decode() {
        let decoded: RecentContexts = serde_json::from_str(r#"{"entries":[]}"#).unwrap();
        assert_eq!(decoded, RecentContexts::default());
    }

    #[test]
    fn rc2_capacity_keeps_the_newest() {
        let mut recents = RecentContexts::default();
        for index in 0..30 {
            recents = recents.recording(album(&format!("x{index}")), at(index));
        }
        assert_eq!(recents.entries.len(), RECENT_CAPACITY);
        assert_eq!(recents.entries.first().unwrap().context.id, "x29");
        assert_eq!(recents.entries.last().unwrap().context.id, "x6");
    }

    fn recent(name: &str, seconds: i64) -> RecentEntry {
        RecentEntry {
            context: album(name),
            played_at: at(seconds),
        }
    }

    #[test]
    fn j1_jump_back_in_merges_newest_first_and_recorded_wins_ties() {
        let recents = vec![recent("a", 100), recent("b", 50)];
        let history = vec![recent("c", 80), recent("a", 10), recent("d", 50)];
        let ids = |picked: Vec<PlaybackContext>| picked.into_iter().map(|c| c.id).collect::<Vec<_>>();
        assert_eq!(
            ids(jump_back_in(&recents, &history, &HashSet::new(), &BTreeMap::new(), JUMP_BACK_IN_LIMIT)),
            vec!["a", "c", "b", "d"]
        );
        assert_eq!(
            ids(jump_back_in(
                &recents,
                &history,
                &HashSet::from(["album:c".to_string()]),
                &BTreeMap::new(),
                JUMP_BACK_IN_LIMIT
            )),
            vec!["a", "b", "d"]
        );
        assert_eq!(ids(jump_back_in(&recents, &history, &HashSet::new(), &BTreeMap::new(), 2)), vec!["a", "c"]);
    }

    fn plays(album: &str, artist: &str, at: i64, count: i64) -> Vec<HomePlay> {
        (0..count)
            .map(|i| HomePlay {
                album: album.to_string(),
                artist: artist.to_string(),
                at: at + i * 60,
                seconds: 200,
            })
            .collect()
    }

    #[test]
    fn o1_the_most_played_album_on_this_date_in_an_earlier_year() {
        let mut history = plays("Midnatt", "Solveig", date(2023, 10, 25, 9, 0), 4);
        history.extend(plays("Statuary", "Ashgrove", date(2024, 10, 25, 9, 0), 3));
        history.extend(plays("Other", "Someone", date(2025, 10, 25, 9, 0), 2));
        let pick = on_this_day(&history, now(), 0).unwrap();
        assert_eq!(pick.kind, OnThisDayKind::SameDay);
        assert_eq!(pick.album, "Midnatt");
        assert_eq!(pick.year, 2023);
        assert_eq!(pick.plays, 4);
    }

    #[test]
    fn o2_equal_counts_go_to_the_more_recent_year() {
        let mut history = plays("A", "One", date(2023, 10, 25, 9, 0), 3);
        history.extend(plays("B", "Two", date(2024, 10, 25, 9, 0), 3));
        assert_eq!(on_this_day(&history, now(), 0).unwrap().album, "B");
    }

    #[test]
    fn o3_years_do_not_merge_and_a_year_ago_this_week_is_the_fallback() {
        let mut history = plays("A", "One", date(2022, 10, 25, 9, 0), 2);
        history.extend(plays("A", "One", date(2023, 10, 25, 9, 0), 2));
        history.extend(plays("Week", "Three", date(2025, 10, 23, 20, 0), 3));
        history.extend(plays("Far", "Four", date(2025, 10, 30, 20, 0), 5));
        let pick = on_this_day(&history, now(), 0).unwrap();
        assert_eq!(pick.kind, OnThisDayKind::YearAgoThisWeek);
        assert_eq!(pick.album, "Week");
        assert_eq!(pick.year, 2025);
        assert_eq!(pick.plays, 3);
    }

    #[test]
    fn o4_this_years_plays_are_not_a_day_to_remember() {
        assert_eq!(on_this_day(&plays("Now", "Five", date(2026, 10, 25, 9, 0), 5), now(), 0), None);
    }

    #[test]
    fn o5_undated_and_untitled_plays_are_ignored() {
        let mut history = plays("Zero", "Six", 0, 5);
        history.extend(plays("", "Seven", date(2023, 10, 25, 9, 0), 5));
        assert_eq!(on_this_day(&history, now(), 0), None);
    }

    #[test]
    fn o6_names_come_from_the_latest_play_of_the_group() {
        let mut history = plays("Midnatt", "Solveig", date(2023, 10, 25, 9, 0), 2);
        history.extend(plays("MIDNATT", "Solveig", date(2023, 10, 25, 20, 0), 1));
        let pick = on_this_day(&history, now(), 0).unwrap();
        assert_eq!(pick.album, "MIDNATT");
        assert_eq!(pick.plays, 3);
        assert_eq!(pick.last_played_at, date(2023, 10, 25, 20, 0));
    }

    fn play(at: i64, seconds: i64) -> HomePlay {
        HomePlay {
            album: "a".to_string(),
            artist: "a".to_string(),
            at,
            seconds,
        }
    }

    #[test]
    fn w1_windows_daily_buckets_and_deltas() {
        let n = now();
        let entries = vec![
            play(n - 3600, 200),
            play(n - 2 * DAY, 300),
            play(n - (6 * DAY + 23 * 3600), 100),
            play(n - 7 * DAY, 50),
            play(n - 8 * DAY, 60),
            play(n - 13 * DAY, 70),
            play(n - 14 * DAY, 80),
            play(n - 15 * DAY, 90),
            play(n + 3600, 999),
            play(0, 999),
        ];
        let glance = WeekGlance::compute(&entries, n, 0);
        assert_eq!(glance.plays, 4);
        assert_eq!(glance.seconds, 650);
        assert_eq!(glance.previous_plays, 3);
        assert_eq!(glance.previous_seconds, 210);
        assert_eq!(glance.daily, [0, 0, 0, 0, 1, 0, 1]);
        assert_eq!(glance.peak_index(), Some(6));
        assert_eq!(glance.plays_delta(), PeriodDelta::Up(33));
        assert_eq!(glance.seconds_delta(), PeriodDelta::Up(210));
        assert!(glance.has_plays());
    }

    #[test]
    fn w2_hours_and_minutes_truncate() {
        assert_eq!(hours_and_minutes(51_600), (14, 20));
        assert_eq!(hours_and_minutes(59), (0, 0));
        assert_eq!(hours_and_minutes(-5), (0, 0));
    }

    #[test]
    fn w3_no_plays_means_nothing_to_show() {
        let glance = WeekGlance::compute(&[], now(), 0);
        assert!(!glance.has_plays());
        assert_eq!(glance.peak_index(), None);
        assert_eq!(glance.daily, [0; 7]);
    }
}
