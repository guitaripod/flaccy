//! The music of a Flaccy Server: its OpenSubsonic API serves the same songs the sync is about, signed in with this device's token as an API key, so the songs join the library through the machinery regular servers use. One server is marked as the Flaccy Server's library; the Preferences row for it is the Flaccy Server row, not a line of the regular list.

use crate::remote::servers::Server;
use crate::remote::service::Remote;

/// The saved server that is the Flaccy Server's library, if there is one.
pub fn find(remote: &Remote) -> Option<Server> {
    remote
        .servers()
        .into_iter()
        .find(|server| server.flaccy_server)
}

/// Makes the Flaccy Server's music part of the library, replacing an earlier entry that pointed elsewhere or held another token. Answers true when a library entry was added and its songs still have to be fetched, false for an entry for the same address and token, which is kept and only renamed when the name changed.
pub fn attach(remote: &Remote, name: &str, address: &str, device_token: &str) -> Result<bool, String> {
    if let Some(existing) = find(remote) {
        if existing.address == address.trim() && existing.api_key.as_deref() == Some(device_token) {
            if existing.name != name.trim() {
                remote.rename_server(&existing.id, name)?;
            }
            return Ok(false);
        }
        remote.remove_server(&existing.id)?;
    }
    remote.add_server(Server::flaccy_library(name, address, device_token))?;
    Ok(true)
}

/// Takes the Flaccy Server's music out of the library with its cached files. Answers how many songs left; none when it was not there.
pub fn detach(remote: &Remote) -> Result<usize, String> {
    match find(remote) {
        Some(server) => remote.remove_server(&server.id),
        None => Ok(0),
    }
}
