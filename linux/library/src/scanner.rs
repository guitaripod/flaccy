use crate::db::{now_ms, Db, NewTrack};
use crate::fingerprint;
use crate::load_progress::{LoadPhase, LoadProgress};
use lofty::file::{AudioFile, FileType, TaggedFile, TaggedFileExt};
use lofty::prelude::*;
use lofty::tag::ItemKey;
use flaccy_shared::track_revision::{self, Outcome};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Held for the whole revision pass, so a scan started while the previous one
/// is still fingerprinting waits for it and then finds the rows already settled
/// instead of recognising the same re-export twice.
static REVISION_PASS: Mutex<()> = Mutex::new(());

pub const SUPPORTED_EXTENSIONS: [&str; 8] = ["flac", "mp3", "m4a", "ogg", "opus", "wav", "aiff", "aif"];

pub enum ScanEvent {
    Progress(LoadProgress),
    /// Albums whose embedded cover this chunk just wrote into `albumInfo`,
    /// announced so the Debut's mosaic fills during the tag pass instead of
    /// waiting for the first build.
    CoversHoisted(Vec<(String, String)>),
    Done {
        added: usize,
        removed: usize,
    },
    /// Sent after `Done`, once the revision pass has recognised re-exports of
    /// songs already in the library: the paths whose audio is a new version.
    Revised(Vec<String>),
    /// Sent after `Done` when the revision pass re-read tags that changed on
    /// files whose audio did not, so the views reload.
    Retagged,
    Failed(String),
}

/// What the revision pass decided about the files it had to look at.
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct RevisionReport {
    pub baseline: usize,
    pub retagged: usize,
    pub new_versions: Vec<String>,
}

pub fn spawn_scan(root: PathBuf, db_path: PathBuf, tx: async_channel::Sender<ScanEvent>) {
    std::thread::Builder::new()
        .name("flaccy-scan".into())
        .spawn(move || {
            match run_scan(&root, &db_path, &tx) {
                Ok(outcome) => {
                    let _ = tx.send_blocking(ScanEvent::Done {
                        added: outcome.added,
                        removed: outcome.removed,
                    });
                    announce_revisions(&root, &db_path, &outcome.files, &tx);
                }
                Err(message) => {
                    let _ = tx.send_blocking(ScanEvent::Failed(message));
                }
            }
        })
        .ok();
}

struct ScanOutcome {
    added: usize,
    removed: usize,
    files: Vec<PathBuf>,
}

/// Runs the revision pass behind a finished scan and tells the main loop what
/// it found. A database that cannot be opened here already failed the scan.
fn announce_revisions(
    root: &Path,
    db_path: &Path,
    files: &[PathBuf],
    tx: &async_channel::Sender<ScanEvent>,
) {
    let Ok(db) = Db::open(db_path) else { return };
    let report = run_revision_pass(root, &db, files);
    if report.baseline + report.retagged + report.new_versions.len() > 0 {
        crate::logger::info(
            "library",
            &format!(
                "revision pass: {} baseline, {} retagged, {} new versions",
                report.baseline,
                report.retagged,
                report.new_versions.len()
            ),
        );
    }
    if report.retagged > 0 {
        let _ = tx.send_blocking(ScanEvent::Retagged);
    }
    if !report.new_versions.is_empty() {
        let _ = tx.send_blocking(ScanEvent::Revised(report.new_versions));
    }
}

/// Looks at every file that is both on disk and already indexed. A file whose
/// size and modification time match what is stored is not read; one that moved
/// is fingerprinted, and `track_revision` decides whether only its tags
/// changed (the row is refreshed in place and keeps its revision) or its audio
/// did (the row is refreshed and its revision goes up). A file that changed
/// again while it was being read, or cannot be read as audio yet, is left for
/// the next scan.
pub(crate) fn run_revision_pass(root: &Path, db: &Db, files: &[PathBuf]) -> RevisionReport {
    let _held = REVISION_PASS.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let stored = db.fetch_stored_versions();
    let mut report = RevisionReport::default();
    let mut album_moved = false;
    for path in files {
        let rel = relative_path(root, path);
        let Some(known) = stored.get(&rel) else {
            continue;
        };
        let Some(signature) = fingerprint::signature(path) else {
            continue;
        };
        if !track_revision::needs_inspection(known, &signature) {
            continue;
        }
        let digest = fingerprint::fingerprint(path);
        if fingerprint::signature(path) != Some(signature) {
            continue;
        }
        let outcome = track_revision::classify(known, digest.as_deref());
        let next = track_revision::applying(outcome, known, signature, digest.as_deref(), now_ms());
        if matches!(outcome, Outcome::Retagged | Outcome::NewVersion) {
            let Some(track) = read_metadata(path, &rel) else {
                crate::logger::warn("library", &format!("revision pass could not read {rel}"));
                continue;
            };
            match db.refresh_track_in_place(&track) {
                Ok(moved) => album_moved |= moved,
                Err(err) => {
                    crate::logger::error("library", &format!("refresh failed for {rel}: {err}"));
                    continue;
                }
            }
        }
        if let Err(err) = db.update_version(&rel, &next) {
            crate::logger::error("library", &format!("version write failed for {rel}: {err}"));
            continue;
        }
        match outcome {
            Outcome::Baseline => report.baseline += 1,
            Outcome::Retagged => report.retagged += 1,
            Outcome::NewVersion => report.new_versions.push(rel),
            Outcome::Unchanged => {}
        }
    }
    if album_moved {
        if let Err(err) = db.sweep_orphaned_enrichment() {
            crate::logger::error("library", &format!("orphan sweep failed: {err}"));
        }
    }
    report
}

fn run_scan(
    root: &Path,
    db_path: &Path,
    tx: &async_channel::Sender<ScanEvent>,
) -> Result<ScanOutcome, String> {
    let db = Db::open(db_path).map_err(|e| format!("db open failed: {e}"))?;
    let mut progress = LoadProgress::new(LoadPhase::FindingFiles);
    let _ = tx.send_blocking(ScanEvent::Progress(progress));

    let files = collect_audio_files(root);
    progress.files_found = files.len();
    let _ = tx.send_blocking(ScanEvent::Progress(progress));
    let disk_paths: HashSet<String> = files.iter().map(|path| relative_path(root, path)).collect();
    let existing = db.fetch_relative_paths();

    if disk_paths.is_empty() && !existing.is_empty() {
        crate::logger::warn(
            "library",
            "scan found zero files but database is non-empty; keeping database (transient-empty root guard)",
        );
        return Ok(ScanOutcome {
            added: 0,
            removed: 0,
            files: Vec::new(),
        });
    }

    let to_add: Vec<&PathBuf> = files
        .iter()
        .filter(|path| !existing.contains(&relative_path(root, path)))
        .collect();
    let total = to_add.len();
    let mut added = 0;
    let already_indexed = existing
        .iter()
        .filter(|path| disk_paths.contains(*path))
        .count();

    progress.phase = LoadPhase::ReadingTags;
    progress.total = total;
    progress.completed = 0;
    progress.tracks_indexed = already_indexed;
    let _ = tx.send_blocking(ScanEvent::Progress(progress));

    let mut hoisted: Vec<(String, String)> = Vec::new();
    let mut announced: HashSet<String> = HashSet::new();

    for (index, path) in to_add.iter().enumerate() {
        if index % 25 == 0 || index + 1 == total {
            progress.completed = index + 1;
            progress.tracks_indexed = already_indexed + added;
            let _ = tx.send_blocking(ScanEvent::Progress(progress));
            if !hoisted.is_empty() {
                let _ = tx.send_blocking(ScanEvent::CoversHoisted(std::mem::take(&mut hoisted)));
            }
        }
        let rel = relative_path(root, path);
        match read_track(path, &rel) {
            Some(track) => {
                let cover = track.artwork.is_some() && !track.album.is_empty();
                if let Err(err) = db.insert_track(&track) {
                    crate::logger::error("library", &format!("insert failed for {rel}: {err}"));
                } else {
                    added += 1;
                    if cover && announced.insert(format!("{}|{}", track.album, track.artist)) {
                        hoisted.push((track.album.clone(), track.artist.clone()));
                    }
                }
            }
            None => {
                crate::logger::warn("library", &format!("skipped unreadable audio: {rel}"));
            }
        }
    }
    if !hoisted.is_empty() {
        let _ = tx.send_blocking(ScanEvent::CoversHoisted(hoisted));
    }

    let removed = db
        .delete_tracks_not_in(&disk_paths)
        .map_err(|e| format!("prune failed: {e}"))?;
    crate::logger::info(
        "library",
        &format!(
            "scan complete: {added} added, {removed} removed, {} on disk",
            disk_paths.len()
        ),
    );
    Ok(ScanOutcome {
        added,
        removed,
        files,
    })
}

fn collect_audio_files(root: &Path) -> Vec<PathBuf> {
    let mut result = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    let mut visited: HashSet<PathBuf> = HashSet::new();
    while let Some(dir) = stack.pop() {
        if let Ok(canonical) = std::fs::canonicalize(&dir) {
            if !visited.insert(canonical) {
                continue;
            }
        }
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name();
            if name.to_string_lossy().starts_with('.') {
                continue;
            }
            if path.is_dir() {
                stack.push(path);
            } else if let Some(ext) = path.extension() {
                let ext = ext.to_string_lossy().to_lowercase();
                if SUPPORTED_EXTENSIONS.contains(&ext.as_str()) {
                    result.push(path);
                }
            }
        }
    }
    result.sort();
    result
}

/// Preserves the on-disk byte form of the relative path: Linux filesystems are
/// normalization-sensitive, so an NFC-normalized key (the Apple
/// canonicalSyncPath behavior) would point at a nonexistent file for
/// NFD-named libraries copied from a Mac.
pub(crate) fn relative_path(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| {
            path.file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string()
        })
}

/// A new file's tags together with the signature and fingerprint that baseline
/// it, so the first re-export is told apart from the original.
fn read_track(path: &Path, rel_path: &str) -> Option<NewTrack> {
    let mut track = read_metadata(path, rel_path)?;
    track.signature = fingerprint::signature(path);
    track.fingerprint = fingerprint::fingerprint(path);
    Some(track)
}

/// What a file's tags and stream properties say, without reading the audio
/// bytes a second time. Also what restoring a previous mix re-reads in place.
pub fn read_metadata(path: &Path, rel_path: &str) -> Option<NewTrack> {
    let tagged = lofty::probe::Probe::open(path).ok()?.read().ok()?;
    let properties = tagged.properties();
    let duration = properties.duration().as_secs_f64();
    if duration <= 0.0 {
        return None;
    }

    let tag = tagged.primary_tag().or_else(|| tagged.first_tag());
    let stem = path.file_stem().unwrap_or_default().to_string_lossy();
    let parsed = parse_filename(&stem);
    let (path_artist, path_album) = path_info(rel_path);

    let title = tag
        .and_then(|t| t.title().map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
        .unwrap_or(parsed.title);
    let artist = tag
        .and_then(|t| t.artist().map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
        .or(path_artist)
        .unwrap_or_else(|| "Unknown Artist".to_string());
    let album = tag
        .and_then(|t| t.album().map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
        .or(path_album)
        .unwrap_or_else(|| "Unknown Album".to_string());
    let album_artist = tag
        .and_then(|t| t.get_string(&ItemKey::AlbumArtist).map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty());
    let tag_track = tag.and_then(|t| t.track()).unwrap_or(0) as i32;
    let track_number = if tag_track > 0 {
        tag_track
    } else {
        parsed.track_number
    };

    let artwork = tag.and_then(|t| {
        t.pictures()
            .iter()
            .find(|p| p.pic_type() == lofty::picture::PictureType::CoverFront)
            .or_else(|| t.pictures().first())
            .map(|p| p.data().to_vec())
    });

    Some(NewTrack {
        rel_path: rel_path.to_string(),
        title,
        artist,
        album,
        album_artist,
        track_number,
        duration,
        codec: detect_codec(&tagged, path),
        bit_depth: properties.bit_depth().map(|b| b as i32),
        sample_rate: properties.sample_rate().map(|r| r as i32),
        channels: properties.channels().map(|c| c as i32),
        artwork,
        signature: None,
        fingerprint: None,
    })
}

/// Resolves the badge codec from the detected stream format (mirroring
/// AudioMetadataReader.readFormat, which distinguishes ALAC from AAC inside
/// the same .m4a container), falling back to the extension map.
fn detect_codec(tagged: &TaggedFile, path: &Path) -> Option<String> {
    let codec = match tagged.file_type() {
        FileType::Flac => "FLAC",
        FileType::Mpeg => "MP3",
        FileType::Mp4 => return mp4_codec(path).or_else(|| codec_for_extension(path)),
        FileType::Vorbis => "OGG",
        FileType::Opus => "OPUS",
        FileType::Wav => "WAV",
        FileType::Aiff => "AIFF",
        FileType::Aac => "AAC",
        _ => return codec_for_extension(path),
    };
    Some(codec.to_string())
}

fn mp4_codec(path: &Path) -> Option<String> {
    let mut file = std::fs::File::open(path).ok()?;
    let mp4 = lofty::mp4::Mp4File::read_from(&mut file, lofty::config::ParseOptions::new()).ok()?;
    let codec = match mp4.properties().codec() {
        lofty::mp4::Mp4Codec::AAC => "AAC",
        lofty::mp4::Mp4Codec::ALAC => "ALAC",
        lofty::mp4::Mp4Codec::MP3 => "MP3",
        lofty::mp4::Mp4Codec::FLAC => "FLAC",
        _ => return None,
    };
    Some(codec.to_string())
}

fn codec_for_extension(path: &Path) -> Option<String> {
    let ext = path.extension()?.to_string_lossy().to_lowercase();
    let codec = match ext.as_str() {
        "flac" => "FLAC",
        "mp3" => "MP3",
        "m4a" => "AAC",
        "ogg" => "OGG",
        "opus" => "OPUS",
        "wav" => "WAV",
        "aiff" | "aif" => "AIFF",
        _ => return None,
    };
    Some(codec.to_string())
}

fn path_info(rel_path: &str) -> (Option<String>, Option<String>) {
    let components: Vec<&str> = {
        let mut parts: Vec<&str> = rel_path.split('/').collect();
        parts.pop();
        parts
    };
    match components.len() {
        0 => (None, None),
        1 => (None, Some(components[0].to_string())),
        n => (
            Some(components[n - 2].to_string()),
            Some(components[n - 1].to_string()),
        ),
    }
}

pub struct ParsedFilename {
    pub title: String,
    pub track_number: i32,
}

/// Port of FlaccyCore.FilenameParser: leading 1–3 digit track number followed
/// by a separator in `-._)]` or whitespace, then the title; underscores become
/// spaces and whitespace runs collapse.
pub fn parse_filename(filename: &str) -> ParsedFilename {
    let mut name = filename.to_string();
    let mut track_number = 0;

    let digits: String = filename
        .chars()
        .take_while(|c| c.is_ascii_digit())
        .collect();
    let digit_count = filename.chars().take_while(|c| c.is_ascii_digit()).count();
    if (1..=3).contains(&digit_count) && digit_count < filename.chars().count() {
        let rest: String = filename.chars().skip(digit_count).collect();
        let after_spaces = rest.trim_start();
        let leading_spaces = rest.len() - after_spaces.len();
        let mut chars = after_spaces.chars();
        let separator = chars.next();
        let extracted = match separator {
            Some(c) if "-._)]".contains(c) => Some(chars.as_str().trim_start().to_string()),
            Some(_) if leading_spaces > 0 => Some(after_spaces.to_string()),
            _ => None,
        };
        if let Some(title) = extracted {
            track_number = digits.parse().unwrap_or(0);
            let trimmed = title.trim();
            if !trimmed.is_empty() {
                name = trimmed.to_string();
            }
        }
    }

    let cleaned: String = name
        .replace('_', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");

    ParsedFilename {
        title: if cleaned.is_empty() {
            filename.to_string()
        } else {
            cleaned
        },
        track_number,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leading_track_number_with_dash() {
        let parsed = parse_filename("03 - Some Song");
        assert_eq!(parsed.track_number, 3);
        assert_eq!(parsed.title, "Some Song");
    }

    #[test]
    fn leading_track_number_with_space() {
        let parsed = parse_filename("07 Another Song");
        assert_eq!(parsed.track_number, 7);
        assert_eq!(parsed.title, "Another Song");
    }

    #[test]
    fn no_track_number() {
        let parsed = parse_filename("Just_A_Song");
        assert_eq!(parsed.track_number, 0);
        assert_eq!(parsed.title, "Just A Song");
    }

    #[test]
    fn four_digit_prefix_is_not_a_track_number() {
        let parsed = parse_filename("1234 Song");
        assert_eq!(parsed.track_number, 0);
        assert_eq!(parsed.title, "1234 Song");
    }

    #[test]
    fn tab_separator_whitespace_class() {
        let parsed = parse_filename("03\t- Some Song");
        assert_eq!(parsed.track_number, 3);
        assert_eq!(parsed.title, "Some Song");
    }

    #[test]
    fn empty_title_still_takes_track_number() {
        let parsed = parse_filename("01 - ");
        assert_eq!(parsed.track_number, 1);
        assert_eq!(parsed.title, "01 -");
    }

    #[test]
    fn dot_separator() {
        let parsed = parse_filename("12. Twelfth");
        assert_eq!(parsed.track_number, 12);
        assert_eq!(parsed.title, "Twelfth");
    }

    mod revision_pass {
        use super::super::*;
        use crate::fingerprint::fixtures::{info_tags, tone, wav_bytes, TempDir};
        use flaccy_shared::track_revision::StoredVersion;

        const REL: &str = "Imported/Rough Mix.wav";

        struct Fixture {
            _dir: TempDir,
            root: PathBuf,
            db: Db,
        }

        fn fixture() -> Fixture {
            let dir = TempDir::new("revision-pass");
            let root = dir.path().join("music");
            std::fs::create_dir_all(root.join("Imported")).unwrap();
            let db = Db::open(&dir.path().join("data/library.sqlite")).unwrap();
            Fixture { root, db, _dir: dir }
        }

        fn write(fixture: &Fixture, title: &str, album: &str, samples: usize, step: i16) {
            let tags = info_tags(title, "Drill Band", album);
            std::fs::write(
                fixture.root.join(REL),
                wav_bytes(&tone(samples, step), Some(&tags)),
            )
            .unwrap();
        }

        fn pass(fixture: &Fixture) -> RevisionReport {
            let files = collect_audio_files(&fixture.root);
            run_revision_pass(&fixture.root, &fixture.db, &files)
        }

        fn version(fixture: &Fixture) -> StoredVersion {
            fixture.db.fetch_stored_versions().remove(REL).expect("version")
        }

        fn track(fixture: &Fixture) -> crate::library::Track {
            fixture
                .db
                .fetch_all_tracks()
                .into_iter()
                .find(|track| track.rel_path == REL)
                .expect("track")
        }

        fn index(fixture: &Fixture) {
            let track = read_track(&fixture.root.join(REL), REL).expect("track");
            fixture.db.insert_track(&track).unwrap();
        }

        #[test]
        fn a_file_scanned_before_versions_existed_is_baselined_once_and_left_alone() {
            let fixture = fixture();
            write(&fixture, "Rough Mix", "Rough Cuts", 4000, 7);
            let mut legacy = read_metadata(&fixture.root.join(REL), REL).unwrap();
            legacy.signature = None;
            legacy.fingerprint = None;
            fixture.db.insert_track(&legacy).unwrap();

            let first = pass(&fixture);
            assert_eq!((first.baseline, first.retagged, first.new_versions.len()), (1, 0, 0));
            let stored = version(&fixture);
            assert_eq!((stored.revision, stored.revised_at), (1, None));
            assert!(stored.fingerprint.is_some() && stored.signature.is_some());

            assert_eq!(pass(&fixture), RevisionReport::default());
        }

        #[test]
        fn a_retag_refreshes_the_row_in_place_without_a_new_revision() {
            let fixture = fixture();
            write(&fixture, "Rough Mix", "Rough Cuts", 4000, 7);
            index(&fixture);
            let id = track(&fixture).id;

            write(&fixture, "Rough Mix (Final)", "Rough Cuts", 4000, 7);
            let report = pass(&fixture);

            assert_eq!((report.baseline, report.retagged, report.new_versions.len()), (0, 1, 0));
            let row = track(&fixture);
            assert_eq!((row.id, row.title.as_str(), row.revision), (id, "Rough Mix (Final)", 1));
            assert_eq!(row.revised_at, None);
        }

        #[test]
        fn a_re_export_keeps_the_row_and_the_playlist_and_raises_the_revision() {
            let fixture = fixture();
            write(&fixture, "Rough Mix", "Rough Cuts", 4000, 7);
            index(&fixture);
            let id = track(&fixture).id;
            let playlist = fixture.db.create_playlist("Mixes").unwrap();
            fixture.db.add_track_to_playlist(playlist, REL).unwrap();
            let before = fixture.db.playlist_tracks(playlist);
            let fingerprint_before = version(&fixture).fingerprint;

            write(&fixture, "Rough Mix", "Rough Cuts", 5000, 11);
            let report = pass(&fixture);

            assert_eq!(report.new_versions, vec![REL.to_string()]);
            let row = track(&fixture);
            assert_eq!((row.id, row.revision, row.duration > 0.6), (id, 2, true));
            assert!(row.revised_at.is_some());
            let stored = version(&fixture);
            assert_ne!(stored.fingerprint, fingerprint_before);
            let after = fixture.db.playlist_tracks(playlist);
            assert_eq!(
                after.iter().map(|r| (r.row_id, r.rel_path.clone())).collect::<Vec<_>>(),
                before.iter().map(|r| (r.row_id, r.rel_path.clone())).collect::<Vec<_>>()
            );
            assert_eq!(pass(&fixture), RevisionReport::default());
        }

        #[test]
        fn a_file_that_cannot_be_read_as_audio_yet_is_tried_again_next_scan() {
            let fixture = fixture();
            write(&fixture, "Rough Mix", "Rough Cuts", 4000, 7);
            index(&fixture);
            let before = version(&fixture);

            std::fs::write(fixture.root.join(REL), b"RIFF not a wave yet").unwrap();
            let report = pass(&fixture);

            assert_eq!(report.new_versions.len() + report.retagged, 0);
            assert_eq!(version(&fixture), before);
        }
    }
}
