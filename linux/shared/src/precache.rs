//! What Flaccy prepares ahead of time and what it gives up to make room: the
//! lyrics and music videos a person is likely to want before they ask. Pure
//! functions over plain values, so the choice is testable without a network,
//! a disk or a clock.

/// Entries ahead of the playing one whose video file is fetched in full.
pub const FULL_QUEUE_DEPTH: usize = 3;
/// Entries ahead of the playing one whose video is matched and aligned.
pub const MATCH_QUEUE_DEPTH: usize = 10;
/// Entries ahead of the playing one whose lyrics are fetched.
pub const LYRICS_QUEUE_DEPTH: usize = 50;
/// Songs outside the queue whose video is prepared on the strength of habit.
pub const HABIT_LIMIT: usize = 200;
/// How much likelier a wanted song must be than the one it would evict.
pub const REPLACE_MARGIN: f64 = 1.5;
/// A file this young is never evicted, so a fill cannot undo itself.
pub const FRESH_GRACE_SECONDS: i64 = 24 * 60 * 60;
/// The disk space prepared files never eat into, in bytes, and as a share of
/// the disk.
pub const FREE_FLOOR_BYTES: u64 = 5 * 1024 * 1024 * 1024;
pub const FREE_FLOOR_SHARE: f64 = 0.05;

/// Where a song stands against the listener's habits and the queue.
#[derive(Clone, Debug, PartialEq)]
pub struct Candidate {
    pub key: String,
    /// Places ahead of the playing song, `None` when it is not queued.
    pub queue_distance: Option<usize>,
    /// Another track of the album that is playing.
    pub album_sibling: bool,
    pub plays_30_days: i64,
    pub plays_total: i64,
    pub days_since_played: Option<f64>,
    pub days_since_added: f64,
}

/// How far a song's video is prepared.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tier {
    /// The video file itself, on disk.
    File,
    /// Its match decided and its alignment done, no video bytes.
    Match,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Wanted {
    pub key: String,
    pub tier: Tier,
    pub chance: f64,
}

/// How likely the song is to play soon, from 0 to 1: the queue says it
/// plainly, the rest of an album in progress says it fairly, and habit says
/// it by degrees.
pub fn chance_of_play(candidate: &Candidate) -> f64 {
    let queued = candidate
        .queue_distance
        .map_or(0.0, |distance| 1.0 / (1.0 + 0.35 * distance as f64));
    let sibling = if candidate.album_sibling { 0.3 } else { 0.0 };
    let recent = candidate
        .days_since_played
        .is_some_and(|days| days <= 7.0);
    let habit = 0.5 * (1.0 - (-(candidate.plays_30_days as f64) / 6.0).exp())
        + if recent { 0.1 } else { 0.0 }
        + 0.05 * (1.0 - (-(candidate.plays_total as f64) / 20.0).exp());
    queued.max(sibling).max(habit).min(1.0)
}

/// The songs whose video to prepare, likeliest first. The playing song
/// (distance 0) is the live path's business, not this one's.
pub fn wanted_videos(candidates: &[Candidate]) -> Vec<Wanted> {
    let mut wanted: Vec<(Wanted, bool)> = candidates
        .iter()
        .filter_map(|candidate| {
            let chance = chance_of_play(candidate);
            let upcoming = candidate.queue_distance.filter(|distance| *distance > 0);
            let tier = match upcoming {
                Some(distance) if distance <= FULL_QUEUE_DEPTH => Tier::File,
                Some(distance) if distance <= MATCH_QUEUE_DEPTH => Tier::Match,
                _ if candidate.queue_distance == Some(0) => return None,
                _ if candidate.album_sibling => Tier::Match,
                _ if chance >= 0.25 => Tier::File,
                _ => return None,
            };
            let in_view = candidate.queue_distance.is_some() || candidate.album_sibling;
            Some((
                Wanted {
                    key: candidate.key.clone(),
                    tier,
                    chance,
                },
                in_view,
            ))
        })
        .collect();
    wanted.sort_by(|a, b| b.0.chance.total_cmp(&a.0.chance).then(a.0.key.cmp(&b.0.key)));
    let mut habit = 0usize;
    wanted
        .into_iter()
        .filter(|(_, in_view)| {
            if *in_view {
                return true;
            }
            habit += 1;
            habit <= HABIT_LIMIT
        })
        .map(|(entry, _)| entry)
        .collect()
}

/// The songs whose lyrics to fetch, most wanted first. With `whole_library`
/// every song is eventually asked about; without, only the queue and what the
/// listener plays.
pub fn lyrics_order(candidates: &[Candidate], whole_library: bool) -> Vec<String> {
    let mut scored: Vec<(f64, &str)> = candidates
        .iter()
        .filter_map(|candidate| {
            let queued = candidate
                .queue_distance
                .is_some_and(|distance| distance <= LYRICS_QUEUE_DEPTH);
            let played = candidate.plays_30_days >= 1 || candidate.plays_total >= 3;
            if !queued && !played && !candidate.album_sibling && !whole_library {
                return None;
            }
            let queue_bonus = candidate
                .queue_distance
                .filter(|distance| *distance <= LYRICS_QUEUE_DEPTH)
                .map_or(0.0, |distance| 100.0 / (1.0 + distance as f64));
            let fresh = if candidate.days_since_added <= 14.0 { 5.0 } else { 0.0 };
            let score = queue_bonus
                + 10.0 * (1.0 + candidate.plays_30_days as f64).ln()
                + 3.0 * (1.0 + candidate.plays_total as f64).ln()
                + fresh
                + if candidate.album_sibling { 8.0 } else { 0.0 };
            Some((score, candidate.key.as_str()))
        })
        .collect();
    scored.sort_by(|a, b| b.0.total_cmp(&a.0).then(a.1.cmp(b.1)));
    scored.into_iter().map(|(_, key)| key.to_string()).collect()
}

/// A prepared video file as the cache sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct Held {
    pub id: String,
    pub bytes: u64,
    pub pinned: bool,
    /// How likely a song that uses this video is to play soon, 0 when no
    /// song in view does or the file was made for another quality.
    pub chance: f64,
    pub age_seconds: i64,
}

/// What the cache may hold: the budget, or what the disk leaves above its
/// free-space floor, whichever is less. `used` is what the cache already
/// holds, since that space is the cache's to give back.
pub fn effective_budget(budget: u64, used: u64, free: u64, disk_total: u64) -> u64 {
    let floor = FREE_FLOOR_BYTES.max((disk_total as f64 * FREE_FLOOR_SHARE) as u64);
    budget.min(used.saturating_add(free.saturating_sub(floor)))
}

/// Which files to remove so `need` more bytes fit under `budget`. `Some` of
/// an empty list means it already fits; `None` means it cannot be made to fit
/// without removing something at least as likely to be played as the newcomer
/// (`chance`), something pinned, or something just fetched.
pub fn make_room(held: &[Held], need: u64, budget: u64, chance: f64) -> Option<Vec<String>> {
    let used: u64 = held.iter().map(|file| file.bytes).sum();
    if used.saturating_add(need) <= budget {
        return Some(Vec::new());
    }
    let mut evictable: Vec<&Held> = held
        .iter()
        .filter(|file| !file.pinned && file.age_seconds >= FRESH_GRACE_SECONDS)
        .collect();
    evictable.sort_by(|a, b| {
        let worth = |file: &Held| file.chance / file.bytes.max(1) as f64;
        worth(a)
            .total_cmp(&worth(b))
            .then(b.age_seconds.cmp(&a.age_seconds))
            .then(a.id.cmp(&b.id))
    });
    let mut freed = 0u64;
    let mut victims = Vec::new();
    for file in evictable {
        if used - freed + need <= budget {
            break;
        }
        if file.chance * REPLACE_MARGIN >= chance {
            return None;
        }
        freed += file.bytes;
        victims.push(file.id.clone());
    }
    (used - freed + need <= budget).then_some(victims)
}

/// Why a piece of preparation failed, which decides how long to leave it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    /// The network or the server hiccuped.
    Transient,
    /// The server is up and answered "busy" to this one question: it gives up
    /// on what it cannot answer from memory within moments and keeps working
    /// on it, so the same question a little later is usually answered.
    Busy,
    /// The server asked for fewer requests.
    Throttled,
    /// The server refuses this client.
    Blocked,
    /// There is nothing to prepare: no video, no lyrics.
    NotFound,
    /// This file will never play here.
    Permanent,
}

impl Failure {
    pub fn id(self) -> &'static str {
        match self {
            Failure::Transient => "transient",
            Failure::Busy => "busy",
            Failure::Throttled => "throttled",
            Failure::Blocked => "blocked",
            Failure::NotFound => "not-found",
            Failure::Permanent => "permanent",
        }
    }

    pub fn from_id(id: &str) -> Option<Failure> {
        [
            Failure::Transient,
            Failure::Busy,
            Failure::Throttled,
            Failure::Blocked,
            Failure::NotFound,
            Failure::Permanent,
        ]
        .into_iter()
        .find(|failure| failure.id() == id)
    }
}

/// Seconds to leave a failure alone after its `attempts`-th occurrence.
/// `jitter` is a number in [0, 1) that spreads retries by up to 30 % so a
/// batch that failed together does not retry together.
pub fn retry_delay_seconds(failure: Failure, attempts: u32, jitter: f64) -> i64 {
    let doubling = |base: i64, cap: i64| -> i64 {
        let exponent = attempts.saturating_sub(1).min(16);
        base.saturating_mul(1i64 << exponent).min(cap)
    };
    let base = match failure {
        Failure::Transient | Failure::Busy => doubling(30, 60 * 60),
        Failure::Throttled => doubling(5 * 60, 6 * 60 * 60),
        Failure::Blocked => doubling(30 * 60, 24 * 60 * 60),
        Failure::NotFound => 7 * 24 * 60 * 60,
        Failure::Permanent => 30 * 24 * 60 * 60,
    };
    (base as f64 * (1.0 + 0.3 * jitter.clamp(0.0, 1.0))) as i64
}

/// The songs a lane tried and could not finish, with when each may be tried
/// again. Times are unix seconds, passed in, so the rules need no clock.
#[derive(Clone, Debug, Default)]
pub struct RetryLedger {
    entries: std::collections::HashMap<String, LedgerEntry>,
}

#[derive(Clone, Copy, Debug)]
struct LedgerEntry {
    attempts: u32,
    due_unix: i64,
}

impl RetryLedger {
    /// Notes a failure: the song waits `retry_delay_seconds` for its
    /// `attempts`-th failure in a row before it is tried again.
    pub fn failed(&mut self, key: &str, failure: Failure, now_unix: i64, jitter: f64) {
        let attempts = self.entries.get(key).map_or(0, |entry| entry.attempts) + 1;
        let wait = retry_delay_seconds(failure, attempts, jitter);
        self.entries.insert(
            key.to_string(),
            LedgerEntry {
                attempts,
                due_unix: now_unix.saturating_add(wait),
            },
        );
    }

    /// The song was prepared: whatever kept it waiting is forgotten.
    pub fn succeeded(&mut self, key: &str) {
        self.entries.remove(key);
    }

    /// Whether the song is still being left alone at `now_unix`.
    pub fn is_waiting(&self, key: &str, now_unix: i64) -> bool {
        self.entries
            .get(key)
            .is_some_and(|entry| entry.due_unix > now_unix)
    }

    /// How many songs are still being left alone.
    pub fn waiting(&self, now_unix: i64) -> usize {
        self.entries
            .values()
            .filter(|entry| entry.due_unix > now_unix)
            .count()
    }

    /// When the first waiting song may be tried again.
    pub fn next_due(&self, now_unix: i64) -> Option<i64> {
        self.entries
            .values()
            .map(|entry| entry.due_unix)
            .filter(|due| *due > now_unix)
            .min()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(key: &str) -> Candidate {
        Candidate {
            key: key.to_string(),
            queue_distance: None,
            album_sibling: false,
            plays_30_days: 0,
            plays_total: 0,
            days_since_played: None,
            days_since_added: 400.0,
        }
    }

    fn queued(key: &str, distance: usize) -> Candidate {
        Candidate {
            queue_distance: Some(distance),
            ..candidate(key)
        }
    }

    fn held(id: &str, megabytes: u64, chance: f64, age_hours: i64) -> Held {
        Held {
            id: id.to_string(),
            bytes: megabytes * 1_000_000,
            pinned: false,
            chance,
            age_seconds: age_hours * 3600,
        }
    }

    #[test]
    fn the_queue_outranks_habit_and_habit_outranks_nothing() {
        let next = chance_of_play(&queued("a", 1));
        let habitual = chance_of_play(&Candidate {
            plays_30_days: 12,
            days_since_played: Some(2.0),
            ..candidate("b")
        });
        let stranger = chance_of_play(&candidate("c"));
        assert!(next > habitual);
        assert!(habitual > stranger);
        assert_eq!(stranger, 0.0);
        assert_eq!(chance_of_play(&queued("d", 0)), 1.0);
    }

    #[test]
    fn the_next_three_get_files_the_next_ten_a_match_and_the_playing_song_nothing() {
        let candidates = vec![
            queued("now", 0),
            queued("one", 1),
            queued("three", 3),
            queued("four", 4),
            queued("ten", 10),
            queued("eleven", 11),
        ];
        let wanted = wanted_videos(&candidates);
        let tier = |key: &str| wanted.iter().find(|w| w.key == key).map(|w| w.tier);
        assert_eq!(tier("now"), None);
        assert_eq!(tier("one"), Some(Tier::File));
        assert_eq!(tier("three"), Some(Tier::File));
        assert_eq!(tier("four"), Some(Tier::Match));
        assert_eq!(tier("ten"), Some(Tier::Match));
        assert_eq!(tier("eleven"), None);
    }

    #[test]
    fn habit_earns_a_file_only_past_a_quarter_chance_and_is_capped() {
        let favourite = Candidate {
            plays_30_days: 20,
            plays_total: 80,
            days_since_played: Some(1.0),
            ..candidate("fav")
        };
        let once = Candidate {
            plays_30_days: 1,
            ..candidate("once")
        };
        let wanted = wanted_videos(&[favourite, once]);
        assert_eq!(wanted.len(), 1);
        assert_eq!(wanted[0].key, "fav");
        assert_eq!(wanted[0].tier, Tier::File);

        let crowd: Vec<Candidate> = (0..HABIT_LIMIT + 50)
            .map(|index| Candidate {
                plays_30_days: 30,
                days_since_played: Some(1.0),
                ..candidate(&format!("song-{index:04}"))
            })
            .collect();
        assert_eq!(wanted_videos(&crowd).len(), HABIT_LIMIT);
    }

    #[test]
    fn wanted_videos_come_likeliest_first_and_planning_twice_agrees() {
        let candidates = vec![queued("three", 3), queued("one", 1), queued("two", 2)];
        let first = wanted_videos(&candidates);
        let keys: Vec<&str> = first.iter().map(|w| w.key.as_str()).collect();
        assert_eq!(keys, ["one", "two", "three"]);
        assert_eq!(first, wanted_videos(&candidates));
    }

    #[test]
    fn an_album_in_progress_is_matched_ahead_of_time() {
        let sibling = Candidate {
            album_sibling: true,
            ..candidate("sib")
        };
        let wanted = wanted_videos(&[sibling]);
        assert_eq!(wanted[0].tier, Tier::Match);
    }

    #[test]
    fn lyrics_cover_the_queue_and_habit_first_and_the_library_only_when_asked() {
        let candidates = vec![
            candidate("stranger"),
            queued("next", 1),
            Candidate {
                plays_total: 9,
                ..candidate("known")
            },
        ];
        assert_eq!(lyrics_order(&candidates, false), ["next", "known"]);
        assert_eq!(
            lyrics_order(&candidates, true),
            ["next", "known", "stranger"]
        );
    }

    #[test]
    fn a_new_arrival_is_asked_about_before_an_old_stranger() {
        let fresh = Candidate {
            days_since_added: 2.0,
            ..candidate("fresh")
        };
        let order = lyrics_order(&[candidate("old"), fresh], true);
        assert_eq!(order, ["fresh", "old"]);
    }

    #[test]
    fn the_disk_floor_shrinks_the_budget_but_never_below_what_is_held() {
        let gb = 1_000_000_000u64;
        assert_eq!(effective_budget(10 * gb, 0, 500 * gb, 1000 * gb), 10 * gb);
        assert_eq!(effective_budget(10 * gb, 3 * gb, 8 * gb, 1000 * gb), 3 * gb);
        assert_eq!(effective_budget(10 * gb, 3 * gb, 54 * gb, 1000 * gb), 7 * gb);
        assert_eq!(effective_budget(10 * gb, 4 * gb, 0, 1000 * gb), 4 * gb);
    }

    #[test]
    fn what_fits_evicts_nothing() {
        let files = vec![held("a", 100, 0.5, 100)];
        assert_eq!(make_room(&files, 100_000_000, 300_000_000, 0.9), Some(vec![]));
    }

    #[test]
    fn the_least_worth_per_byte_goes_first() {
        let files = vec![
            held("keep", 100, 0.8, 100),
            held("dear", 400, 0.1, 100),
            held("cheap", 100, 0.1, 100),
        ];
        let victims = make_room(&files, 100_000_000, 600_000_000, 0.9).unwrap();
        assert_eq!(victims, ["dear"]);
    }

    #[test]
    fn a_newcomer_must_beat_the_victim_by_the_margin() {
        let files = vec![held("a", 500, 0.5, 100)];
        assert_eq!(make_room(&files, 500_000_000, 600_000_000, 0.7), None);
        assert_eq!(
            make_room(&files, 500_000_000, 600_000_000, 0.8),
            Some(vec!["a".to_string()])
        );
    }

    #[test]
    fn pinned_and_fresh_files_are_never_evicted() {
        let mut pinned = held("pinned", 500, 0.0, 1000);
        pinned.pinned = true;
        let fresh = held("fresh", 500, 0.0, 2);
        assert_eq!(make_room(&[pinned, fresh], 500_000_000, 1_000_000_000, 1.0), None);
    }

    #[test]
    fn a_file_for_another_quality_goes_before_a_wanted_one() {
        let files = vec![held("wanted", 100, 0.4, 100), held("stale", 100, 0.0, 100)];
        let victims = make_room(&files, 100_000_000, 200_000_000, 0.5).unwrap();
        assert_eq!(victims, ["stale"]);
    }

    #[test]
    fn failures_back_off_by_kind_and_double_up_to_a_cap() {
        assert_eq!(retry_delay_seconds(Failure::Transient, 1, 0.0), 30);
        assert_eq!(retry_delay_seconds(Failure::Transient, 3, 0.0), 120);
        assert_eq!(retry_delay_seconds(Failure::Transient, 30, 0.0), 3600);
        assert_eq!(retry_delay_seconds(Failure::Busy, 1, 0.0), 30);
        assert_eq!(retry_delay_seconds(Failure::Busy, 3, 0.0), 120);
        assert_eq!(retry_delay_seconds(Failure::Throttled, 1, 0.0), 300);
        assert_eq!(retry_delay_seconds(Failure::Blocked, 20, 0.0), 24 * 3600);
        assert_eq!(retry_delay_seconds(Failure::NotFound, 1, 0.0), 7 * 24 * 3600);
        assert_eq!(retry_delay_seconds(Failure::Permanent, 1, 0.0), 30 * 24 * 3600);
    }

    #[test]
    fn jitter_spreads_a_delay_by_up_to_thirty_percent() {
        assert_eq!(retry_delay_seconds(Failure::Transient, 1, 1.0), 39);
        assert_eq!(retry_delay_seconds(Failure::Transient, 1, 5.0), 39);
        assert_eq!(retry_delay_seconds(Failure::Transient, 1, -1.0), 30);
    }

    #[test]
    fn failure_ids_round_trip() {
        for failure in [
            Failure::Transient,
            Failure::Busy,
            Failure::Throttled,
            Failure::Blocked,
            Failure::NotFound,
            Failure::Permanent,
        ] {
            assert_eq!(Failure::from_id(failure.id()), Some(failure));
        }
        assert_eq!(Failure::from_id("unknown"), None);
    }

    #[test]
    fn a_failed_song_waits_longer_each_time_and_is_forgiven_by_a_success() {
        let mut ledger = RetryLedger::default();
        ledger.failed("a", Failure::Transient, 1_000, 0.0);
        assert!(ledger.is_waiting("a", 1_029));
        assert!(!ledger.is_waiting("a", 1_030));
        ledger.failed("a", Failure::Transient, 1_030, 0.0);
        assert_eq!(ledger.next_due(1_030), Some(1_090));
        ledger.succeeded("a");
        assert!(!ledger.is_waiting("a", 1_031));
        assert_eq!(ledger.next_due(1_031), None);
    }

    #[test]
    fn the_ledger_counts_only_the_songs_still_waiting_and_names_the_first_due() {
        let mut ledger = RetryLedger::default();
        ledger.failed("quick", Failure::Transient, 0, 0.0);
        ledger.failed("slow", Failure::Throttled, 0, 0.0);
        assert_eq!(ledger.waiting(0), 2);
        assert_eq!(ledger.next_due(0), Some(30));
        assert_eq!(ledger.waiting(60), 1);
        assert_eq!(ledger.next_due(60), Some(300));
        assert!(!ledger.is_waiting("never-failed", 0));
    }
}
