//! The Rust half of Flaccy's cross-client logic.
//!
//! Every module here mirrors a file in `FlaccyCore/Sources/FlaccyCore/Library`
//! and is covered by tests that assert the *same numbers* as the Swift cases —
//! same phase weights, same backoff ladder, same routing decisions. The crate
//! deliberately depends on nothing but `chrono` and `serde` so it builds and
//! tests on any machine, including the Mac that owns the Apple clients and has
//! no GStreamer for the `flaccy` binary crate.

pub mod enrichment_job;
pub mod library_debut;
pub mod library_surface;
pub mod load_progress;
