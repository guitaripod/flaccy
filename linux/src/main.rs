mod app;
mod config;
mod db;
mod enrichment;
mod events;
mod importer;
mod lastfm;
mod library;
mod logger;
mod lyrics;
mod mpris;
mod palette;
mod player;
mod recap;
mod samples;
mod scanner;
mod scrobbler;
mod songlink;
mod station;
mod suggested;
mod ui;

use adw::prelude::*;
use gtk::glib;

const APP_ID: &str = "cc.midgarcorp.Flaccy";
const DEMO_APP_ID: &str = "cc.midgarcorp.Flaccy.Demo";

fn main() -> glib::ExitCode {
    let smoke = std::env::args().any(|arg| arg == "--smoke");
    if std::env::args().any(|arg| arg == "--demo") {
        std::env::set_var("FLACCY_DEMO", "1");
    }
    logger::init();
    logger::info(
        "lifecycle",
        &format!("flaccy {} starting (smoke={smoke})", env!("CARGO_PKG_VERSION")),
    );
    if let Err(err) = gst::init() {
        logger::error("playback", &format!("gstreamer init failed: {err}"));
        return glib::ExitCode::FAILURE;
    }
    if gst::ElementFactory::find("playbin3").is_none() {
        logger::error(
            "playback",
            "GStreamer playbin3 element is missing; install gst-plugins-base (playback plugin)",
        );
        return glib::ExitCode::FAILURE;
    }
    if !lastfm::keys_available() {
        logger::warn("auth", "built without Last.fm keys; scrobbling UI hidden");
    }

    let app_id = if config::demo_mode() { DEMO_APP_ID } else { APP_ID };
    let application = adw::Application::builder()
        .application_id(app_id)
        .build();
    application.connect_activate(move |app| app::activate(app, smoke));

    let args: Vec<String> = std::env::args()
        .filter(|arg| arg != "--smoke" && arg != "--demo")
        .collect();
    application.run_with_args(&args)
}
