//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Equalizer/EqualizerPresets.swift`.
//!
//! The sixteen built-in curves, as the ten gains a person would read off the
//! sliders. They are starting points tuned by ear, not taken from any other
//! player's tables. The table is pinned by a test asserting the same numbers as
//! the Swift one.

use super::profile::EqualizerProfile;

/// One built-in curve: its key, its English name and the ten slider targets.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Entry {
    pub key: &'static str,
    pub english_name: &'static str,
    pub targets: &'static [f64],
}

pub struct EqualizerPresets;

impl EqualizerPresets {
    pub const FLAT_KEY: &'static str = "flat";

    pub const ENTRIES: &'static [Entry] = &[
        Entry {
            key: "flat",
            english_name: "Flat",
            targets: &[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        },
        Entry {
            key: "bassBoost",
            english_name: "Bass Boost",
            targets: &[6.0, 5.0, 4.0, 2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        },
        Entry {
            key: "bassReducer",
            english_name: "Bass Reducer",
            targets: &[-6.0, -5.0, -3.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
        },
        Entry {
            key: "trebleBoost",
            english_name: "Treble Boost",
            targets: &[0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 3.0, 5.0, 6.0, 6.0],
        },
        Entry {
            key: "trebleReducer",
            english_name: "Treble Reducer",
            targets: &[0.0, 0.0, 0.0, 0.0, 0.0, 0.0, -1.0, -3.0, -5.0, -6.0],
        },
        Entry {
            key: "vocal",
            english_name: "Vocal",
            targets: &[0.0, 0.0, -2.0, -1.0, 2.0, 4.0, 3.0, 1.0, 0.0, 0.0],
        },
        Entry {
            key: "spokenWord",
            english_name: "Spoken Word",
            targets: &[-4.0, -3.0, -1.0, 0.0, 3.0, 4.0, 4.0, 2.0, 0.0, -2.0],
        },
        Entry {
            key: "soften",
            english_name: "Soften",
            targets: &[0.0, 0.0, 0.0, 0.0, 0.0, -1.0, -3.0, -4.0, -2.0, 0.0],
        },
        Entry {
            key: "loudness",
            english_name: "Loudness",
            targets: &[5.0, 3.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 4.0, 5.0],
        },
        Entry {
            key: "acoustic",
            english_name: "Acoustic",
            targets: &[3.0, 3.0, 2.0, 1.0, 0.0, 1.0, 2.0, 3.0, 3.0, 2.0],
        },
        Entry {
            key: "classical",
            english_name: "Classical",
            targets: &[0.0, 0.0, 0.0, 0.0, -1.0, -1.0, 0.0, 2.0, 3.0, 3.0],
        },
        Entry {
            key: "rock",
            english_name: "Rock",
            targets: &[4.0, 3.0, 1.0, 0.0, -1.0, 0.0, 2.0, 3.0, 4.0, 4.0],
        },
        Entry {
            key: "electronic",
            english_name: "Electronic",
            targets: &[5.0, 4.0, 1.0, 0.0, -2.0, 0.0, 1.0, 3.0, 4.0, 5.0],
        },
        Entry {
            key: "hipHop",
            english_name: "Hip-Hop",
            targets: &[6.0, 5.0, 2.0, 1.0, -1.0, -1.0, 1.0, 0.0, 1.0, 2.0],
        },
        Entry {
            key: "jazz",
            english_name: "Jazz",
            targets: &[3.0, 2.0, 1.0, 2.0, -1.0, -1.0, 0.0, 1.0, 2.0, 3.0],
        },
        Entry {
            key: "pop",
            english_name: "Pop",
            targets: &[-1.0, 1.0, 3.0, 4.0, 3.0, 0.0, -1.0, 0.0, 1.0, 2.0],
        },
    ];

    pub const TUNE_KEYS: &'static [&'static str] = &[
        "bassBoost",
        "bassReducer",
        "trebleBoost",
        "trebleReducer",
        "vocal",
        "spokenWord",
        "soften",
        "loudness",
    ];

    pub const GENRE_KEYS: &'static [&'static str] = &[
        "acoustic",
        "classical",
        "rock",
        "electronic",
        "hipHop",
        "jazz",
        "pop",
    ];

    /// The id a built-in curve carries: `builtin.` followed by its key.
    pub fn id_for_key(key: &str) -> String {
        format!("builtin.{key}")
    }

    /// The key of a built-in id, or `None` for anything else.
    pub fn key_for_id(id: &str) -> Option<&str> {
        id.strip_prefix("builtin.")
    }

    pub fn profile_for_key(key: &str) -> Option<EqualizerProfile> {
        Self::ENTRIES
            .iter()
            .find(|entry| entry.key == key)
            .map(|entry| {
                EqualizerProfile::graphic(
                    Self::id_for_key(entry.key),
                    entry.english_name,
                    entry.targets.to_vec(),
                )
            })
    }

    pub fn profile_for_id(id: &str) -> Option<EqualizerProfile> {
        Self::key_for_id(id).and_then(Self::profile_for_key)
    }

    pub fn flat() -> EqualizerProfile {
        Self::profile_for_key(Self::FLAT_KEY).expect("the flat preset is in the table")
    }

    pub fn all() -> Vec<EqualizerProfile> {
        Self::ENTRIES
            .iter()
            .filter_map(|entry| Self::profile_for_key(entry.key))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_preset_table_is_pinned() {
        assert_eq!(EqualizerPresets::ENTRIES.len(), 16);
        let keys: Vec<&str> = EqualizerPresets::ENTRIES.iter().map(|entry| entry.key).collect();
        assert_eq!(
            keys,
            vec![
                "flat",
                "bassBoost",
                "bassReducer",
                "trebleBoost",
                "trebleReducer",
                "vocal",
                "spokenWord",
                "soften",
                "loudness",
                "acoustic",
                "classical",
                "rock",
                "electronic",
                "hipHop",
                "jazz",
                "pop",
            ]
        );
        assert_eq!(
            EqualizerPresets::profile_for_key("rock").unwrap().targets,
            vec![4.0, 3.0, 1.0, 0.0, -1.0, 0.0, 2.0, 3.0, 4.0, 4.0]
        );
        assert_eq!(
            EqualizerPresets::profile_for_key("hipHop").unwrap().targets,
            vec![6.0, 5.0, 2.0, 1.0, -1.0, -1.0, 1.0, 0.0, 1.0, 2.0]
        );
        assert_eq!(
            EqualizerPresets::TUNE_KEYS.len() + EqualizerPresets::GENRE_KEYS.len() + 1,
            16
        );
    }
}
