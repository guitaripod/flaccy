//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Library/TrackRevision.swift`.
//!
//! What a scan decides about a path it already knows. A file whose size and
//! modification time are unchanged is not read again. When it changed, its
//! audio fingerprint decides whether only the tags moved (a retag keeps the
//! revision) or the music itself was replaced (a new version bumps it, and the
//! library shows the new mix for two weeks). Times are milliseconds since the
//! Unix epoch.

use crate::audio_payload::Location;

pub const NEW_MIX_WINDOW_MS: i64 = 14 * 86_400_000;
pub const PREVIOUS_VERSION_RETENTION_MS: i64 = 30 * 86_400_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileSignature {
    pub size: i64,
    pub modified_ms: i64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct StoredVersion {
    pub signature: Option<FileSignature>,
    pub fingerprint: Option<String>,
    pub revision: i64,
    pub revised_at: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Unchanged,
    Baseline,
    Retagged,
    NewVersion,
}

/// A file whose signature differs from the stored one, or that was never
/// signed, has to be read again before the scan can trust it.
pub fn needs_inspection(stored: &StoredVersion, current: &FileSignature) -> bool {
    stored.signature.as_ref() != Some(current)
}

/// The first fingerprint ever seen is a baseline, not a change. After that, a
/// fingerprint that is missing now or still equal means the tags moved, and a
/// different one means the audio did.
pub fn classify(stored: &StoredVersion, current_fingerprint: Option<&str>) -> Outcome {
    match (stored.fingerprint.as_deref(), current_fingerprint) {
        (None, _) => Outcome::Baseline,
        (Some(_), None) => Outcome::Retagged,
        (Some(stored), Some(current)) if stored == current => Outcome::Retagged,
        (Some(_), Some(_)) => Outcome::NewVersion,
    }
}

/// The stored record after a scan. Only a new version moves the revision and
/// stamps `revised_at`; a retag keeps the fingerprint it already had when the
/// new one is missing.
pub fn applying(
    outcome: Outcome,
    stored: &StoredVersion,
    signature: FileSignature,
    fingerprint: Option<&str>,
    now_ms: i64,
) -> StoredVersion {
    match outcome {
        Outcome::Unchanged => stored.clone(),
        Outcome::Baseline => StoredVersion {
            signature: Some(signature),
            fingerprint: fingerprint.map(str::to_string),
            revision: stored.revision,
            revised_at: stored.revised_at,
        },
        Outcome::Retagged => StoredVersion {
            signature: Some(signature),
            fingerprint: fingerprint
                .map(str::to_string)
                .or_else(|| stored.fingerprint.clone()),
            revision: stored.revision,
            revised_at: stored.revised_at,
        },
        Outcome::NewVersion => StoredVersion {
            signature: Some(signature),
            fingerprint: fingerprint.map(str::to_string),
            revision: stored.revision + 1,
            revised_at: Some(now_ms),
        },
    }
}

pub fn shows_new_mix(revised_at: Option<i64>, now_ms: i64) -> bool {
    revised_at.is_some_and(|at| now_ms - at < NEW_MIX_WINDOW_MS)
}

pub fn previous_version_expired(moved_at_ms: i64, now_ms: i64) -> bool {
    now_ms - moved_at_ms >= PREVIOUS_VERSION_RETENTION_MS
}

/// Identifies the audio: a FLAC's own MD5 when it has one, otherwise the
/// SHA-256 of the audio ranges, which the caller computes only then.
pub fn fingerprint(location: &Location, sha256_hex: Option<&str>) -> Option<String> {
    match location {
        Location::FlacMd5(digest) => Some(format!("flac:{digest}")),
        Location::Ranges(_) => sha256_hex.map(|digest| format!("sha256:{digest}")),
    }
}

/// The English words every client shows for track versions, kept as the
/// strings the Apple catalog uses: `%@` stands for text and `%lld` for a count.
pub mod copy {
    pub const NEW_MIX: &str = "New mix";
    pub const NEW_MIX_OF: &str = "New mix of “%@”";
    pub const PLAY_FROM_START: &str = "Play from start";
    pub const EXPORTED_AT: &str = "Exported %@ at %@";
    pub const REPLACE_HEADING_ONE: &str = "Replace “%@” with a newer version?";
    pub const REPLACE_HEADING_MANY: &str = "Replace %lld songs with newer versions?";
    pub const REPLACE_BODY: &str = "The versions you have now stay in Previous Versions for 30 days.";
    pub const KEEP_BOTH: &str = "Keep Both";
    pub const REPLACE: &str = "Replace";
    pub const RESTORE_PREVIOUS: &str = "Restore Previous Mix";
    pub const RESTORED: &str = "Restored the previous mix of “%@”";
    pub const REPLACED_ONE: &str = "1 song replaced with a newer version";
    pub const REPLACED_COUNT: &str = "%lld songs replaced with newer versions";

    /// Puts `values` into the `%@` and `%lld` slots of `template`, in order.
    pub fn fill(template: &str, values: &[&str]) -> String {
        let mut out = String::with_capacity(template.len());
        let mut remaining = values.iter();
        let mut rest = template;
        while let Some(at) = rest.find('%') {
            out.push_str(&rest[..at]);
            let tail = &rest[at..];
            let slot = ["%lld", "%@"].into_iter().find(|slot| tail.starts_with(slot));
            match slot {
                Some(slot) => {
                    out.push_str(remaining.next().copied().unwrap_or_default());
                    rest = &tail[slot.len()..];
                }
                None => {
                    out.push('%');
                    rest = &tail[1..];
                }
            }
        }
        out.push_str(rest);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: i64 = 1_800_000_000_000;
    const DAY: i64 = 86_400_000;

    fn signature(size: i64, modified_ms: i64) -> FileSignature {
        FileSignature { size, modified_ms }
    }

    fn stored(
        signature: Option<FileSignature>,
        fingerprint: Option<&str>,
        revision: i64,
        revised_at: Option<i64>,
    ) -> StoredVersion {
        StoredVersion {
            signature,
            fingerprint: fingerprint.map(str::to_string),
            revision,
            revised_at,
        }
    }

    #[test]
    fn needs_inspection_when_unsigned_or_changed() {
        let old = signature(100, 5);
        assert!(needs_inspection(&stored(None, None, 0, None), &old));
        assert!(!needs_inspection(&stored(Some(old), None, 0, None), &old));
        assert!(needs_inspection(
            &stored(Some(old), None, 0, None),
            &signature(101, 5)
        ));
        assert!(needs_inspection(
            &stored(Some(old), None, 0, None),
            &signature(100, 6)
        ));
    }

    #[test]
    fn classify_separates_baseline_retag_and_new_version() {
        assert_eq!(
            classify(&stored(None, None, 1, None), Some("a")),
            Outcome::Baseline
        );
        assert_eq!(
            classify(&stored(None, Some("a"), 2, None), None),
            Outcome::Retagged
        );
        assert_eq!(
            classify(&stored(None, Some("a"), 2, None), Some("a")),
            Outcome::Retagged
        );
        assert_eq!(
            classify(&stored(None, Some("a"), 2, None), Some("b")),
            Outcome::NewVersion
        );
    }

    #[test]
    fn applying_a_baseline_sets_the_fingerprint_only() {
        let before = stored(None, None, 1, None);
        let after = applying(Outcome::Baseline, &before, signature(1, 2), Some("a"), NOW);
        assert_eq!(after, stored(Some(signature(1, 2)), Some("a"), 1, None));
    }

    #[test]
    fn applying_a_retag_keeps_revision_and_time() {
        let before = stored(Some(signature(1, 2)), Some("a"), 2, Some(NOW - DAY));
        let after = applying(Outcome::Retagged, &before, signature(3, 4), None, NOW);
        assert_eq!(
            after,
            stored(Some(signature(3, 4)), Some("a"), 2, Some(NOW - DAY))
        );
    }

    #[test]
    fn applying_a_new_version_bumps_the_revision_and_stamps_now() {
        let before = stored(Some(signature(1, 2)), Some("a"), 2, Some(NOW - DAY));
        let after = applying(
            Outcome::NewVersion,
            &before,
            signature(3, 4),
            Some("b"),
            NOW,
        );
        assert_eq!(
            after,
            stored(Some(signature(3, 4)), Some("b"), 3, Some(NOW))
        );
    }

    #[test]
    fn applying_unchanged_leaves_the_record_identical() {
        let before = stored(Some(signature(1, 2)), Some("a"), 2, Some(NOW - DAY));
        assert_eq!(
            applying(Outcome::Unchanged, &before, signature(1, 2), Some("z"), NOW),
            before
        );
    }

    #[test]
    fn new_mix_shows_for_fourteen_days() {
        assert!(!shows_new_mix(None, NOW));
        assert!(shows_new_mix(Some(NOW - 13 * DAY), NOW));
        assert!(!shows_new_mix(Some(NOW - 14 * DAY), NOW));
    }

    #[test]
    fn previous_version_is_kept_for_thirty_days() {
        assert!(!previous_version_expired(NOW - 29 * DAY, NOW));
        assert!(previous_version_expired(NOW - 30 * DAY, NOW));
    }

    #[test]
    fn fingerprints_prefer_the_flac_md5() {
        assert_eq!(
            fingerprint(&Location::FlacMd5("ab".into()), Some("cd")),
            Some("flac:ab".into())
        );
        assert_eq!(
            fingerprint(&Location::Ranges(vec![0..1]), Some("cd")),
            Some("sha256:cd".into())
        );
        assert_eq!(fingerprint(&Location::Ranges(vec![0..1]), None), None);
    }

    #[test]
    fn copy_fills_text_and_count_slots_in_order() {
        assert_eq!(
            copy::fill(copy::EXPORTED_AT, &["25 Oct 2026", "14:02"]),
            "Exported 25 Oct 2026 at 14:02"
        );
        assert_eq!(
            copy::fill(copy::REPLACE_HEADING_MANY, &["3"]),
            "Replace 3 songs with newer versions?"
        );
        assert_eq!(
            copy::fill(copy::REPLACE_HEADING_ONE, &["Rough Mix"]),
            "Replace “Rough Mix” with a newer version?"
        );
        assert_eq!(copy::fill("100% sure", &[]), "100% sure");
    }
}
