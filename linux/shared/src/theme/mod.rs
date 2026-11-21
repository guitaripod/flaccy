//! What a theme is and what it resolves to, shared by every client: the
//! document (`pack`), the look a choice of scheme and variant gives
//! (`look`) and the color arithmetic under both (`color`). Mirrored in
//! FlaccyCore's `Themes`, and held to it by one golden file both suites read.
pub mod color;
pub mod document;
pub mod look;
pub mod pack;
