//! Lyrics as a document: the lines of a song with when each starts and ends,
//! the words inside them when a source knows them, and the interludes between.
//!
//! Mirrors `Core/FlaccyCore/Sources/FlaccyCore/Lyrics` and is covered by the same
//! vectors, so every client reads an LRC, an enhanced LRC or a Lyricsfile into
//! the same lines and asks the same clock which of them to light.

mod clock;
mod document;
mod lrc;
mod lyricsfile;
mod query;
mod score;
mod status;
mod timing_note;

pub use clock::{LineProgress, INTERLUDE_BEATS, OVERLAP_LOOKBACK};
pub use document::{
    Document, Line, LineKind, RawLine, RawWord, Word, MAX_INFERRED_HOLD, MIN_INTERLUDE,
};
pub use lrc::{parse_lrc, parse_raw_lines, parse_timestamp};
pub use lyricsfile::parse_lyricsfile;
pub use query::{clean_title, lead_artist, EDITION_KEYWORDS};
pub use score::{
    best_candidate, score, similarity, Candidate, Wanted, ACCEPTED_SCORE, MAX_DURATION_DRIFT,
};
pub use status::{
    failed as failure_status, idle as idle_status, instrumental as instrumental_status,
    missing as missing_status, searching as searching_status, LyricsFailure, LyricsStatus,
};
pub use timing_note::{timing_note, TimingNote, TimingNoteKind};
