use crate::db::{now_ms, Db};
use crate::fingerprint;
use flaccy_shared::enrichment_job as job;
use flaccy_shared::import_plan::{Inspector, Placed, Placement};
use flaccy_shared::track_revision::{self, StoredVersion};
use lofty::file::TaggedFileExt;
use lofty::prelude::*;
use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Where the versions a replacement or a restore moved aside are kept, beside
/// the library database so both follow the same data directory.
pub fn previous_root(db_path: &Path) -> PathBuf {
    db_path
        .parent()
        .unwrap_or(Path::new("."))
        .join("previous-versions")
}

/// What stopped a replacement or a restore: the step that failed and the
/// operating system's reason, for the toast to name.
#[derive(Debug)]
pub struct VersionFailure {
    pub step: &'static str,
    pub cause: String,
}

impl VersionFailure {
    fn new(step: &'static str, cause: impl std::fmt::Display) -> Self {
        Self {
            step,
            cause: cause.to_string(),
        }
    }
}

/// Tells a newer version of a song from a copy of the same file for the import
/// plan: by the audio fingerprint, and by the title and artist tags.
pub struct TagInspector;

impl Inspector for TagInspector {
    fn audio_fingerprint(&self, path: &Path) -> Option<String> {
        fingerprint::fingerprint(path)
    }

    fn song_key(&self, path: &Path) -> Option<String> {
        let tagged = lofty::probe::Probe::open(path).ok()?.read().ok()?;
        let tag = tagged.primary_tag().or_else(|| tagged.first_tag())?;
        let title = job::normalize(tag.title()?.trim());
        let artist = job::normalize(tag.artist()?.trim());
        (!title.is_empty() && !artist.is_empty()).then(|| format!("{title}|{artist}"))
    }
}

/// The title a file's tags give it, or its file name without the extension.
pub fn display_title(path: &Path) -> String {
    let tagged_title = lofty::probe::Probe::open(path)
        .ok()
        .and_then(|probe| probe.read().ok())
        .and_then(|tagged| {
            let tag = tagged.primary_tag().or_else(|| tagged.first_tag())?;
            let title = tag.title()?.trim().to_string();
            (!title.is_empty()).then_some(title)
        });
    tagged_title.unwrap_or_else(|| {
        path.file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_default()
    })
}

fn hidden_sibling(target: &Path, suffix: &str) -> PathBuf {
    let name = target
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    target
        .parent()
        .unwrap_or(target)
        .join(format!(".{name}.{suffix}"))
}

/// Writes `source` beside `target` as a hidden `.name.flaccy-part`, the file a
/// copy only becomes the real name from once it is complete. A failure leaves
/// no part behind.
pub fn stage_copy(source: &Path, target: &Path) -> io::Result<PathBuf> {
    let parent = target.parent().unwrap_or(target);
    fs::create_dir_all(parent)?;
    let staging = hidden_sibling(target, "flaccy-part");
    let _ = fs::remove_file(&staging);
    if let Err(err) = fs::copy(source, &staging) {
        let _ = fs::remove_file(&staging);
        return Err(err);
    }
    Ok(staging)
}

/// Moves a file, copying across file systems when a rename cannot reach them.
pub fn move_file(from: &Path, to: &Path) -> io::Result<()> {
    if fs::rename(from, to).is_ok() {
        return Ok(());
    }
    fs::copy(from, to)?;
    fs::remove_file(from)
}

fn carry_modified_time(source: &Path, staging: &Path) {
    let modified = fs::metadata(source).and_then(|metadata| metadata.modified());
    if let Ok(modified) = modified {
        if let Ok(file) = fs::OpenOptions::new().write(true).open(staging) {
            let _ = file.set_modified(modified);
        }
    }
}

/// Writes `source` over the song at `rel` without ever leaving the library
/// without it. The new version is completed in a hidden part file first; only
/// then is the current file moved to `previous_root`, its row recorded, and the
/// part renamed into place. A failure at any step puts the original back.
pub fn replace_in_place(
    db: &Db,
    music_root: &Path,
    previous_root: &Path,
    rel: &str,
    source: &Path,
) -> Result<(), VersionFailure> {
    let target = music_root.join(rel);
    let part = stage_copy(source, &target)
        .map_err(|err| VersionFailure::new("copying the new version", err))?;
    carry_modified_time(source, &part);
    let abandon = |failure: VersionFailure| {
        let _ = fs::remove_file(&part);
        failure
    };

    let kept = previous_root.join(rel);
    let incoming = hidden_sibling(&kept, "flaccy-incoming");
    if let Some(parent) = kept.parent() {
        fs::create_dir_all(parent).map_err(|err| {
            abandon(VersionFailure::new("making room in Previous Versions", err))
        })?;
    }
    move_file(&target, &incoming)
        .map_err(|err| abandon(VersionFailure::new("moving the current version aside", err)))?;

    let earlier = db.previous_version(rel);
    let put_back = |failure: VersionFailure| {
        let _ = move_file(&incoming, &target);
        abandon(failure)
    };
    db.upsert_previous_version(rel, &kept.to_string_lossy(), now_ms())
        .map_err(|err| put_back(VersionFailure::new("recording the previous version", err)))?;
    if let Err(err) = fs::rename(&part, &target) {
        match &earlier {
            Some(row) => {
                let _ = db.upsert_previous_version(rel, &row.stored_path, row.moved_at_ms);
            }
            None => {
                let _ = db.delete_previous_version(rel);
            }
        }
        return Err(put_back(VersionFailure::new("putting the new version in place", err)));
    }
    if let Err(err) = move_file(&incoming, &kept) {
        crate::logger::warn(
            "library",
            &format!("previous version of {rel} stays at {}: {err}", incoming.display()),
        );
        let _ = db.upsert_previous_version(rel, &incoming.to_string_lossy(), now_ms());
    }
    Ok(())
}

/// Swaps the song at `rel` with the version kept for it, then re-reads the
/// restored file in place: the same row, the revision unchanged and no new-mix
/// stamp, because going back is not a new export.
pub fn restore_previous(db: &Db, music_root: &Path, rel: &str) -> Result<(), VersionFailure> {
    let Some(previous) = db.previous_version(rel) else {
        return Err(VersionFailure::new(
            "finding the previous version",
            "none is kept for this song",
        ));
    };
    let kept = PathBuf::from(&previous.stored_path);
    if !kept.is_file() {
        return Err(VersionFailure::new(
            "finding the previous version",
            format!("{} is gone", kept.display()),
        ));
    }
    let current = music_root.join(rel);
    let swap = hidden_sibling(&current, "flaccy-swap");
    move_file(&current, &swap)
        .map_err(|err| VersionFailure::new("moving the current version aside", err))?;
    if let Err(err) = move_file(&kept, &current) {
        let _ = move_file(&swap, &current);
        return Err(VersionFailure::new("putting the previous version back", err));
    }
    if let Err(err) = move_file(&swap, &kept) {
        let _ = move_file(&current, &kept);
        let _ = move_file(&swap, &current);
        return Err(VersionFailure::new("keeping the version just replaced", err));
    }
    db.upsert_previous_version(rel, &previous.stored_path, now_ms())
        .map_err(|err| VersionFailure::new("recording the swap", err))?;
    adopt_file(db, &current, rel)
}

fn adopt_file(db: &Db, path: &Path, rel: &str) -> Result<(), VersionFailure> {
    let stored = db
        .fetch_stored_versions()
        .remove(rel)
        .unwrap_or_default();
    let version = StoredVersion {
        signature: fingerprint::signature(path),
        fingerprint: fingerprint::fingerprint(path),
        revision: stored.revision.max(1),
        revised_at: None,
    };
    if let Some(track) = crate::scanner::read_metadata(path, rel) {
        let moved = db
            .refresh_track_in_place(&track)
            .map_err(|err| VersionFailure::new("reading the restored file", err))?;
        if moved {
            let _ = db.sweep_orphaned_enrichment();
        }
    }
    db.update_version(rel, &version)
        .map_err(|err| VersionFailure::new("recording the restored file", err))
}

/// Deletes the versions kept longer than the retention allows, the file and
/// its row. Returns how many were removed.
pub fn purge_expired(db: &Db, now_ms: i64) -> usize {
    let mut purged = 0;
    for version in db.fetch_previous_versions() {
        if !track_revision::previous_version_expired(version.moved_at_ms, now_ms) {
            continue;
        }
        let removed = match fs::remove_file(&version.stored_path) {
            Ok(()) => true,
            Err(err) => err.kind() == io::ErrorKind::NotFound,
        };
        if removed && db.delete_previous_version(&version.rel_path).is_ok() {
            purged += 1;
        }
    }
    purged
}

fn split_extension(name: &str) -> (&str, &str) {
    match name.rfind('.') {
        Some(index) if index > 0 && index + 1 < name.len() => (&name[..index], &name[index + 1..]),
        _ => (name, ""),
    }
}

/// Turns every replacement into a copy of its own, at the first free
/// `stem_n.ext` that neither the disk nor another file of this import holds.
pub fn keep_both(placed: Vec<Placed>, import_root: &Path) -> Vec<Placed> {
    let mut claimed: HashSet<String> = placed
        .iter()
        .filter_map(|entry| match &entry.placement {
            Placement::Copy(destination) | Placement::Replace(destination) => {
                Some(destination.clone())
            }
            Placement::AlreadyPresent => None,
        })
        .collect();
    placed
        .into_iter()
        .map(|entry| {
            let Placement::Replace(destination) = &entry.placement else {
                return entry;
            };
            let free = free_destination(destination, import_root, &claimed);
            claimed.insert(free.clone());
            Placed {
                item: entry.item,
                placement: Placement::Copy(free),
            }
        })
        .collect()
}

fn free_destination(destination: &str, import_root: &Path, claimed: &HashSet<String>) -> String {
    let (parent, name) = match destination.rsplit_once('/') {
        Some((parent, name)) => (Some(parent), name),
        None => (None, destination),
    };
    let (stem, extension) = split_extension(name);
    (1..)
        .map(|counter| {
            let renamed = if extension.is_empty() {
                format!("{stem}_{counter}")
            } else {
                format!("{stem}_{counter}.{extension}")
            };
            match parent {
                Some(parent) => format!("{parent}/{renamed}"),
                None => renamed,
            }
        })
        .find(|candidate| !claimed.contains(candidate) && !import_root.join(candidate).exists())
        .unwrap_or_else(|| destination.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fingerprint::fixtures::{tone, wav_bytes, TempDir};
    use flaccy_shared::import_plan::{Item, Kind};

    struct Library {
        _dir: TempDir,
        root: PathBuf,
        previous: PathBuf,
        db: Db,
    }

    fn library() -> Library {
        let dir = TempDir::new("versions");
        let root = dir.path().join("music");
        fs::create_dir_all(root.join("Imported")).unwrap();
        let db = Db::open(&dir.path().join("data/library.sqlite")).expect("db");
        let previous = previous_root(&dir.path().join("data/library.sqlite"));
        Library {
            root,
            previous,
            db,
            _dir: dir,
        }
    }

    fn write_wav(path: &Path, step: i16) -> String {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, wav_bytes(&tone(4000, step), None)).unwrap();
        fingerprint::fingerprint(path).expect("fingerprint")
    }

    fn index(library: &Library, rel: &str) {
        let path = library.root.join(rel);
        let mut track = crate::scanner::read_metadata(&path, rel).expect("metadata");
        track.signature = fingerprint::signature(&path);
        track.fingerprint = fingerprint::fingerprint(&path);
        library.db.insert_track(&track).expect("insert");
    }

    #[test]
    fn a_replacement_keeps_the_old_bytes_and_records_where() {
        let library = library();
        let rel = "Imported/Rough Mix.wav";
        let original = write_wav(&library.root.join(rel), 7);
        index(&library, rel);
        let incoming = library.root.join("..").join("incoming/Rough Mix.wav");
        let replacement = write_wav(&incoming, 11);

        replace_in_place(&library.db, &library.root, &library.previous, rel, &incoming)
            .expect("replaced");

        assert_eq!(
            fingerprint::fingerprint(&library.root.join(rel)),
            Some(replacement)
        );
        let kept = library.db.previous_version(rel).expect("row");
        assert_eq!(kept.stored_path, library.previous.join(rel).to_string_lossy());
        assert_eq!(
            fingerprint::fingerprint(Path::new(&kept.stored_path)),
            Some(original)
        );
        assert!(!hidden_sibling(&library.root.join(rel), "flaccy-part").exists());
    }

    #[test]
    fn the_original_survives_a_copy_that_fails() {
        let library = library();
        let rel = "Imported/Rough Mix.wav";
        let original = write_wav(&library.root.join(rel), 7);
        index(&library, rel);

        let failure = replace_in_place(
            &library.db,
            &library.root,
            &library.previous,
            rel,
            &library.root.join("missing/Rough Mix.wav"),
        )
        .expect_err("the source does not exist");

        assert_eq!(failure.step, "copying the new version");
        assert_eq!(
            fingerprint::fingerprint(&library.root.join(rel)),
            Some(original)
        );
        assert!(library.db.previous_version(rel).is_none());
        assert!(!library.previous.join(rel).exists());
    }

    #[test]
    fn the_original_survives_when_previous_versions_cannot_be_written() {
        let library = library();
        let rel = "Imported/Rough Mix.wav";
        let original = write_wav(&library.root.join(rel), 7);
        index(&library, rel);
        let incoming = library.root.join("..").join("incoming/Rough Mix.wav");
        write_wav(&incoming, 11);
        fs::create_dir_all(library.previous.parent().unwrap()).unwrap();
        fs::write(&library.previous, b"not a directory").unwrap();

        let failure =
            replace_in_place(&library.db, &library.root, &library.previous, rel, &incoming)
                .expect_err("previous-versions is a file");

        assert_eq!(failure.step, "making room in Previous Versions");
        assert_eq!(
            fingerprint::fingerprint(&library.root.join(rel)),
            Some(original)
        );
        assert!(library.db.previous_version(rel).is_none());
        assert!(!hidden_sibling(&library.root.join(rel), "flaccy-part").exists());
    }

    #[test]
    fn restoring_swaps_the_two_files_and_keeps_the_row() {
        let library = library();
        let rel = "Imported/Rough Mix.wav";
        let original = write_wav(&library.root.join(rel), 7);
        index(&library, rel);
        let id_before = track_id(&library, rel);
        let incoming = library.root.join("..").join("incoming/Rough Mix.wav");
        let replacement = write_wav(&incoming, 11);
        replace_in_place(&library.db, &library.root, &library.previous, rel, &incoming)
            .expect("replaced");

        restore_previous(&library.db, &library.root, rel).expect("restored");

        assert_eq!(
            fingerprint::fingerprint(&library.root.join(rel)),
            Some(original.clone())
        );
        let kept = library.db.previous_version(rel).expect("row");
        assert_eq!(
            fingerprint::fingerprint(Path::new(&kept.stored_path)),
            Some(replacement)
        );
        let stored = library.db.fetch_stored_versions().remove(rel).expect("version");
        assert_eq!(stored.fingerprint, Some(original));
        assert_eq!(stored.revised_at, None);
        assert_eq!(stored.revision, 1);
        assert_eq!(track_id(&library, rel), id_before);
    }

    #[test]
    fn restoring_without_a_kept_version_says_so() {
        let library = library();
        let rel = "Imported/Rough Mix.wav";
        write_wav(&library.root.join(rel), 7);
        index(&library, rel);
        let failure = restore_previous(&library.db, &library.root, rel).expect_err("nothing kept");
        assert_eq!(failure.step, "finding the previous version");
    }

    #[test]
    fn expired_versions_are_deleted_with_their_rows_and_fresh_ones_stay() {
        let library = library();
        let day = 86_400_000;
        let now = 100 * day;
        let old = library.previous.join("Imported/old.wav");
        let fresh = library.previous.join("Imported/fresh.wav");
        write_wav(&old, 3);
        write_wav(&fresh, 5);
        library
            .db
            .upsert_previous_version("Imported/old.wav", &old.to_string_lossy(), now - 31 * day)
            .unwrap();
        library
            .db
            .upsert_previous_version("Imported/fresh.wav", &fresh.to_string_lossy(), now - 29 * day)
            .unwrap();

        assert_eq!(purge_expired(&library.db, now), 1);

        assert!(!old.exists());
        assert!(library.db.previous_version("Imported/old.wav").is_none());
        assert!(fresh.exists());
        assert!(library.db.previous_version("Imported/fresh.wav").is_some());
    }

    #[test]
    fn keeping_both_files_the_copy_beside_whatever_the_import_already_holds() {
        let library = library();
        let import_root = library.root.join("Imported");
        fs::write(import_root.join("Song.wav"), b"x").unwrap();
        fs::write(import_root.join("Song_1.wav"), b"y").unwrap();
        let item = |name: &str| Item {
            source: PathBuf::from(name),
            destination: name.to_string(),
            kind: Kind::Audio,
            size: Some(1),
        };
        let placed = vec![
            Placed {
                item: item("Song.wav"),
                placement: Placement::Replace("Song.wav".into()),
            },
            Placed {
                item: item("Song_2.wav"),
                placement: Placement::Copy("Song_2.wav".into()),
            },
            Placed {
                item: item("Song.wav"),
                placement: Placement::Replace("Song.wav".into()),
            },
        ];

        let kept = keep_both(placed, &import_root);

        let destinations: Vec<_> = kept
            .iter()
            .map(|entry| match &entry.placement {
                Placement::Copy(destination) => destination.as_str(),
                other => panic!("expected a copy, got {other:?}"),
            })
            .collect();
        assert_eq!(destinations, ["Song_3.wav", "Song_2.wav", "Song_4.wav"]);
    }

    fn track_id(library: &Library, rel: &str) -> i64 {
        library
            .db
            .fetch_all_tracks()
            .into_iter()
            .find(|track| track.rel_path == rel)
            .map(|track| track.id)
            .expect("track")
    }
}
