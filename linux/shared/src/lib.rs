//! The Rust half of Flaccy's cross-client logic.
//!
//! Every module here mirrors a file in `Core/FlaccyCore/Sources/FlaccyCore/Library`
//! and is covered by tests that assert the *same numbers* as the Swift cases —
//! same phase weights, same backoff ladder, same routing decisions. The crate
//! deliberately depends on nothing but `chrono` and `serde` so it builds and
//! tests on any machine, including the Mac that owns the Apple clients and has
//! no GStreamer for the `flaccy` binary crate.
//!
//! Which bytes identify a file's audio and what a rescan decides about a known
//! path live in `audio_payload` and `track_revision`.

pub mod album_credit;
pub mod artwork_framing;
pub mod artwork_local;
pub mod audio_payload;
pub mod enrichment_job;
pub mod equalizer;
pub mod home;
pub mod home_copy;
pub mod import_plan;
pub mod library_debut;
pub mod library_filter;
pub mod library_surface;
pub mod load_progress;
pub mod lyrics;
pub mod lyric_share;
pub mod playlist_cover;
pub mod remote;
pub mod track_page_layout;
pub mod track_revision;
