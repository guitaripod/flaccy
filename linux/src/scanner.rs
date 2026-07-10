use crate::db::{Db, NewTrack};
use lofty::file::{AudioFile, FileType, TaggedFile, TaggedFileExt};
use lofty::prelude::*;
use std::collections::HashSet;
use std::path::{Path, PathBuf};

const SUPPORTED_EXTENSIONS: [&str; 8] = ["flac", "mp3", "m4a", "ogg", "opus", "wav", "aiff", "aif"];

pub enum ScanEvent {
    Progress(usize, usize),
    Done { added: usize, removed: usize },
    Failed(String),
}

pub fn spawn_scan(root: PathBuf, db_path: PathBuf, tx: async_channel::Sender<ScanEvent>) {
    std::thread::Builder::new()
        .name("flaccy-scan".into())
        .spawn(move || {
            let result = run_scan(&root, &db_path, &tx);
            let event = match result {
                Ok((added, removed)) => ScanEvent::Done { added, removed },
                Err(message) => ScanEvent::Failed(message),
            };
            let _ = tx.send_blocking(event);
        })
        .ok();
}

fn run_scan(
    root: &Path,
    db_path: &Path,
    tx: &async_channel::Sender<ScanEvent>,
) -> Result<(usize, usize), String> {
    let db = Db::open(db_path).map_err(|e| format!("db open failed: {e}"))?;
    let files = collect_audio_files(root);
    let disk_paths: HashSet<String> = files
        .iter()
        .map(|path| relative_path(root, path))
        .collect();
    let existing = db.fetch_relative_paths();

    if disk_paths.is_empty() && !existing.is_empty() {
        crate::logger::warn(
            "library",
            "scan found zero files but database is non-empty; keeping database (transient-empty root guard)",
        );
        return Ok((0, 0));
    }

    let to_add: Vec<&PathBuf> = files
        .iter()
        .filter(|path| !existing.contains(&relative_path(root, path)))
        .collect();
    let total = to_add.len();
    let mut added = 0;

    for (index, path) in to_add.iter().enumerate() {
        let _ = tx.send_blocking(ScanEvent::Progress(index + 1, total));
        let rel = relative_path(root, path);
        match read_track(path, &rel) {
            Some(track) => {
                if let Err(err) = db.insert_track(&track) {
                    crate::logger::error("library", &format!("insert failed for {rel}: {err}"));
                } else {
                    added += 1;
                }
            }
            None => {
                crate::logger::warn("library", &format!("skipped unreadable audio: {rel}"));
            }
        }
    }

    let removed = db
        .delete_tracks_not_in(&disk_paths)
        .map_err(|e| format!("prune failed: {e}"))?;
    crate::logger::info(
        "library",
        &format!("scan complete: {added} added, {removed} removed, {} on disk", disk_paths.len()),
    );
    Ok((added, removed))
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
fn relative_path(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.file_name().unwrap_or_default().to_string_lossy().to_string())
}

fn read_track(path: &Path, rel_path: &str) -> Option<NewTrack> {
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
    let tag_track = tag.and_then(|t| t.track()).unwrap_or(0) as i32;
    let track_number = if tag_track > 0 { tag_track } else { parsed.track_number };

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
        track_number,
        duration,
        codec: detect_codec(&tagged, path),
        bit_depth: properties.bit_depth().map(|b| b as i32),
        sample_rate: properties.sample_rate().map(|r| r as i32),
        channels: properties.channels().map(|c| c as i32),
        artwork,
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

    let digits: String = filename.chars().take_while(|c| c.is_ascii_digit()).collect();
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
}
