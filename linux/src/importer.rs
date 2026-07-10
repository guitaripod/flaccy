use crate::app::AppCore;
use crate::db::Db;
use crate::events::AppEvent;
use crate::lastfm::LastFmClient;
use gtk::glib;
use std::collections::HashSet;
use std::path::PathBuf;
use std::rc::Rc;

const PAGE_LIMIT: u32 = 200;
const MAX_PAGES: u32 = 10_000;

struct Progress {
    imported: usize,
    page: u32,
    total_pages: u32,
    done: bool,
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
                config.import_page_cursor = if progress.done { 1 } else { progress.page };
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
                break;
            }
        }
    });
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
        match client.fetch_recent_tracks(username, page, PAGE_LIMIT) {
            Ok((tracks, pages)) => {
                total_pages = pages.max(1);
                for (uts, title, artist, album) in tracks {
                    let key = crate::recap::import_key(uts, &title);
                    if !seen.insert(key) {
                        continue;
                    }
                    match db.insert_scrobble(&title, &artist, &album, uts, 0, true) {
                        Ok(()) => imported += 1,
                        Err(err) => {
                            crate::logger::error(
                                "import",
                                &format!("insert imported scrobble failed: {err}"),
                            );
                        }
                    }
                }
            }
            Err(err) => {
                crate::logger::warn(
                    "import",
                    &format!("history import interrupted at page {page}: {err}"),
                );
                let _ = tx.send_blocking(Progress {
                    imported,
                    page,
                    total_pages,
                    done: true,
                });
                return;
            }
        }
        let done = page >= total_pages || page >= MAX_PAGES;
        let _ = tx.send_blocking(Progress {
            imported,
            page: if done { page } else { page + 1 },
            total_pages,
            done,
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
