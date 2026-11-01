//! What the background preparation is doing, for Preferences to show. Each
//! lane writes its own part; the reader gets a copy.

use std::sync::Mutex;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum LaneState {
    #[default]
    Off,
    Idle,
    Working,
    /// Resting until the given unix time, and why.
    Resting {
        until_unix: i64,
        reason: String,
    },
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Status {
    pub lyrics: LaneState,
    pub lyrics_waiting: usize,
    pub lyrics_prepared: usize,
    pub video: LaneState,
    pub video_files: usize,
    pub video_bytes: u64,
    pub video_cap_bytes: u64,
    pub video_current: String,
}

static STATUS: Mutex<Option<Status>> = Mutex::new(None);

pub fn snapshot() -> Status {
    STATUS
        .lock()
        .ok()
        .and_then(|status| status.clone())
        .unwrap_or_default()
}

pub fn update(change: impl FnOnce(&mut Status)) {
    if let Ok(mut status) = STATUS.lock() {
        change(status.get_or_insert_with(Status::default));
    }
}

/// "12 minutes", "2 hours": how long a resting lane has left, to a person's
/// precision.
pub fn rest_label(seconds: i64) -> String {
    match seconds.max(1) {
        1 => "a second".to_string(),
        seconds @ 2..=89 => format!("{seconds} seconds"),
        seconds @ 90..=5399 => format!("{} minutes", (seconds + 30) / 60),
        seconds => format!("{} hours", (seconds + 1800) / 3600),
    }
}

/// "lrclib asked for fewer requests; resuming in 5 minutes".
pub fn resting_line(until_unix: i64, reason: &str, now_unix: i64) -> String {
    format!("{reason}; resuming in {}", rest_label(until_unix - now_unix))
}

/// What the lyrics lane is doing, in a sentence.
pub fn lyrics_line(status: &Status, now_unix: i64) -> String {
    match &status.lyrics {
        LaneState::Off => "Starting up".to_string(),
        LaneState::Idle => match status.lyrics_prepared {
            0 => "Everything wanted is already fetched".to_string(),
            1 => "Up to date; fetched 1 song this session".to_string(),
            count => format!("Up to date; fetched {count} songs this session"),
        },
        LaneState::Working => match status.lyrics_waiting {
            1 => "Fetching; 1 song waiting".to_string(),
            count => format!("Fetching; {count} songs waiting"),
        },
        LaneState::Resting { until_unix, reason } => resting_line(*until_unix, reason, now_unix),
    }
}

/// What the video lane is doing, in a sentence. `lens_on` is whether the video
/// lens is switched on, which the lane waits for.
pub fn video_line(status: &Status, enabled: bool, lens_on: bool, now_unix: i64) -> String {
    if !enabled {
        return "Off".to_string();
    }
    if !lens_on {
        return "Waiting for the video lens to be turned on".to_string();
    }
    match &status.video {
        LaneState::Off => "Starting up".to_string(),
        LaneState::Idle => "Everything wanted is prepared".to_string(),
        LaneState::Working if status.video_current.is_empty() => "Preparing".to_string(),
        LaneState::Working => format!("Preparing \u{201c}{}\u{201d}", status.video_current),
        LaneState::Resting { until_unix, reason } => resting_line(*until_unix, reason, now_unix),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_rest_reads_in_the_unit_a_person_would_say() {
        assert_eq!(rest_label(0), "a second");
        assert_eq!(rest_label(45), "45 seconds");
        assert_eq!(rest_label(300), "5 minutes");
        assert_eq!(rest_label(3 * 3600), "3 hours");
    }

    #[test]
    fn a_resting_lane_says_why_and_for_how_long() {
        let status = Status {
            lyrics: LaneState::Resting {
                until_unix: 1_300,
                reason: "lrclib asked for fewer requests".into(),
            },
            ..Status::default()
        };
        assert_eq!(
            lyrics_line(&status, 1_000),
            "lrclib asked for fewer requests; resuming in 5 minutes"
        );
    }

    #[test]
    fn the_lyrics_lane_counts_what_it_has_done_and_what_waits() {
        let working = Status {
            lyrics: LaneState::Working,
            lyrics_waiting: 40,
            ..Status::default()
        };
        assert_eq!(lyrics_line(&working, 0), "Fetching; 40 songs waiting");
        let done = Status {
            lyrics: LaneState::Idle,
            lyrics_prepared: 1,
            ..Status::default()
        };
        assert_eq!(lyrics_line(&done, 0), "Up to date; fetched 1 song this session");
    }

    #[test]
    fn the_video_lane_waits_for_the_lens_and_names_the_song_it_is_on() {
        let working = Status {
            video: LaneState::Working,
            video_current: "Heartless".into(),
            ..Status::default()
        };
        assert_eq!(video_line(&working, false, true, 0), "Off");
        assert_eq!(
            video_line(&working, true, false, 0),
            "Waiting for the video lens to be turned on"
        );
        assert_eq!(video_line(&working, true, true, 0), "Preparing \u{201c}Heartless\u{201d}");
    }
}
