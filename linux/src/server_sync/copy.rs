//! Every word the person reads about Flaccy Server, from `docs/server/UX.md`. Nothing outside this module spells a user-visible string of the feature, so a translation later changes one file.

pub const GROUP_TITLE: &str = "Flaccy Server";
pub const NOT_CONNECTED: &str = "Not connected";
pub const NOT_CONNECTED_DETAIL: &str = "Add one to keep playlists, loves and history in sync.";
pub const ADD_BUTTON: &str = "Add Flaccy Server…";
pub const SYNC_BADGE: &str = "Sync";
pub const NUDGE: &str = "Have a computer with your music on it? Flaccy Server shares it with your other devices, and keeps playlists, loves and history in sync. It's free: flaccy.app/server.";
pub const NUDGE_DISMISS: &str = "Not Now";
pub const NUDGE_DISMISS_TOOLTIP: &str = "Hide this for good";

pub const DIALOG_TITLE: &str = "Add Flaccy Server";
pub const LINK_ROW_TITLE: &str = "Paste the link from your computer";
pub const TYPE_INSTEAD: &str = "Type it instead";
pub const ADDRESS_ROW_TITLE: &str = "Address";
pub const CODE_ROW_TITLE: &str = "Code";
pub const CONNECT_BUTTON: &str = "Connect";
pub const CANCEL_BUTTON: &str = "Cancel";
pub const DONE_BUTTON: &str = "Done";
pub const OK_BUTTON: &str = "OK";
pub const TRY_AGAIN_BUTTON: &str = "Try Again";
pub const ADD_AS_REGULAR_BUTTON: &str = "Add as Regular Server";
pub const CONNECTED_BODY: &str = "Your playlists, loves and history now sync with this server. Its music is in your library under Servers.";
pub const LINK_UNREADABLE: &str = "This is not a Flaccy Server link. Open the link the server printed, or paste it whole.";
pub const NOTHING_TO_CONNECT: &str =
    "Paste the link from your computer, or type its address and the code.";
pub const ADDRESS_UNREADABLE: &str =
    "That address can't be used. Type the computer's name or its Tailscale address, like arch or 100.91.211.44.";
pub const CODE_INCOMPLETE: &str =
    "The code has 26 letters and numbers. Check it against the one on your computer.";
pub const SERVER_NAME_FALLBACK: &str = "your computer";

pub const DETAIL_TITLE_STATUS: &str = "Status";
pub const DETAIL_LAST_SYNCED: &str = "Last Synced";
pub const DETAIL_NEVER_SYNCED: &str = "Not yet";
pub const DEVICES_TITLE: &str = "Devices";
pub const DEVICES_LOADING: &str = "Loading devices…";
pub const THIS_DEVICE: &str = "This computer";
pub const DISCONNECT_BUTTON: &str = "Disconnect This Device";
pub const DISCONNECT_CONFIRM_BUTTON: &str = "Disconnect";
pub const DISCONNECTED_TOAST: &str = "Disconnected. Your playlists and history stay here.";
pub const DISCONNECT_FAILED: &str = "Couldn't disconnect: the local data could not be updated. Restart Flaccy and try again.";
pub const SERVICE_UNAVAILABLE: &str = "Sync isn't running. Restart Flaccy and try again.";

pub const STATUS_NOT_SYNCED: &str = "Not synced yet";
pub const STATUS_JUST_NOW: &str = "Synced just now";

/// "Connecting to arch…"
pub fn checking(name: &str) -> String {
    format!("Connecting to {name}…")
}

/// "Connected to arch."
pub fn connected_title(name: &str) -> String {
    format!("Connected to {name}.")
}

/// The confirmation body of Disconnect.
pub fn disconnect_body(name: &str) -> String {
    format!("This computer stops syncing with {name}. Your playlists and history stay here, and {name} keeps its copy.")
}

/// The confirmation title of Disconnect.
pub fn disconnect_title(name: &str) -> String {
    format!("Disconnect from {name}?")
}

/// "Synced 4 minutes ago".
pub fn synced_ago(amount: i64, unit: &str) -> String {
    let plural = if amount == 1 { "" } else { "s" };
    format!("Synced {amount} {unit}{plural} ago")
}

/// "Syncing 12 changes…"
pub fn syncing(changes: usize) -> String {
    let plural = if changes == 1 { "change" } else { "changes" };
    format!("Syncing {changes} {plural}…")
}

/// "Offline. 4 changes will send when arch is reachable."
pub fn offline_waiting(changes: usize, name: &str) -> String {
    if changes == 1 {
        format!("Offline. 1 change will send when {name} is reachable.")
    } else {
        format!("Offline. {changes} changes will send when {name} is reachable.")
    }
}

/// "Can't reach arch. Is Tailscale on?"
pub fn unreachable_line(name: &str) -> String {
    format!("Can't reach {name}. Is Tailscale on?")
}

/// The line for a server whose clock is wrong.
pub fn clock_line(name: &str) -> String {
    format!("The clock on {name} is wrong. Sync is paused.")
}

/// The line for a server with no disk space left.
pub fn disk_full_line(name: &str) -> String {
    format!("{name} is out of disk space. Free some up and Flaccy retries by itself.")
}

/// The line for a server that stopped accepting this device.
pub fn revoked_line(name: &str) -> String {
    format!("{name} no longer accepts this device. Disconnect it, then add the server again.")
}

/// When the server last heard from another device.
pub fn last_seen(ago: &str) -> String {
    format!("Last seen {ago}")
}

/// The subtitle of a device row.
pub fn device_subtitle(platform: &str, seen: &str) -> String {
    if platform.is_empty() {
        seen.to_owned()
    } else {
        format!("{platform} · {seen}")
    }
}

/// The line under Devices when the list could not be read.
pub fn devices_failed(cause: &str) -> String {
    format!("Couldn't load the device list. {cause}")
}

/// "Can't reach arch"
pub fn cant_reach_title(name: &str) -> String {
    format!("Can't reach {name}")
}

pub const CANT_REACH_BODY: &str = "Is Tailscale on? Open Tailscale and connect on this computer and on the server, then try again.";

/// "Can't find arch"
pub fn cant_find_title(name: &str) -> String {
    format!("Can't find {name}")
}

pub const CANT_FIND_BODY: &str =
    "Check the name on the server with `tailscale status`, or paste the link from the server.";
pub const CODE_REFUSED_TITLE: &str = "That code didn't work";
pub const CODE_REFUSED_BODY: &str = "A code works once and expires after 10 minutes. On the server, run `flaccy-server enroll` for a new one.";
pub const TOO_MANY_TITLE: &str = "Too many tries";
pub const TOO_MANY_BODY: &str = "Wait a minute, then try again.";

/// "arch isn't a Flaccy Server"
pub fn not_flaccy_title(name: &str) -> String {
    format!("{name} isn't a Flaccy Server")
}

pub const NOT_FLACCY_BODY: &str = "It answered, but not as Flaccy Server. If it is Navidrome or another Subsonic server, add it as a regular server.";
pub const SERVER_TOO_OLD_TITLE: &str = "Update your Flaccy Server";
pub const SERVER_TOO_OLD_BODY: &str = "This version of Flaccy needs Flaccy Server 1.0 or newer.";
pub const APP_TOO_OLD_TITLE: &str = "Update Flaccy";

/// "arch needs a newer Flaccy than this one."
pub fn app_too_old_body(name: &str) -> String {
    format!("{name} needs a newer Flaccy than this one.")
}

/// "The clock on arch is wrong"
pub fn clock_title(name: &str) -> String {
    format!("The clock on {name} is wrong")
}

pub const CLOCK_BODY: &str =
    "Sync stays off until the server's date and time are right. Check it with `timedatectl`.";

/// The heading of a failure with no entry of its own in the table.
pub fn generic_title(name: &str) -> String {
    format!("Couldn't connect to {name}")
}

/// The body of a failure with no entry of its own: the cause, then the next step.
pub fn generic_body(cause: &str) -> String {
    format!("{cause} Try again, or run `flaccy-server doctor` on the server.")
}

/// Shown under the fields when an address answered as a Flaccy Server but no code was typed.
pub fn code_needed(name: &str) -> String {
    format!("{name} is a Flaccy Server. Type the code it printed, or run `flaccy-server enroll` on it for a new one.")
}

/// How a platform word from the server reads in the device list.
pub fn platform_label(platform: &str) -> String {
    match platform {
        "ios" => "iPhone".to_owned(),
        "macos" => "Mac".to_owned(),
        "linux" => "Linux".to_owned(),
        "windows" => "Windows".to_owned(),
        "" | "other" => String::new(),
        other => other.to_owned(),
    }
}

pub const NEVER_SEEN: &str = "Not seen yet";
