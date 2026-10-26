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
use flaccy_library::logger;

use crate::catalog::Catalog;
use crate::config::Config;
use crate::credentials::{CredentialStore, Credentials};
use crate::native::BearerThrottle;
use crate::security::{self, DeviceId};
use crate::store::Store;
use crate::sync::{self, DeviceRenamer};
use crate::throttle::LoginThrottle;

/// Opens `security.sqlite` and `state.sqlite`, and adopts the legacy account's keys when `credentials.toml` exists.
async fn open_identity_and_sync(
    config: &Config,
    credentials: &CredentialStore,
) -> Result<(security::Store, sync::Store), String> {
    let security = security::Store::open(&config.security_path()).await.map_err(|error| error.to_string())?;
    if let Some(account) = credentials.current() {
        adopt_legacy_account(&security, &account).await?;
    }
    let incarnation = security.incarnation().await.map_err(|error| error.to_string())?;
    let sync = sync::Store::open(&config.state_path(), incarnation).await.map_err(|error| error.to_string())?;
    sync.set_device_renamer(device_renamer(security.clone()));
    Ok((security, sync))
}

/// Makes the legacy account's name the first admin and gives that admin the legacy API keys.
async fn adopt_legacy_account(security: &security::Store, account: &Credentials) -> Result<(), String> {
    if account.username.trim().is_empty() {
        return Ok(());
    }
    security.ensure_owner(&account.username).await.map_err(|error| error.to_string())?;
    let imported = security.import_legacy(account).await.map_err(|error| error.to_string())?;
    if imported.imported > 0 {
        logger::info("server", &format!("imported {} API key(s) from credentials.toml", imported.imported));
    }
    Ok(())
}

/// Renames a device in the security store when a `device.rename` mutation commits.
fn device_renamer(security: security::Store) -> DeviceRenamer {
    let runtime = tokio::runtime::Handle::current();
    Arc::new(move |device: &str, name: &str| {
        let security = security.clone();
        let id = DeviceId(device.to_owned());
        let name = name.to_owned();
        runtime.spawn(async move {
            if let Err(error) = security.rename_device(&id, &name).await {
                logger::warn("server", &format!("could not rename device {id}: {error}"));
            }
        });
    })
}

/// The shared pieces behind `AppState`.
pub struct Shared {
    pub config: Config,
    credentials: CredentialStore,
    db: Mutex<Db>,
    pub store: Store,
    pub login_throttle: LoginThrottle,
    /// Failed bearer tokens of the native API, per peer address.
    pub bearer_throttle: BearerThrottle,
    /// Users, devices, enrollments, API keys and the audit trail.
    pub security: security::Store,
    /// The sync state: playlists, loves, ratings, scalars, sessions and listens.
    pub sync: sync::Store,
    /// The program that converts audio, `ffmpeg` unless `FLACCY_SERVER_FFMPEG` names another.
    pub ffmpeg: String,
    catalog: RwLock<Catalog>,
    pub(crate) refresh_gate: Mutex<()>,
}

/// A cheap handle to the shared pieces, cloned into every request.
#[derive(Clone)]
pub struct AppState(pub Arc<Shared>);

impl AppState {
    /// Opens the databases in the data folder, creates the server's tables and
    /// builds the catalog from what the last scan stored. The music folder is
    /// not scanned here.
    pub async fn open(config: Config) -> Result<AppState, String> {
        let ffmpeg = std::env::var("FLACCY_SERVER_FFMPEG").unwrap_or_else(|_| "ffmpeg".to_string());
        Self::open_with_ffmpeg(config, ffmpeg).await
    }

    /// Like `open`, converting audio with the program `ffmpeg` names.
    pub async fn open_with_ffmpeg(config: Config, ffmpeg: String) -> Result<AppState, String> {
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
        let (security, sync) = open_identity_and_sync(&config, &credentials).await?;
        Ok(AppState(Arc::new(Shared {
            config,
            credentials,
            db: Mutex::new(db),
            store,
            login_throttle: LoginThrottle::default(),
            bearer_throttle: BearerThrottle::default(),
            security,
            sync,
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
