//! Fetches lyrics before they are asked for. The lane works down the planner's
//! order one song at a time, behind the same gate as the lyrics panel, and
//! rests when lrclib or the network does.

use super::candidates::{self, Ranked};
use super::governor::{Breaker, LRCLIB};
use super::status::{self, LaneState};
use crate::db::Db;
use crate::library::Track;
use crate::lyrics::{self, LyricsResult, Pace};
use flaccy_shared::lyrics::LyricsFailure;
use flaccy_shared::precache::{lyrics_order, Failure};
use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

/// What the lane is asked to prepare: the queue as it stands, and whether the
/// whole library is wanted or only what the listener plays.
#[derive(Clone)]
pub struct Intent {
    pub queue: Vec<Track>,
    pub whole_library: bool,
}

/// How long the lane naps between looks at a gate, a rest or the network, so a
/// new intent is picked up within a second.
const NAP: Duration = Duration::from_millis(500);

pub fn spawn(
    db_path: PathBuf,
    music_root: PathBuf,
    blocker: super::Blocker,
) -> async_channel::Sender<Option<Intent>> {
    let (tx, rx) = async_channel::unbounded::<Option<Intent>>();
    std::thread::Builder::new()
        .name("flaccy-lyrics-lane".into())
        .spawn(move || run(&db_path, &music_root, &*blocker, &rx))
        .ok();
    tx
}

fn newest(rx: &async_channel::Receiver<Option<Intent>>) -> Option<Option<Intent>> {
    let mut latest = None;
    while let Ok(intent) = rx.try_recv() {
        latest = Some(intent);
    }
    latest
}

fn run(
    db_path: &PathBuf,
    music_root: &PathBuf,
    blocker: &dyn Fn() -> Option<&'static str>,
    rx: &async_channel::Receiver<Option<Intent>>,
) {
    let mut breaker = Breaker::default();
    let mut intent = None;
    loop {
        if intent.is_none() {
            match rx.recv_blocking() {
                Ok(next) => intent = Some(next),
                Err(_) => return,
            }
        }
        if let Some(newer) = newest(rx) {
            intent = Some(newer);
        }
        let Some(Some(current)) = intent.clone() else {
            status::update(|status| {
                status.lyrics = LaneState::Off;
                status.lyrics_waiting = 0;
            });
            intent = None;
            continue;
        };
        let Ok(db) = Db::open(db_path) else {
            std::thread::sleep(NAP);
            continue;
        };
        let pending = pending_tracks(&db, &current);
        status::update(|status| status.lyrics_waiting = pending.len());
        if pending.is_empty() {
            status::update(|status| status.lyrics = LaneState::Idle);
            intent = None;
            continue;
        }
        match work(&pending, music_root, db_path, blocker, rx, &mut breaker) {
            Worked::Finished => {
                status::update(|status| status.lyrics = LaneState::Idle);
                intent = None;
            }
            Worked::Replaced(next) => intent = Some(next),
        }
    }
}

enum Worked {
    Finished,
    Replaced(Option<Intent>),
}

/// The tracks that still need a lookup, in the order the planner wants them.
fn pending_tracks(db: &Db, intent: &Intent) -> Vec<Track> {
    let now = chrono::Utc::now().timestamp();
    let ranked = candidates::build(db, &intent.queue, now);
    let order = lyrics_order(
        &ranked
            .iter()
            .map(|entry| entry.candidate.clone())
            .collect::<Vec<_>>(),
        intent.whole_library,
    );
    let mut by_key: HashMap<String, Ranked> = ranked
        .into_iter()
        .map(|entry| (entry.candidate.key.clone(), entry))
        .collect();
    order
        .into_iter()
        .filter_map(|key| by_key.remove(&key))
        .map(|entry| entry.track)
        .filter(|track| !lyrics::is_cached(db, track))
        .collect()
}

fn work(
    pending: &[Track],
    music_root: &PathBuf,
    db_path: &PathBuf,
    blocker: &dyn Fn() -> Option<&'static str>,
    rx: &async_channel::Receiver<Option<Intent>>,
    breaker: &mut Breaker,
) -> Worked {
    let total = pending.len();
    for (done, track) in pending.iter().enumerate() {
        loop {
            if let Some(newer) = newest(rx) {
                return Worked::Replaced(newer);
            }
            let rest = breaker.rest_left().max(LRCLIB.cooldown_left());
            if !rest.is_zero() {
                let until = chrono::Utc::now().timestamp() + rest.as_secs() as i64;
                let reason = rest_reason(breaker.last());
                status::update(|status| {
                    status.lyrics = LaneState::Resting {
                        until_unix: until,
                        reason,
                    }
                });
                std::thread::sleep(rest.min(NAP));
                continue;
            }
            if let Some(reason) = blocker() {
                status::update(|status| {
                    status.lyrics = LaneState::Resting {
                        until_unix: chrono::Utc::now().timestamp() + 5,
                        reason: reason.to_string(),
                    }
                });
                std::thread::sleep(NAP);
                continue;
            }
            break;
        }
        status::update(|status| {
            status.lyrics = LaneState::Working;
            status.lyrics_waiting = total - done;
        });
        match lyrics::fetch_shared(db_path, music_root, track, Pace::Immediate) {
            Some(LyricsResult::Failed(failure)) => {
                let class = classify(&failure);
                crate::logger::warn(
                    "precache",
                    &format!("lyrics for {} failed ({}): {failure:?}", track.title, class.id()),
                );
                breaker.failed(class);
            }
            Some(_) => {
                breaker.succeeded();
                status::update(|status| status.lyrics_prepared += 1);
            }
            None => {}
        }
    }
    Worked::Finished
}

fn classify(failure: &LyricsFailure) -> Failure {
    match failure {
        LyricsFailure::Busy => Failure::Throttled,
        LyricsFailure::Rejected(_) => Failure::Blocked,
        LyricsFailure::Unreachable | LyricsFailure::TimedOut | LyricsFailure::Server(_) => {
            Failure::Transient
        }
    }
}

fn rest_reason(last: Option<Failure>) -> String {
    match last {
        Some(Failure::Throttled) => "lrclib asked for fewer requests".to_string(),
        Some(Failure::Blocked) => "lrclib turned the requests away".to_string(),
        Some(Failure::Transient) => "lrclib could not be reached".to_string(),
        _ => "lrclib asked for fewer requests".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::super::candidates::fixtures::{library, temp_db};
    use super::*;
    use crate::db::LyricsContent;

    fn intent(db: &Db, rel_paths: &[&str], whole_library: bool) -> Intent {
        let all = db.fetch_all_tracks();
        Intent {
            queue: rel_paths
                .iter()
                .map(|path| all.iter().find(|track| track.rel_path == *path).unwrap().clone())
                .collect(),
            whole_library,
        }
    }

    fn rel_paths(tracks: &[Track]) -> Vec<&str> {
        tracks.iter().map(|track| track.rel_path.as_str()).collect()
    }

    #[test]
    fn the_queue_comes_first_then_habit_then_the_album_and_never_the_stranger() {
        let temp = temp_db("lane-order");
        library(&temp.db);
        let pending = pending_tracks(&temp.db, &intent(&temp.db, &["x/1.flac", "x/2.flac"], false));
        assert_eq!(rel_paths(&pending), ["x/1.flac", "x/2.flac", "y/1.flac", "x/3.flac"]);
    }

    #[test]
    fn the_whole_library_adds_the_stranger_last() {
        let temp = temp_db("lane-whole");
        library(&temp.db);
        let pending = pending_tracks(&temp.db, &intent(&temp.db, &["x/1.flac"], true));
        assert_eq!(rel_paths(&pending).last(), Some(&"z/1.flac"));
        assert_eq!(pending.len(), 5);
    }

    #[test]
    fn a_song_whose_lyrics_or_miss_are_stored_needs_no_lookup() {
        let temp = temp_db("lane-cached");
        library(&temp.db);
        let miss = LyricsContent {
            synced: None,
            plain: None,
            lyricsfile: None,
            instrumental: false,
            revision: 2,
        };
        temp.db.save_lyrics("Second", "Pilot", &miss).unwrap();
        let pending = pending_tracks(&temp.db, &intent(&temp.db, &["x/1.flac", "x/2.flac"], false));
        assert_eq!(rel_paths(&pending), ["x/1.flac", "y/1.flac", "x/3.flac"]);
    }

    #[test]
    fn what_each_failure_means_for_the_lane() {
        assert_eq!(classify(&LyricsFailure::Busy), Failure::Throttled);
        assert_eq!(classify(&LyricsFailure::Rejected(403)), Failure::Blocked);
        assert_eq!(classify(&LyricsFailure::TimedOut), Failure::Transient);
        assert_eq!(classify(&LyricsFailure::Server(502)), Failure::Transient);
    }
}
