use crate::db::Db;
use crate::library::Track;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::rc::Rc;

/// Drops the songs that live on a server, which have no file here to trash,
/// and says so. What is left is what the Trash can take.
fn without_remote(ui: &Rc<Ui>, tracks: Vec<Track>) -> Vec<Track> {
    let (remote, local): (Vec<Track>, Vec<Track>) = tracks
        .into_iter()
        .partition(|track| crate::remote::is_remote(&track.rel_path));
    if let Some(first) = remote.first() {
        let server = crate::remote::server_of(&first.rel_path)
            .map(|id| crate::remote::server_name(&id))
            .unwrap_or_default();
        ui.core.toast(&format!(
            "\u{201c}{}\u{201d} lives on {server}, so Flaccy can't move it to the Trash. Delete it on the server, or remove the server in Preferences to take all its songs out of the library.",
            first.title
        ));
    }
    local
}

pub fn present_delete_tracks(ui: &Rc<Ui>, tracks: Vec<Track>) {
    let tracks = without_remote(ui, tracks);
    if tracks.is_empty() {
        return;
    }
    let subject = if tracks.len() == 1 {
        format!("\u{201c}{}\u{201d}", tracks[0].title)
    } else {
        format!("{} songs", tracks.len())
    };
    confirm(ui, &subject, file_clause(tracks.len()), tracks);
}

pub fn present_delete_album(ui: &Rc<Ui>, key: &str) {
    let library = ui.core.library.borrow().clone();
    let Some(album) = library.album_by_key(key) else {
        return;
    };
    let subject = format!("\u{201c}{}\u{201d}", album.title);
    let tracks = without_remote(ui, album.tracks.clone());
    if tracks.is_empty() {
        return;
    }
    confirm(ui, &subject, file_clause(tracks.len()), tracks);
}

fn file_clause(count: usize) -> &'static str {
    if count == 1 {
        "file to the trash, where it can be recovered"
    } else {
        "files to the trash, where they can be recovered"
    }
}

/// Same contract as the macOS TrackDeletion alert: flaccy indexes the music
/// folder in place, so removal from the library moves the original files to
/// the trash, where they stay recoverable.
fn confirm(ui: &Rc<Ui>, subject: &str, file_clause: &str, tracks: Vec<Track>) {
    let dialog = adw::AlertDialog::builder()
        .heading(format!("Move {subject} to the Trash?"))
        .body(format!(
            "Flaccy indexes your music folder in place, so removing from the \
             library moves the original {file_clause}."
        ))
        .close_response("cancel")
        .default_response("cancel")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("trash", "Move to Trash");
    dialog.set_response_appearance("trash", adw::ResponseAppearance::Destructive);

    let pending = std::cell::RefCell::new(Some(tracks));
    let ui = Rc::clone(ui);
    let window = ui.window.clone();
    dialog.connect_response(None, move |_, response| {
        if response != "trash" {
            return;
        }
        let Some(tracks) = pending.borrow_mut().take() else {
            return;
        };
        apply(&ui, tracks);
    });
    dialog.present(Some(&window));
}

fn apply(ui: &Rc<Ui>, tracks: Vec<Track>) {
    let rel_paths: Vec<String> = tracks.into_iter().map(|track| track.rel_path).collect();
    let total = rel_paths.len();
    let db_path = ui.core.db_path.clone();
    let root = ui.core.music_root();
    let (tx, rx) = async_channel::bounded::<(usize, Option<String>)>(1);
    {
        let rel_paths = rel_paths.clone();
        std::thread::Builder::new()
            .name("flaccy-delete".into())
            .spawn(move || {
                let _ = tx.send_blocking(apply_blocking(&db_path, &root, &rel_paths));
            })
            .ok();
    }
    let ui = Rc::clone(ui);
    glib::spawn_future_local(async move {
        let Ok((trashed, first_failure)) = rx.recv().await else { return };
        crate::logger::info(
            "library",
            &format!("delete: {trashed} of {total} file(s) moved to trash"),
        );
        let deleted: HashSet<String> = rel_paths.into_iter().collect();
        ui.core.player.handle_deleted(&deleted);
        ui.core.rescan();
        ui.core.reload_library();
        if trashed == total {
            ui.core.toast("Moved to Trash");
        } else {
            ui.core
                .toast(&partial_removal_message(trashed, total, first_failure.as_deref()));
        }
    });
}

/// The toast for a removal that moved only some files to the Trash, naming the
/// first reason a file stayed behind when the log has one.
fn partial_removal_message(trashed: usize, total: usize, first_failure: Option<&str>) -> String {
    let kept = total - trashed;
    let cause = first_failure
        .map(|reason| format!(": {reason}"))
        .unwrap_or_default();
    format!("Moved {trashed} of {total} to the Trash; {kept} stayed on disk{cause}. The library will show them again.")
}

/// Rows are dropped before files: if a trash call fails, the follow-up rescan
/// finds the file still on disk and restores its row, so the library never
/// points at ghosts and never loses a real file silently.
fn apply_blocking(db_path: &Path, root: &Path, rel_paths: &[String]) -> (usize, Option<String>) {
    let Ok(db) = Db::open(db_path) else {
        crate::logger::error("library", "delete: database open failed");
        return (0, Some("the library database couldn't be opened".to_string()));
    };
    let mut trashed = 0;
    let mut first_failure: Option<String> = None;
    for rel_path in rel_paths {
        if let Err(err) = db.delete_track_by_rel_path(rel_path) {
            crate::logger::error(
                "database",
                &format!("delete row failed for {rel_path}: {err}"),
            );
            first_failure.get_or_insert_with(|| format!("the library database refused the change ({err})"));
            continue;
        }
        match try_trash(&root.join(rel_path)) {
            Ok(()) => trashed += 1,
            Err(reason) => {
                first_failure.get_or_insert(reason);
            }
        }
    }
    (trashed, first_failure)
}

/// Sends a file to the desktop trash so a mistaken removal stays recoverable,
/// unlike an unlink.
pub(crate) fn trash_file(path: &PathBuf) -> bool {
    match try_trash(path) {
        Ok(()) => true,
        Err(reason) => {
            crate::logger::warn(
                "library",
                &format!("gio trash failed for {}: {reason}", path.display()),
            );
            false
        }
    }
}

/// Runs `gio trash`, returning why it refused: gio's own message when it
/// printed one, else its exit status or the spawn error.
fn try_trash(path: &PathBuf) -> Result<(), String> {
    let output = std::process::Command::new("gio")
        .arg("trash")
        .arg(path)
        .output()
        .map_err(|err| format!("gio couldn't be started ({err})"))?;
    if output.status.success() {
        return Ok(());
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let message = stderr
        .lines()
        .rev()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .map(|line| line.trim_start_matches("gio: ").to_string());
    Err(message.unwrap_or_else(|| format!("gio trash exited {}", output.status)))
}
