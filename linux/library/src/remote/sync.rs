//! Pulling a server's whole catalog, and turning it into library changes.
//!
//! The catalog comes from `search3` with an empty query, 500 songs a page. A
//! server that answers an empty query with nothing is walked album by album
//! instead, four albums at a time. `apply` then runs the shared
//! `catalog_diff` against the rows already stored for that server and writes
//! the result in one transaction.

use super::catalog::RemoteSong;
use super::client::{Client, RemoteError};
use crate::db::{ApplyReport, Db};
use flaccy_shared::remote::catalog_diff::{self, CatalogSong};
use flaccy_shared::remote::subsonic_response::Child;
use std::collections::HashSet;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// Songs asked for per `search3` page, and albums per `getAlbumList2` page.
pub const PAGE_SIZE: usize = 500;
/// Albums fetched at the same time on the album walk.
pub const ALBUM_PARALLELISM: usize = 4;
const MAX_PAGES: usize = 10_000;

/// Receives how many songs have been read so far; called from several threads
/// on the album walk.
pub type Progress<'a> = &'a (dyn Fn(usize) + Sync);

/// Reads every song a server has.
pub fn fetch_catalog(client: &Client, on_progress: Progress<'_>) -> Result<Vec<Child>, RemoteError> {
    let songs = fetch_by_search(client, on_progress)?;
    if !songs.is_empty() {
        return Ok(songs);
    }
    fetch_by_albums(client, on_progress)
}

fn fetch_by_search(client: &Client, on_progress: Progress<'_>) -> Result<Vec<Child>, RemoteError> {
    let mut songs: Vec<Child> = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    for page in 0..MAX_PAGES {
        let batch = client.search_songs(page * PAGE_SIZE, PAGE_SIZE)?;
        let received = batch.len();
        for song in batch {
            if seen.insert(song.id.clone()) {
                songs.push(song);
            }
        }
        on_progress(songs.len());
        if received < PAGE_SIZE {
            break;
        }
    }
    Ok(songs)
}

fn fetch_by_albums(client: &Client, on_progress: Progress<'_>) -> Result<Vec<Child>, RemoteError> {
    let mut album_ids: Vec<String> = Vec::new();
    for page in 0..MAX_PAGES {
        let batch = client.album_ids(page * PAGE_SIZE, PAGE_SIZE)?;
        let received = batch.len();
        album_ids.extend(batch);
        if received < PAGE_SIZE {
            break;
        }
    }
    let queue = Arc::new(Mutex::new(album_ids.into_iter()));
    let collected: Arc<Mutex<Vec<Child>>> = Arc::new(Mutex::new(Vec::new()));
    let failure: Arc<Mutex<Option<RemoteError>>> = Arc::new(Mutex::new(None));
    let counted = Arc::new(AtomicUsize::new(0));
    std::thread::scope(|scope| {
        for _ in 0..ALBUM_PARALLELISM {
            scope.spawn(|| loop {
                if failure.lock().unwrap_or_else(|p| p.into_inner()).is_some() {
                    return;
                }
                let next = queue.lock().unwrap_or_else(|p| p.into_inner()).next();
                let Some(album) = next else { return };
                match client.album_songs(&album) {
                    Ok(songs) => {
                        counted.fetch_add(songs.len(), Ordering::SeqCst);
                        collected.lock().unwrap_or_else(|p| p.into_inner()).extend(songs);
                        on_progress(counted.load(Ordering::SeqCst));
                    }
                    Err(error) => {
                        *failure.lock().unwrap_or_else(|p| p.into_inner()) = Some(error);
                        return;
                    }
                }
            });
        }
    });
    if let Some(error) = failure.lock().unwrap_or_else(|p| p.into_inner()).take() {
        return Err(error);
    }
    let mut seen = HashSet::new();
    let mut songs = std::mem::take(&mut *collected.lock().unwrap_or_else(|p| p.into_inner()));
    songs.retain(|song| seen.insert(song.id.clone()));
    Ok(songs)
}

/// What a catalog sync changed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SyncReport {
    pub songs: usize,
    pub applied: ApplyReport,
}

/// Why a catalog could not be applied.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ApplyError {
    EmptyCatalog { stored: usize },
    Database(String),
}

impl ApplyError {
    /// The sentence a toast shows for this failure.
    pub fn message(&self, server: &str) -> String {
        match self {
            Self::EmptyCatalog { stored } => format!(
                "{server} listed no songs, so its {stored} songs were kept. Check that the server's music library is scanned, then refresh it again."
            ),
            Self::Database(cause) => format!(
                "Couldn’t save {server}’s songs to the library: {cause}. Check the disk has free space, then refresh it again."
            ),
        }
    }
}

/// Writes the differences between `children` and the stored rows of `server`.
/// A catalog with no songs never wipes a library that has some, the same guard
/// the folder scan has against a root that vanished.
pub fn apply(db: &Db, server: &str, children: &[Child]) -> Result<(Vec<RemoteSong>, SyncReport), ApplyError> {
    let songs: Vec<RemoteSong> = children
        .iter()
        .map(|child| RemoteSong::from_child(server, child))
        .collect();
    let local = db.remote_catalog(server);
    if songs.is_empty() && !local.is_empty() {
        return Err(ApplyError::EmptyCatalog { stored: local.len() });
    }
    let listed: Vec<CatalogSong> = songs.iter().map(RemoteSong::catalog_song).collect();
    let diff = catalog_diff::diff(&listed, &local);
    let applied = db
        .apply_remote_catalog(server, &songs, &diff)
        .map_err(|error| ApplyError::Database(error.to_string()))?;
    let report = SyncReport {
        songs: songs.len(),
        applied,
    };
    Ok((songs, report))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::remote::servers::Server;
    use crate::remote::testing::{child_json, FixtureServer};

    fn fixture_with(count: usize) -> (FixtureServer, Client) {
        let fixture = FixtureServer::start();
        for index in 0..count {
            fixture.add_child(child_json(
                &format!("song-{index:04}"),
                &format!("Title {index}"),
                &format!("Album {}", index / 10),
                (index % 10) as i64 + 1,
                1000 + index,
            ));
        }
        let server = Server::new("Fixture", &fixture.address(), "ana", "pw", false);
        let client = Client::new(&server).unwrap();
        (fixture, client)
    }

    #[test]
    fn the_whole_catalog_is_read_in_pages_of_five_hundred() {
        let (_fixture, client) = fixture_with(1203);
        let pages = Mutex::new(Vec::new());
        let songs = fetch_catalog(&client, &|so_far| pages.lock().unwrap().push(so_far)).unwrap();
        assert_eq!(songs.len(), 1203);
        assert_eq!(*pages.lock().unwrap(), vec![500, 1000, 1203]);
    }

    #[test]
    fn a_server_with_nothing_for_an_empty_query_is_walked_album_by_album() {
        let (fixture, client) = fixture_with(95);
        fixture.empty_search_results();
        let songs = fetch_catalog(&client, &|_| {}).unwrap();
        assert_eq!(songs.len(), 95);
        let ids: HashSet<&str> = songs.iter().map(|song| song.id.as_str()).collect();
        assert_eq!(ids.len(), 95);
    }

    fn scratch_db(name: &str) -> (Db, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!("flaccy-sync-{name}-{}.sqlite", std::process::id()));
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
        (Db::open(&path).unwrap(), path)
    }

    fn cleanup(path: &std::path::Path) {
        for suffix in ["", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{suffix}", path.display()));
        }
    }

    #[test]
    fn syncing_applies_the_diff_to_the_database() {
        let (fixture, client) = fixture_with(12);
        let (db, path) = scratch_db("apply");
        let children = fetch_catalog(&client, &|_| {}).unwrap();
        let (_, first) = apply(&db, "s1", &children).unwrap();
        assert_eq!(first.songs, 12);
        assert_eq!(first.applied.inserted, 12);
        assert_eq!(db.fetch_all_tracks().len(), 12);

        fixture.clear_catalog();
        for index in 1..12 {
            let title = if index == 3 { "Retitled".to_string() } else { format!("Title {index}") };
            let size = if index == 5 { 99_999 } else { 1000 + index };
            fixture.add_child(child_json(
                &format!("song-{index:04}"),
                &title,
                &format!("Album {}", index / 10),
                (index % 10) as i64 + 1,
                size,
            ));
        }
        fixture.add_child(child_json("song-new", "Brand New", "Album 9", 1, 5000));
        let children = fetch_catalog(&client, &|_| {}).unwrap();
        let (_, second) = apply(&db, "s1", &children).unwrap();
        assert_eq!(second.applied.inserted, 1);
        assert_eq!(second.applied.updated, 1);
        assert_eq!(second.applied.new_versions, vec!["song-0005".to_string()]);
        assert_eq!(second.applied.removed, vec!["song-0000".to_string()]);
        let rows = db.fetch_all_tracks();
        assert_eq!(rows.len(), 12);
        assert!(rows.iter().any(|row| row.title == "Retitled"));
        assert_eq!(db.remote_revision("s1", "song-0005").map(|(revision, _)| revision), Some(2));
        cleanup(&path);
    }

    #[test]
    fn an_empty_catalog_never_wipes_a_library_that_has_songs() {
        let (_fixture, client) = fixture_with(3);
        let (db, path) = scratch_db("empty-guard");
        let children = fetch_catalog(&client, &|_| {}).unwrap();
        apply(&db, "s1", &children).unwrap();
        let error = apply(&db, "s1", &[]).unwrap_err();
        assert_eq!(error, ApplyError::EmptyCatalog { stored: 3 });
        assert!(error.message("Home").contains("kept"));
        assert_eq!(db.fetch_all_tracks().len(), 3);
        cleanup(&path);
    }
}
