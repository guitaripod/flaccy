//! Mirrors `FlaccyCore/Sources/FlaccyCore/Library/LibraryDebut.swift`.
//!
//! The first build of a library is a once-per-library showpiece in three acts:
//! the bounded load bar, then the fraction-free job countdown, then a summary
//! card. It runs iff `libraryDebut.completedAt IS NULL` and the first build
//! produced at least one album.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::enrichment_job::{Activity, JobProgress};
use crate::load_progress::LoadProgress;

#[derive(Clone, PartialEq, Debug, Serialize, Deserialize)]
pub struct DebutSummary {
    pub track_count: usize,
    pub album_count: usize,
    pub artist_count: usize,
    pub covers_resolved: usize,
    pub albums_dated: usize,
    pub ai_cleaned_tracks: usize,
    pub lossless_track_count: usize,
    pub average_bitrate: usize,
    pub total_duration_seconds: f64,
    pub completed_at: DateTime<Utc>,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DebutAct {
    Indexing,
    Finishing,
    Summary,
    Done,
}

/// The longest the finishing act may hold a new user's library. Whatever is
/// still queued after this continues on the ambient surface.
pub const CURTAIN_BUDGET: f64 = 90.0;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct DebutDirector {
    act: DebutAct,
}

impl Default for DebutDirector {
    fn default() -> Self {
        Self {
            act: DebutAct::Indexing,
        }
    }
}

impl DebutDirector {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn act(&self) -> DebutAct {
        self.act
    }

    /// Advances the act, never backwards. Returns true when the act changed.
    pub fn advance(
        &mut self,
        load: &LoadProgress,
        job: &JobProgress,
        album_count: usize,
        elapsed_in_finishing: f64,
    ) -> bool {
        let next = Self::target(load, job, album_count, elapsed_in_finishing, self.act);
        if next <= self.act {
            return false;
        }
        self.act = next;
        true
    }

    fn target(
        load: &LoadProgress,
        job: &JobProgress,
        album_count: usize,
        elapsed_in_finishing: f64,
        current: DebutAct,
    ) -> DebutAct {
        if load.phase.blocks_library() {
            return DebutAct::Indexing;
        }
        if album_count == 0 {
            return DebutAct::Done;
        }
        if current == DebutAct::Indexing {
            return DebutAct::Finishing;
        }
        if current == DebutAct::Finishing {
            let drained = job.activity == Activity::Idle || job.remaining == 0;
            let curtain = elapsed_in_finishing >= CURTAIN_BUDGET;
            let blocked = job.activity == Activity::NeedsEntitlement;
            return if drained || curtain || blocked {
                DebutAct::Summary
            } else {
                DebutAct::Finishing
            };
        }
        current
    }
}

/// Every user-visible debut string, matching the Apple `LibraryDebutCopy` deck
/// word for word.
pub mod copy {
    use crate::load_progress::group_digits;

    pub const AI_HEADLINE: &str = "Cleaning up your tags";
    pub const AI_EXPLANATION: &str =
        "Flaccy's AI turns scrambled filenames into real titles, artists and albums.";
    pub const ARTWORK_HEADLINE: &str = "Finding your covers";
    pub const ARTWORK_EXPLANATION: &str =
        "Looking up artwork, years and genres for every album.";
    pub const TRIAL_CHIP: &str = "AI · included in your 7-day trial";
    pub const AI_SKIPPED_HEADLINE: &str = "Tag cleanup skipped — your trial has ended";
    pub const AI_SKIPPED_BUTTON: &str = "Turn on AI cleanup";
    pub const CARD_TITLE: &str = "Your library is ready.";
    pub const STAT_TRACKS: &str = "Tracks";
    pub const STAT_ALBUMS: &str = "Albums";
    pub const STAT_ARTISTS: &str = "Artists";
    pub const STAT_DURATION: &str = "Of music";
    pub const CARD_PAYWALL_LINE: &str =
        "Tag cleanup is powered by Flaccy AI — included in Flaccy Lifetime.";
    pub const CARD_PRIMARY: &str = "Take me to my music";
    pub const CARD_SECONDARY: &str = "See what's included";
    pub const SETTINGS_CAVEAT_FOOTER: &str =
        "The setup summary belongs to this library. Reinstalling or resetting builds a new one.";
    pub const WATCH_CARD_TITLE: &str = "Ready.";

    pub fn card_line_covers(covers: usize, dated: usize) -> String {
        format!(
            "{} covers found · {} albums dated",
            group_digits(covers),
            group_digits(dated)
        )
    }

    pub fn card_line_ai(tracks: usize) -> String {
        format!("{} tracks cleaned up by Flaccy AI", group_digits(tracks))
    }

    pub fn card_line_quality(lossless_percent: usize, average_bitrate: usize) -> String {
        format!(
            "{}% lossless · {} kbps average",
            group_digits(lossless_percent),
            group_digits(average_bitrate)
        )
    }

    pub fn settings_permanent_line(built: &str, tracks: usize, cleaned: usize) -> String {
        format!(
            "Library built {built} · {} tracks · {} cleaned up by AI",
            group_digits(tracks),
            group_digits(cleaned)
        )
    }

    pub fn watch_card_detail(tracks: usize, albums: usize) -> String {
        format!(
            "{} tracks · {} albums on your wrist",
            group_digits(tracks),
            group_digits(albums)
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::enrichment_job::Scope;
    use crate::load_progress::{LoadPhase, LoadProgress};
    use chrono::TimeZone;

    fn built() -> LoadProgress {
        LoadProgress::default()
    }

    fn queued(remaining: usize) -> JobProgress {
        JobProgress {
            activity: Activity::Running,
            scope: Scope::Album,
            remaining,
            ..JobProgress::idle()
        }
    }

    fn summary() -> DebutSummary {
        DebutSummary {
            track_count: 2847,
            album_count: 214,
            artist_count: 38,
            covers_resolved: 191,
            albums_dated: 168,
            ai_cleaned_tracks: 1402,
            lossless_track_count: 2619,
            average_bitrate: 1984,
            total_duration_seconds: 1_656_000.0,
            completed_at: Utc.with_ymd_and_hms(2026, 8, 21, 9, 30, 0).unwrap(),
        }
    }

    #[test]
    fn debut_is_not_written_for_an_empty_library() {
        let mut director = DebutDirector::new();
        assert!(director.advance(&built(), &JobProgress::idle(), 0, 0.0));
        assert_eq!(director.act(), DebutAct::Done);
    }

    #[test]
    fn acts_never_move_backwards() {
        let mut director = DebutDirector::new();
        assert!(director.advance(&built(), &queued(40), 214, 0.0));
        assert_eq!(director.act(), DebutAct::Finishing);

        let scanning = LoadProgress::new(LoadPhase::ReadingTags);
        assert!(!director.advance(&scanning, &queued(40), 214, 0.0));
        assert_eq!(director.act(), DebutAct::Finishing);
    }

    #[test]
    fn finishing_ends_when_the_queue_drains() {
        let mut director = DebutDirector::new();
        director.advance(&built(), &queued(40), 214, 0.0);
        assert!(!director.advance(&built(), &queued(40), 214, 1.0));
        assert!(director.advance(&built(), &queued(0), 214, 1.0));
        assert_eq!(director.act(), DebutAct::Summary);
    }

    #[test]
    fn finishing_ends_at_the_curtain_budget() {
        let mut director = DebutDirector::new();
        director.advance(&built(), &queued(40), 214, 0.0);
        assert!(!director.advance(&built(), &queued(40), 214, CURTAIN_BUDGET - 0.1));
        assert!(director.advance(&built(), &queued(40), 214, CURTAIN_BUDGET));
        assert_eq!(director.act(), DebutAct::Summary);
    }

    #[test]
    fn finishing_ends_immediately_when_the_job_needs_an_entitlement() {
        let mut director = DebutDirector::new();
        director.advance(&built(), &queued(40), 214, 0.0);
        let mut blocked = queued(40);
        blocked.activity = Activity::NeedsEntitlement;
        assert!(director.advance(&built(), &blocked, 214, 0.0));
        assert_eq!(director.act(), DebutAct::Summary);
    }

    #[test]
    fn card_lines_read_as_the_copy_deck() {
        assert_eq!(
            copy::card_line_covers(191, 168),
            "191 covers found · 168 albums dated"
        );
        assert_eq!(
            copy::card_line_ai(1402),
            "1\u{202f}402 tracks cleaned up by Flaccy AI"
        );
        assert_eq!(
            copy::card_line_quality(92, 1984),
            "92% lossless · 1\u{202f}984 kbps average"
        );
    }

    /// The `summaryJSON` contract: the binary crate writes this struct with
    /// serde_json, which the shared crate deliberately does not depend on, so
    /// the round trip is proved against SQLite's own JSON functions using the
    /// exact key names serde derives from the field names.
    #[test]
    fn summary_round_trips_through_its_json() {
        let original = summary();
        let conn = rusqlite::Connection::open_in_memory().expect("memory db");
        let json: String = conn
            .query_row(
                "SELECT json_object(
                     'track_count', ?1, 'album_count', ?2, 'artist_count', ?3,
                     'covers_resolved', ?4, 'albums_dated', ?5, 'ai_cleaned_tracks', ?6,
                     'lossless_track_count', ?7, 'average_bitrate', ?8,
                     'total_duration_seconds', ?9, 'completed_at', ?10)",
                rusqlite::params![
                    original.track_count as i64,
                    original.album_count as i64,
                    original.artist_count as i64,
                    original.covers_resolved as i64,
                    original.albums_dated as i64,
                    original.ai_cleaned_tracks as i64,
                    original.lossless_track_count as i64,
                    original.average_bitrate as i64,
                    original.total_duration_seconds,
                    crate::enrichment_job::encode_timestamp(original.completed_at),
                ],
                |row| row.get(0),
            )
            .expect("encode");

        let restored = conn
            .query_row(
                "SELECT json_extract(?1, '$.track_count'), json_extract(?1, '$.album_count'),
                        json_extract(?1, '$.artist_count'), json_extract(?1, '$.covers_resolved'),
                        json_extract(?1, '$.albums_dated'), json_extract(?1, '$.ai_cleaned_tracks'),
                        json_extract(?1, '$.lossless_track_count'), json_extract(?1, '$.average_bitrate'),
                        json_extract(?1, '$.total_duration_seconds'), json_extract(?1, '$.completed_at')",
                [&json],
                |row| {
                    Ok(DebutSummary {
                        track_count: row.get::<_, i64>(0)? as usize,
                        album_count: row.get::<_, i64>(1)? as usize,
                        artist_count: row.get::<_, i64>(2)? as usize,
                        covers_resolved: row.get::<_, i64>(3)? as usize,
                        albums_dated: row.get::<_, i64>(4)? as usize,
                        ai_cleaned_tracks: row.get::<_, i64>(5)? as usize,
                        lossless_track_count: row.get::<_, i64>(6)? as usize,
                        average_bitrate: row.get::<_, i64>(7)? as usize,
                        total_duration_seconds: row.get::<_, f64>(8)?,
                        completed_at: crate::enrichment_job::decode_timestamp(
                            &row.get::<_, String>(9)?,
                        )
                        .expect("timestamp"),
                    })
                },
            )
            .expect("decode");

        assert_eq!(restored, original);
    }
}
