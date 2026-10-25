//! Flaccy's library layer without a UI: the SQLite database, the folder
//! scanner, track versions, fingerprints, hygiene and recap logic, and the
//! text keys they share. It builds with no GTK or GStreamer packages so a
//! headless server can reuse it.

pub mod db;
pub mod fingerprint;
pub mod hygiene;
pub mod keys;
pub mod library;
pub mod logger;
pub mod music_video;
pub mod recap;
pub mod scanner;
pub mod versions;

pub(crate) use flaccy_shared::load_progress;
