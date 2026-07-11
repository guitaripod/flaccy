use crate::db::{AlbumInfoMerge, AlbumRetitle, Db, KeeperUpdate};
use crate::hygiene::{self, AlbumVariant, ConsolidationGroup, DuplicateGroup};
use crate::library::{self, Track};
use crate::ui::Ui;
use adw::prelude::*;
use gtk::glib;
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::rc::Rc;

const DETAIL_LINE_LIMIT: usize = 60;

struct CleanupPlan {
    duplicates: Vec<DuplicateGroup>,
    consolidations: Vec<ConsolidationGroup>,
}

impl CleanupPlan {
    fn duplicate_file_count(&self) -> usize {
        self.duplicates.iter().map(|group| group.losers.len()).sum()
    }

    fn merge_count(&self) -> usize {
        self.consolidations
            .iter()
            .map(|group| group.variants.len())
            .sum()
    }

    fn is_empty(&self) -> bool {
        self.duplicate_file_count() == 0 && self.merge_count() == 0
    }
}

struct CleanupResult {
    removed: usize,
    merged: usize,
}

impl CleanupResult {
    fn summary(&self) -> String {
        if self.removed == 0 && self.merged == 0 {
            return "Nothing to clean up".to_string();
        }
        let mut parts = Vec::new();
        if self.removed > 0 {
            parts.push(format!(
                "removed {} duplicate file{}",
                self.removed,
                plural(self.removed)
            ));
        }
        if self.merged > 0 {
            parts.push(format!(
                "merged {} album variation{}",
                self.merged,
                plural(self.merged)
            ));
        }
        let mut text = parts.join(" · ");
        if let Some(first) = text.get_mut(0..1) {
            first.make_ascii_uppercase();
        }
        text
    }
}

/// The full-library "Clean Up Library…" flow: scans off-main for duplicate
/// files and album-edition variations, shows a mandatory dry-run preview, and
/// only mutates the library (trashing losers, fusing editions) on confirmation.
pub fn present(ui: &Rc<Ui>) {
    let db_path = ui.core.db_path.clone();
    let root = ui.core.music_root();
    let (tx, rx) = async_channel::bounded::<CleanupPlan>(1);
    std::thread::Builder::new()
        .name("flaccy-cleanup-scan".into())
        .spawn(move || {
            let Ok(db) = Db::open(&db_path) else { return };
            let raw = library::load(&db, false);
            let plan = CleanupPlan {
                duplicates: hygiene::find_duplicate_groups(&raw.tracks, &root),
                consolidations: hygiene::consolidation_groups(&raw.albums),
            };
            let _ = tx.send_blocking(plan);
        })
        .ok();
    ui.core.toast("Scanning library for duplicates…");
    let ui = Rc::clone(ui);
    glib::spawn_future_local(async move {
        let Ok(plan) = rx.recv().await else { return };
        if plan.is_empty() {
            ui.core.toast("Library is already tidy — nothing to clean up");
            return;
        }
        present_plan(&ui, plan);
    });
}

fn present_plan(ui: &Rc<Ui>, plan: CleanupPlan) {
    let removable = plan.duplicate_file_count();
    let merges = plan.merge_count();
    let body = format!(
        "{} duplicate file{} to remove, keeping the best copy · {} album variation{} to merge into their main release.\n\nRemoved files go to the trash and can be recovered.",
        removable,
        plural(removable),
        merges,
        plural(merges)
    );

    let dialog = adw::AlertDialog::builder()
        .heading("Clean Up Library")
        .body(body)
        .close_response("cancel")
        .default_response("cancel")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("clean", "Clean Up");
    dialog.set_response_appearance("clean", adw::ResponseAppearance::Destructive);
    dialog.set_extra_child(Some(&detail_view(&plan)));

    let plan_cell = Rc::new(RefCell::new(Some(plan)));
    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response != "clean" {
            return;
        }
        let Some(plan) = plan_cell.borrow_mut().take() else {
            return;
        };
        apply_plan(&ui, plan);
    });
    dialog.present(Some(&window));
}

fn detail_view(plan: &CleanupPlan) -> gtk::ScrolledWindow {
    let content = gtk::Box::builder()
        .orientation(gtk::Orientation::Vertical)
        .spacing(4)
        .build();
    let mut lines = 0;

    for group in &plan.consolidations {
        if lines >= DETAIL_LINE_LIMIT {
            break;
        }
        content.append(&detail_line(&format!(
            "Merge {} into “{}” — {}",
            join_variants(&group.variants),
            group.canonical_title,
            group.artist
        )));
        lines += 1;
    }
    for group in &plan.duplicates {
        if lines >= DETAIL_LINE_LIMIT {
            break;
        }
        content.append(&detail_line(&format!(
            "Keep {} copy of “{}” — {}, remove {} other{}",
            keeper_quality(&group.keeper),
            group.keeper.title,
            group.keeper.artist,
            group.losers.len(),
            plural(group.losers.len())
        )));
        lines += 1;
    }
    let total = plan.consolidations.len() + plan.duplicates.len();
    if total > lines {
        content.append(&detail_line(&format!("…and {} more", total - lines)));
    }

    gtk::ScrolledWindow::builder()
        .hscrollbar_policy(gtk::PolicyType::Never)
        .min_content_height(180)
        .max_content_height(320)
        .propagate_natural_height(true)
        .child(&content)
        .build()
}

fn detail_line(text: &str) -> gtk::Label {
    let label = gtk::Label::builder()
        .label(text)
        .xalign(0.0)
        .wrap(true)
        .build();
    label.add_css_class("caption");
    label.add_css_class("dim");
    label
}

fn keeper_quality(track: &Track) -> String {
    track.quality_badge().unwrap_or_else(|| "best".to_string())
}

fn join_variants(variants: &[AlbumVariant]) -> String {
    variants
        .iter()
        .map(|variant| format!("“{}”", variant.title))
        .collect::<Vec<_>>()
        .join(", ")
}

/// The selection-scoped "Remove Duplicates in Selection" flow: dedup groups are
/// already computed by the caller; this only confirms and applies.
pub fn present_selection_dedup(ui: &Rc<Ui>, tracks: Vec<Track>) {
    let root = ui.core.music_root();
    let groups = hygiene::find_duplicate_groups(&tracks, &root);
    let removable: usize = groups.iter().map(|group| group.losers.len()).sum();
    if removable == 0 {
        ui.core.toast("No duplicates in the selection");
        return;
    }
    let dialog = adw::AlertDialog::builder()
        .heading("Remove Duplicates")
        .body(format!(
            "Remove {} duplicate file{} from the selection, keeping the best copy of each. Removed files go to the trash.",
            removable,
            plural(removable)
        ))
        .close_response("cancel")
        .default_response("cancel")
        .build();
    dialog.add_response("cancel", "Cancel");
    dialog.add_response("remove", "Remove");
    dialog.set_response_appearance("remove", adw::ResponseAppearance::Destructive);

    let plan_cell = Rc::new(RefCell::new(Some(CleanupPlan {
        duplicates: groups,
        consolidations: Vec::new(),
    })));
    let window = ui.window.clone();
    let ui = Rc::clone(ui);
    dialog.connect_response(None, move |_, response| {
        if response != "remove" {
            return;
        }
        let Some(plan) = plan_cell.borrow_mut().take() else {
            return;
        };
        apply_plan(&ui, plan);
    });
    dialog.present(Some(&window));
}

fn apply_plan(ui: &Rc<Ui>, plan: CleanupPlan) {
    let db_path = ui.core.db_path.clone();
    let root = ui.core.music_root();
    let (tx, rx) = async_channel::bounded::<CleanupResult>(1);
    std::thread::Builder::new()
        .name("flaccy-cleanup-apply".into())
        .spawn(move || {
            let _ = tx.send_blocking(apply_blocking(&db_path, &root, plan));
        })
        .ok();
    let ui = Rc::clone(ui);
    glib::spawn_future_local(async move {
        let Ok(result) = rx.recv().await else { return };
        crate::logger::info(
            "library",
            &format!(
                "cleanup applied: {} files trashed, {} variations merged",
                result.removed, result.merged
            ),
        );
        ui.core.rescan();
        ui.core.reload_library();
        ui.core.toast(&result.summary());
    });
}

fn apply_blocking(db_path: &Path, root: &Path, plan: CleanupPlan) -> CleanupResult {
    let Ok(db) = Db::open(db_path) else {
        crate::logger::error("library", "cleanup apply: database open failed");
        return CleanupResult { removed: 0, merged: 0 };
    };

    let retitles: Vec<AlbumRetitle> = plan
        .consolidations
        .iter()
        .flat_map(|group| {
            group.variants.iter().map(move |variant| AlbumRetitle {
                from_title: variant.title.clone(),
                from_artist: variant.artist.clone(),
                to_title: group.canonical_title.clone(),
                to_artist: group.artist.clone(),
            })
        })
        .collect();
    let album_info_merges: Vec<AlbumInfoMerge> = plan
        .consolidations
        .iter()
        .map(|group| AlbumInfoMerge {
            canonical_title: group.canonical_title.clone(),
            canonical_artist: group.artist.clone(),
            variants: group
                .variants
                .iter()
                .map(|variant| (variant.title.clone(), variant.artist.clone()))
                .collect(),
        })
        .collect();
    let keeper_updates: Vec<KeeperUpdate> = plan
        .duplicates
        .iter()
        .map(|group| KeeperUpdate {
            rel_path: group.keeper.rel_path.clone(),
            loved: group.loved,
            play_count: group.play_count,
        })
        .collect();
    let loser_rel_paths: Vec<String> = plan
        .duplicates
        .iter()
        .flat_map(|group| group.losers.iter().map(|loser| loser.rel_path.clone()))
        .collect();
    let merged = retitles.len();

    if let Err(err) =
        db.apply_cleanup(&retitles, &keeper_updates, &album_info_merges, &loser_rel_paths)
    {
        crate::logger::error("library", &format!("cleanup apply failed: {err}"));
        return CleanupResult { removed: 0, merged: 0 };
    }

    let mut removed = 0;
    for rel_path in &loser_rel_paths {
        if trash_file(&root.join(rel_path)) {
            removed += 1;
        }
    }
    CleanupResult { removed, merged }
}

/// Sends a file to the desktop trash so a mistaken cleanup stays recoverable,
/// unlike an unlink.
fn trash_file(path: &PathBuf) -> bool {
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

fn plural(count: usize) -> &'static str {
    if count == 1 {
        ""
    } else {
        "s"
    }
}
