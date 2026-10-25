//! The words on Home, word for word the Apple clients' (`HomeCopy` in
//! FlaccyCore). Every formatter is pure: calendar questions take the local UTC
//! offset, so the same vectors prove both languages.

use chrono::Datelike;

use crate::home::{local, OnThisDayKind, PlaybackContext, ContextKind, Recency, Section};
use crate::library_filter::PeriodDelta;
use crate::load_progress::group_digits;

pub const HOME: &str = "Home";
pub const CONTINUE: &str = "Continue";
pub const JUMP_BACK_IN: &str = "Jump Back In";
pub const MADE_FOR_YOU: &str = "Made for You";
pub const RECENTLY_ADDED: &str = "Recently Added";
pub const ON_THIS_DAY: &str = "On This Day";
pub const THIS_WEEK: &str = "This Week";
pub const SEE_ALL: &str = "See All";
pub const OPEN_STATS: &str = "Open Stats";
pub const CUSTOMIZE_HOME: &str = "Customize Home…";

pub const RESUME: &str = "Resume";
pub const PLAY: &str = "Play";
pub const SHUFFLE: &str = "Shuffle";
pub const PLAY_NEXT_TOOLTIP: &str = "Play after the current song";

pub const YOUR_QUEUE: &str = "Your Queue";

pub const UP_NEXT_PLAYING_KICKER: &str = "Up next · made for you";
pub const UP_NEXT_KICKER: &str = "Made for you";

pub const DAY_ONE_KICKER: &str = "Your library is in";
pub const DAY_ONE_TITLE: &str = "Start anywhere";
pub const SHUFFLE_LIBRARY: &str = "Shuffle Library";
pub const RADIO: &str = "Radio";

pub const LIBRARY_RADIO_TITLE: &str = "Library Radio";
pub const LIBRARY_RADIO_SUBTITLE: &str = "Endless, from everything";
pub const LIBRARY_RADIO_ID: &str = "library";
pub const MORE_MIXES_PLACEHOLDER: &str = "More mixes appear as you listen";

pub const A_YEAR_AGO_THIS_WEEK: &str = "A year ago this week";

pub const CUSTOMIZE_TITLE: &str = "Customize Home";
pub const CUSTOMIZE_INTRO: &str =
    "Drag to reorder. Turn a section off to hide it; it stays here for when you want it back.";
pub const CUSTOMIZE_FOOTER: &str = "Home is put together on this device from your library and what you play. Sections with nothing to show stay out of the way.";
pub const RESTORE_DEFAULT: &str = "Restore Default";

pub const OPEN_AT_LAUNCH: &str = "Open at launch";
pub const LAUNCH_HOME: &str = "Home";
pub const LAUNCH_WHERE_YOU_LEFT_OFF: &str = "Where you left off";

pub fn section_title(section: Section) -> &'static str {
    match section {
        Section::Resume => CONTINUE,
        Section::JumpBackIn => JUMP_BACK_IN,
        Section::MadeForYou => MADE_FOR_YOU,
        Section::RecentlyAdded => RECENTLY_ADDED,
        Section::OnThisDay => ON_THIS_DAY,
        Section::ThisWeek => THIS_WEEK,
    }
}

pub fn section_subtitle(section: Section) -> &'static str {
    match section {
        Section::Resume => "Your last album or playlist",
        Section::JumpBackIn => "Six things you played recently",
        Section::MadeForYou => "Mixes and Library Radio",
        Section::RecentlyAdded => "New in your library",
        Section::OnThisDay => "From your listening history",
        Section::ThisWeek => "A glance at Stats",
    }
}

const WEEKDAYS: [&str; 7] = [
    "Sunday",
    "Monday",
    "Tuesday",
    "Wednesday",
    "Thursday",
    "Friday",
    "Saturday",
];

const MONTHS: [&str; 12] = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
];

/// "Continue · just now", "… · yesterday", "… · Wednesday", "… · Oct 12".
pub fn resume_kicker(recency: Recency, offset_seconds: i32) -> String {
    let when = match recency {
        Recency::JustNow => "just now".to_string(),
        Recency::EarlierToday => "earlier today".to_string(),
        Recency::LastNight => "last night".to_string(),
        Recency::Yesterday => "yesterday".to_string(),
        Recency::Weekday(number) => WEEKDAYS[(number.clamp(1, 7) - 1) as usize].to_string(),
        Recency::Date(unix) => {
            let date = local(unix, offset_seconds);
            format!("{} {}", MONTHS[date.month0() as usize], date.day())
        }
    };
    format!("{CONTINUE} · {when}")
}

/// "5 · Slow Machine": the track's 1-based place in the queue.
pub fn resume_track_line(index: usize, title: &str) -> String {
    format!("{} · {}", index + 1, title)
}

/// Minutes round up and never read zero; from sixty minutes it is "1 h 5 min".
pub fn remaining_text(seconds: f64) -> String {
    let minutes = ((seconds.max(0.0) / 60.0).ceil() as i64).max(1);
    if minutes >= 60 {
        format!("{} h {} min left", minutes / 60, minutes % 60)
    } else {
        format!("{minutes} min left")
    }
}

pub fn song_count(count: usize) -> String {
    if count == 1 {
        "1 song".to_string()
    } else {
        format!("{count} songs")
    }
}

/// "38 min" under an hour, else "1 h 38 min".
pub fn duration_text(seconds: f64) -> String {
    let minutes = (seconds.max(0.0) / 60.0).round() as i64;
    if minutes >= 60 {
        format!("{} h {} min", minutes / 60, minutes % 60)
    } else {
        format!("{minutes} min")
    }
}

/// "24 songs · 1 h 38 min".
pub fn mix_meta(count: usize, seconds: f64) -> String {
    format!("{} · {}", song_count(count), duration_text(seconds))
}

/// "Starts with A, B and C": the first four names at most.
pub fn starts_with(names: &[String]) -> Option<String> {
    let names: Vec<&str> = names.iter().take(4).map(String::as_str).collect();
    match names.as_slice() {
        [] => None,
        [one] => Some(format!("Starts with {one}")),
        [first, last] => Some(format!("Starts with {first} and {last}")),
        [init @ .., last] => Some(format!("Starts with {} and {last}", init.join(", "))),
    }
}

pub fn up_next_kicker(is_playing: bool) -> &'static str {
    if is_playing {
        UP_NEXT_PLAYING_KICKER
    } else {
        UP_NEXT_KICKER
    }
}

/// "1,284 songs · 112 albums".
pub fn day_one_counts(songs: usize, albums: usize) -> String {
    format!(
        "{} {} · {} {}",
        group_digits(songs),
        if songs == 1 { "song" } else { "songs" },
        group_digits(albums),
        if albums == 1 { "album" } else { "albums" },
    )
}

/// "38 of them hi-res", nothing when none are.
pub fn hi_res_line(count: usize) -> Option<String> {
    (count > 0).then(|| format!("{} of them hi-res", group_digits(count)))
}

/// Lossless at more than CD depth or rate.
pub fn is_hi_res(lossless: bool, bit_depth: Option<i32>, sample_rate: Option<i32>) -> bool {
    lossless && (bit_depth.unwrap_or(0) > 16 || sample_rate.unwrap_or(0) > 48_000)
}

pub fn on_this_day_title(kind: OnThisDayKind, year: i32) -> String {
    match kind {
        OnThisDayKind::SameDay => format!("On this day in {year}"),
        OnThisDayKind::YearAgoThisWeek => A_YEAR_AGO_THIS_WEEK.to_string(),
    }
}

pub fn on_this_day_subtitle(album: &str, plays: usize) -> String {
    format!("{album}, {plays} plays")
}

/// "14 h 20 m", or "42 min" under an hour.
pub fn week_value(seconds: i64) -> String {
    let (hours, minutes) = crate::home::hours_and_minutes(seconds);
    if hours == 0 {
        format!("{minutes} min")
    } else {
        format!("{hours} h {minutes} m")
    }
}

/// "▲ 12% · 214": the chip when there is one, then the plays.
pub fn week_delta_line(delta: PeriodDelta, plays: i64) -> String {
    match delta.chip_text() {
        Some(chip) => format!("{chip} · {plays}"),
        None => plays.to_string(),
    }
}

pub fn downloading(count: usize) -> String {
    if count == 1 {
        "Downloading 1 song".to_string()
    } else {
        format!("Downloading {count} songs")
    }
}

pub fn show_more(count: usize) -> String {
    format!("Show {count} More")
}

/// The second line of a Jump Back In row.
pub fn jump_subtitle(context: &PlaybackContext, songs: usize) -> String {
    match context.kind {
        ContextKind::Album => context.subtitle.clone(),
        ContextKind::Playlist => format!("Playlist · {}", song_count(songs)),
        ContextKind::Mix => format!("Mix · {}", song_count(songs)),
        ContextKind::Radio => "Radio".to_string(),
        ContextKind::Queue => song_count(songs),
    }
}

/// What a queue with no album or playlist behind it is called.
pub fn queue_title() -> &'static str {
    YOUR_QUEUE
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{TimeZone, Utc};

    fn at(y: i32, m: u32, d: u32) -> i64 {
        Utc.with_ymd_and_hms(y, m, d, 12, 0, 0).unwrap().timestamp()
    }

    fn strings(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| n.to_string()).collect()
    }

    #[test]
    fn c1_section_titles_and_subtitles() {
        assert_eq!(section_title(Section::Resume), "Continue");
        assert_eq!(section_title(Section::JumpBackIn), "Jump Back In");
        assert_eq!(section_title(Section::MadeForYou), "Made for You");
        assert_eq!(section_title(Section::RecentlyAdded), "Recently Added");
        assert_eq!(section_title(Section::OnThisDay), "On This Day");
        assert_eq!(section_title(Section::ThisWeek), "This Week");
        assert_eq!(section_subtitle(Section::Resume), "Your last album or playlist");
        assert_eq!(section_subtitle(Section::ThisWeek), "A glance at Stats");
    }

    #[test]
    fn c2_resume_kickers_name_when_the_session_was_left() {
        assert_eq!(resume_kicker(Recency::JustNow, 0), "Continue · just now");
        assert_eq!(resume_kicker(Recency::EarlierToday, 0), "Continue · earlier today");
        assert_eq!(resume_kicker(Recency::LastNight, 0), "Continue · last night");
        assert_eq!(resume_kicker(Recency::Yesterday, 0), "Continue · yesterday");
        assert_eq!(resume_kicker(Recency::Weekday(4), 0), "Continue · Wednesday");
        assert_eq!(resume_kicker(Recency::Weekday(1), 0), "Continue · Sunday");
        assert_eq!(
            resume_kicker(Recency::Date(at(2026, 10, 12)), 0),
            "Continue · Oct 12"
        );
    }

    #[test]
    fn c3_a_date_kicker_follows_the_local_calendar() {
        let late = Utc.with_ymd_and_hms(2026, 10, 12, 23, 30, 0).unwrap().timestamp();
        assert_eq!(resume_kicker(Recency::Date(late), 0), "Continue · Oct 12");
        assert_eq!(resume_kicker(Recency::Date(late), 3 * 3600), "Continue · Oct 13");
    }

    #[test]
    fn c4_track_line_is_one_based() {
        assert_eq!(resume_track_line(4, "Slow Machine"), "5 · Slow Machine");
    }

    #[test]
    fn c5_remaining_rounds_minutes_up_and_never_reads_zero() {
        assert_eq!(remaining_text(0.0), "1 min left");
        assert_eq!(remaining_text(1.0), "1 min left");
        assert_eq!(remaining_text(60.0), "1 min left");
        assert_eq!(remaining_text(61.0), "2 min left");
        assert_eq!(remaining_text(18.0 * 60.0), "18 min left");
        assert_eq!(remaining_text(59.0 * 60.0 + 1.0), "1 h 0 min left");
        assert_eq!(remaining_text(3600.0), "1 h 0 min left");
        assert_eq!(remaining_text(3600.0 + 65.0 * 60.0), "2 h 5 min left");
    }

    #[test]
    fn c6_mix_meta_and_durations() {
        assert_eq!(duration_text(38.0 * 60.0), "38 min");
        assert_eq!(duration_text(98.0 * 60.0), "1 h 38 min");
        assert_eq!(duration_text(60.0 * 60.0), "1 h 0 min");
        assert_eq!(mix_meta(24, 98.0 * 60.0), "24 songs · 1 h 38 min");
        assert_eq!(mix_meta(1, 120.0), "1 song · 2 min");
    }

    #[test]
    fn c7_starts_with_lists_at_most_four_albums() {
        assert_eq!(starts_with(&[]), None);
        assert_eq!(starts_with(&strings(&["A"])), Some("Starts with A".into()));
        assert_eq!(
            starts_with(&strings(&["A", "B"])),
            Some("Starts with A and B".into())
        );
        assert_eq!(
            starts_with(&strings(&["A", "B", "C"])),
            Some("Starts with A, B and C".into())
        );
        assert_eq!(
            starts_with(&strings(&["A", "B", "C", "D", "E"])),
            Some("Starts with A, B, C and D".into())
        );
    }

    #[test]
    fn c8_up_next_kicker_follows_playback() {
        assert_eq!(up_next_kicker(true), "Up next · made for you");
        assert_eq!(up_next_kicker(false), "Made for you");
    }

    #[test]
    fn c9_day_one_copy() {
        assert_eq!(day_one_counts(1284, 112), "1\u{202f}284 songs · 112 albums");
        assert_eq!(day_one_counts(1, 1), "1 song · 1 album");
        assert_eq!(hi_res_line(38), Some("38 of them hi-res".into()));
        assert_eq!(hi_res_line(0), None);
    }

    #[test]
    fn c10_hi_res_means_more_than_cd_quality_and_lossless() {
        assert!(is_hi_res(true, Some(24), Some(48_000)));
        assert!(is_hi_res(true, Some(16), Some(96_000)));
        assert!(!is_hi_res(true, Some(16), Some(44_100)));
        assert!(!is_hi_res(true, None, None));
        assert!(!is_hi_res(false, Some(24), Some(96_000)));
    }

    #[test]
    fn c11_on_this_day_lines() {
        assert_eq!(
            on_this_day_title(OnThisDayKind::SameDay, 2023),
            "On this day in 2023"
        );
        assert_eq!(
            on_this_day_title(OnThisDayKind::YearAgoThisWeek, 2025),
            "A year ago this week"
        );
        assert_eq!(on_this_day_subtitle("Midnatt", 9), "Midnatt, 9 plays");
    }

    #[test]
    fn c12_week_value_truncates() {
        assert_eq!(week_value(14 * 3600 + 20 * 60 + 59), "14 h 20 m");
        assert_eq!(week_value(42 * 60), "42 min");
        assert_eq!(week_value(0), "0 min");
        assert_eq!(week_value(3600), "1 h 0 m");
    }

    #[test]
    fn c13_week_delta_line_pairs_the_chip_with_the_plays() {
        assert_eq!(week_delta_line(PeriodDelta::Up(12), 214), "▲ 12% · 214");
        assert_eq!(week_delta_line(PeriodDelta::Down(8), 9), "▼ 8% · 9");
        assert_eq!(week_delta_line(PeriodDelta::Even, 5), "Even · 5");
        assert_eq!(week_delta_line(PeriodDelta::New, 5), "New · 5");
        assert_eq!(week_delta_line(PeriodDelta::None, 5), "5");
    }

    #[test]
    fn c14_downloads_and_show_more() {
        assert_eq!(downloading(1), "Downloading 1 song");
        assert_eq!(downloading(2), "Downloading 2 songs");
        assert_eq!(show_more(3), "Show 3 More");
    }

    #[test]
    fn c15_jump_subtitles_by_kind() {
        let context = |kind, subtitle: &str| PlaybackContext {
            kind,
            id: "x".into(),
            title: "T".into(),
            subtitle: subtitle.into(),
        };
        assert_eq!(jump_subtitle(&context(ContextKind::Album, "Solveig"), 3), "Solveig");
        assert_eq!(
            jump_subtitle(&context(ContextKind::Playlist, ""), 42),
            "Playlist · 42 songs"
        );
        assert_eq!(jump_subtitle(&context(ContextKind::Mix, ""), 30), "Mix · 30 songs");
        assert_eq!(jump_subtitle(&context(ContextKind::Radio, ""), 0), "Radio");
    }

    #[test]
    fn c16_fixed_strings() {
        assert_eq!(CUSTOMIZE_TITLE, "Customize Home");
        assert_eq!(RESTORE_DEFAULT, "Restore Default");
        assert_eq!(LIBRARY_RADIO_SUBTITLE, "Endless, from everything");
        assert_eq!(MORE_MIXES_PLACEHOLDER, "More mixes appear as you listen");
        assert_eq!(queue_title(), "Your Queue");
        assert_eq!(song_count(5), "5 songs");
    }
}
