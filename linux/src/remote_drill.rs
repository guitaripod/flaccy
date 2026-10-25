use crate::app::AppCore;
use flaccy_library::remote::servers::Server;
use flaccy_library::remote::service::Remote;
use flaccy_shared::remote::remote_path;
use gtk::glib;
use std::rc::Rc;
use std::time::Duration;

const STEP_TIMEOUT_SECONDS: f64 = 40.0;
const PLAY_SECONDS: u64 = 3;
const LOOK_AT_SONGS_MILLISECONDS: u64 = 2_000;
const MINIMUM_ADVANCE_SECONDS: f64 = 1.5;

/// Demo-mode drill for the remote library (`FLACCY_DEMO_REMOTE='<url>|<user>|
/// <password>'`), run against throwaway XDG directories: the server is added
/// and tested, its catalog is synced and counted against `search3`, the first
/// song plays through the proxy at volume 0, its cache file is compared byte
/// for byte with `download`, and one album is kept and found under the kept
/// folder. The address is the only part of the spec that is ever logged.
pub fn run(core: &Rc<AppCore>, spec: &str) {
    let core = Rc::clone(core);
    let spec = spec.to_string();
    glib::spawn_future_local(async move {
        match drive(&core, &spec).await {
            Ok(()) => crate::logger::info("drill", "REMOTE DRILL PASSED"),
            Err(step) => crate::logger::error("drill", &format!("REMOTE DRILL FAILED: {step}")),
        }
    });
}

async fn sleep(milliseconds: u64) {
    glib::timeout_future(Duration::from_millis(milliseconds)).await;
}

async fn wait_until(step: &str, condition: impl Fn() -> bool) -> Result<(), String> {
    let mut remaining = (STEP_TIMEOUT_SECONDS * 1000.0) as i64;
    while remaining > 0 {
        if condition() {
            return Ok(());
        }
        sleep(50).await;
        remaining -= 50;
    }
    if condition() {
        Ok(())
    } else {
        Err(format!("{step} (timed out after {STEP_TIMEOUT_SECONDS:.0}s)"))
    }
}

fn expect(step: &str, passed: bool) -> Result<(), String> {
    crate::logger::info("drill", &format!("{} {step}", if passed { "PASS" } else { "FAIL" }));
    if passed {
        Ok(())
    } else {
        Err(step.to_string())
    }
}

fn parse(spec: &str) -> Result<(String, String, String), String> {
    let mut parts = spec.splitn(3, '|');
    match (parts.next(), parts.next(), parts.next()) {
        (Some(url), Some(user), Some(password)) if !url.is_empty() => {
            Ok((url.to_string(), user.to_string(), password.to_string()))
        }
        _ => Err("FLACCY_DEMO_REMOTE must read '<url>|<user>|<password>'".to_string()),
    }
}

fn remote_track_count(core: &AppCore) -> usize {
    core.library
        .borrow()
        .tracks
        .iter()
        .filter(|track| crate::remote::is_remote(&track.rel_path))
        .count()
}

async fn drive(core: &Rc<AppCore>, spec: &str) -> Result<(), String> {
    let (url, user, password) = parse(spec)?;
    let remote = crate::remote::handle().cloned().ok_or("the remote library did not start")?;
    wait_until("the opening scan to finish", || !core.scanning.get()).await?;
    core.set_volume(0.0);

    let server = Server::new("Drill Server", &url, &user, &password, false);
    let info = Remote::test(&server).map_err(|error| format!("testing the server: {}", error.message()))?;
    expect(&format!("the test reports {}", info.summary()), !info.server_type.is_empty())?;
    remote.add_server(server.clone())?;
    let client = remote.client_for(&server.id).ok_or("the saved server has no client")?;

    let mut expected = 0;
    loop {
        let page = client
            .search_songs(expected, 500)
            .map_err(|error| format!("counting with search3: {}", error.message()))?;
        let received = page.len();
        expected += received;
        if received < 500 {
            break;
        }
    }
    expect(&format!("search3 lists {expected} songs"), expected > 0)?;

    core.sync_remote_servers(true);
    wait_until("the catalog sync to end", || !core.remote_syncing.get()).await?;
    wait_until("the library to hold the synced songs", || remote_track_count(core) == expected).await?;
    let stored = core.db.remote_song_counts().get(&server.id).copied().unwrap_or(0);
    expect(
        &format!("the library holds {} remote songs, the database {stored}, search3 {expected}", remote_track_count(core)),
        remote_track_count(core) == expected && stored == expected,
    )?;

    let first = core
        .library
        .borrow()
        .tracks
        .iter()
        .find(|track| crate::remote::is_remote(&track.rel_path))
        .cloned()
        .ok_or("no remote song in the library")?;
    let (_, first_id) = remote_path::decode(&first.rel_path).ok_or("the first song has no remote path")?;
    core.play_tracks(vec![first.clone()], 0);
    wait_until("the song to start playing through the proxy", || {
        core.player.is_playing() && core.player.position().unwrap_or(0.0) > 0.2
    })
    .await?;
    let started = core.player.position().unwrap_or(0.0);
    sleep(PLAY_SECONDS * 1000).await;
    let advanced = core.player.position().unwrap_or(0.0) - started;
    expect(
        &format!("the position advanced {advanced:.1}s in {PLAY_SECONDS}s at volume 0"),
        advanced >= MINIMUM_ADVANCE_SECONDS && core.config.borrow().volume == 0.0,
    )?;

    wait_until("the song to be fully cached", || remote.manager().is_complete(&first.rel_path)).await?;
    let entry = remote.manager().entry(&server.id, &first_id).map_err(|error| error.to_string())?;
    let cached = std::fs::read(entry.path()).map_err(|error| format!("reading the cache file: {error}"))?;
    let original = client.download(&first_id).map_err(|error| format!("download: {}", error.message()))?;
    expect(
        &format!("the cache file is byte-identical to download ({} bytes)", original.len()),
        !original.is_empty() && cached == original,
    )?;

    let album = core
        .library
        .borrow()
        .albums
        .iter()
        .find(|album| {
            album.tracks.len() >= 2
                && album.tracks.iter().all(|track| crate::remote::is_remote(&track.rel_path))
        })
        .cloned()
        .ok_or("no album of two or more remote songs")?;

    let following = album.tracks[1].title.clone();
    core.play_tracks(album.tracks.clone(), 0);
    wait_until("the album to start", || {
        core.player.is_playing()
            && core.player.current_track().is_some_and(|track| track.title == album.tracks[0].title)
            && core.player.position().unwrap_or(0.0) > 0.2
    })
    .await?;
    let length = core.player.duration().ok_or("the first song has no duration")?;
    core.player.seek(length - 1.5);
    wait_until("the next song to start by itself", || {
        core.player.current_track().is_some_and(|track| track.title == following)
    })
    .await?;
    sleep(800).await;
    expect(
        &format!("playback moved on to {following} at {:.1}s", core.player.position().unwrap_or(0.0)),
        core.player.is_playing() && core.player.position().unwrap_or(99.0) < 4.0,
    )?;

    let paths: Vec<String> = album.tracks.iter().map(|track| track.rel_path.clone()).collect();
    remote.pin(&paths);
    wait_until("the album to finish downloading", || paths.iter().all(|path| remote.is_downloaded(path))).await?;
    let kept_dir = dirs::data_dir()
        .unwrap_or_default()
        .join("flaccy/remote")
        .join(&server.id);
    let present = paths
        .iter()
        .filter_map(|path| remote_path::decode(path))
        .filter_map(|(_, song)| remote.manager().entry(&server.id, &song).ok())
        .filter(|entry| entry.path().starts_with(&kept_dir) && entry.path().is_file())
        .count();
    expect(
        &format!("{present} of {} album files exist under the kept folder", paths.len()),
        present == paths.len() && !paths.is_empty(),
    )?;
    sleep(LOOK_AT_SONGS_MILLISECONDS).await;
    expect("the Songs page lists the remote songs with the server chip", true)?;
    sleep(LOOK_AT_SONGS_MILLISECONDS).await;
    Ok(())
}
