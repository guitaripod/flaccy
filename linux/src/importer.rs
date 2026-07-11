use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use crate::lastfm::LastFmClient;
use gtk::glib;
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::Duration;

const PAGE_LIMIT: u32 = 200;
const MAX_PAGES: u32 = 10_000;
const MAX_PAGE_RETRIES: u32 = 4;
const RETRY_BACKOFF_MS: u64 = 800;

struct Progress {
    imported: usize,
    page: u32,
    total_pages: u32,
    done: bool,
    /// True only when the whole history was pulled to the last page. False when
    /// the run stopped early (transient Last.fm failure) so the caller keeps the
    /// page cursor for a resume instead of restarting from page 1.
    completed: bool,
}

/// Imports the user's full Last.fm listening history into the local scrobbles
/// table (duration 0, submitted, deduped by timestamp+title), resuming from
/// the persisted page cursor. Progress is streamed back to the main loop.
pub fn start(core: &Rc<AppCore>) {
    if core.import_in_flight.get() {
        return;
    }
    let Some(session) = core.session.borrow().clone() else { return };
    let Some(client) = LastFmClient::new(Some(session.key.clone())) else { return };
    core.import_in_flight.set(true);

    let db_path = core.db_path.clone();
    let username = session.username.clone();
    let start_page = core.config.borrow().import_page_cursor.max(1);
    let (tx, rx) = async_channel::unbounded::<Progress>();
    std::thread::Builder::new()
        .name("flaccy-import".into())
        .spawn(move || run_import(&db_path, &client, &username, start_page, tx))
        .ok();

    let weak = Rc::downgrade(core);
    glib::spawn_future_local(async move {
        while let Ok(progress) = rx.recv().await {
            let Some(core) = weak.upgrade() else { break };
            {
                let mut config = core.config.borrow_mut();
                config.import_page_cursor = if progress.completed { 1 } else { progress.page };
            }
            core.save_config();
            if progress.done {
                core.import_in_flight.set(false);
            }
            core.hub.emit(&AppEvent::HistoryImport {
                imported: progress.imported,
                page: progress.page,
                total_pages: progress.total_pages,
                done: progress.done,
            });
            if progress.done {
                core.reload_library();
                break;
            }
        }
    });
}

/// Synchronous full-history import for the `--import-history` headless entry
/// point (no GTK, no single-instance registration). Resumes from `start_page`
/// and returns the number of newly-imported scrobbles.
pub fn import_blocking(
    db_path: &PathBuf,
    session: &crate::config::Session,
    start_page: u32,
) -> usize {
    let Some(client) = LastFmClient::new(Some(session.key.clone())) else {
        crate::logger::warn("import", "import_blocking: Last.fm keys unavailable");
        return 0;
    };
    let (tx, rx) = async_channel::unbounded::<Progress>();
    run_import(db_path, &client, &session.username, start_page.max(1), tx);
    let mut imported = 0usize;
    while let Ok(progress) = rx.try_recv() {
        imported = progress.imported;
    }
    imported
}

fn run_import(
    db_path: &PathBuf,
    client: &LastFmClient,
    username: &str,
    start_page: u32,
    tx: async_channel::Sender<Progress>,
) {
    let Ok(db) = Db::open(db_path) else {
        let _ = tx.send_blocking(Progress {
            imported: 0,
            page: start_page,
            total_pages: 0,
            done: true,
            completed: true,
        });
        return;
    };
    let existing = db.fetch_all_scrobble_rows();
    let mut seen: HashSet<String> = existing
        .iter()
        .map(|row| crate::recap::import_key(row.timestamp_unix, &row.title))
        .collect();

    let mut page = start_page;
    let mut total_pages = start_page;
    let mut imported = 0usize;
    crate::logger::info(
        "import",
        &format!("history import starting at page {page} ({} local rows)", existing.len()),
    );
    loop {
        let (tracks, pages) = match fetch_page_with_retry(client, username, page) {
            Ok(result) => result,
            Err(err) => {
                crate::logger::warn(
                    "import",
                    &format!(
                        "history import interrupted at page {page} after {MAX_PAGE_RETRIES} retries: {err}"
                    ),
                );
                if imported > 0 {
                    db.reconcile_play_counts_from_scrobbles();
                }
                let _ = tx.send_blocking(Progress {
                    imported,
                    page,
                    total_pages,
                    done: true,
                    completed: false,
                });
                return;
            }
        };
        total_pages = pages.max(1);
        let mut batch: Vec<(String, String, String, i64, i64, bool)> =
            Vec::with_capacity(tracks.len());
        for (uts, title, artist, album) in tracks {
            let key = crate::recap::import_key(uts, &title);
            if !seen.insert(key) {
                continue;
            }
            batch.push((title, artist, album, uts, 0, true));
        }
        match db.insert_scrobbles_batch(&batch) {
            Ok(count) => imported += count,
            Err(err) => {
                crate::logger::error(
                    "import",
                    &format!("insert imported scrobble page failed: {err}"),
                );
            }
        }
        let done = page >= total_pages || page >= MAX_PAGES;
        if done {
            db.reconcile_play_counts_from_scrobbles();
        }
        let _ = tx.send_blocking(Progress {
            imported,
            page: if done { page } else { page + 1 },
            total_pages,
            done,
            completed: done,
        });
        if done {
            crate::logger::info(
                "import",
                &format!("history import finished: {imported} imported over {page} pages"),
            );
            return;
        }
        page += 1;
    }
}

/// Fetches a single history page, retrying transient Last.fm failures (its
/// "backend service failed" 500s are common on long pulls) with linear backoff
/// before giving up, so one hiccup can't abort an 800-page import.
fn fetch_page_with_retry(
    client: &LastFmClient,
    username: &str,
    page: u32,
) -> Result<(Vec<(i64, String, String, String)>, u32), String> {
    let mut attempt = 0u32;
    loop {
        match client.fetch_recent_tracks(username, page, PAGE_LIMIT) {
            Ok(result) => return Ok(result),
            Err(err) => {
                attempt += 1;
                if attempt > MAX_PAGE_RETRIES {
                    return Err(err);
                }
                let backoff = RETRY_BACKOFF_MS * attempt as u64;
                crate::logger::info(
                    "import",
                    &format!("history import page {page} attempt {attempt} failed ({err}); retrying in {backoff}ms"),
                );
                std::thread::sleep(Duration::from_millis(backoff));
            }
        }
    }
}
