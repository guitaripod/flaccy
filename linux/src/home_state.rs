//! What Home remembers between launches: the last session (the queue as it
//! stood, so Continue can put it back) and the albums, playlists, mixes and
//! radios the person started. Both are small JSON files in the data directory,
//! written through a temporary file so a crash never leaves half of one.

use flaccy_shared::home::{PlaybackContext, RecentContexts, ResumePoint};
use serde::{Deserialize, Serialize};
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

const SESSION_FILE: &str = "session.json";
const RECENTS_FILE: &str = "recent-contexts.json";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SavedTrack {
    pub rel_path: String,
    pub duration: f64,
}

/// The queue as it stood when playback was last touched.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SavedSession {
    pub saved_at: i64,
    pub tracks: Vec<SavedTrack>,
    pub index: usize,
    pub elapsed: f64,
    pub context: PlaybackContext,
}

/// What of a saved queue can still be played: the songs whose files are
/// still in the library, where the listener was among them, and how far in.
#[derive(Clone, Debug, PartialEq)]
pub struct Surviving {
    pub tracks: Vec<SavedTrack>,
    pub index: usize,
    pub elapsed: f64,
}

impl SavedSession {
    /// Drops the songs `duration_of` no longer knows (it returns the length of
    /// one that is still there) and keeps the place in the queue: the song the
    /// listener was on when it survives, else the next one that does, from its
    /// start. `None` when nothing is left to play.
    pub fn surviving(&self, duration_of: impl Fn(&str) -> Option<f64>) -> Option<Surviving> {
        let mut tracks = Vec::new();
        let mut before_current = 0;
        let mut current_survives = false;
        for (position, saved) in self.tracks.iter().enumerate() {
            let Some(duration) = duration_of(&saved.rel_path) else {
                continue;
            };
            if position < self.index {
                before_current += 1;
            } else if position == self.index {
                current_survives = true;
            }
            tracks.push(SavedTrack {
                rel_path: saved.rel_path.clone(),
                duration,
            });
        }
        if tracks.is_empty() {
            return None;
        }
        let index = before_current.min(tracks.len() - 1);
        let kept_place = current_survives && before_current < tracks.len();
        Some(Surviving {
            tracks,
            index,
            elapsed: if kept_place { self.elapsed.max(0.0) } else { 0.0 },
        })
    }
}

impl Surviving {
    pub fn resume_point(&self, saved_at: i64) -> ResumePoint {
        ResumePoint {
            track_index: self.index,
            elapsed: self.elapsed,
            durations: self.tracks.iter().map(|track| track.duration).collect(),
            saved_at,
        }
    }
}

pub fn data_dir() -> PathBuf {
    dirs::data_dir().unwrap_or_default().join("flaccy")
}

fn session_path() -> PathBuf {
    data_dir().join(SESSION_FILE)
}

fn recents_path() -> PathBuf {
    data_dir().join(RECENTS_FILE)
}

pub fn load_session() -> Option<SavedSession> {
    read_json(&session_path())
}

pub fn save_session(session: &SavedSession) {
    write_json(&session_path(), session);
}

pub fn load_recents() -> RecentContexts {
    read_json(&recents_path()).unwrap_or_default()
}

pub fn save_recents(recents: &RecentContexts) {
    write_json(&recents_path(), recents);
}

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> Option<T> {
    serde_json::from_str(&fs::read_to_string(path).ok()?).ok()
}

fn write_json<T: Serialize>(path: &Path, value: &T) {
    match serde_json::to_vec(value) {
        Ok(bytes) => {
            if let Err(err) = write_atomically(path, &bytes) {
                crate::logger::error(
                    "database",
                    &format!("could not save {}: {err}", path.display()),
                );
            }
        }
        Err(err) => crate::logger::error("database", &format!("could not encode state: {err}")),
    }
}

/// Writes `bytes` beside `path` and renames them over it, so a reader sees the
/// old file or the new one and never a torn one.
fn write_atomically(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut temporary = path.as_os_str().to_owned();
    temporary.push(".tmp");
    let temporary = PathBuf::from(temporary);
    {
        let mut file = fs::File::create(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    fs::rename(&temporary, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use flaccy_shared::home::ContextKind;

    fn saved(rel_paths: &[&str], index: usize, elapsed: f64) -> SavedSession {
        SavedSession {
            saved_at: 1_000,
            tracks: rel_paths
                .iter()
                .map(|rel| SavedTrack {
                    rel_path: rel.to_string(),
                    duration: 100.0,
                })
                .collect(),
            index,
            elapsed,
            context: PlaybackContext::anonymous_queue(),
        }
    }

    fn only(present: &'static [&'static str]) -> impl Fn(&str) -> Option<f64> {
        move |rel| present.contains(&rel).then_some(200.0)
    }

    #[test]
    fn an_intact_queue_keeps_its_place_and_takes_the_library_durations() {
        let session = saved(&["a", "b", "c"], 1, 42.0);
        let plan = session.surviving(only(&["a", "b", "c"])).unwrap();
        assert_eq!(plan.index, 1);
        assert_eq!(plan.elapsed, 42.0);
        assert_eq!(plan.tracks.len(), 3);
        assert!(plan.tracks.iter().all(|track| track.duration == 200.0));
    }

    #[test]
    fn a_missing_song_before_the_current_one_shifts_the_index() {
        let session = saved(&["a", "b", "c", "d"], 2, 30.0);
        let plan = session.surviving(only(&["a", "c", "d"])).unwrap();
        assert_eq!(plan.index, 1);
        assert_eq!(plan.tracks[plan.index].rel_path, "c");
        assert_eq!(plan.elapsed, 30.0);
    }

    #[test]
    fn a_missing_current_song_moves_on_to_the_next_from_its_start() {
        let session = saved(&["a", "b", "c", "d"], 1, 30.0);
        let plan = session.surviving(only(&["a", "c", "d"])).unwrap();
        assert_eq!(plan.tracks[plan.index].rel_path, "c");
        assert_eq!(plan.elapsed, 0.0);
    }

    #[test]
    fn a_missing_last_song_falls_back_to_the_last_that_remains() {
        let session = saved(&["a", "b", "c"], 2, 30.0);
        let plan = session.surviving(only(&["a", "b"])).unwrap();
        assert_eq!(plan.tracks[plan.index].rel_path, "b");
        assert_eq!(plan.elapsed, 0.0);
    }

    #[test]
    fn a_queue_with_nothing_left_has_no_plan() {
        let session = saved(&["a", "b"], 0, 5.0);
        assert!(session.surviving(only(&[])).is_none());
    }

    #[test]
    fn the_resume_point_carries_place_progress_and_age() {
        let session = saved(&["a", "b", "c"], 1, 42.0);
        let point = session
            .surviving(only(&["a", "b", "c"]))
            .unwrap()
            .resume_point(session.saved_at);
        assert_eq!(point.track_index, 1);
        assert_eq!(point.elapsed, 42.0);
        assert_eq!(point.durations, vec![200.0; 3]);
        assert_eq!(point.saved_at, 1_000);
    }

    #[test]
    fn a_session_survives_a_json_round_trip() {
        let mut session = saved(&["a", "b"], 1, 12.5);
        session.context = PlaybackContext {
            kind: ContextKind::Mix,
            id: "on-repeat".into(),
            title: "On Repeat".into(),
            subtitle: "Solveig".into(),
        };
        let text = serde_json::to_string(&session).unwrap();
        assert!(text.contains("\"mix\""));
        assert_eq!(serde_json::from_str::<SavedSession>(&text).unwrap(), session);
    }

    #[test]
    fn writing_replaces_the_file_whole_and_leaves_no_temporary_behind() {
        let dir = std::env::temp_dir().join(format!("flaccy-home-state-{}", std::process::id()));
        let path = dir.join("nested").join("session.json");
        write_atomically(&path, b"first").unwrap();
        write_atomically(&path, b"second").unwrap();
        assert_eq!(fs::read_to_string(&path).unwrap(), "second");
        let leftovers: Vec<_> = fs::read_dir(path.parent().unwrap())
            .unwrap()
            .flatten()
            .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
            .collect();
        assert!(leftovers.is_empty());
        let _ = fs::remove_dir_all(&dir);
    }
}
