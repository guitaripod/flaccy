//! The library as the planner sees it: every song with how far it is from
//! playing and how often the listener plays it.

use crate::db::Db;
use crate::library::Track;
use flaccy_library::recap::track_key;
use flaccy_shared::precache::Candidate;
use std::collections::HashMap;

const DAY_SECONDS: i64 = 24 * 60 * 60;

/// Songs ahead of the playing one the snapshot of the queue carries.
pub const QUEUE_WINDOW: usize = flaccy_shared::precache::LYRICS_QUEUE_DEPTH + 1;

/// A song of the library and what the planner makes of it. `candidate.key` is
/// the song's path in the library.
pub struct Ranked {
    pub track: Track,
    pub candidate: Candidate,
}

/// Every song with its distance in `queue` (index 0 is the playing song) and
/// its plays. The rest of the playing song's album counts as in progress.
pub fn build(db: &Db, queue: &[Track], now_unix: i64) -> Vec<Ranked> {
    let month = db.listen_tallies(Some(now_unix - 30 * DAY_SECONDS));
    let ever = db.listen_tallies(None);
    let mut distance: HashMap<&str, usize> = HashMap::new();
    for (index, track) in queue.iter().enumerate() {
        distance.entry(track.rel_path.as_str()).or_insert(index);
    }
    let playing = queue.first();
    db.fetch_all_tracks()
        .into_iter()
        .map(|track| {
            let key = track_key(&track.title, &track.artist);
            let sibling = playing.is_some_and(|playing| {
                playing.rel_path != track.rel_path
                    && playing.album == track.album
                    && playing.credit() == track.credit()
            });
            let candidate = Candidate {
                key: track.rel_path.clone(),
                queue_distance: distance.get(track.rel_path.as_str()).copied(),
                album_sibling: sibling,
                plays_30_days: month.get(&key).map_or(0, |tally| tally.plays),
                plays_total: ever.get(&key).map_or(0, |tally| tally.plays),
                days_since_played: track
                    .last_played
                    .map(|played| (now_unix - played).max(0) as f64 / DAY_SECONDS as f64),
                days_since_added: (now_unix - track.date_added).max(0) as f64 / DAY_SECONDS as f64,
            };
            Ranked { track, candidate }
        })
        .collect()
}

#[cfg(test)]
pub(crate) mod fixtures {
    use crate::db::{Db, NewTrack};
    use std::path::PathBuf;

    pub struct TempDb {
        dir: PathBuf,
        pub db: Db,
    }

    impl Drop for TempDb {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    pub fn temp_db(name: &str) -> TempDb {
        let dir = std::env::temp_dir().join(format!("flaccy-precache-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let db = Db::open(&dir.join("library.sqlite")).expect("temp db opens");
        TempDb { dir, db }
    }

    pub fn insert(db: &Db, rel_path: &str, title: &str, artist: &str, album: &str) {
        db.insert_track(&NewTrack {
            rel_path: rel_path.to_string(),
            title: title.to_string(),
            artist: artist.to_string(),
            album: album.to_string(),
            album_artist: Some(artist.to_string()),
            track_number: 1,
            duration: 200.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            artwork: None,
            signature: None,
            fingerprint: None,
        })
        .expect("track inserts");
    }

    pub fn library(db: &Db) {
        insert(db, "x/1.flac", "Opening", "Pilot", "Album X");
        insert(db, "x/2.flac", "Second", "Pilot", "Album X");
        insert(db, "x/3.flac", "Third", "Pilot", "Album X");
        insert(db, "y/1.flac", "Favourite", "Other", "Album Y");
        insert(db, "z/1.flac", "Stranger", "Third", "Album Z");
        let day = 86_400;
        let now = chrono::Utc::now().timestamp();
        for age in 1..=4 {
            db.insert_scrobble("Favourite", "Other", "Album Y", now - age * day, 200, true)
                .expect("scrobble inserts");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fixtures::{library, temp_db};
    use super::*;

    fn queue(db: &Db, rel_paths: &[&str]) -> Vec<Track> {
        let all = db.fetch_all_tracks();
        rel_paths
            .iter()
            .map(|path| all.iter().find(|track| track.rel_path == *path).unwrap().clone())
            .collect()
    }

    fn find<'a>(ranked: &'a [Ranked], rel_path: &str) -> &'a Candidate {
        &ranked.iter().find(|entry| entry.candidate.key == rel_path).unwrap().candidate
    }

    #[test]
    fn distance_siblings_and_plays_are_read_from_the_queue_and_the_history() {
        let temp = temp_db("candidates");
        library(&temp.db);
        let playing = queue(&temp.db, &["x/1.flac", "x/2.flac"]);
        let ranked = build(&temp.db, &playing, chrono::Utc::now().timestamp());
        assert_eq!(ranked.len(), 5);
        assert_eq!(find(&ranked, "x/1.flac").queue_distance, Some(0));
        assert_eq!(find(&ranked, "x/2.flac").queue_distance, Some(1));
        assert_eq!(find(&ranked, "x/3.flac").queue_distance, None);
        assert!(find(&ranked, "x/3.flac").album_sibling);
        assert!(find(&ranked, "x/2.flac").album_sibling);
        assert!(!find(&ranked, "x/1.flac").album_sibling);
        assert!(!find(&ranked, "y/1.flac").album_sibling);
        let favourite = find(&ranked, "y/1.flac");
        assert_eq!((favourite.plays_30_days, favourite.plays_total), (4, 4));
        let stranger = find(&ranked, "z/1.flac");
        assert_eq!((stranger.plays_30_days, stranger.plays_total), (0, 0));
    }

    #[test]
    fn an_empty_queue_still_ranks_the_library_by_habit() {
        let temp = temp_db("candidates-empty");
        library(&temp.db);
        let ranked = build(&temp.db, &[], chrono::Utc::now().timestamp());
        assert!(ranked.iter().all(|entry| entry.candidate.queue_distance.is_none()));
        assert!(ranked.iter().all(|entry| !entry.candidate.album_sibling));
        assert_eq!(find(&ranked, "y/1.flac").plays_30_days, 4);
    }
}
