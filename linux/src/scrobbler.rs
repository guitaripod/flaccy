use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use crate::lastfm::{BatchOutcome, LastFmClient, ScrobbleEntry};
use crate::library::Track;
use std::path::PathBuf;
use std::rc::Rc;

pub struct CurrentPlay {
    pub track: Track,
    pub started_unix: i64,
    pub scrobbled: bool,
    pub counted: bool,
    pub played_seconds: f64,
    pub last_position: f64,
}

const MAX_TICK_DELTA: f64 = 1.0;

fn eligibility_threshold(duration: f64) -> f64 {
    (duration / 2.0).max(30.0).min(240.0)
}

fn client_for(core: &AppCore) -> Option<LastFmClient> {
    let session = core.session.borrow();
    LastFmClient::new(session.as_ref().map(|s| s.key.clone()))
}

pub fn on_track_started(core: &Rc<AppCore>, track: Option<Track>) {
    match track {
        Some(track) => {
            *core.current_play.borrow_mut() = Some(CurrentPlay {
                track: track.clone(),
                started_unix: chrono::Utc::now().timestamp(),
                scrobbled: false,
                counted: false,
                played_seconds: 0.0,
                last_position: 0.0,
            });
            if let Some(client) = client_for(core) {
                if client.session_key.is_some() {
                    std::thread::spawn(move || {
                        client.update_now_playing(
                            &track.title,
                            &track.artist,
                            &track.album,
                            track.duration.round() as i64,
                        );
                    });
                }
            }
        }
        None => {
            *core.current_play.borrow_mut() = None;
        }
    }
}

pub fn on_tick(core: &Rc<AppCore>, position: f64) {
    let ready = {
        let mut play = core.current_play.borrow_mut();
        let Some(play) = play.as_mut() else { return };
        let delta = position - play.last_position;
        play.last_position = position;
        if delta > 0.0 {
            play.played_seconds += delta.min(MAX_TICK_DELTA);
        }
        if play.scrobbled || play.played_seconds < eligibility_threshold(play.track.duration) {
            return;
        }
        play.scrobbled = true;
        let counted = play.counted;
        play.counted = true;
        (play.track.clone(), play.started_unix, counted)
    };
    persist_scrobble(core, &ready.0, ready.1, false, !ready.2);
    drain_pending(core);
}

pub fn checkpoint_skip(core: &Rc<AppCore>) {
    let ready = {
        let mut play = core.current_play.borrow_mut();
        let Some(play) = play.as_mut() else { return };
        if play.scrobbled || play.played_seconds < eligibility_threshold(play.track.duration) {
            return;
        }
        play.scrobbled = true;
        let counted = play.counted;
        play.counted = true;
        (play.track.clone(), play.started_unix, counted)
    };
    persist_scrobble(core, &ready.0, ready.1, false, !ready.2);
    drain_pending(core);
}

pub fn on_natural_end(core: &Rc<AppCore>, track: &Track) {
    let action = {
        let mut play = core.current_play.borrow_mut();
        let Some(play) = play.as_mut() else { return };
        if play.track.rel_path != track.rel_path {
            return;
        }
        if play.scrobbled {
            None
        } else {
            play.scrobbled = true;
            let eligible = track.duration >= eligibility_threshold(track.duration);
            let counted = play.counted;
            play.counted = true;
            Some((play.started_unix, eligible, counted))
        }
    };
    if let Some((started, eligible, counted)) = action {
        persist_scrobble(core, track, started, !eligible, !counted);
        if eligible {
            drain_pending(core);
        }
    }
}

fn persist_scrobble(
    core: &Rc<AppCore>,
    track: &Track,
    started_unix: i64,
    local_only: bool,
    count_play: bool,
) {
    if let Err(err) = core.db.insert_scrobble(
        &track.title,
        &track.artist,
        &track.album,
        started_unix,
        track.duration.round() as i64,
        local_only,
    ) {
        crate::logger::error("scrobble", &format!("insert scrobble failed: {err}"));
        return;
    }
    if count_play {
        if let Err(err) = core.db.increment_play_count(&track.rel_path) {
            crate::logger::error("database", &format!("play count failed: {err}"));
        }
    }
    crate::logger::info(
        "scrobble",
        &format!(
            "scrobble recorded ({}): {} — {}",
            if local_only { "local only" } else { "pending" },
            track.title,
            track.artist
        ),
    );
}

pub fn drain_pending(core: &Rc<AppCore>) {
    if core.drain_in_flight.get() {
        return;
    }
    let Some(client) = client_for(core) else { return };
    if client.session_key.is_none() {
        return;
    }
    core.drain_in_flight.set(true);
    let flag = Rc::clone(&core.drain_in_flight);
    let db_path = core.db_path.clone();
    let (tx, rx) = async_channel::bounded::<usize>(1);
    std::thread::spawn(move || {
        let submitted = drain_blocking(&db_path, &client);
        let _ = tx.send_blocking(submitted);
    });
    gtk::glib::spawn_future_local(async move {
        let submitted = rx.recv().await.unwrap_or(0);
        flag.set(false);
        if submitted > 0 {
            crate::logger::info("scrobble", &format!("drained {submitted} pending scrobbles"));
        }
    });
}

fn drain_blocking(db_path: &PathBuf, client: &LastFmClient) -> usize {
    let Ok(db) = Db::open(db_path) else { return 0 };
    let pending = db.fetch_pending_scrobbles();
    if pending.is_empty() {
        return 0;
    }
    let mut submitted_total = 0;
    for chunk in pending.chunks(50) {
        let entries: Vec<ScrobbleEntry> = chunk
            .iter()
            .map(|p| ScrobbleEntry {
                id: p.id,
                title: p.title.clone(),
                artist: p.artist.clone(),
                album: p.album.clone(),
                timestamp: p.timestamp_unix,
                duration: p.duration,
            })
            .collect();
        match client.scrobble_batch(&entries) {
            Ok(BatchOutcome::Submitted(ids)) => {
                submitted_total += ids.len();
                mark_submitted_with_retry(&db, &ids);
            }
            Ok(BatchOutcome::Retryable { code, message }) => {
                crate::logger::warn(
                    "scrobble",
                    &format!("batch deferred (error {code}: {message}), {} kept pending", chunk.len()),
                );
            }
            Err(err) => {
                crate::logger::warn("scrobble", &format!("batch failed, kept pending: {err}"));
                break;
            }
        }
    }
    submitted_total
}

/// Retries the local submitted-flag update because the network submit already
/// succeeded: leaving rows pending after Last.fm accepted them would re-submit
/// duplicates on the next drain.
fn mark_submitted_with_retry(db: &Db, ids: &[i64]) {
    for attempt in 0..3 {
        match db.mark_scrobbles_submitted(ids) {
            Ok(()) => return,
            Err(err) => {
                crate::logger::error(
                    "scrobble",
                    &format!("mark submitted failed (attempt {}): {err}", attempt + 1),
                );
                std::thread::sleep(std::time::Duration::from_millis(250));
            }
        }
    }
}

pub fn submit_love(core: &Rc<AppCore>, rel_path: &str, title: &str, artist: &str, loved: bool) {
    let Some(client) = client_for(core) else { return };
    if client.session_key.is_none() {
        return;
    }
    let db_path = core.db_path.clone();
    let rel_path = rel_path.to_string();
    let title = title.to_string();
    let artist = artist.to_string();
    std::thread::spawn(move || match client.set_love(&title, &artist, loved) {
        Ok(()) => {
            if let Ok(db) = Db::open(&db_path) {
                let _ = db.clear_pending_love_op(&rel_path);
            }
        }
        Err(err) => {
            crate::logger::warn("scrobble", &format!("love submit failed, kept pending: {err}"));
        }
    });
}

pub fn flush_pending_love_ops(core: &Rc<AppCore>) {
    let Some(client) = client_for(core) else { return };
    if client.session_key.is_none() {
        return;
    }
    let db_path = core.db_path.clone();
    std::thread::spawn(move || {
        let Ok(db) = Db::open(&db_path) else { return };
        for op in db.fetch_pending_love_ops() {
            let loved = op.op == "love";
            match client.set_love(&op.title, &op.artist, loved) {
                Ok(()) => {
                    let _ = db.clear_pending_love_op(&op.rel_path);
                }
                Err(err) => {
                    crate::logger::warn("scrobble", &format!("pending love flush failed: {err}"));
                    break;
                }
            }
        }
    });
}

/// Splits library tracks into love/unlove reconciliation lists against the
/// remote loved set (keys: lowercased "title\0artist"), skipping tracks with a
/// pending local op — the journal wins until drained (iOS syncLovedFromLastFM).
pub fn reconcile_loved(
    tracks: &[(String, String, String, bool, bool)],
    remote: &std::collections::HashSet<String>,
) -> (Vec<String>, Vec<String>) {
    let mut to_love = Vec::new();
    let mut to_unlove = Vec::new();
    for (rel_path, title, artist, loved, has_pending_op) in tracks {
        if *has_pending_op {
            continue;
        }
        let key = format!("{}\u{0}{}", title.to_lowercase(), artist.to_lowercase());
        let desired = remote.contains(&key);
        if desired && !loved {
            to_love.push(rel_path.clone());
        } else if !desired && *loved {
            to_unlove.push(rel_path.clone());
        }
    }
    (to_love, to_unlove)
}

/// Downloads the user's loved tracks (paged, max 20 pages of 1000) and
/// reconciles `tracks.loved` for matching library rows, then reloads the
/// library if anything changed.
pub fn sync_loved_from_lastfm(core: &Rc<AppCore>) {
    let Some(session) = core.session.borrow().clone() else { return };
    let Some(client) = LastFmClient::new(Some(session.key.clone())) else { return };
    let db_path = core.db_path.clone();
    let username = session.username.clone();
    let (tx, rx) = async_channel::bounded::<usize>(1);
    std::thread::Builder::new()
        .name("flaccy-loved-sync".into())
        .spawn(move || {
            let changed = sync_loved_blocking(&db_path, &client, &username);
            let _ = tx.send_blocking(changed);
        })
        .ok();
    let weak = Rc::downgrade(core);
    gtk::glib::spawn_future_local(async move {
        let changed = rx.recv().await.unwrap_or(0);
        let Some(core) = weak.upgrade() else { return };
        if changed > 0 {
            crate::logger::info(
                "scrobble",
                &format!("loved down-sync updated {changed} tracks"),
            );
            core.reload_library();
        }
    });
}

fn sync_loved_blocking(db_path: &PathBuf, client: &LastFmClient, username: &str) -> usize {
    let mut remote: std::collections::HashSet<String> = std::collections::HashSet::new();
    let mut page = 1u32;
    let mut total_pages;
    loop {
        match client.fetch_loved_tracks(username, page, 1000) {
            Ok((tracks, pages)) => {
                for (title, artist) in tracks {
                    remote.insert(format!(
                        "{}\u{0}{}",
                        title.to_lowercase(),
                        artist.to_lowercase()
                    ));
                }
                total_pages = pages;
            }
            Err(err) => {
                crate::logger::warn("scrobble", &format!("loved down-sync fetch failed: {err}"));
                return 0;
            }
        }
        page += 1;
        if page > total_pages || page > 20 {
            break;
        }
    }
    let Ok(db) = Db::open(db_path) else { return 0 };
    let pending: std::collections::HashSet<String> = db
        .fetch_pending_love_ops()
        .into_iter()
        .map(|op| op.rel_path)
        .collect();
    let rows: Vec<(String, String, String, bool, bool)> = db
        .fetch_all_tracks()
        .into_iter()
        .map(|t| {
            let has_pending = pending.contains(&t.rel_path);
            (t.rel_path, t.title, t.artist, t.loved, has_pending)
        })
        .collect();
    let (to_love, to_unlove) = reconcile_loved(&rows, &remote);
    let changed = to_love.len() + to_unlove.len();
    if let Err(err) = db.mark_loved(&to_love, true) {
        crate::logger::error("database", &format!("loved down-sync write failed: {err}"));
    }
    if let Err(err) = db.mark_loved(&to_unlove, false) {
        crate::logger::error("database", &format!("loved down-sync write failed: {err}"));
    }
    changed
}

pub fn startup_maintenance(core: &Rc<AppCore>) {
    let cutoff = chrono::Utc::now().timestamp() - 14 * 24 * 3600;
    let retired = core.db.retire_pending_scrobbles_older_than(cutoff);
    if retired > 0 {
        crate::logger::info("scrobble", &format!("retired {retired} stale pending scrobbles"));
    }
    drain_pending(core);
    flush_pending_love_ops(core);
    sync_loved_from_lastfm(core);
}

#[cfg(test)]
mod tests {
    use super::reconcile_loved;
    use std::collections::HashSet;

    fn row(rel: &str, title: &str, artist: &str, loved: bool, pending: bool) -> (String, String, String, bool, bool) {
        (rel.to_string(), title.to_string(), artist.to_string(), loved, pending)
    }

    #[test]
    fn reconcile_applies_remote_state_case_insensitively() {
        let mut remote = HashSet::new();
        remote.insert("song a\u{0}artist x".to_string());
        let tracks = vec![
            row("a", "Song A", "Artist X", false, false),
            row("b", "Song B", "Artist X", true, false),
            row("c", "Song C", "Artist X", false, false),
        ];
        let (to_love, to_unlove) = reconcile_loved(&tracks, &remote);
        assert_eq!(to_love, vec!["a"]);
        assert_eq!(to_unlove, vec!["b"]);
    }

    #[test]
    fn reconcile_pending_ops_win() {
        let mut remote = HashSet::new();
        remote.insert("song a\u{0}artist x".to_string());
        let tracks = vec![
            row("a", "Song A", "Artist X", false, true),
            row("b", "Song B", "Artist X", true, true),
        ];
        let (to_love, to_unlove) = reconcile_loved(&tracks, &remote);
        assert!(to_love.is_empty());
        assert!(to_unlove.is_empty());
    }

    #[test]
    fn reconcile_noop_when_in_sync() {
        let mut remote = HashSet::new();
        remote.insert("song a\u{0}artist x".to_string());
        let tracks = vec![row("a", "Song A", "Artist X", true, false)];
        let (to_love, to_unlove) = reconcile_loved(&tracks, &remote);
        assert!(to_love.is_empty());
        assert!(to_unlove.is_empty());
    }
}

pub fn disconnect_cleanup(core: &Rc<AppCore>) {
    let retired = core.db.retire_all_pending_scrobbles();
    crate::logger::info(
        "scrobble",
        &format!("last.fm disconnected; retired {retired} pending scrobbles to local history"),
    );
    core.hub.emit(&AppEvent::LastFmChanged);
}
