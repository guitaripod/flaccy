//! Everything a request handler shares: the configuration, the account, the
//! database and the in-memory catalog.
//!
//! Lock order is always catalog first, database second. A handler that changes
//! a play count, a loved flag or a rating takes the catalog write lock before it
//! writes the database, so a rebuild that swaps the catalog in can never count
//! the same change twice.

use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};

use flaccy_library::db::Db;

use crate::catalog::Catalog;
use crate::config::Config;
use crate::credentials::{CredentialStore, Credentials};
use crate::store::Store;
use crate::throttle::LoginThrottle;

/// The shared pieces behind `AppState`.
pub struct Shared {
    pub config: Config,
    credentials: CredentialStore,
    db: Mutex<Db>,
    pub store: Store,
    pub login_throttle: LoginThrottle,
    /// The program that converts audio, `ffmpeg` unless `FLACCY_SERVER_FFMPEG` names another.
    pub ffmpeg: String,
    catalog: RwLock<Catalog>,
    pub(crate) refresh_gate: Mutex<()>,
}

/// A cheap handle to the shared pieces, cloned into every request.
#[derive(Clone)]
pub struct AppState(pub Arc<Shared>);

impl AppState {
    /// Opens the database in the data folder, creates the server's tables and
    /// builds the catalog from what the last scan stored. The music folder is
    /// not scanned here.
    pub fn open(config: Config) -> Result<AppState, String> {
        let ffmpeg = std::env::var("FLACCY_SERVER_FFMPEG").unwrap_or_else(|_| "ffmpeg".to_string());
        Self::open_with_ffmpeg(config, ffmpeg)
    }

    /// Like `open`, converting audio with the program `ffmpeg` names.
    pub fn open_with_ffmpeg(config: Config, ffmpeg: String) -> Result<AppState, String> {
        if !config.music_folder.is_dir() {
            return Err(format!(
                "The music folder {} does not exist or is not a folder. Set `music_folder` in the configuration file to the folder your music lives in.",
                config.music_folder.display()
            ));
        }
        let data_dir = config.data_dir();
        std::fs::create_dir_all(&data_dir).map_err(|err| {
            format!(
                "Could not create the data folder {}: {err}. Make its parent writable, or set `data_dir` in the configuration file to a folder you own.",
                data_dir.display()
            )
        })?;
        let database_path = config.database_path();
        let db = Db::open(&database_path).map_err(|err| {
            format!(
                "Could not open the library database at {}: {err}. If the file is damaged, move it away and start the server again; the next scan rebuilds the library, though playlists in the file are lost.",
                database_path.display()
            )
        })?;
        let store = Store::open(&database_path)?;
        let catalog = Catalog::build(&db, &store, &config.music_folder);
        let credentials = CredentialStore::new(config.credentials_path());
        Ok(AppState(Arc::new(Shared {
            config,
            credentials,
            db: Mutex::new(db),
            store,
            login_throttle: LoginThrottle::default(),
            ffmpeg,
            catalog: RwLock::new(catalog),
            refresh_gate: Mutex::new(()),
        })))
    }

    /// The music folder the library is indexed from.
    pub fn music_root(&self) -> &Path {
        &self.0.config.music_folder
    }

    /// The account and keys as they are on disk now.
    pub fn credentials(&self) -> Option<Credentials> {
        self.0.credentials.current()
    }

    /// Shared access to the catalog. Never hold it across an `.await`.
    pub fn catalog(&self) -> RwLockReadGuard<'_, Catalog> {
        self.0.catalog.read().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Exclusive access to the catalog, taken before the database for any change.
    pub fn catalog_mut(&self) -> RwLockWriteGuard<'_, Catalog> {
        self.0.catalog.write().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// The library database connection.
    pub fn db(&self) -> MutexGuard<'_, Db> {
        self.0.db.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Groups the library afresh from the database and swaps the result in,
    /// carrying over any play, love or rating that changed while it was built.
    pub fn rebuild_catalog(&self) {
        let path = self.0.config.database_path();
        let db = match Db::open(&path) {
            Ok(db) => db,
            Err(err) => {
                flaccy_library::logger::error(
                    "server",
                    &format!(
                        "could not reopen {} to rebuild the catalog: {err}; the server keeps serving the previous catalog, so check the data folder and trigger another scan",
                        path.display()
                    ),
                );
                return;
            }
        };
        let mut fresh = Catalog::build(&db, &self.0.store, self.music_root());
        let mut guard = self.catalog_mut();
        fresh.apply_dynamic(&self.db().fetch_all_tracks(), &self.0.store.ratings());
        *guard = fresh;
    }
}
