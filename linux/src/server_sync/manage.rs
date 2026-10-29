use super::*;
use flaccy_library::server_sync::{library, Blocker, SyncState};

impl Service {
    /// Gives a device of the account another name.
    pub async fn rename_device(&self, id: &str, name: &str) -> Result<(), Failure> {
        let (reply, answer) = async_channel::bounded(1);
        let command = Command::RenameDevice {
            id: id.to_owned(),
            name: name.to_owned(),
            reply,
        };
        self.device_call(command, answer).await
    }

    /// Removes a device of the account from the server; the device stops syncing at its next call.
    pub async fn remove_device(&self, id: &str) -> Result<(), Failure> {
        let (reply, answer) = async_channel::bounded(1);
        let command = Command::RemoveDevice {
            id: id.to_owned(),
            reply,
        };
        self.device_call(command, answer).await
    }

    async fn device_call(
        &self,
        command: Command,
        answer: async_channel::Receiver<Result<(), flaccy_library::server_sync::SyncError>>,
    ) -> Result<(), Failure> {
        let name = self.name();
        if !self.send(command) {
            return Err(unavailable(&name));
        }
        match answer.recv().await {
            Ok(Ok(())) => Ok(()),
            Ok(Err(error)) => Err(failure_for(&error, Stage::Connected, &name)),
            Err(_) => Err(unavailable(&name)),
        }
    }

    /// True while the server's music is meant to show in the library.
    pub fn library_visible(&self) -> bool {
        self.core
            .upgrade()
            .is_some_and(|core| !core.config.borrow().flaccy_server_library_hidden)
    }

    /// The line under the server's name in Preferences: the status, then how many songs it brought.
    pub fn row_line(&self) -> String {
        copy::row_subtitle(
            &self.status_line(),
            self.library_visible(),
            self.library_songs(),
        )
    }

    /// How many songs of the server are in the library, once counted.
    pub fn library_songs(&self) -> Option<usize> {
        self.library_songs.get()
    }

    /// Why the server's music cannot be fetched right now, if it cannot.
    pub fn library_trouble(&self) -> Option<copy::LibraryTrouble> {
        let signed_out = matches!(
            self.status.borrow().as_ref().map(|status| &status.state),
            Some(SyncState::Blocked(Blocker::DeviceRevoked))
        );
        if signed_out {
            return Some(copy::LibraryTrouble::SignedOut);
        }
        let remote = crate::remote::handle()?;
        let server = library::find(remote)?;
        (!remote.manager().is_reachable(&server.id)).then_some(copy::LibraryTrouble::Unreachable)
    }

    /// Shows the server's music in the library or takes it out, and remembers the choice.
    pub async fn show_library(self: &Rc<Self>, visible: bool) -> Result<(), String> {
        let (reply, answer) = async_channel::bounded(1);
        let command = Command::ShowLibrary {
            name: self.name(),
            visible,
            reply,
        };
        if !self.send(command) {
            return Err(copy::SERVICE_UNAVAILABLE.to_owned());
        }
        match answer.recv().await {
            Ok(Ok(())) => {
                self.remember_library_choice(visible);
                Ok(())
            }
            Ok(Err(message)) => Err(message),
            Err(_) => Err(copy::SERVICE_UNAVAILABLE.to_owned()),
        }
    }

    fn remember_library_choice(&self, visible: bool) {
        let Some(core) = self.core.upgrade() else {
            return;
        };
        core.config.borrow_mut().flaccy_server_library_hidden = !visible;
        core.save_config();
        core.hub.emit(&AppEvent::ServerSyncChanged);
    }

    /// At start: brings the saved library entry in line with the connection and the person's choice.
    pub(super) fn ensure_library(&self) {
        if !self.connected() {
            return;
        }
        self.send(Command::EnsureLibrary {
            name: self.name(),
            visible: self.library_visible(),
        });
    }

    /// The server's music joined or left the library under the worker.
    pub(super) fn library_changed(self: &Rc<Self>, change: LibraryChange) {
        let Some(core) = self.core.upgrade() else {
            return;
        };
        match change {
            LibraryChange::Added => core.sync_remote_servers(false),
            LibraryChange::Removed => core.reload_library(),
        }
        self.library_songs.set(None);
        self.refresh_library_count();
    }

    /// Counts the server's songs off the main thread and tells the interface when the number changed.
    pub(super) fn refresh_library_count(self: &Rc<Self>) {
        let (Some(core), Some(remote)) = (self.core.upgrade(), crate::remote::handle()) else {
            return;
        };
        if self.counting.replace(true) {
            return;
        }
        let Some(id) = library::find(remote).map(|server| server.id) else {
            self.counting.set(false);
            self.set_library_songs(None);
            return;
        };
        let (reply, answer) = async_channel::bounded(1);
        let db_path = core.db_path.clone();
        let started = std::thread::Builder::new()
            .name("flaccy-server-count".into())
            .spawn(move || {
                let count = flaccy_library::db::Db::open(&db_path)
                    .ok()
                    .map(|db| db.remote_song_counts().get(&id).copied().unwrap_or(0));
                let _ = reply.send_blocking(count);
            })
            .is_ok();
        if !started {
            self.counting.set(false);
            return;
        }
        let service = Rc::clone(self);
        glib::spawn_future_local(async move {
            let count = answer.recv().await.ok().flatten();
            service.counting.set(false);
            service.set_library_songs(count);
        });
    }

    fn set_library_songs(&self, count: Option<usize>) {
        if self.library_songs.replace(count) == count {
            return;
        }
        if let Some(core) = self.core.upgrade() {
            core.hub.emit(&AppEvent::ServerSyncChanged);
        }
    }

    /// The first connect combined something: keeps it for the summary sheet and tells the window.
    pub(super) fn set_merge(&self, merge: MergeReport) {
        crate::logger::info(
            LOG,
            &format!(
                "first connect combined {} playlists and {} loves",
                merge.playlists.len(),
                merge.loves.len()
            ),
        );
        *self.merge.borrow_mut() = Some(merge);
        if let Some(core) = self.core.upgrade() {
            core.hub.emit(&AppEvent::ServerMergeReady);
        }
    }

    /// What the first connect combined, for the summary sheet.
    pub fn merge(&self) -> Option<MergeReport> {
        self.merge.borrow().clone()
    }

    /// A remote sync brought songs in: playlist entries that waited for them can show now.
    pub fn resolve_ghosts(&self) {
        self.send(Command::ResolveGhosts);
    }
}
