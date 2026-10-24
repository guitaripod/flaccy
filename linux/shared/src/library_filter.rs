//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/LibraryFilterRules.swift` and
//! `PeriodDelta.swift`.
//!
//! The pure rules behind the desktop library chips (Recently Added, Recently
//! Played, Rediscover, Most Played) and the "vs the previous period" chip on
//! the Stats tiles. Everything takes `now` as an argument and returns ordered
//! ids, so the same vectors prove both languages.

use std::cmp::Ordering;

pub const DAY: i64 = 86_400;

/// How far back "recent" reaches for the Recently Added and Recently Played
/// chips.
pub const RECENT_WINDOW: i64 = 30 * DAY;

/// How many recent entries make a list worth showing on its own, and how many
/// of the newest to show instead when fewer than that qualify.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Thresholds {
    pub minimum: usize,
    pub fallback: usize,
}

pub const SONG_THRESHOLDS: Thresholds = Thresholds {
    minimum: 10,
    fallback: 40,
};

pub const ALBUM_THRESHOLDS: Thresholds = Thresholds {
    minimum: 6,
    fallback: 24,
};

/// An album must have gone this many whole days unheard to be worth
/// rediscovering.
pub const REDISCOVER_MIN_DAYS: i64 = 14;

/// ...and must have been played at least this often, so a one-off listen never
/// counts as a favourite.
pub const REDISCOVER_MIN_PLAYS: i64 = 2;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AddedEntry {
    pub id: String,
    pub date_added: i64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlayedEntry {
    pub id: String,
    pub last_played: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RediscoverEntry {
    pub id: String,
    pub plays: i64,
    pub last_played: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MostPlayedEntry {
    pub id: String,
    pub plays: i64,
    pub last_played: Option<i64>,
    pub title: String,
}

/// The newest additions: everything inside the recent window when that is
/// enough to fill a list, otherwise the newest `fallback` regardless of age.
pub fn recently_added(entries: &[AddedEntry], now: i64, thresholds: Thresholds) -> Vec<String> {
    let mut sorted: Vec<&AddedEntry> = entries.iter().collect();
    sorted.sort_by(|a, b| b.date_added.cmp(&a.date_added));
    let cutoff = now - RECENT_WINDOW;
    let recent: Vec<&AddedEntry> = sorted
        .iter()
        .copied()
        .filter(|entry| entry.date_added >= cutoff)
        .collect();
    let chosen = if recent.len() >= thresholds.minimum {
        recent
    } else {
        sorted.into_iter().take(thresholds.fallback).collect()
    };
    chosen.into_iter().map(|entry| entry.id.clone()).collect()
}

/// What was played lately: the played entries inside the recent window when
/// that is enough to fill a list, otherwise every played entry, newest first.
pub fn recently_played(entries: &[PlayedEntry], now: i64, thresholds: Thresholds) -> Vec<String> {
    let mut played: Vec<(&PlayedEntry, i64)> = entries
        .iter()
        .filter_map(|entry| entry.last_played.map(|at| (entry, at)))
        .collect();
    played.sort_by(|a, b| b.1.cmp(&a.1));
    let cutoff = now - RECENT_WINDOW;
    let recent_count = played.iter().filter(|(_, at)| *at >= cutoff).count();
    let chosen: Vec<&(&PlayedEntry, i64)> = if recent_count >= thresholds.minimum {
        played.iter().filter(|(_, at)| *at >= cutoff).collect()
    } else {
        played.iter().collect()
    };
    chosen
        .into_iter()
        .map(|(entry, _)| entry.id.clone())
        .collect()
}

/// Albums played often but not lately, ranked by a Longplay-style negligence
/// score of plays over days since the last play.
pub fn rediscover(entries: &[RediscoverEntry], now: i64) -> Vec<String> {
    let mut scored: Vec<(&str, f64)> = entries
        .iter()
        .filter_map(|entry| {
            let last = entry.last_played?;
            let days = (now - last).div_euclid(DAY);
            if days < REDISCOVER_MIN_DAYS || entry.plays < REDISCOVER_MIN_PLAYS {
                return None;
            }
            Some((entry.id.as_str(), entry.plays as f64 / (days + 1) as f64))
        })
        .collect();
    scored.sort_by(|a, b| {
        b.1.partial_cmp(&a.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| a.0.cmp(b.0))
    });
    scored.into_iter().map(|(id, _)| id.to_string()).collect()
}

/// The Most Played ranking: entries with no plays in the range drop out, the
/// rest run by plays, then by how recently they were last played (never-played
/// last), then by title.
pub fn most_played(entries: &[MostPlayedEntry]) -> Vec<String> {
    let mut ranked: Vec<&MostPlayedEntry> =
        entries.iter().filter(|entry| entry.plays > 0).collect();
    ranked.sort_by(|a, b| {
        b.plays
            .cmp(&a.plays)
            .then_with(|| b.last_played.cmp(&a.last_played))
            .then_with(|| a.title.to_lowercase().cmp(&b.title.to_lowercase()))
            .then_with(|| a.title.cmp(&b.title))
    });
    ranked.into_iter().map(|entry| entry.id.clone()).collect()
}

/// How a metric moved against the previous period of equal length.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PeriodDelta {
    None,
    Up(u32),
    Down(u32),
    Even,
    New,
}

/// The most a rise is allowed to read: past this a percentage stops meaning
/// anything a person can feel.
pub const MAX_RISE_PERCENT: u32 = 999;

impl PeriodDelta {
    pub fn compare(current: i64, previous: i64) -> PeriodDelta {
        if previous <= 0 {
            return if current <= 0 {
                PeriodDelta::None
            } else {
                PeriodDelta::New
            };
        }
        if current == previous {
            return PeriodDelta::Even;
        }
        let percent = ((current - previous) as f64 / previous as f64 * 100.0).round();
        if percent == 0.0 {
            return PeriodDelta::Even;
        }
        if current > previous {
            PeriodDelta::Up((percent as u32).min(MAX_RISE_PERCENT))
        } else {
            PeriodDelta::Down((percent.abs() as u32).min(100))
        }
    }

    /// The text of the chip, `None` when there is nothing worth saying.
    pub fn chip_text(self) -> Option<String> {
        match self {
            PeriodDelta::None => None,
            PeriodDelta::Up(percent) => Some(format!("▲ {percent}%")),
            PeriodDelta::Down(percent) => Some(format!("▼ {percent}%")),
            PeriodDelta::Even => Some("Even".to_string()),
            PeriodDelta::New => Some("New".to_string()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    fn added(id: &str, days_ago: i64) -> AddedEntry {
        AddedEntry {
            id: id.to_string(),
            date_added: NOW - days_ago * DAY,
        }
    }

    fn played(id: &str, days_ago: Option<i64>) -> PlayedEntry {
        PlayedEntry {
            id: id.to_string(),
            last_played: days_ago.map(|d| NOW - d * DAY),
        }
    }

    fn ids(prefix: &str, range: std::ops::RangeInclusive<usize>) -> Vec<String> {
        range.map(|n| format!("{prefix}{n}")).collect()
    }

    #[test]
    fn r1_recently_added_songs_reorder_newest_first() {
        let entries: Vec<AddedEntry> = (1..=12)
            .rev()
            .map(|k| added(&format!("s{k}"), k as i64))
            .collect();
        assert_eq!(
            recently_added(&entries, NOW, SONG_THRESHOLDS),
            ids("s", 1..=12)
        );
    }

    #[test]
    fn r2_recently_added_songs_fall_back_when_too_few_are_recent() {
        let mut entries: Vec<AddedEntry> = (1..=9).map(|k| added(&format!("s{k}"), k)).collect();
        entries.push(added("s10", 40));
        entries.push(added("s11", 50));
        entries.push(added("s12", 60));
        assert_eq!(
            recently_added(&entries, NOW, SONG_THRESHOLDS),
            ids("s", 1..=12)
        );
    }

    #[test]
    fn r3_recently_added_songs_keep_the_window_inclusive() {
        let entries: Vec<AddedEntry> = (1..=45).map(|k| added(&format!("s{k}"), k)).collect();
        assert_eq!(
            recently_added(&entries, NOW, SONG_THRESHOLDS),
            ids("s", 1..=30)
        );
    }

    #[test]
    fn r4_recently_added_songs_cap_the_fallback() {
        let entries: Vec<AddedEntry> = (1..=45).map(|k| added(&format!("s{k}"), 99 + k)).collect();
        assert_eq!(
            recently_added(&entries, NOW, SONG_THRESHOLDS),
            ids("s", 1..=40)
        );
    }

    #[test]
    fn r5_recently_played_songs_skip_the_never_played() {
        let entries = vec![
            played("p1", Some(1)),
            played("p2", Some(2)),
            played("p3", Some(3)),
            played("q1", None),
            played("q2", None),
        ];
        assert_eq!(
            recently_played(&entries, NOW, SONG_THRESHOLDS),
            ids("p", 1..=3)
        );
    }

    #[test]
    fn r6_recently_played_songs_drop_the_old_once_enough_are_recent() {
        let mut entries: Vec<PlayedEntry> = (1..=10)
            .map(|k| played(&format!("p{k}"), Some(k)))
            .collect();
        entries.push(played("o1", Some(50)));
        entries.push(played("o2", Some(60)));
        assert_eq!(
            recently_played(&entries, NOW, SONG_THRESHOLDS),
            ids("p", 1..=10)
        );
    }

    #[test]
    fn r7_recently_added_albums_use_their_own_minimum() {
        let mut entries: Vec<AddedEntry> = (1..=6).map(|k| added(&format!("a{k}"), k)).collect();
        entries.extend((0..5).map(|k| added(&format!("b{}", k + 1), 100 + k)));
        assert_eq!(
            recently_added(&entries, NOW, ALBUM_THRESHOLDS),
            ids("a", 1..=6)
        );
    }

    #[test]
    fn r8_recently_added_albums_cap_the_fallback_at_twenty_four() {
        let mut entries: Vec<AddedEntry> = (1..=5).map(|k| added(&format!("a{k}"), k)).collect();
        entries.extend((0..30).map(|k| added(&format!("b{}", k + 1), 100 + k)));
        let mut expected = ids("a", 1..=5);
        expected.extend(ids("b", 1..=19));
        assert_eq!(recently_added(&entries, NOW, ALBUM_THRESHOLDS), expected);
    }

    fn candidate(id: &str, plays: i64, days_ago: Option<i64>) -> RediscoverEntry {
        RediscoverEntry {
            id: id.to_string(),
            plays,
            last_played: days_ago.map(|d| NOW - d * DAY),
        }
    }

    #[test]
    fn r9_rediscover_ranks_by_negligence() {
        let entries = vec![
            candidate("A", 10, Some(20)),
            candidate("B", 5, Some(14)),
            candidate("C", 1, Some(40)),
            candidate("D", 9, Some(13)),
            candidate("E", 30, Some(100)),
            candidate("F", 3, None),
        ];
        assert_eq!(rediscover(&entries, NOW), vec!["A", "B", "E"]);
    }

    fn ranked(id: &str, plays: i64, days_ago: Option<i64>, title: &str) -> MostPlayedEntry {
        MostPlayedEntry {
            id: id.to_string(),
            plays,
            last_played: days_ago.map(|d| NOW - d * DAY),
            title: title.to_string(),
        }
    }

    #[test]
    fn r10_most_played_orders_by_plays_then_recency() {
        let entries = vec![
            ranked("x", 3, Some(5), "b"),
            ranked("y", 3, Some(2), "a"),
            ranked("z", 5, Some(9), "c"),
            ranked("w", 0, Some(1), "d"),
            ranked("v", 3, None, "e"),
        ];
        assert_eq!(most_played(&entries), vec!["z", "y", "x", "v"]);
    }

    #[test]
    fn most_played_breaks_a_full_tie_on_title_without_regard_to_case() {
        let entries = vec![
            ranked("1", 2, Some(1), "Beta"),
            ranked("2", 2, Some(1), "alpha"),
        ];
        assert_eq!(most_played(&entries), vec!["2", "1"]);
    }

    #[test]
    fn d1_to_d8_period_delta_vectors() {
        assert_eq!(PeriodDelta::compare(56, 50), PeriodDelta::Up(12));
        assert_eq!(PeriodDelta::compare(50, 56), PeriodDelta::Down(11));
        assert_eq!(PeriodDelta::compare(5, 0), PeriodDelta::New);
        assert_eq!(PeriodDelta::compare(0, 0), PeriodDelta::None);
        assert_eq!(PeriodDelta::compare(7, 7), PeriodDelta::Even);
        assert_eq!(PeriodDelta::compare(1001, 1000), PeriodDelta::Even);
        assert_eq!(PeriodDelta::compare(4000, 100), PeriodDelta::Up(999));
        assert_eq!(PeriodDelta::compare(0, 10), PeriodDelta::Down(100));
    }

    #[test]
    fn chip_text_reads_the_way_the_apple_clients_do() {
        assert_eq!(PeriodDelta::Up(12).chip_text().as_deref(), Some("▲ 12%"));
        assert_eq!(PeriodDelta::Down(11).chip_text().as_deref(), Some("▼ 11%"));
        assert_eq!(PeriodDelta::New.chip_text().as_deref(), Some("New"));
        assert_eq!(PeriodDelta::Even.chip_text().as_deref(), Some("Even"));
        assert_eq!(PeriodDelta::None.chip_text(), None);
    }
}
