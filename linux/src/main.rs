mod app;
mod config;
mod db;
mod enrichment;
mod events;
mod hygiene;
mod importer;
mod lastfm;
mod library;
mod logger;
mod lyrics;
mod mpris;
mod palette;
mod player;
mod recap;
mod render;
mod samples;
mod scanner;
mod scrobbler;
mod songlink;
mod station;
mod suggested;
mod ui;
mod wantlist;

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

    if std::env::args().any(|arg| arg == "--import-history") {
        return run_headless_import();
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

/// Pulls the authenticated user's full Last.fm history into the local database
/// without opening the GUI (so it never contends for the single-instance lock),
/// then exits. Resumes from the persisted page cursor.
fn run_headless_import() -> glib::ExitCode {
    let Some(session) = config::load_session() else {
        eprintln!("not signed in to Last.fm — nothing to import");
        return glib::ExitCode::FAILURE;
    };
    if !lastfm::keys_available() {
        eprintln!("this build has no Last.fm API keys");
        return glib::ExitCode::FAILURE;
    }
    let db_path = db::default_db_path();
    let start_page = config::load().import_page_cursor.max(1);
    logger::info(
        "import",
        &format!("headless history import for {} starting", session.username),
    );
    let imported = importer::import_blocking(&db_path, &session, start_page);
    println!("imported {imported} scrobbles for {}", session.username);
    logger::info("import", &format!("headless history import done: {imported} scrobbles"));
    glib::ExitCode::SUCCESS
}
