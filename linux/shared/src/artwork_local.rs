//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/ArtworkLocalRules.swift`.
//!
//! Which images lying next to a release's music files are worth offering as its
//! cover, and in what order. File access stays with each client; this is the
//! part that must not drift.

use std::collections::BTreeSet;

pub const IMAGE_EXTENSIONS: [&str; 4] = ["jpg", "jpeg", "png", "webp"];

/// Larger files are skipped rather than decoded: a 60 MB scan of a booklet is
/// not a cover.
pub const MAXIMUM_FILE_BYTES: u64 = 25 * 1024 * 1024;

pub const MAXIMUM_IMAGES_PER_FOLDER: usize = 12;

const FRONT_NAMES: [&str; 7] = [
    "cover", "folder", "front", "albumart", "album", "artwork", "art",
];
const FRONT_HINTS: [&str; 2] = ["cover", "front"];
const BACK_WORDS: [&str; 8] = [
    "disc", "disk", "cd", "inlay", "booklet", "tray", "spine", "obi",
];
const BACK_PREFIXES: [&str; 2] = ["back", "rear"];

fn split_name(file_name: &str) -> Option<(&str, &str)> {
    let dot = file_name.rfind('.')?;
    Some((&file_name[..dot], &file_name[dot + 1..]))
}

/// An image by extension, not hidden (this includes macOS `._name` resource
/// forks on foreign volumes) and not a thumbnail.
pub fn is_candidate(file_name: &str) -> bool {
    if file_name.starts_with('.') {
        return false;
    }
    let Some((stem, extension)) = split_name(file_name) else {
        return false;
    };
    IMAGE_EXTENSIONS.contains(&extension.to_lowercase().as_str())
        && !is_thumbnail(&stem.to_lowercase())
}

/// The candidates among `names`, front covers first, then anything that merely
/// sounds like one, then the rest, scans of the back last; ties alphabetical so
/// the order never depends on directory enumeration.
pub fn rank(names: &[String]) -> Vec<String> {
    let mut ranked: Vec<(i32, &String)> = names
        .iter()
        .filter(|name| is_candidate(name))
        .map(|name| (tier(name), name))
        .collect();
    ranked.sort_by(|(lt, ln), (rt, rn)| {
        lt.cmp(rt)
            .then_with(|| ln.to_lowercase().cmp(&rn.to_lowercase()))
            .then_with(|| ln.cmp(rn))
    });
    ranked
        .into_iter()
        .take(MAXIMUM_IMAGES_PER_FOLDER)
        .map(|(_, name)| name.clone())
        .collect()
}

/// The folders to look in for a release whose tracks sit at `relative_paths`
/// under the library root: the folder every track shares first (where a
/// multi-disc release keeps its one cover), then each track's own folder. The
/// root itself is never offered, because images there belong to no particular
/// release.
pub fn folders(relative_paths: &[String]) -> Vec<String> {
    let parents: BTreeSet<String> = relative_paths
        .iter()
        .filter_map(|path| {
            let parts: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
            let folder = &parts[..parts.len().saturating_sub(1)];
            (!folder.is_empty()).then(|| folder.join("/"))
        })
        .collect();
    if parents.is_empty() {
        return Vec::new();
    }
    let shared = common_ancestor(&parents);
    let mut result = Vec::new();
    if !shared.is_empty() && !parents.contains(&shared) {
        result.push(shared);
    }
    result.extend(parents);
    result
}

fn tier(file_name: &str) -> i32 {
    let stem = split_name(file_name)
        .map_or(file_name, |(stem, _)| stem)
        .to_lowercase();
    if let Some(index) = FRONT_NAMES.iter().position(|name| *name == stem) {
        return index as i32;
    }
    if stem.starts_with("albumart") {
        return 3;
    }
    if is_back(&stem) {
        return 90;
    }
    if FRONT_HINTS.iter().any(|hint| stem.contains(hint)) {
        return 10;
    }
    20
}

/// Windows Media Player's `AlbumArtSmall.jpg` and `AlbumArt_{id}_Small.jpg` and
/// any `thumb…` file: smaller copies of a cover that sits beside them.
fn is_thumbnail(stem: &str) -> bool {
    words(stem)
        .iter()
        .any(|word| word == "small" || word.starts_with("thumb") || word == "albumartsmall")
}

fn is_back(stem: &str) -> bool {
    words(stem).iter().any(|word| {
        BACK_WORDS.contains(&word.as_str())
            || BACK_PREFIXES.iter().any(|prefix| word.starts_with(prefix))
    })
}

/// Lowercase alphanumeric runs of a file stem with trailing digits dropped, so
/// `CD2` reads as `cd` and `acdc` does not read as one.
fn words(stem: &str) -> Vec<String> {
    stem.split(|c: char| !c.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(|word| {
            let mut trimmed: Vec<char> = word.chars().collect();
            while trimmed.len() > 1 && trimmed.last().is_some_and(|c| c.is_numeric()) {
                trimmed.pop();
            }
            trimmed.into_iter().collect()
        })
        .collect()
}

fn common_ancestor(folders: &BTreeSet<String>) -> String {
    let mut shared: Option<Vec<&str>> = None;
    for folder in folders {
        let parts: Vec<&str> = folder.split('/').collect();
        shared = Some(match shared {
            None => parts,
            Some(current) => current
                .into_iter()
                .zip(parts)
                .take_while(|(left, right)| left == right)
                .map(|(left, _)| left)
                .collect(),
        });
    }
    shared.unwrap_or_default().join("/")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn l1_only_images_are_candidates() {
        assert!(is_candidate("cover.JPG"));
        assert!(is_candidate("Front.webp"));
        assert!(!is_candidate("01 Song.flac"));
        assert!(!is_candidate("cover.tiff"));
        assert!(!is_candidate("cover"));
    }

    #[test]
    fn l2_hidden_and_resource_fork_files_are_skipped() {
        assert!(!is_candidate("._cover.jpg"));
        assert!(!is_candidate(".folder.jpg"));
    }

    #[test]
    fn l3_thumbnails_are_skipped() {
        assert!(!is_candidate("AlbumArtSmall.jpg"));
        assert!(!is_candidate("AlbumArt_{4F2A}_Small.jpg"));
        assert!(!is_candidate("cover-thumb.jpg"));
        assert!(is_candidate("AlbumArt_{4F2A}_Large.jpg"));
        assert!(is_candidate("Smallville Soundtrack.png"));
    }

    #[test]
    fn l4_front_cover_names_outrank_everything_in_a_fixed_order() {
        let input = names(&[
            "booklet.jpg",
            "scan 1.jpg",
            "front.jpg",
            "Folder.jpg",
            "cover.png",
            "back.jpg",
            "AlbumArt_{1}_Large.jpg",
        ]);
        assert_eq!(
            rank(&input),
            names(&[
                "cover.png",
                "Folder.jpg",
                "front.jpg",
                "AlbumArt_{1}_Large.jpg",
                "scan 1.jpg",
                "back.jpg",
                "booklet.jpg",
            ])
        );
    }

    #[test]
    fn l5_names_that_merely_sound_like_a_cover_come_before_others() {
        assert_eq!(
            rank(&names(&["zebra.jpg", "Album Cover (1999).jpg", "alpha.jpg"])),
            names(&["Album Cover (1999).jpg", "alpha.jpg", "zebra.jpg"])
        );
    }

    #[test]
    fn l6_back_scans_are_recognised_by_word_not_by_substring() {
        assert_eq!(
            rank(&names(&["Back Cover.jpg", "acdc.jpg"])),
            names(&["acdc.jpg", "Back Cover.jpg"])
        );
        assert_eq!(
            rank(&names(&["CD2.jpg", "mine.jpg"])),
            names(&["mine.jpg", "CD2.jpg"])
        );
    }

    #[test]
    fn l7_ranking_is_capped_and_stable() {
        let mut input: Vec<String> = (0..30).map(|i| format!("scan {i:02}.jpg")).collect();
        input.reverse();
        let ranked = rank(&input);
        assert_eq!(ranked.len(), MAXIMUM_IMAGES_PER_FOLDER);
        assert_eq!(ranked[0], "scan 00.jpg");
    }

    #[test]
    fn l8_a_single_folder_is_its_own_answer() {
        assert_eq!(
            folders(&names(&["Artist/Album/01.flac", "Artist/Album/02.flac"])),
            names(&["Artist/Album"])
        );
    }

    #[test]
    fn l9_disc_folders_are_searched_after_their_shared_parent() {
        assert_eq!(
            folders(&names(&[
                "Artist/Album/CD2/01.flac",
                "Artist/Album/CD1/01.flac"
            ])),
            names(&["Artist/Album", "Artist/Album/CD1", "Artist/Album/CD2"])
        );
    }

    #[test]
    fn l10_the_library_root_is_never_searched() {
        assert!(folders(&names(&["01.flac", "02.flac"])).is_empty());
        assert_eq!(
            folders(&names(&["A/Album/01.flac", "B/Album/02.flac"])),
            names(&["A/Album", "B/Album"])
        );
    }

    #[test]
    fn l11_a_track_at_the_root_does_not_hide_its_siblings_folder() {
        assert_eq!(
            folders(&names(&["01.flac", "Album/02.flac"])),
            names(&["Album"])
        );
    }
}
