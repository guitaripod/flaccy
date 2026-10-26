//! Flaccy's headless OpenSubsonic server for one person's music folder.
//!
//! It indexes the folder with `flaccy-library`, so a re-export saved over a
//! file keeps its song id, playlists and play count, and answers the Subsonic
//! REST API over HTTP for any client, the Flaccy apps included. It builds with
//! no GTK or GStreamer packages and is meant to sit behind `tailscale serve`
//! or a reverse proxy that terminates HTTPS.

pub mod admin;
pub mod api;
pub mod auth;
pub mod backup;
pub mod catalog;
pub mod command;
pub mod config;
pub mod cover;
pub mod credentials;
pub mod dbthread;
pub mod doctor;
pub mod error;
pub mod export;
pub mod export_m3u;
pub mod ids;
pub mod lastfm;
pub mod lock;
pub mod maintenance;
pub mod native;
pub mod net;
pub mod nightly;
pub mod probe;
pub mod queue_session;
pub mod refresh;
pub mod reply;
pub mod request;
pub mod restore;
pub mod runner;
pub mod retention;
pub mod security;
pub mod service;
pub mod setup;
pub mod shutdown;
pub mod songref;
pub mod state;
pub mod store;
pub mod storage;
pub mod sync;
pub mod tailscale;
pub mod terminal;
pub mod throttle;
pub mod transcode;
pub mod xml;

#[cfg(test)]
mod tests;
