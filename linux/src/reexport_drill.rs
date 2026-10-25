use crate::app::{AppCore, ConfirmReplace, ReplaceChoice};
use crate::fingerprint::{self, fixtures};
use flaccy_shared::track_revision;
use gtk::glib;
use std::path::Path;
use std::rc::Rc;
use std::time::Duration;

const REL_PATH: &str = "Imported/Rough Mix.wav";
const TITLE: &str = "Rough Mix";
const ARTIST: &str = "Drill Band";
const ALBUM: &str = "Rough Cuts";
const SAMPLES: usize = 24_000;
const STEP_TIMEOUT_SECONDS: f64 = 25.0;
const LOOK_AT_SONGS_MILLISECONDS: u64 = 4_000;

/// Demo-mode drill for track versions (`FLACCY_DEMO_REEXPORT`), run against
/// throwaway XDG directories: a song is exported, put in a playlist, exported
/// again over itself, imported a third time from another folder, and finally
/// restored, with the id, the playlist row, the revision, the new-mix window
/// and the fingerprints checked at each step. It leaves the Songs page open so
/// the New mix chip can be looked at.
pub fn run(core: &Rc<AppCore>) {
    let core = Rc::clone(core);
    glib::spawn_future_local(async move {
        match drive(&core).await {
            Ok(()) => crate::logger::info("drill", "REEXPORT DRILL PASSED"),
            Err(step) => crate::logger::error("drill", &format!("REEXPORT DRILL FAILED: {step}")),
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

fn write_mix(path: &Path, step: i16) -> Result<String, String> {
    let parent = path.parent().ok_or("a path without a folder")?;
    std::fs::create_dir_all(parent).map_err(|err| format!("making {}: {err}", parent.display()))?;
    let tags = fixtures::info_tags(TITLE, ARTIST, ALBUM);
    std::fs::write(path, fixtures::wav_bytes(&fixtures::tone(SAMPLES, step), Some(&tags)))
        .map_err(|err| format!("writing {}: {err}", path.display()))?;
    fingerprint::fingerprint(path).ok_or_else(|| format!("fingerprinting {}", path.display()))
}

struct Snapshot {
    id: i64,
    revision: i64,
    revised_at: Option<i64>,
    fingerprint: Option<String>,
}

fn snapshot(core: &AppCore) -> Result<Snapshot, String> {
    let row = core
        .db
        .fetch_all_tracks()
        .into_iter()
        .find(|track| track.rel_path == REL_PATH)
        .ok_or("the song is not in the library")?;
    let stored = core
        .db
        .fetch_stored_versions()
        .remove(REL_PATH)
        .unwrap_or_default();
    Ok(Snapshot {
        id: row.id,
        revision: stored.revision,
        revised_at: stored.revised_at,
        fingerprint: stored.fingerprint,
    })
}

fn revision_of(core: &AppCore) -> Option<i64> {
    snapshot(core).ok().map(|snapshot| snapshot.revision)
}

fn playlist_entry(core: &AppCore, playlist: i64) -> Option<(usize, i64)> {
    core.db
        .playlist_tracks(playlist)
        .into_iter()
        .enumerate()
        .find(|(_, row)| row.rel_path == REL_PATH)
        .map(|(position, row)| (position, row.row_id))
}

fn expect(step: &str, passed: bool) -> Result<(), String> {
    crate::logger::info("drill", &format!("{} {step}", if passed { "PASS" } else { "FAIL" }));
    if passed {
        Ok(())
    } else {
        Err(step.to_string())
    }
}

async fn drive(core: &Rc<AppCore>) -> Result<(), String> {
    let path = core.music_root().join(REL_PATH);
    wait_until("the opening scan to finish", || !core.scanning.get()).await?;

    let first = write_mix(&path, 7)?;
    core.rescan();
    wait_until("the first scan to index the song", || snapshot(core).is_ok()).await?;
    let indexed = snapshot(core)?;
    expect("the first version is baselined at revision 1", indexed.revision == 1 && indexed.fingerprint.as_deref() == Some(first.as_str()))?;

    let playlist = core.db.create_playlist("Drill Mixes").map_err(|err| format!("creating the playlist: {err}"))?;
    core.db.add_track_to_playlist(playlist, REL_PATH).map_err(|err| format!("filling the playlist: {err}"))?;
    let placed = playlist_entry(core, playlist).ok_or("the song is not in the playlist")?;

    sleep(1100).await;
    let second = write_mix(&path, 11)?;
    expect("the re-export differs from the first version", second != first)?;
    wait_until("the scan to be free", || !core.scanning.get()).await?;
    core.rescan();
    wait_until("the rescan to recognise revision 2", || revision_of(core) == Some(2)).await?;
    let revised = snapshot(core)?;
    expect("the re-export keeps the track id", revised.id == indexed.id)?;
    expect(
        "the re-export keeps its playlist row and position",
        playlist_entry(core, playlist) == Some(placed),
    )?;
    expect("the re-export is revision 2", revised.revision == 2)?;
    expect(
        "the re-export shows as a new mix",
        track_revision::shows_new_mix(revised.revised_at, crate::db::now_ms()),
    )?;
    expect(
        "the re-export stores the new fingerprint",
        revised.fingerprint.as_deref() == Some(second.as_str()),
    )?;
    wait_until("the library to carry the new mix", || {
        core.library
            .borrow()
            .track_by_rel_path(REL_PATH)
            .is_some_and(|track| track.revised_at.is_some())
    })
    .await?;
    expect("the Songs page lists the new mix", true)?;
    sleep(LOOK_AT_SONGS_MILLISECONDS).await;

    let incoming = core
        .db_path
        .parent()
        .ok_or("a database without a folder")?
        .join("drill-incoming/Rough Mix.wav");
    sleep(1100).await;
    let third = write_mix(&incoming, 17)?;
    wait_until("the scan to be free", || !core.scanning.get()).await?;
    let always_replace: ConfirmReplace = Rc::new(|_, respond| respond(ReplaceChoice::Replace));
    core.import_dropped_paths(vec![incoming], always_replace);
    wait_until("the import to land as revision 3", || revision_of(core) == Some(3)).await?;
    let imported = snapshot(core)?;
    expect("the import keeps the track id", imported.id == indexed.id)?;
    expect(
        "the import keeps its playlist row and position",
        playlist_entry(core, playlist) == Some(placed),
    )?;
    expect(
        "the import stores the third fingerprint",
        imported.fingerprint.as_deref() == Some(third.as_str()),
    )?;
    let kept = core
        .db
        .previous_version(REL_PATH)
        .ok_or("no previous version was recorded")?;
    expect(
        "the replaced file is kept on disk",
        Path::new(&kept.stored_path).is_file(),
    )?;
    expect(
        "the kept file is the second version",
        fingerprint::fingerprint(Path::new(&kept.stored_path)).as_deref() == Some(second.as_str()),
    )?;

    core.restore_previous_version(REL_PATH);
    wait_until("the restore to put the second version back", || {
        fingerprint::fingerprint(&path).as_deref() == Some(second.as_str())
    })
    .await?;
    wait_until("the restored version to be recorded", || {
        snapshot(core).is_ok_and(|now| now.fingerprint.as_deref() == Some(second.as_str()))
    })
    .await?;
    let restored = snapshot(core)?;
    expect("the restore keeps the track id", restored.id == indexed.id)?;
    expect("the restore keeps the revision", restored.revision == 3)?;
    expect(
        "the restore keeps its playlist row and position",
        playlist_entry(core, playlist) == Some(placed),
    )?;
    expect(
        "the restore clears the new-mix stamp",
        restored.revised_at.is_none(),
    )?;
    Ok(())
}
