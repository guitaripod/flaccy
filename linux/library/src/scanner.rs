use crate::db::{now_ms, Db, NewTrack};
use crate::fingerprint;
use crate::load_progress::{LoadPhase, LoadProgress};
use lofty::file::{AudioFile, FileType, TaggedFile, TaggedFileExt};
use lofty::prelude::*;
use lofty::tag::ItemKey;
use flaccy_shared::track_revision::{self, Outcome};
use std::collections::{BTreeMap, HashSet};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

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
    /// Files that still have to be fingerprinted because the time budget ran out.
    pub backlog: usize,
    pub retagged: usize,
    pub new_versions: Vec<String>,
}

/// How a scan differs from the default of the desktop client.
#[derive(Clone, Default)]
pub struct ScanOptions {
    /// How long the revision pass behind the scan may spend fingerprinting files whose audio has to be read to
    /// the end; what it leaves undone is counted in `backlog` and taken up by the next scan. `None` finishes it.
    pub revision_budget: Option<Duration>,
    /// Receives how many files the budget left unfingerprinted.
    pub backlog: Option<Arc<AtomicUsize>>,
}

pub fn spawn_scan(root: PathBuf, db_path: PathBuf, tx: async_channel::Sender<ScanEvent>) {
    spawn_scan_with(root, db_path, tx, ScanOptions::default());
}

pub fn spawn_scan_with(root: PathBuf, db_path: PathBuf, tx: async_channel::Sender<ScanEvent>, options: ScanOptions) {
    std::thread::Builder::new()
        .name("flaccy-scan".into())
        .spawn(move || {
            match run_scan(&root, &db_path, &tx) {
                Ok(outcome) => {
                    let _ = tx.send_blocking(ScanEvent::Done {
                        added: outcome.added,
                        removed: outcome.removed,
                    });
                    announce_revisions(&root, &db_path, &outcome.files, &tx, &options);
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
    options: &ScanOptions,
) {
    let Ok(db) = Db::open(db_path) else { return };
    let deadline = options.revision_budget.map(|budget| Instant::now() + budget);
    let report = run_revision_pass_until(root, &db, files, deadline);
    if let Some(backlog) = &options.backlog {
        backlog.store(report.backlog, Ordering::SeqCst);
    }
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

/// [`run_revision_pass_until`] with no time limit.
#[cfg(test)]
pub(crate) fn run_revision_pass(root: &Path, db: &Db, files: &[PathBuf]) -> RevisionReport {
    run_revision_pass_until(root, db, files, None)
}

/// Looks at every file that is both on disk and already indexed. A file whose
/// size and modification time match what is stored is not read; one that moved
/// is fingerprinted, and `track_revision` decides whether only its tags
/// changed (the row is refreshed in place and keeps its revision) or its audio
/// did (the row is refreshed and its revision goes up). A file that changed
/// again while it was being read, or cannot be read as audio yet, is left for
/// the next scan.
///
/// With a `deadline`, files whose audio has still to be read are left once it has passed and counted in
/// `backlog`, for the next scan to take up.
pub(crate) fn run_revision_pass_until(root: &Path, db: &Db, files: &[PathBuf], deadline: Option<Instant>) -> RevisionReport {
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
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            report.backlog += 1;
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

    let mut batch = InsertBatch::new(&db);

    read_in_order(root, &to_add, |index, rel, track| {
        if index % 25 == 0 || index + 1 == total {
            progress.completed = index + 1;
            progress.tracks_indexed = already_indexed + added;
            let _ = tx.send_blocking(ScanEvent::Progress(progress));
            if !hoisted.is_empty() {
                batch.commit();
                let _ = tx.send_blocking(ScanEvent::CoversHoisted(std::mem::take(&mut hoisted)));
            }
        }
        match track {
            Some(track) => {
                let cover = track.artwork.is_some() && !track.album.is_empty();
                if let Err(err) = batch.insert(&track) {
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
    });
    batch.commit();
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

/// How many files are read at once. A cold file on an SD card, a NAS or a
/// network share costs a round trip of its own, so reading them one by one
/// leaves the volume idle; eight in flight read a slow volume many times
/// faster and still leave a fast one to the processor.
const TAG_READERS: usize = 8;

/// How far the readers may run ahead of the file the scan is waiting for, so
/// the tracks held in memory (each may carry a cover) stay few.
const READ_AHEAD: usize = 32;

/// Lets the readers go when the scan stops waiting for them, even by panicking.
struct ReleaseReaders<'a>(&'a AtomicUsize);

impl Drop for ReleaseReaders<'_> {
    fn drop(&mut self) {
        self.0.store(usize::MAX / 2, Ordering::SeqCst);
    }
}

/// Reads `paths` on [`TAG_READERS`] threads and hands each result to `consume`
/// in the order of `paths`, with its relative path, so rows are inserted exactly
/// as a one-by-one scan would insert them. A file that panics the reader counts
/// as unreadable.
fn read_in_order<F>(root: &Path, paths: &[&PathBuf], mut consume: F)
where
    F: FnMut(usize, &str, Option<NewTrack>),
{
    if paths.is_empty() {
        return;
    }
    let claimed = AtomicUsize::new(0);
    let consumed = AtomicUsize::new(0);
    let (sender, receiver) = mpsc::channel::<(usize, Option<NewTrack>)>();
    std::thread::scope(|scope| {
        for _ in 0..TAG_READERS.min(paths.len()) {
            let sender = sender.clone();
            let (claimed, consumed) = (&claimed, &consumed);
            scope.spawn(move || loop {
                let index = claimed.fetch_add(1, Ordering::SeqCst);
                if index >= paths.len() {
                    break;
                }
                while index >= consumed.load(Ordering::SeqCst).saturating_add(READ_AHEAD) {
                    std::thread::sleep(Duration::from_millis(2));
                }
                let rel = relative_path(root, paths[index]);
                let track = catch_unwind(AssertUnwindSafe(|| read_track_deferring_audio_hash(paths[index], &rel))).unwrap_or(None);
                if sender.send((index, track)).is_err() {
                    break;
                }
            });
        }
        drop(sender);
        let _release = ReleaseReaders(&consumed);
        let mut waiting: BTreeMap<usize, Option<NewTrack>> = BTreeMap::new();
        let mut next = 0;
        for (index, track) in receiver {
            waiting.insert(index, track);
            while let Some(track) = waiting.remove(&next) {
                consume(next, &relative_path(root, paths[next]), track);
                next += 1;
                consumed.store(next, Ordering::SeqCst);
            }
        }
    });
}

const INSERT_BATCH_SIZE: usize = 200;

/// Groups a scan's inserts into transactions of `INSERT_BATCH_SIZE` rows, so a
/// first import of thousands of files commits dozens of times instead of once
/// per statement. A reader told about hoisted covers must find them, so the
/// scan commits before announcing a chunk.
struct InsertBatch<'a> {
    db: &'a Db,
    open_rows: Option<usize>,
}

impl<'a> InsertBatch<'a> {
    fn new(db: &'a Db) -> Self {
        Self { db, open_rows: None }
    }

    fn insert(&mut self, track: &NewTrack) -> Result<(), rusqlite::Error> {
        if self.open_rows.is_none() && self.db.begin_inserts().is_ok() {
            self.open_rows = Some(0);
        }
        let result = self.db.insert_track(track);
        if let Some(rows) = self.open_rows.as_mut() {
            *rows += 1;
            if *rows >= INSERT_BATCH_SIZE {
                self.commit();
            }
        }
        result
    }

    fn commit(&mut self) {
        if self.open_rows.take().is_some() {
            if let Err(err) = self.db.commit_inserts() {
                crate::logger::error("library", &format!("batch commit failed: {err}"));
            }
        }
    }
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
#[cfg(test)]
fn read_track(path: &Path, rel_path: &str) -> Option<NewTrack> {
    let mut track = read_metadata(path, rel_path)?;
    track.signature = fingerprint::signature(path);
    track.fingerprint = fingerprint::fingerprint(path);
    Some(track)
}

/// [`read_track`] for a scan: a file whose audio would have to be read to the end to fingerprint it is stored
/// without signature or fingerprint, which the revision pass behind the scan takes for a file never baselined and
/// fingerprints in the background, so the library lists the music after the tags alone.
fn read_track_deferring_audio_hash(path: &Path, rel_path: &str) -> Option<NewTrack> {
    let mut track = read_metadata(path, rel_path)?;
    if let Some(fingerprint) = fingerprint::quick_fingerprint(path) {
        track.signature = fingerprint::signature(path);
        track.fingerprint = Some(fingerprint);
    }
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

    fn sample_track(index: usize) -> NewTrack {
        NewTrack {
            rel_path: format!("Album/{index:04}.flac"),
            title: format!("Song {index}"),
            artist: "Artist".to_string(),
            album: "Album".to_string(),
            album_artist: None,
            track_number: index as i32,
            duration: 60.0,
            codec: None,
            bit_depth: None,
            sample_rate: None,
            channels: None,
            artwork: (index == 0).then(|| vec![1, 2, 3]),
            signature: None,
            fingerprint: None,
        }
    }

    #[test]
    fn a_batched_scan_stores_every_row_and_publishes_them_on_commit() {
        let dir = std::env::temp_dir().join(format!("flaccy-batch-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("library.sqlite");
        let db = Db::open(&path).expect("db opens");
        let reader = Db::open(&path).expect("reader opens");
        let mut batch = InsertBatch::new(&db);

        for index in 0..(INSERT_BATCH_SIZE * 2 + 50) {
            batch.insert(&sample_track(index)).expect("insert");
        }
        assert_eq!(reader.fetch_relative_paths().len(), INSERT_BATCH_SIZE * 2);
        assert!(reader.fetch_album_artwork("Album", "Artist").is_some());

        batch.commit();
        assert_eq!(reader.fetch_relative_paths().len(), INSERT_BATCH_SIZE * 2 + 50);
        batch.insert(&sample_track(9999)).expect("insert after commit");
        batch.commit();
        assert_eq!(reader.fetch_relative_paths().len(), INSERT_BATCH_SIZE * 2 + 51);
        drop(batch);
        drop(db);
        drop(reader);
        let _ = std::fs::remove_dir_all(&dir);
    }
    mod parallel_reading {
        use super::super::*;
        use crate::fingerprint::fixtures::{info_tags, tone, wav_bytes, TempDir};

        fn library_of(count: usize) -> (TempDir, PathBuf) {
            let dir = TempDir::new("parallel-scan");
            let root = dir.path().join("music");
            for number in 0..count {
                let folder = root.join(format!("Artist {:02}", number % 7)).join(format!("Album {:02}", number % 3));
                std::fs::create_dir_all(&folder).unwrap();
                let tags = info_tags(&format!("Song {number:03}"), &format!("Artist {:02}", number % 7), &format!("Album {:02}", number % 3));
                std::fs::write(folder.join(format!("{number:03}.wav")), wav_bytes(&tone(2000 + number, 5), Some(&tags))).unwrap();
            }
            (dir, root)
        }

        fn paths_in_insertion_order(db_path: &Path) -> Vec<String> {
            let mut rows = Db::open(db_path).unwrap().fetch_all_tracks();
            rows.sort_by_key(|row| row.id);
            rows.into_iter().map(|row| row.rel_path).collect()
        }

        fn scan(root: &Path, db_path: &Path) -> (usize, Vec<usize>) {
            let (sender, receiver) = async_channel::unbounded();
            let outcome = run_scan(root, db_path, &sender).expect("scan");
            drop(sender);
            let mut completed = Vec::new();
            while let Ok(event) = receiver.try_recv() {
                if let ScanEvent::Progress(progress) = event {
                    completed.push(progress.completed);
                }
            }
            (outcome.added, completed)
        }

        #[test]
        fn rows_are_inserted_in_listing_order_however_the_readers_interleave() {
            let (dir, root) = library_of(90);
            let db_path = dir.path().join("data/library.sqlite");
            let (added, completed) = scan(&root, &db_path);
            assert_eq!(added, 90);
            let listed: Vec<String> = collect_audio_files(&root).iter().map(|path| relative_path(&root, path)).collect();
            assert_eq!(paths_in_insertion_order(&db_path), listed);
            assert!(completed.windows(2).all(|pair| pair[0] <= pair[1]), "{completed:?}");
            assert_eq!(completed.last(), Some(&90));
        }

        #[test]
        fn an_unreadable_file_is_skipped_and_its_neighbours_still_land_in_order() {
            let (dir, root) = library_of(40);
            std::fs::write(root.join("Artist 00").join("Album 00").join("000.wav"), b"RIFF not a wave").unwrap();
            let db_path = dir.path().join("data/library.sqlite");
            let (added, _) = scan(&root, &db_path);
            assert_eq!(added, 39);
            let paths = paths_in_insertion_order(&db_path);
            let listed: Vec<String> = collect_audio_files(&root)
                .iter()
                .map(|path| relative_path(&root, path))
                .filter(|path| path != "Artist 00/Album 00/000.wav")
                .collect();
            assert_eq!(paths, listed);
        }

        #[test]
        fn nothing_to_read_returns_without_starting_readers() {
            let mut calls = 0;
            read_in_order(Path::new("/nonexistent"), &[], |_, _, _| calls += 1);
            assert_eq!(calls, 0);
        }
    }
    mod deferred_hashing {
        use super::super::*;
        use crate::fingerprint::fixtures::{info_tags, tone, wav_bytes, TempDir};

        fn flac_header(md5: [u8; 16]) -> Vec<u8> {
            let mut bytes = b"fLaC".to_vec();
            bytes.extend_from_slice(&[0x80, 0, 0, 34]);
            let mut info = vec![0u8; 34];
            info[18..34].copy_from_slice(&md5);
            bytes.extend_from_slice(&info);
            bytes.extend_from_slice(&[0u8; 64]);
            bytes
        }

        fn scanned_wavs(count: usize) -> (TempDir, PathBuf, PathBuf) {
            let dir = TempDir::new("deferred");
            let root = dir.path().join("music");
            std::fs::create_dir_all(&root).unwrap();
            for number in 0..count {
                let tags = info_tags(&format!("Song {number}"), "Band", "Record");
                std::fs::write(root.join(format!("{number}.wav")), wav_bytes(&tone(3000 + number, 5), Some(&tags))).unwrap();
            }
            let db_path = dir.path().join("data/library.sqlite");
            let (sender, _receiver) = async_channel::unbounded();
            run_scan(&root, &db_path, &sender).expect("scan");
            (dir, root, db_path)
        }

        #[test]
        fn only_a_flac_with_an_md5_is_fingerprinted_without_reading_its_audio() {
            let dir = TempDir::new("quick");
            let with_md5 = dir.path().join("with.flac");
            let without_md5 = dir.path().join("without.flac");
            let wave = dir.path().join("song.wav");
            std::fs::write(&with_md5, flac_header([7u8; 16])).unwrap();
            std::fs::write(&without_md5, flac_header([0u8; 16])).unwrap();
            std::fs::write(&wave, wav_bytes(&tone(2000, 3), None)).unwrap();
            assert_eq!(fingerprint::quick_fingerprint(&with_md5).as_deref(), Some("flac:07070707070707070707070707070707"));
            assert_eq!(fingerprint::quick_fingerprint(&without_md5), None);
            assert_eq!(fingerprint::quick_fingerprint(&wave), None);
        }

        #[test]
        fn a_scan_lists_files_that_need_their_audio_hashed_and_leaves_the_hash_to_the_revision_pass() {
            let (_dir, root, db_path) = scanned_wavs(5);
            let db = Db::open(&db_path).unwrap();
            assert_eq!(db.fetch_all_tracks().len(), 5);
            assert!(db.fetch_stored_versions().values().all(|version| version.signature.is_none() && version.fingerprint.is_none()));

            let files = collect_audio_files(&root);
            let first = run_revision_pass(&root, &db, &files);
            assert_eq!((first.baseline, first.retagged, first.backlog, first.new_versions.len()), (5, 0, 0, 0));
            assert!(db.fetch_stored_versions().values().all(|version| version.signature.is_some() && version.fingerprint.is_some()));
            assert_eq!(run_revision_pass(&root, &db, &files), RevisionReport::default());
        }

        #[test]
        fn a_spent_budget_leaves_the_hashing_counted_for_the_next_scan() {
            let (_dir, root, db_path) = scanned_wavs(4);
            let db = Db::open(&db_path).unwrap();
            let files = collect_audio_files(&root);

            let none_done = run_revision_pass_until(&root, &db, &files, Some(Instant::now()));
            assert_eq!((none_done.baseline, none_done.backlog), (0, 4));
            assert!(db.fetch_stored_versions().values().all(|version| version.fingerprint.is_none()));

            let rest = run_revision_pass_until(&root, &db, &files, Some(Instant::now() + Duration::from_secs(60)));
            assert_eq!((rest.baseline, rest.backlog), (4, 0));
        }

        #[test]
        fn the_backlog_reaches_the_caller_through_the_options() {
            let (dir, root, db_path) = scanned_wavs(3);
            let backlog = Arc::new(AtomicUsize::new(99));
            let (sender, receiver) = async_channel::unbounded();
            let options = ScanOptions { revision_budget: Some(Duration::ZERO), backlog: Some(backlog.clone()) };
            spawn_scan_with(root, db_path, sender, options);
            while receiver.recv_blocking().is_ok() {}
            assert_eq!(backlog.load(Ordering::SeqCst), 3);
            drop(dir);
        }
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
