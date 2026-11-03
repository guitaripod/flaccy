//! One artist's listening history as their page tells it: how often, since
//! when, in which years, which songs, and where the artist ranks among
//! everyone the person listens to.

use crate::recap::MIN_DATED_UNIX;
use chrono::{Local, TimeZone};
use std::collections::HashMap;

/// One stored play of the artist.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArtistPlay {
    pub timestamp_unix: i64,
    pub title_key: String,
    pub title: String,
    /// Seconds played, 0 for a play pulled from Last.fm without a length.
    pub duration: i64,
}

/// One song's plays, under the spelling heard most.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SongPlays {
    pub title_key: String,
    pub title: String,
    pub plays: i64,
    pub measured_seconds: i64,
    /// Plays stored without a length, whose minutes the caller estimates
    /// from the library's copy of the song.
    pub unmeasured_plays: i64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ArtistListening {
    pub plays: i64,
    /// The earliest dated play: when, and the song.
    pub first: Option<(i64, String)>,
    pub last_unix: Option<i64>,
    /// Plays per local calendar year, oldest first, from the year of the first
    /// dated play through `through_year`, quiet years included as zero so the
    /// timeline shows the gaps too.
    pub years: Vec<(i32, i64)>,
    /// Most played first, then by title.
    pub songs: Vec<SongPlays>,
    /// 1 for the person's most played artist; `None` without plays.
    pub rank: Option<usize>,
}

impl ArtistListening {
    /// The year with the most plays, the latest of a tie.
    pub fn peak_year(&self) -> Option<(i32, i64)> {
        self.years
            .iter()
            .copied()
            .filter(|(_, plays)| *plays > 0)
            .max_by_key(|(year, plays)| (*plays, *year))
    }
}

/// Folds an artist's plays into their listening history, with the timeline
/// running through `through_year` (the current year, so a quiet spell since
/// the last play shows as one).
pub fn tally(plays: &[ArtistPlay], through_year: i32) -> ArtistListening {
    struct Song {
        spellings: HashMap<String, (i64, i64)>,
        plays: i64,
        measured_seconds: i64,
        unmeasured_plays: i64,
    }
    let mut songs: HashMap<&str, Song> = HashMap::new();
    let mut years: HashMap<i32, i64> = HashMap::new();
    let mut first: Option<(i64, &str)> = None;
    let mut last_unix: Option<i64> = None;
    for play in plays {
        let song = songs.entry(play.title_key.as_str()).or_insert_with(|| Song {
            spellings: HashMap::new(),
            plays: 0,
            measured_seconds: 0,
            unmeasured_plays: 0,
        });
        song.plays += 1;
        if play.duration > 0 {
            song.measured_seconds += play.duration;
        } else {
            song.unmeasured_plays += 1;
        }
        let spelling = song.spellings.entry(play.title.clone()).or_insert((0, i64::MIN));
        spelling.0 += 1;
        spelling.1 = spelling.1.max(play.timestamp_unix);
        if play.timestamp_unix < MIN_DATED_UNIX {
            continue;
        }
        *years.entry(local_year(play.timestamp_unix)).or_insert(0) += 1;
        if first.is_none_or(|(at, _)| play.timestamp_unix < at) {
            first = Some((play.timestamp_unix, play.title.as_str()));
        }
        last_unix = Some(last_unix.map_or(play.timestamp_unix, |at| at.max(play.timestamp_unix)));
    }
    let timeline = match years.keys().min() {
        Some(&start) => {
            let end = through_year.max(*years.keys().max().unwrap_or(&start));
            (start..=end).map(|year| (year, years.get(&year).copied().unwrap_or(0))).collect()
        }
        None => Vec::new(),
    };
    let mut songs: Vec<SongPlays> = songs
        .into_iter()
        .map(|(title_key, song)| SongPlays {
            title_key: title_key.to_string(),
            title: most_heard(song.spellings),
            plays: song.plays,
            measured_seconds: song.measured_seconds,
            unmeasured_plays: song.unmeasured_plays,
        })
        .collect();
    songs.sort_by(|a, b| b.plays.cmp(&a.plays).then_with(|| a.title.cmp(&b.title)));
    ArtistListening {
        plays: plays.len() as i64,
        first: first.map(|(at, title)| (at, title.to_string())),
        last_unix,
        years: timeline,
        songs,
        rank: None,
    }
}

/// The spelling heard most, ties to the one heard last, then the
/// alphabetically first.
fn most_heard(spellings: HashMap<String, (i64, i64)>) -> String {
    spellings
        .into_iter()
        .max_by(|(a_name, a), (b_name, b)| a.cmp(b).then_with(|| b_name.cmp(a_name)))
        .map(|(name, _)| name)
        .unwrap_or_default()
}

fn local_year(unix: i64) -> i32 {
    use chrono::Datelike;
    Local
        .timestamp_opt(unix, 0)
        .single()
        .map(|at| at.year())
        .unwrap_or(1970)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn play(at: i64, title: &str, duration: i64) -> ArtistPlay {
        ArtistPlay {
            timestamp_unix: at,
            title_key: crate::listen_history::title_key(title),
            title: title.to_string(),
            duration,
        }
    }

    fn mid_year(year: i32) -> i64 {
        Local
            .with_ymd_and_hms(year, 6, 15, 12, 0, 0)
            .single()
            .expect("mid-year instant")
            .timestamp()
    }

    #[test]
    fn songs_fold_spellings_and_split_measured_from_unmeasured_plays() {
        let plays = vec![
            play(mid_year(2019), "One", 400),
            play(mid_year(2019) + 60, "One - Remastered", 0),
            play(mid_year(2020), "One", 0),
            play(mid_year(2020) + 60, "Fade to Black", 420),
        ];
        let listening = tally(&plays, 2020);
        assert_eq!(listening.plays, 4);
        assert_eq!(listening.songs.len(), 2);
        let one = &listening.songs[0];
        assert_eq!(one.title, "One");
        assert_eq!((one.plays, one.measured_seconds, one.unmeasured_plays), (3, 400, 2));
        assert_eq!(listening.songs[1].title, "Fade to Black");
    }

    #[test]
    fn the_timeline_keeps_quiet_years_and_runs_through_the_given_year() {
        let plays = vec![
            play(mid_year(2016), "A", 200),
            play(mid_year(2016) + 1, "A", 200),
            play(mid_year(2018), "B", 200),
        ];
        let listening = tally(&plays, 2020);
        assert_eq!(
            listening.years,
            vec![(2016, 2), (2017, 0), (2018, 1), (2019, 0), (2020, 0)]
        );
        assert_eq!(listening.peak_year(), Some((2016, 2)));
        assert_eq!(listening.first.as_ref().map(|(_, title)| title.as_str()), Some("A"));
        assert_eq!(listening.last_unix, Some(mid_year(2018)));
    }

    #[test]
    fn undated_plays_count_but_stay_off_the_timeline_and_first_play() {
        let plays = vec![play(0, "Old", 200), play(mid_year(2021), "New", 200)];
        let listening = tally(&plays, 2021);
        assert_eq!(listening.plays, 2);
        assert_eq!(listening.years, vec![(2021, 1)]);
        assert_eq!(listening.first, Some((mid_year(2021), "New".to_string())));
    }

    #[test]
    fn a_peak_tie_goes_to_the_later_year() {
        let plays = vec![play(mid_year(2010), "A", 1), play(mid_year(2012), "A", 1)];
        assert_eq!(tally(&plays, 2012).peak_year(), Some((2012, 1)));
    }

    #[test]
    fn no_plays_is_an_empty_history() {
        let listening = tally(&[], 2024);
        assert_eq!(listening, ArtistListening::default());
        assert_eq!(listening.peak_year(), None);
    }
}
