//! Which dated backups to keep: the last of each of the 14 newest days and of each of the 8 newest weeks.
//!
//! Only files named exactly `state-YYYYMMDD-HHMMSS.sqlite` or
//! `security-YYYYMMDD-HHMMSS.sqlite` are ever considered; anything else in the
//! folder, including copies a person put there, is left alone. The newest
//! backup of each kind is always kept.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use chrono::{Datelike, NaiveDateTime};

const STAMP_FORMAT: &str = "%Y%m%d-%H%M%S";
const KINDS: [&str; 2] = ["state", "security"];

/// How many days keep their last backup.
pub const KEEP_DAYS: usize = 14;
/// How many weeks keep their last backup.
pub const KEEP_WEEKS: usize = 8;

/// The kind and moment a backup file name carries, or `None` for any other name.
pub fn parse_name(name: &str) -> Option<(&'static str, NaiveDateTime)> {
    let body = name.strip_suffix(".sqlite")?;
    KINDS.iter().find_map(|kind| {
        let stamp = body.strip_prefix(kind)?.strip_prefix('-')?;
        NaiveDateTime::parse_from_str(stamp, STAMP_FORMAT).ok().map(|moment| (*kind, moment))
    })
}

/// The stamps to delete from `stamps`, oldest first; everything not returned stays.
pub fn expired(stamps: &[NaiveDateTime]) -> Vec<NaiveDateTime> {
    let mut newest_first = stamps.to_vec();
    newest_first.sort_unstable_by(|a, b| b.cmp(a));
    newest_first.dedup();
    let mut keep: BTreeSet<NaiveDateTime> = newest_first.first().copied().into_iter().collect();
    keep.extend(last_of_each(&newest_first, KEEP_DAYS, |moment| (moment.year(), moment.ordinal())));
    keep.extend(last_of_each(&newest_first, KEEP_WEEKS, |moment| {
        let week = moment.iso_week();
        (week.year(), week.week())
    }));
    let mut gone: Vec<NaiveDateTime> = newest_first.into_iter().filter(|moment| !keep.contains(moment)).collect();
    gone.reverse();
    gone
}

fn last_of_each<K: PartialEq>(newest_first: &[NaiveDateTime], groups: usize, key: impl Fn(&NaiveDateTime) -> K) -> Vec<NaiveDateTime> {
    let mut seen: Vec<K> = Vec::new();
    let mut kept = Vec::new();
    for moment in newest_first {
        let group = key(moment);
        if seen.contains(&group) {
            continue;
        }
        if seen.len() == groups {
            break;
        }
        seen.push(group);
        kept.push(*moment);
    }
    kept
}

fn stamps_of(files: &[(&'static str, NaiveDateTime, PathBuf)], kind: &str) -> Vec<NaiveDateTime> {
    files.iter().filter(|(found, _, _)| *found == kind).map(|(_, moment, _)| *moment).collect()
}

/// Deletes the expired backups in `dir` and returns how many files went. Call it only after a verified new backup.
pub fn prune(dir: &Path) -> Result<usize, String> {
    let entries = std::fs::read_dir(dir).map_err(|error| format!("Could not list the backup folder {}: {error}.", dir.display()))?;
    let files: Vec<(&'static str, NaiveDateTime, PathBuf)> = entries
        .flatten()
        .filter_map(|entry| {
            let (kind, moment) = parse_name(&entry.file_name().to_string_lossy())?;
            Some((kind, moment, entry.path()))
        })
        .collect();
    let mut removed = 0;
    for kind in KINDS {
        let gone = expired(&stamps_of(&files, kind));
        for (_, _, path) in files.iter().filter(|(found, moment, _)| *found == kind && gone.contains(moment)) {
            std::fs::remove_file(path).map_err(|error| format!("Could not delete the old backup {}: {error}.", path.display()))?;
            removed += 1;
        }
    }
    Ok(removed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, NaiveDate};

    fn at(year: i32, month: u32, day: u32, hour: u32) -> NaiveDateTime {
        NaiveDate::from_ymd_opt(year, month, day).unwrap().and_hms_opt(hour, 30, 0).unwrap()
    }

    fn nightly(days: i64) -> Vec<NaiveDateTime> {
        let first = at(2026, 1, 1, 3);
        (0..days).map(|offset| first + Duration::days(offset)).collect()
    }

    #[test]
    fn only_exact_backup_names_parse() {
        assert!(parse_name("state-20261026-033007.sqlite").is_some());
        assert!(parse_name("security-20261026-033007.sqlite").is_some());
        for other in ["state-20261026-033007.sqlite.partial", "state.before-restore-20261026-033007.sqlite", "state-2026.sqlite", "notes.txt", "state-20261026-253007.sqlite"] {
            assert!(parse_name(other).is_none(), "{other}");
        }
    }

    #[test]
    fn fewer_backups_than_the_limits_all_stay() {
        assert!(expired(&nightly(14)).is_empty());
        assert!(expired(&[]).is_empty());
    }

    #[test]
    fn a_year_of_nightly_backups_keeps_fourteen_days_and_the_weekly_tail() {
        let all = nightly(365);
        let gone = expired(&all);
        let kept: Vec<NaiveDateTime> = all.iter().copied().filter(|moment| !gone.contains(moment)).collect();
        let last_fourteen = &all[365 - KEEP_DAYS..];
        assert!(last_fourteen.iter().all(|moment| kept.contains(moment)));
        assert!(kept.len() >= KEEP_DAYS && kept.len() <= KEEP_DAYS + KEEP_WEEKS, "{}", kept.len());
        assert!(kept.contains(all.last().unwrap()));
    }

    #[test]
    fn the_last_backup_of_a_day_is_the_one_kept() {
        let mut stamps = nightly(30);
        let early = at(2026, 1, 30, 1);
        let late = at(2026, 1, 30, 23);
        stamps.extend([early, late]);
        let gone = expired(&stamps);
        assert!(gone.contains(&early) && gone.contains(&at(2026, 1, 30, 3)));
        assert!(!gone.contains(&late));
    }

    #[test]
    fn the_newest_backup_always_survives() {
        let lone = vec![at(2020, 5, 5, 3)];
        assert!(expired(&lone).is_empty());
        let mut stamps = nightly(400);
        stamps.reverse();
        let newest = stamps[0];
        assert!(!expired(&stamps).contains(&newest));
    }

    #[test]
    fn pruning_touches_only_dated_backups_of_both_kinds() {
        let dir = std::env::temp_dir().join(format!("flaccy-retention-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        for stamp in nightly(60) {
            for kind in KINDS {
                std::fs::write(dir.join(format!("{kind}-{}.sqlite", stamp.format(STAMP_FORMAT))), b"x").unwrap();
            }
        }
        std::fs::write(dir.join("keep-me.txt"), b"x").unwrap();
        std::fs::write(dir.join("state.before-restore-20260101-000000.sqlite"), b"x").unwrap();
        let removed = prune(&dir).unwrap();
        assert!(removed > 0 && removed % 2 == 0, "{removed}");
        assert!(dir.join("keep-me.txt").exists() && dir.join("state.before-restore-20260101-000000.sqlite").exists());
        assert!(dir.join("state-20260301-033000.sqlite").exists(), "the newest day stays");
        assert_eq!(prune(&dir).unwrap(), 0, "a second pass has nothing left to do");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
