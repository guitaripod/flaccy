//! Mirrors `FlaccyCore/Sources/FlaccyCore/Library/ImportPlan.swift`.
//!
//! What an import copies and where each file lands, decided before a byte
//! moves so every client files a picked folder the same way. A picked file
//! lands at the top of the import root under its own name; a picked folder
//! keeps its own name as the top folder with its whole tree beneath it,
//! because album credits are resolved per containing folder and flattening a
//! compilation's folder would split it back into one album per performer.
//! Lyrics sidecars travel with the music and nothing else does. A file that
//! already lives inside the library is counted, never copied in again.
//!
//! The Apple half also recognises iCloud placeholders; no Linux file system
//! leaves them, so this half skips them like any other hidden file.

use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

pub const LYRICS_EXTENSIONS: [&str; 2] = ["lrc", "elrc"];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Audio,
    Lyrics,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Item {
    pub source: PathBuf,
    /// Slash-separated path under the import root.
    pub destination: String,
    pub kind: Kind,
    pub size: Option<u64>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Plan {
    pub items: Vec<Item>,
    /// Audio files among the picked sources that already live inside the library.
    pub already_in_library: usize,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Placement {
    Copy(String),
    AlreadyPresent,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Placed {
    pub item: Item,
    pub placement: Placement,
}

/// What one import did, counted in audio files only: a lyrics sidecar rides
/// along with its song and is never reported on its own.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Outcome {
    pub imported: usize,
    pub skipped: usize,
    pub failed: usize,
}

/// Walks every picked source. Hidden files and folders are skipped, a folder
/// reached twice through a symlink is walked once, and the order is stable so
/// two runs over the same tree plan the same copies.
pub fn plan(picked: &[PathBuf], library_root: &Path, audio_extensions: &[&str]) -> Plan {
    let mut walk = Walk {
        library_root: canonical(library_root),
        audio_extensions: audio_extensions.iter().map(|e| e.to_lowercase()).collect(),
        items: Vec::new(),
        already_in_library: 0,
        visited: HashSet::new(),
    };
    for source in picked {
        let name = source
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let top: Vec<String> = if name.is_empty() { Vec::new() } else { vec![name.clone()] };
        if source.is_dir() {
            walk.walk(source, &top);
        } else {
            let inside = is_inside(&canonical(source), &walk.library_root);
            walk.add(source, &name, &top, file_size(source), false, inside);
        }
    }
    Plan {
        items: walk.items,
        already_in_library: walk.already_in_library,
    }
}

/// Where each planned file goes under `import_root`, in plan order.
///
/// The same relative path at the same size is the same file and is left alone,
/// which is also what makes an interrupted import resumable. A different file
/// under a taken name gets the first free `name_n.ext` beside it, and a
/// `name_n` that already holds this very file counts as present, so importing
/// one folder twice never breeds a second copy. Destinations claimed earlier in
/// the same import are taken too.
pub fn placements(plan: &Plan, import_root: &Path) -> Vec<Placed> {
    let mut claimed: HashMap<String, Option<u64>> = HashMap::new();
    plan.items
        .iter()
        .map(|item| {
            let placement = place(item, import_root, &claimed);
            if let Placement::Copy(destination) = &placement {
                claimed.insert(destination.clone(), item.size);
            }
            Placed {
                item: item.clone(),
                placement,
            }
        })
        .collect()
}

/// The sentence the Apple clients' `ImportOutcomeCopy.report` shows, word for
/// word in its English form, and whether it reports a failure.
pub fn report(outcome: &Outcome) -> (String, bool) {
    match (outcome.imported, outcome.skipped, outcome.failed) {
        (0, 0, 0) => ("Nothing to import.".to_string(), false),
        (0, 1, 0) => ("Already in your library.".to_string(), false),
        (0, skipped, 0) => (format!("All {skipped} items are already in your library."), false),
        (0, _, _) => ("Import failed — the files couldn't be copied.".to_string(), true),
        (1, 0, 0) => ("Imported 1 item".to_string(), false),
        (imported, 0, 0) => (format!("Imported {imported} items"), false),
        (imported, skipped, 0) => (format!("Imported {imported}, {skipped} already in your library"), false),
        (imported, _, failed) => (format!("Imported {imported}, {failed} failed to copy"), true),
    }
}

enum Slot {
    Free,
    Taken(Option<u64>),
}

fn place(item: &Item, import_root: &Path, claimed: &HashMap<String, Option<u64>>) -> Placement {
    let (parent, name) = match item.destination.rsplit_once('/') {
        Some((parent, name)) => (parent.to_string(), name.to_string()),
        None => (String::new(), item.destination.clone()),
    };
    let (stem, extension) = split_extension(&name);
    let mut candidate = item.destination.clone();
    let mut counter = 0;
    loop {
        match slot(&candidate, import_root, claimed) {
            Slot::Free => return Placement::Copy(candidate),
            Slot::Taken(occupant) => match (item.size, occupant) {
                (Some(size), Some(occupant)) if size != occupant => {}
                _ => return Placement::AlreadyPresent,
            },
        }
        counter += 1;
        let renamed = if extension.is_empty() {
            format!("{stem}_{counter}")
        } else {
            format!("{stem}_{counter}.{extension}")
        };
        candidate = if parent.is_empty() {
            renamed
        } else {
            format!("{parent}/{renamed}")
        };
    }
}

fn slot(destination: &str, import_root: &Path, claimed: &HashMap<String, Option<u64>>) -> Slot {
    if let Some(size) = claimed.get(destination) {
        return Slot::Taken(*size);
    }
    let target = import_root.join(destination);
    if target.exists() {
        Slot::Taken(file_size(&target))
    } else {
        Slot::Free
    }
}

/// `NSString.pathExtension` semantics: a leading dot is part of the stem, so
/// `.hidden` has no extension and `song.flac` has `flac`.
fn split_extension(name: &str) -> (String, String) {
    match name.rfind('.') {
        Some(index) if index > 0 && index + 1 < name.len() => {
            (name[..index].to_string(), name[index + 1..].to_string())
        }
        _ => (name.to_string(), String::new()),
    }
}

fn extension_of(name: &str) -> String {
    split_extension(name).1.to_lowercase()
}

struct Walk {
    library_root: PathBuf,
    audio_extensions: HashSet<String>,
    items: Vec<Item>,
    already_in_library: usize,
    visited: HashSet<PathBuf>,
}

impl Walk {
    fn add(
        &mut self,
        file: &Path,
        name: &str,
        components: &[String],
        size: Option<u64>,
        allows_lyrics: bool,
        inside_library: bool,
    ) {
        let extension = extension_of(name);
        let kind = if self.audio_extensions.contains(&extension) {
            Kind::Audio
        } else if allows_lyrics && LYRICS_EXTENSIONS.contains(&extension.as_str()) {
            Kind::Lyrics
        } else {
            return;
        };
        if inside_library {
            if kind == Kind::Audio {
                self.already_in_library += 1;
            }
            return;
        }
        self.items.push(Item {
            source: file.to_path_buf(),
            destination: components.join("/"),
            kind,
            size,
        });
    }

    /// Whether a folder sits inside the library is decided once per folder
    /// rather than per file, because resolving a path costs a round trip per
    /// component on a network mount.
    fn walk(&mut self, folder: &Path, components: &[String]) {
        let canonical = canonical(folder);
        if !self.visited.insert(canonical.clone()) {
            return;
        }
        let inside_library = is_inside(&canonical, &self.library_root);
        let Ok(entries) = fs::read_dir(folder) else {
            return;
        };
        let mut children: Vec<(String, PathBuf)> = entries
            .flatten()
            .map(|entry| (entry.file_name().to_string_lossy().into_owned(), entry.path()))
            .collect();
        children.sort();
        for (name, child) in children {
            if name.starts_with('.') {
                continue;
            }
            let mut nested = components.to_vec();
            nested.push(name.clone());
            if child.is_dir() {
                self.walk(&child, &nested);
            } else {
                self.add(&child, &name, &nested, file_size(&child), true, inside_library);
            }
        }
    }
}

fn file_size(path: &Path) -> Option<u64> {
    fs::metadata(path).ok().map(|m| m.len())
}

fn canonical(path: &Path) -> PathBuf {
    fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn is_inside(path: &Path, root: &Path) -> bool {
    path.starts_with(root)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const AUDIO: [&str; 2] = ["flac", "mp3"];

    struct Sandbox {
        base: PathBuf,
        outside: PathBuf,
        library: PathBuf,
    }

    impl Sandbox {
        fn new() -> Self {
            static COUNTER: AtomicUsize = AtomicUsize::new(0);
            let base = std::env::temp_dir().join(format!(
                "flaccy-import-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::SeqCst)
            ));
            let outside = base.join("outside");
            let library = base.join("library");
            fs::create_dir_all(&outside).unwrap();
            fs::create_dir_all(&library).unwrap();
            Self {
                base,
                outside,
                library,
            }
        }

        fn write(&self, base: &Path, path: &str, bytes: usize) -> PathBuf {
            let target = base.join(path);
            fs::create_dir_all(target.parent().unwrap()).unwrap();
            fs::write(&target, vec![7u8; bytes]).unwrap();
            target
        }

        fn plan(&self, picked: &[PathBuf]) -> Plan {
            plan(picked, &self.library, &AUDIO)
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.base);
        }
    }

    fn destinations(plan: &Plan) -> Vec<String> {
        plan.items.iter().map(|i| i.destination.clone()).collect()
    }

    fn verdicts(placed: &[Placed]) -> Vec<Placement> {
        placed.iter().map(|p| p.placement.clone()).collect()
    }

    #[test]
    fn a_picked_file_lands_at_the_top_under_its_own_name() {
        let s = Sandbox::new();
        let file = s.write(&s.outside, "Downloads/song.flac", 4);

        let plan = s.plan(&[file]);

        assert_eq!(destinations(&plan), vec!["song.flac"]);
        assert_eq!(plan.items[0].kind, Kind::Audio);
        assert_eq!(plan.items[0].size, Some(4));
    }

    #[test]
    fn a_picked_folder_keeps_its_name_and_its_tree() {
        let s = Sandbox::new();
        s.write(&s.outside, "Score/CD1/01.flac", 4);
        s.write(&s.outside, "Score/CD2/01.flac", 4);

        let plan = s.plan(&[s.outside.join("Score")]);

        assert_eq!(destinations(&plan), vec!["Score/CD1/01.flac", "Score/CD2/01.flac"]);
    }

    #[test]
    fn only_music_and_its_lyrics_travel() {
        let s = Sandbox::new();
        for name in ["song.flac", "song.LRC", "song.elrc", "cover.jpg", "notes.txt", ".hidden.flac", ".DS_Store"] {
            s.write(&s.outside, &format!("Album/{name}"), 4);
        }

        let plan = s.plan(&[s.outside.join("Album")]);

        assert_eq!(destinations(&plan), vec!["Album/song.LRC", "Album/song.elrc", "Album/song.flac"]);
        let kinds: Vec<Kind> = plan.items.iter().map(|i| i.kind).collect();
        assert_eq!(kinds, vec![Kind::Lyrics, Kind::Lyrics, Kind::Audio]);
    }

    #[test]
    fn hidden_folders_are_not_walked() {
        let s = Sandbox::new();
        s.write(&s.outside, "Album/.git/objects/a.flac", 4);
        s.write(&s.outside, "Album/b.flac", 4);

        assert_eq!(destinations(&s.plan(&[s.outside.join("Album")])), vec!["Album/b.flac"]);
    }

    #[test]
    fn a_lyrics_file_picked_on_its_own_is_not_imported() {
        let s = Sandbox::new();
        let lyrics = s.write(&s.outside, "song.lrc", 4);

        assert!(s.plan(&[lyrics]).items.is_empty());
    }

    #[test]
    fn music_already_inside_the_library_is_counted_not_copied() {
        let s = Sandbox::new();
        s.write(&s.library, "Artist/Album/01.flac", 4);
        s.write(&s.library, "Artist/Album/02.mp3", 4);
        s.write(&s.library, "Artist/Album/02.lrc", 4);

        let plan = s.plan(&[s.library.join("Artist")]);

        assert!(plan.items.is_empty());
        assert_eq!(plan.already_in_library, 2);
    }

    #[test]
    fn the_same_file_at_the_same_path_is_already_present() {
        let s = Sandbox::new();
        s.write(&s.outside, "Album/01.flac", 4);
        s.write(&s.library, "Album/01.flac", 4);

        let placed = placements(&s.plan(&[s.outside.join("Album")]), &s.library);

        assert_eq!(verdicts(&placed), vec![Placement::AlreadyPresent]);
    }

    #[test]
    fn a_different_file_under_a_taken_name_gets_the_next_free_name() {
        let s = Sandbox::new();
        s.write(&s.outside, "Album/01.flac", 9);
        s.write(&s.library, "Album/01.flac", 4);

        let placed = placements(&s.plan(&[s.outside.join("Album")]), &s.library);

        assert_eq!(verdicts(&placed), vec![Placement::Copy("Album/01_1.flac".into())]);
    }

    #[test]
    fn importing_the_same_folder_twice_never_breeds_a_second_copy() {
        let s = Sandbox::new();
        s.write(&s.outside, "Album/01.flac", 9);
        s.write(&s.library, "Album/01.flac", 4);
        s.write(&s.library, "Album/01_1.flac", 9);

        let placed = placements(&s.plan(&[s.outside.join("Album")]), &s.library);

        assert_eq!(verdicts(&placed), vec![Placement::AlreadyPresent]);
    }

    #[test]
    fn two_picked_files_that_share_a_name_do_not_land_on_each_other() {
        let s = Sandbox::new();
        let first = s.write(&s.outside, "a/x.flac", 4);
        let second = s.write(&s.outside, "b/x.flac", 9);
        let twin = s.write(&s.outside, "c/x.flac", 4);

        let placed = placements(&s.plan(&[first, second, twin]), &s.library);

        assert_eq!(
            verdicts(&placed),
            vec![
                Placement::Copy("x.flac".into()),
                Placement::Copy("x_1.flac".into()),
                Placement::AlreadyPresent,
            ]
        );
    }

    #[test]
    fn a_folder_reached_twice_through_a_symlink_is_walked_once() {
        let s = Sandbox::new();
        s.write(&s.outside, "Album/01.flac", 4);
        std::os::unix::fs::symlink(s.outside.join("Album"), s.outside.join("Album/loop")).unwrap();

        assert_eq!(destinations(&s.plan(&[s.outside.join("Album")])), vec!["Album/01.flac"]);
    }

    #[test]
    fn a_hidden_icloud_placeholder_is_skipped_on_linux() {
        let s = Sandbox::new();
        s.write(&s.outside, "Album/.02 Song.flac.icloud", 4);

        assert!(s.plan(&[s.outside.join("Album")]).items.is_empty());
    }

    #[test]
    fn extensions_split_like_nsstring() {
        assert_eq!(split_extension("song.flac"), ("song".into(), "flac".into()));
        assert_eq!(split_extension("archive.tar.gz"), ("archive.tar".into(), "gz".into()));
        assert_eq!(split_extension(".hidden"), (".hidden".into(), String::new()));
        assert_eq!(split_extension("noext"), ("noext".into(), String::new()));
    }

    #[test]
    fn the_report_matches_the_apple_sentences() {
        let cases = [
            ((0, 0, 0), "Nothing to import.", false),
            ((0, 1, 0), "Already in your library.", false),
            ((0, 5, 0), "All 5 items are already in your library.", false),
            ((0, 2, 3), "Import failed — the files couldn't be copied.", true),
            ((1, 0, 0), "Imported 1 item", false),
            ((12, 0, 0), "Imported 12 items", false),
            ((12, 3, 0), "Imported 12, 3 already in your library", false),
            ((12, 3, 2), "Imported 12, 2 failed to copy", true),
        ];
        for ((imported, skipped, failed), sentence, failure) in cases {
            let outcome = Outcome {
                imported,
                skipped,
                failed,
            };
            assert_eq!(report(&outcome), (sentence.to_string(), failure));
        }
    }
}
