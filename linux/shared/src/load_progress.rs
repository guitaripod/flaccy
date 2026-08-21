/// Mirrors `FlaccyCore.LibraryLoadProgress` on the Apple clients: the same
/// phases, the same weights, and the same wording, so a scan reads identically
/// on GNOME and on iPhone.
///
/// Every phase here is bounded disk work, which is why `fraction_completed`
/// reaching 1.0 is a fact rather than a promise. Network enrichment is a
/// durable job with its own countdown surface — see `enrichment_job`.

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub enum LoadPhase {
    #[default]
    Idle,
    OpeningLibrary,
    FindingFiles,
    ReadingTags,
    BuildingAlbums,
}

impl LoadPhase {
    pub const ALL: [LoadPhase; 5] = [
        LoadPhase::Idle,
        LoadPhase::OpeningLibrary,
        LoadPhase::FindingFiles,
        LoadPhase::ReadingTags,
        LoadPhase::BuildingAlbums,
    ];

    /// Cumulative weight of every earlier phase, read from a table instead of
    /// re-summing `ALL` on every publish; `starts_table_matches_accumulated_weights`
    /// is what keeps the table and the weights from drifting apart.
    const CUMULATIVE_STARTS: [f64; 5] = [0.0, 0.0, 0.05, 0.18, 0.85];

    fn order(self) -> usize {
        Self::ALL.iter().position(|phase| *phase == self).unwrap_or(0)
    }

    pub fn weight(self) -> f64 {
        match self {
            LoadPhase::Idle => 0.0,
            LoadPhase::OpeningLibrary => 0.05,
            LoadPhase::FindingFiles => 0.13,
            LoadPhase::ReadingTags => 0.67,
            LoadPhase::BuildingAlbums => 0.15,
        }
    }

    pub fn start(self) -> f64 {
        Self::CUMULATIVE_STARTS[self.order()]
    }

    pub fn headline(self) -> &'static str {
        match self {
            LoadPhase::Idle => "Ready",
            LoadPhase::OpeningLibrary => "Opening your library",
            LoadPhase::FindingFiles => "Looking for music",
            LoadPhase::ReadingTags => "Reading every file",
            LoadPhase::BuildingAlbums => "Building your shelves",
        }
    }

    pub fn explanation(self) -> &'static str {
        match self {
            LoadPhase::Idle => "",
            LoadPhase::OpeningLibrary => "Reading what you already have.",
            LoadPhase::FindingFiles => {
                "Nothing is copied or moved — Flaccy reads your files where they are."
            }
            LoadPhase::ReadingTags => {
                "Titles, artists, and the exact bit depth and sample rate of every track."
            }
            LoadPhase::BuildingAlbums => "Grouping tracks into albums and artists.",
        }
    }

    /// Every phase that is not `Idle` is work the user is waiting on before any
    /// library can appear; nothing unbounded lives in this enum any more.
    pub fn blocks_library(self) -> bool {
        self != LoadPhase::Idle
    }
}

#[derive(Clone, Copy, PartialEq, Debug, Default)]
pub struct LoadProgress {
    pub phase: LoadPhase,
    pub completed: usize,
    pub total: usize,
    pub files_found: usize,
    pub tracks_indexed: usize,
    pub albums_built: usize,
}

impl LoadProgress {
    pub fn new(phase: LoadPhase) -> Self {
        Self {
            phase,
            ..Self::default()
        }
    }

    pub fn is_active(&self) -> bool {
        self.phase != LoadPhase::Idle
    }

    pub fn is_determinate(&self) -> bool {
        self.total > 0
    }

    pub fn phase_fraction(&self) -> f64 {
        if self.total == 0 {
            return 0.0;
        }
        (self.completed as f64 / self.total as f64).clamp(0.0, 1.0)
    }

    pub fn fraction_completed(&self) -> f64 {
        if self.phase == LoadPhase::Idle {
            return 0.0;
        }
        let within = if self.is_determinate() {
            self.phase_fraction()
        } else {
            0.5
        };
        (self.phase.start() + self.phase.weight() * within).min(1.0)
    }

    /// The counter under the headline, matching `LibraryLoadPhaseCopy.detail`.
    pub fn detail(&self) -> String {
        match self.phase {
            LoadPhase::Idle => String::new(),
            LoadPhase::OpeningLibrary => count_line(self.tracks_indexed, "track", "tracks"),
            LoadPhase::FindingFiles => {
                if self.files_found > 0 {
                    format!("{} found", count_line(self.files_found, "file", "files"))
                } else {
                    "Searching…".to_string()
                }
            }
            LoadPhase::ReadingTags => {
                if self.total > 0 {
                    of_line(self.completed, self.total, "files")
                } else {
                    count_line(self.tracks_indexed, "track", "tracks")
                }
            }
            LoadPhase::BuildingAlbums => count_line(self.tracks_indexed, "track", "tracks"),
        }
    }
}

fn count_line(count: usize, singular: &str, plural: &str) -> String {
    if count == 0 {
        return String::new();
    }
    if count == 1 {
        format!("1 {singular}")
    } else {
        format!("{} {plural}", group_digits(count))
    }
}

pub fn of_line(completed: usize, total: usize, unit: &str) -> String {
    if total == 0 {
        return String::new();
    }
    format!(
        "{} of {} {unit}",
        group_digits(completed.min(total)),
        group_digits(total)
    )
}

/// Thin-space grouped digits; large counts are the whole point of the line, so
/// they should be readable at a glance. The Apple clients use a locale-aware
/// `NumberFormatter` instead — the one deliberate copy divergence, recorded in
/// the spec's copy deck, and identical output below 1000.
pub fn group_digits(value: usize) -> String {
    let digits = value.to_string();
    let mut grouped = String::with_capacity(digits.len() + digits.len() / 3);
    for (index, ch) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            grouped.push('\u{202f}');
        }
        grouped.push(ch);
    }
    grouped
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weights_cover_the_whole_load() {
        let total: f64 = LoadPhase::ALL.iter().map(|phase| phase.weight()).sum();
        assert!((total - 1.0).abs() < 0.0001);
    }

    #[test]
    fn starts_match_the_apple_clients() {
        assert!((LoadPhase::Idle.start() - 0.0).abs() < 0.0001);
        assert!((LoadPhase::OpeningLibrary.start() - 0.0).abs() < 0.0001);
        assert!((LoadPhase::FindingFiles.start() - 0.05).abs() < 0.0001);
        assert!((LoadPhase::ReadingTags.start() - 0.18).abs() < 0.0001);
        assert!((LoadPhase::BuildingAlbums.start() - 0.85).abs() < 0.0001);
    }

    #[test]
    fn starts_table_matches_accumulated_weights() {
        let mut accumulated = 0.0;
        for phase in LoadPhase::ALL {
            assert!(
                (phase.start() - accumulated).abs() < 0.0001,
                "{phase:?} start {} accumulated {accumulated}",
                phase.start()
            );
            accumulated += phase.weight();
        }
        assert!((accumulated - 1.0).abs() < 0.0001);
    }

    #[test]
    fn fraction_combines_phase_start_and_phase_progress() {
        let progress = LoadProgress {
            phase: LoadPhase::ReadingTags,
            completed: 50,
            total: 100,
            ..LoadProgress::default()
        };
        assert!((progress.fraction_completed() - (0.18 + 0.67 * 0.5)).abs() < 0.0001);
    }

    #[test]
    fn indeterminate_phase_counts_as_half_done() {
        let progress = LoadProgress::new(LoadPhase::FindingFiles);
        assert!(!progress.is_determinate());
        assert!((progress.fraction_completed() - (0.05 + 0.13 * 0.5)).abs() < 0.0001);
    }

    #[test]
    fn fraction_never_exceeds_one() {
        let progress = LoadProgress {
            phase: LoadPhase::BuildingAlbums,
            completed: 999,
            total: 10,
            ..LoadProgress::default()
        };
        assert!((progress.fraction_completed() - 1.0).abs() < 0.0001);
    }

    #[test]
    fn fraction_is_monotonic_across_phases() {
        let mut last = 0.0;
        for phase in LoadPhase::ALL.iter().skip(1) {
            for completed in 0..=10 {
                let progress = LoadProgress {
                    phase: *phase,
                    completed,
                    total: 10,
                    ..LoadProgress::default()
                };
                let fraction = progress.fraction_completed();
                assert!(fraction >= last - 0.0001, "{phase:?} {completed}");
                last = fraction;
            }
        }
        assert!((last - 1.0).abs() < 0.0001);
    }

    #[test]
    fn every_active_phase_blocks_the_library() {
        assert!(!LoadPhase::Idle.blocks_library());
        for phase in LoadPhase::ALL.iter().skip(1) {
            assert!(phase.blocks_library(), "{phase:?}");
        }
    }

    #[test]
    fn detail_counts_the_unit_of_the_phase() {
        let reading = LoadProgress {
            phase: LoadPhase::ReadingTags,
            completed: 312,
            total: 1204,
            ..LoadProgress::default()
        };
        assert_eq!(reading.detail(), "312 of 1\u{202f}204 files");

        let finding = LoadProgress {
            phase: LoadPhase::FindingFiles,
            files_found: 1,
            ..LoadProgress::default()
        };
        assert_eq!(finding.detail(), "1 file found");
    }

    #[test]
    fn digits_group_in_thousands() {
        assert_eq!(group_digits(1), "1");
        assert_eq!(group_digits(999), "999");
        assert_eq!(group_digits(1234), "1\u{202f}234");
        assert_eq!(group_digits(1234567), "1\u{202f}234\u{202f}567");
    }
}
