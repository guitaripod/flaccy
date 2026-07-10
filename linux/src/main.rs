mod app;
mod config;
mod db;
mod events;
mod lastfm;
mod library;
mod logger;
mod lyrics;
mod mpris;
mod palette;
mod player;
mod scanner;
mod scrobbler;
mod ui;

use adw::prelude::*;
use gtk::glib;

const APP_ID: &str = "cc.midgarcorp.Flaccy";

fn main() -> glib::ExitCode {
    let smoke = std::env::args().any(|arg| arg == "--smoke");
    logger::init();
    logger::info(
        "lifecycle",
        &format!("flaccy {} starting (smoke={smoke})", env!("CARGO_PKG_VERSION")),
    );
    if let Err(err) = gst::init() {
        logger::error("playback", &format!("gstreamer init failed: {err}"));
        return glib::ExitCode::FAILURE;
    }
    if !lastfm::keys_available() {
        logger::warn("auth", "built without Last.fm keys; scrobbling UI hidden");
    }

    let application = adw::Application::builder()
        .application_id(APP_ID)
        .build();
    application.connect_activate(move |app| app::activate(app, smoke));

    let args: Vec<String> = std::env::args().filter(|arg| arg != "--smoke").collect();
    application.run_with_args(&args)
}
