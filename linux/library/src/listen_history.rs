//! Last.fm history as Flaccy's own listening history: the keys a play is
//! counted under, how a pulled scrobble is told apart from one already stored,
//! and which pull the history sync makes next. Mirrors FlaccyCore's
//! `ListenHistory`; the vectors in the tests are asserted on both sides.

use crate::hygiene::{artist_key, consolidation_base_title};
use crate::keys::{base_title_with, normalize};
use std::collections::{HashMap, HashSet};

/// Words whose bracketed or dashed segment says nothing about which recording
/// played: a featured credit or a remaster. "Song (feat. X)", "Song - 2011
/// Remaster" and "Song" are one song; "Song (Live)" and "Song (Acoustic
/// Version)" are not.
pub const LISTEN_TITLE_KEYWORDS: [&str; 7] = [
    "feat",
    "ft.",
    "featuring",
    "with",
    "remaster",
    "remastered",
    "explicit",
];

/// Unbracketed featured-credit clauses cut from a title: "Song feat. X".
const TITLE_FEATURE_CLAUSES: [&str; 4] = [" feat. ", " feat ", " ft. ", " featuring "];

/// How far back Last.fm accepts a scrobble, so how far back a late-arriving one
/// from another device can land.
pub const LATE_SCROBBLE_WINDOW_SECONDS: i64 = 14 * 86_400;

/// How often the sync re-reads that whole window for late arrivals.
pub const SETTLE_INTERVAL_SECONDS: i64 = 86_400;

/// How far before the newest pulled scrobble a catch-up starts, so a scrobble
/// stamped a little before it but submitted after the last pull is not missed.
pub const CATCH_UP_OVERLAP_SECONDS: i64 = 3_600;

/// The shortest gap between two automatic syncs (focus, launch, timer).
pub const AUTOMATIC_SYNC_SPACING_SECONDS: i64 = 120;

/// How often a running client syncs on its own.
pub const PERIODIC_SYNC_SECONDS: i64 = 600;

/// The title a play is counted under: case, diacritics and punctuation folded,
/// featured credits and remaster tags dropped.
pub fn title_key(raw: &str) -> String {
    let lowered = raw.to_lowercase();
    let cut = TITLE_FEATURE_CLAUSES
        .iter()
        .filter_map(|clause| lowered.find(clause))
        .min()
        .unwrap_or(lowered.len());
    let key = base_title_with(&lowered[..cut], &LISTEN_TITLE_KEYWORDS);
    if key.is_empty() {
        normalize(raw)
    } else {
        key
    }
}

/// The artist a play is counted under: the lead of the credit, folded the
/// way the library groups its Artists.
pub fn artist_listen_key(raw: &str) -> String {
    artist_key(raw)
}

/// The release a play is counted under, without its artist: the edition-free
/// base title, so "Abbey Road (2019 Remaster)" counts toward "Abbey Road".
pub fn album_listen_key(raw: &str) -> String {
    consolidation_base_title(raw)
}

/// The keys one play is stored with.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ListenKeys {
    pub title: String,
    pub artist: String,
    pub album: String,
}

impl ListenKeys {
    pub fn of(title: &str, artist: &str, album: &str) -> Self {
        Self {
            title: title_key(title),
            artist: artist_listen_key(artist),
            album: album_listen_key(album),
        }
    }
}

/// `title ␀ artist`: the key a song's plays are counted under, used alike for
/// a scrobble and for a library track.
pub fn track_listen_key(title: &str, artist: &str) -> String {
    let mut key = title_key(title);
    key.push('\u{0}');
    key.push_str(&artist_listen_key(artist));
    key
}

/// One stored play, as dedup needs it.
#[derive(Clone, Debug)]
pub struct StoredListen {
    pub timestamp_unix: i64,
    pub title_key: String,
    pub artist_key: String,
    /// Played in Flaccy (it knows how long the song is) rather than pulled
    /// from Last.fm.
    pub played_here: bool,
}

/// What is already stored, asked whether a pulled scrobble is new.
#[derive(Default)]
pub struct ListenLedger {
    titles: HashSet<(i64, String)>,
    played_here: HashSet<(i64, String)>,
}

impl ListenLedger {
    pub fn new(stored: impl IntoIterator<Item = StoredListen>) -> Self {
        let mut ledger = Self::default();
        for listen in stored {
            ledger.remember(listen);
        }
        ledger
    }

    fn remember(&mut self, listen: StoredListen) {
        if listen.played_here {
            self.played_here
                .insert((listen.timestamp_unix, listen.artist_key.clone()));
        }
        self.titles.insert((listen.timestamp_unix, listen.title_key));
    }

    /// Whether a scrobble pulled from Last.fm is a play that is not stored
    /// yet, and records it when it is. The same second and title is the same
    /// play. So is the same second and artist as a play Flaccy recorded
    /// itself, which Last.fm may hand back under a corrected title; plays
    /// pulled from Last.fm can share a second with each other (bulk-imported
    /// histories do), so that rule never folds two of them together.
    pub fn admit(&mut self, timestamp_unix: i64, keys: &ListenKeys) -> bool {
        if self.played_here.contains(&(timestamp_unix, keys.artist.clone())) {
            return false;
        }
        self.titles.insert((timestamp_unix, keys.title.clone()))
    }
}

/// Folds counts gathered per spelling into one entry per key, named by the
/// spelling heard most (ties go to the alphabetically first), ordered by
/// plays descending then name.
pub fn fold_spellings<K: std::hash::Hash + Eq + Clone>(
    rows: impl IntoIterator<Item = (K, String, i64, i64)>,
) -> Vec<(String, i64, i64)> {
    struct Group {
        name: String,
        name_plays: i64,
        plays: i64,
        seconds: i64,
    }
    let mut groups: HashMap<K, Group> = HashMap::new();
    for (key, name, plays, seconds) in rows {
        let group = groups.entry(key).or_insert_with(|| Group {
            name: name.clone(),
            name_plays: 0,
            plays: 0,
            seconds: 0,
        });
        group.plays += plays;
        group.seconds += seconds;
        if plays > group.name_plays || (plays == group.name_plays && name < group.name) {
            group.name = name;
            group.name_plays = plays;
        }
    }
    let mut folded: Vec<(String, i64, i64)> = groups
        .into_values()
        .map(|group| (group.name, group.plays, group.seconds))
        .collect();
    folded.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
    folded
}

/// Where the history sync stands for one Last.fm account. Persisted by each
/// client.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct HistorySyncState {
    pub account: String,
    pub backfill_complete: bool,
    /// The instant the first full pull reads back from, fixed when it starts so
    /// its pages do not shift as new scrobbles arrive.
    pub backfill_anchor: Option<i64>,
    /// The next page of the first full pull.
    pub backfill_page: u32,
    /// The newest scrobble time pulled so far.
    pub newest_remote: Option<i64>,
    pub last_sync_at: Option<i64>,
    pub last_settle_at: Option<i64>,
}

/// The next pull from Last.fm.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HistorySyncStep {
    /// One page of the first full pull, newest first, of scrobbles up to `to`.
    Backfill { page: u32, to: i64 },
    /// Every scrobble from `from` on, the regular pull.
    CatchUp { from: i64 },
    /// Every scrobble of the window Last.fm still accepts late ones into.
    Settle { from: i64 },
}

impl HistorySyncState {
    /// A fresh state for `account`, or this one when it is the same account.
    pub fn for_account(self, account: &str) -> Self {
        if self.account == account {
            self
        } else {
            Self {
                account: account.to_string(),
                backfill_page: 1,
                ..Self::default()
            }
        }
    }

    /// The state a client that imported history before the sync existed
    /// starts from. `legacy_complete` is its record of a finished import,
    /// `legacy_page` the page an unfinished one stopped at (pages have shifted
    /// since, so it resumes one page early), and `newest_imported` the newest
    /// scrobble that import stored.
    pub fn adopting(
        account: &str,
        legacy_complete: bool,
        legacy_page: u32,
        newest_imported: Option<i64>,
        now: i64,
    ) -> Self {
        let mut state = Self::default().for_account(account);
        if legacy_complete && legacy_page <= 1 {
            state.backfill_complete = true;
            state.newest_remote = newest_imported;
        } else if legacy_page > 1 {
            state.backfill_anchor = Some(now);
            state.backfill_page = legacy_page - 1;
        }
        state
    }

    /// The pull to make now.
    pub fn next_step(&self, now: i64) -> HistorySyncStep {
        if !self.backfill_complete {
            return HistorySyncStep::Backfill {
                page: self.backfill_page.max(1),
                to: self.backfill_anchor.unwrap_or(now),
            };
        }
        let settle_due = self
            .last_settle_at
            .is_none_or(|at| now - at >= SETTLE_INTERVAL_SECONDS);
        let window_start = now - LATE_SCROBBLE_WINDOW_SECONDS;
        match self.newest_remote {
            Some(newest) if !settle_due => HistorySyncStep::CatchUp {
                from: (newest - CATCH_UP_OVERLAP_SECONDS).max(0),
            },
            Some(newest) if newest - CATCH_UP_OVERLAP_SECONDS < window_start => {
                HistorySyncStep::CatchUp {
                    from: (newest - CATCH_UP_OVERLAP_SECONDS).max(0),
                }
            }
            _ => HistorySyncStep::Settle { from: window_start },
        }
    }

    /// Whether an automatic trigger should sync now.
    pub fn automatic_sync_due(&self, now: i64) -> bool {
        self.last_sync_at
            .is_none_or(|at| now - at >= AUTOMATIC_SYNC_SPACING_SECONDS || now < at)
    }

    /// Records a finished page of the first full pull.
    pub fn record_backfill_page(&mut self, page: u32, total_pages: u32, anchor: i64, newest: Option<i64>, now: i64) {
        self.backfill_anchor = Some(anchor);
        self.note_newest(newest);
        if page >= total_pages.max(1) {
            self.backfill_complete = true;
            self.backfill_anchor = None;
            self.backfill_page = 1;
            self.newest_remote = Some(self.newest_remote.unwrap_or(anchor).max(anchor.min(now)));
            self.last_sync_at = Some(now);
        } else {
            self.backfill_page = page + 1;
        }
    }

    /// Records a finished catch-up or settle pull.
    pub fn record_pull(&mut self, step: HistorySyncStep, newest: Option<i64>, now: i64) {
        self.note_newest(newest);
        if self.newest_remote.is_none() {
            self.newest_remote = Some(now);
        }
        self.last_sync_at = Some(now);
        if let HistorySyncStep::Settle { .. } = step {
            self.last_settle_at = Some(now);
        } else if let HistorySyncStep::CatchUp { from } = step {
            if from >= now - LATE_SCROBBLE_WINDOW_SECONDS {
                return;
            }
            self.last_settle_at = Some(now);
        }
    }

    fn note_newest(&mut self, newest: Option<i64>) {
        if let Some(newest) = newest {
            self.newest_remote = Some(self.newest_remote.map_or(newest, |known| known.max(newest)));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000;

    #[test]
    fn title_keys_fold_featured_credits_and_remasters_but_keep_versions_apart() {
        let vectors = [
            ("Song", "song"),
            ("SONG", "song"),
            ("Sóng!", "song"),
            ("Song (feat. Someone)", "song"),
            ("Song [ft. Someone]", "song"),
            ("Song feat. Someone", "song"),
            ("Song Featuring Someone", "song"),
            ("Song (with Someone)", "song"),
            ("Song - 2011 Remaster", "song"),
            ("Song - Remastered 2009", "song"),
            ("Song (Remastered)", "song"),
            ("Song (Explicit)", "song"),
            ("Song (Live)", "songlive"),
            ("Song (Acoustic Version)", "songacousticversion"),
            ("Song - Radio Edit", "songradioedit"),
            ("(feat. Someone)", "featsomeone"),
            ("日本語の歌", "日本語の歌"),
        ];
        for (raw, key) in vectors {
            assert_eq!(title_key(raw), key, "{raw:?}");
        }
    }

    #[test]
    fn artist_and_album_keys_follow_the_library_grouping() {
        assert_eq!(artist_listen_key("Beyoncé"), "beyonce");
        assert_eq!(artist_listen_key("deadmau5 feat. Kaskade"), "deadmau5");
        assert_eq!(artist_listen_key("Sigur Rós"), "sigurros");
        assert_eq!(album_listen_key("Abbey Road (2019 Remaster)"), "abbeyroad");
        assert_eq!(album_listen_key("OK Computer [Deluxe Edition]"), "okcomputer");
        assert_eq!(album_listen_key(""), "");
        assert_eq!(
            track_listen_key("Song (feat. B)", "A feat. B"),
            track_listen_key("song", "a")
        );
    }

    fn keys(title: &str, artist: &str) -> ListenKeys {
        ListenKeys::of(title, artist, "")
    }

    fn stored(timestamp_unix: i64, title: &str, artist: &str, played_here: bool) -> StoredListen {
        StoredListen {
            timestamp_unix,
            title_key: title_key(title),
            artist_key: artist_listen_key(artist),
            played_here,
        }
    }

    #[test]
    fn the_ledger_admits_each_pulled_play_once() {
        let mut ledger = ListenLedger::new([stored(100, "Song", "A", false)]);
        assert!(!ledger.admit(100, &keys("song", "A")));
        assert!(!ledger.admit(100, &keys("Song (Remastered)", "Other")));
        assert!(ledger.admit(101, &keys("Song", "A")));
        assert!(!ledger.admit(101, &keys("Song", "A")));
    }

    #[test]
    fn pulled_plays_sharing_a_second_stay_apart() {
        let mut ledger = ListenLedger::default();
        assert!(ledger.admit(500, &keys("Parabola", "Tool")));
        assert!(ledger.admit(500, &keys("Lateralus", "Tool")));
        assert!(ledger.admit(500, &keys("Triad", "Tool")));
    }

    #[test]
    fn a_corrected_title_is_the_play_flaccy_recorded() {
        let mut ledger = ListenLedger::new([stored(900, "Song (Album Mix)", "Artist", true)]);
        assert!(!ledger.admit(900, &keys("Song", "Artist")));
        assert!(ledger.admit(900, &keys("Song", "Somebody Else")));
        assert!(ledger.admit(901, &keys("Song", "Artist")));
    }

    #[test]
    fn spellings_fold_under_the_one_heard_most() {
        let folded = fold_spellings([
            ("sigurros", "Sigur Ros".to_string(), 3, 30),
            ("sigurros", "Sigur Rós".to_string(), 5, 50),
            ("bjork", "Björk".to_string(), 8, 80),
            ("abba", "ABBA".to_string(), 2, 20),
            ("abba", "Abba".to_string(), 2, 20),
        ]);
        assert_eq!(
            folded,
            vec![
                ("Björk".to_string(), 8, 80),
                ("Sigur Rós".to_string(), 8, 80),
                ("ABBA".to_string(), 4, 40),
            ]
        );
    }

    #[test]
    fn a_new_account_backfills_from_now_and_keeps_its_anchor() {
        let state = HistorySyncState::default().for_account("listener");
        assert_eq!(state.next_step(NOW), HistorySyncStep::Backfill { page: 1, to: NOW });
        let mut state = state;
        state.record_backfill_page(1, 3, NOW, Some(NOW - 10), NOW);
        assert_eq!(
            state.next_step(NOW + 500),
            HistorySyncStep::Backfill { page: 2, to: NOW }
        );
        state.record_backfill_page(2, 3, NOW, Some(NOW - 9_000), NOW + 600);
        state.record_backfill_page(3, 3, NOW, None, NOW + 700);
        assert!(state.backfill_complete);
        assert_eq!(state.newest_remote, Some(NOW));
        assert_eq!(
            state.next_step(NOW + 800),
            HistorySyncStep::Settle { from: NOW + 800 - LATE_SCROBBLE_WINDOW_SECONDS }
        );
    }

    #[test]
    fn a_settled_history_catches_up_from_just_before_the_newest_play() {
        let mut state = HistorySyncState::default().for_account("listener");
        state.backfill_complete = true;
        state.newest_remote = Some(NOW - 50);
        state.record_pull(HistorySyncStep::Settle { from: NOW - LATE_SCROBBLE_WINDOW_SECONDS }, Some(NOW - 20), NOW);
        assert_eq!(state.newest_remote, Some(NOW - 20));
        assert_eq!(
            state.next_step(NOW + 300),
            HistorySyncStep::CatchUp { from: NOW - 20 - CATCH_UP_OVERLAP_SECONDS }
        );
        assert_eq!(
            state.next_step(NOW + SETTLE_INTERVAL_SECONDS),
            HistorySyncStep::Settle { from: NOW + SETTLE_INTERVAL_SECONDS - LATE_SCROBBLE_WINDOW_SECONDS }
        );
    }

    #[test]
    fn a_long_absence_catches_up_from_the_newest_play_and_counts_as_settled() {
        let mut state = HistorySyncState::default().for_account("listener");
        state.backfill_complete = true;
        state.newest_remote = Some(NOW - 90 * 86_400);
        let step = state.next_step(NOW);
        assert_eq!(
            step,
            HistorySyncStep::CatchUp { from: NOW - 90 * 86_400 - CATCH_UP_OVERLAP_SECONDS }
        );
        state.record_pull(step, Some(NOW - 60), NOW);
        assert_eq!(state.last_settle_at, Some(NOW));
        assert_eq!(state.newest_remote, Some(NOW - 60));
    }

    #[test]
    fn a_pull_that_finds_nothing_still_moves_the_clock() {
        let mut state = HistorySyncState::default().for_account("listener");
        state.backfill_complete = true;
        state.record_pull(HistorySyncStep::Settle { from: 0 }, None, NOW);
        assert_eq!(state.newest_remote, Some(NOW));
        assert_eq!(state.last_sync_at, Some(NOW));
    }

    #[test]
    fn automatic_syncs_are_spaced_out() {
        let mut state = HistorySyncState::default().for_account("listener");
        assert!(state.automatic_sync_due(NOW));
        state.last_sync_at = Some(NOW);
        assert!(!state.automatic_sync_due(NOW + AUTOMATIC_SYNC_SPACING_SECONDS - 1));
        assert!(state.automatic_sync_due(NOW + AUTOMATIC_SYNC_SPACING_SECONDS));
        assert!(state.automatic_sync_due(NOW - 10));
    }

    #[test]
    fn switching_accounts_starts_over_and_the_same_account_keeps_its_place() {
        let mut state = HistorySyncState::default().for_account("first");
        state.backfill_complete = true;
        state.newest_remote = Some(NOW);
        let same = state.clone().for_account("first");
        assert_eq!(same, state);
        let other = state.for_account("second");
        assert!(!other.backfill_complete);
        assert_eq!(other.next_step(NOW), HistorySyncStep::Backfill { page: 1, to: NOW });
    }

    #[test]
    fn an_earlier_import_is_adopted() {
        let finished = HistorySyncState::adopting("listener", true, 1, Some(NOW - 5_000), NOW);
        assert!(finished.backfill_complete);
        assert_eq!(finished.newest_remote, Some(NOW - 5_000));

        let stopped = HistorySyncState::adopting("listener", false, 190, Some(NOW - 5_000), NOW);
        assert!(!stopped.backfill_complete);
        assert_eq!(stopped.next_step(NOW + 60), HistorySyncStep::Backfill { page: 189, to: NOW });

        let never = HistorySyncState::adopting("listener", false, 1, None, NOW);
        assert_eq!(never.next_step(NOW), HistorySyncStep::Backfill { page: 1, to: NOW });
    }
}
