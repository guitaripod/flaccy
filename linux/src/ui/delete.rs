use crate::db::Db;
use crate::library::Track;
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::rc::Rc;

pub fn present_delete_tracks(ui: &Rc<Ui>, tracks: Vec<Track>) {
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
    let Some(album) = library.album_by_key(key) else { return };
    let subject = format!("\u{201c}{}\u{201d}", album.title);
    confirm(ui, &subject, file_clause(album.tracks.len()), album.tracks.clone());
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
        let Some(tracks) = pending.borrow_mut().take() else { return };
        apply(&ui, tracks);
    });
    dialog.present(Some(&window));
}

fn apply(ui: &Rc<Ui>, tracks: Vec<Track>) {
    let rel_paths: Vec<String> = tracks.into_iter().map(|track| track.rel_path).collect();
    let total = rel_paths.len();
    let db_path = ui.core.db_path.clone();
    let root = ui.core.music_root();
    let (tx, rx) = async_channel::bounded::<usize>(1);
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
        let Ok(trashed) = rx.recv().await else { return };
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
            ui.core.toast(&format!("Removed {trashed} of {total} — see log"));
        }
    });
}

/// Rows are dropped before files: if a trash call fails, the follow-up rescan
/// finds the file still on disk and restores its row, so the library never
/// points at ghosts and never loses a real file silently.
fn apply_blocking(db_path: &Path, root: &Path, rel_paths: &[String]) -> usize {
    let Ok(db) = Db::open(db_path) else {
        crate::logger::error("library", "delete: database open failed");
        return 0;
    };
    let mut trashed = 0;
    for rel_path in rel_paths {
        if let Err(err) = db.delete_track_by_rel_path(rel_path) {
            crate::logger::error("database", &format!("delete row failed for {rel_path}: {err}"));
            continue;
        }
        if trash_file(&root.join(rel_path)) {
            trashed += 1;
        }
    }
    trashed
}

/// Sends a file to the desktop trash so a mistaken removal stays recoverable,
/// unlike an unlink.
pub(crate) fn trash_file(path: &PathBuf) -> bool {
    match std::process::Command::new("gio").arg("trash").arg(path).status() {
        Ok(status) if status.success() => true,
        Ok(status) => {
            crate::logger::warn(
                "library",
                &format!("gio trash exited {status} for {}", path.display()),
            );
            false
        }
        Err(err) => {
            crate::logger::error(
                "library",
                &format!("gio trash failed for {}: {err}", path.display()),
            );
            false
        }
    }
}
