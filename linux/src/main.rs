mod app;
mod artwork_image;
mod artwork_search;
mod local_artwork;
mod chart_queue;
mod config;
pub(crate) use flaccy_library::db;
mod downloads;
mod enrichment;
mod eq;
mod events;
mod filters;
pub(crate) use flaccy_library::fingerprint;
mod frame_stats;
mod home_data;
mod home_state;
pub(crate) use flaccy_library::hygiene;
mod history_sync;
mod lastfm;
pub(crate) use flaccy_library::library;
/// The load bar mirrors `FlaccyCore.LibraryLoadProgress` and lives in the
/// `flaccy-shared` workspace member, whose tests build on any machine — the
/// Mac that owns the Apple clients has no GStreamer for this crate. Re-exported
/// at the crate root so every `crate::load_progress::…` path still resolves.
pub(crate) use flaccy_shared::load_progress;
pub(crate) use flaccy_library::logger;
mod lyric_share;
mod lyrics;
mod mpris;
mod musicvideo;
mod palette;
mod player;
pub(crate) use flaccy_library::recap;
mod reexport_drill;
mod remote;
mod remote_drill;
mod render;
mod samples;
pub(crate) use flaccy_library::scanner;
mod scrobbler;
mod scrub_drill;
mod songlink;
mod station;
mod suggested;
mod theme;
mod ui;
pub(crate) use flaccy_library::versions;
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
    if let Some(data_dir) = dirs::data_dir() {
        logger::init(&data_dir.join("flaccy"));
    }
    logger::info(
        "lifecycle",
        &format!(
            "flaccy {} starting (smoke={smoke})",
            env!("CARGO_PKG_VERSION")
        ),
    );
    if let Err(err) = gst::init() {
        logger::error("playback", &format!("gstreamer init failed: {err}"));
        return glib::ExitCode::FAILURE;
    }
    eq::register();
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

    let app_id = if config::demo_mode() {
        DEMO_APP_ID
    } else {
        APP_ID
    };
    let application = adw::Application::builder().application_id(app_id).build();
    application.connect_activate(move |app| app::activate(app, smoke));

    let args: Vec<String> = std::env::args()
        .filter(|arg| arg != "--smoke" && arg != "--demo")
        .collect();
    application.run_with_args(&args)
}

/// Brings the authenticated user's Last.fm history into the local database
/// without opening the GUI (so it never contends for the single-instance lock),
/// then exits: the first run pulls everything and resumes where it stopped,
/// later runs pull what arrived since.
fn run_headless_import() -> glib::ExitCode {
    let Some(session) = config::load_session() else {
        eprintln!("not signed in to Last.fm — nothing to sync");
        return glib::ExitCode::FAILURE;
    };
    if !lastfm::keys_available() {
        eprintln!("this build has no Last.fm API keys");
        return glib::ExitCode::FAILURE;
    }
    let db_path = db::default_db_path();
    let legacy_page = config::load().import_page_cursor.max(1);
    logger::info(
        "history",
        &format!("headless history sync for {} starting", session.username),
    );
    match history_sync::sync_blocking(&db_path, &session, legacy_page) {
        Ok(stored) => {
            println!("synced {stored} new plays for {}", session.username);
            glib::ExitCode::SUCCESS
        }
        Err(reason) => {
            eprintln!("history sync stopped: {reason}");
            glib::ExitCode::FAILURE
        }
    }
}
