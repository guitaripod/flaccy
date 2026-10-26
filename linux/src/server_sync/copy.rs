//! Every word the person reads about Flaccy Server, from `docs/server/UX.md`. Nothing outside this module spells a user-visible string of the feature, so a translation later changes one file.

pub const GROUP_TITLE: &str = "Flaccy Server";
pub const NOT_CONNECTED: &str = "Not connected";
pub const NOT_CONNECTED_DETAIL: &str = "Add one to keep playlists, loves and history in sync.";
pub const ADD_BUTTON: &str = "Add Flaccy Server…";
pub const SYNC_BADGE: &str = "Sync";
pub const NUDGE: &str = "Have a computer with your music on it? Flaccy Server shares it with your other devices, and keeps playlists, loves and history in sync. It's free: flaccy.app/server.";
pub const NUDGE_DISMISS: &str = "Not now";
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
pub const TRY_AGAIN_BUTTON: &str = "Try again";
pub const ADD_AS_REGULAR_BUTTON: &str = "Add as regular server";
pub const CONNECTED_BODY: &str = "Your playlists, loves and history now sync with this server. Its music is in your library under Servers.";

/// The Connected body when the server's music could not join the library.
pub fn connected_body_no_library(name: &str) -> String {
    format!("Your playlists, loves and history now sync with this server. Its music could not be added to your library. Open {name} in Preferences, Servers, and turn on {}.", show_music_title(name))
}
pub const LINK_UNREADABLE: &str = "This is not a Flaccy Server link. Open the link the server printed, or paste it whole.";
pub const NOTHING_TO_CONNECT: &str =
    "Paste the link from your computer, or type its address and the code.";
pub const ADDRESS_UNREADABLE: &str =
    "That address can't be used. Type the computer's name or its Tailscale address, like arch or 100.91.211.44.";
pub const CODE_INCOMPLETE: &str =
    "The code has 26 letters and numbers. Check it against the one on your computer.";
pub const SERVER_NAME_FALLBACK: &str = "your computer";

pub const DETAIL_TITLE_STATUS: &str = "Status";
pub const DETAIL_LAST_SYNCED: &str = "Last synced";
pub const DETAIL_NEVER_SYNCED: &str = "Not yet";
pub const DEVICES_TITLE: &str = "Devices";
pub const DEVICES_LOADING: &str = "Loading devices…";
pub const THIS_DEVICE: &str = "This computer";
pub const DISCONNECT_BUTTON: &str = "Disconnect this device";
pub const DISCONNECT_CONFIRM_BUTTON: &str = "Disconnect";
pub const DISCONNECTED_TOAST: &str = "Disconnected. Your playlists and history stay here.";
pub const DISCONNECT_FAILED: &str = "Couldn't disconnect: the local data could not be updated. Restart Flaccy and try again.";
pub const SERVICE_UNAVAILABLE: &str = "Sync isn't running. Restart Flaccy and try again.";

pub const UPDATE_FLACCY_LINE: &str = "Update Flaccy to keep syncing.";
pub const UPDATE_SERVER_LINE: &str = "Update your Flaccy Server to keep syncing.";
pub const UNDO_FAILED: &str = "Couldn't undo that: the local data could not be updated. Restart Flaccy and try again.";

pub const LIBRARY_TITLE: &str = "Library";
pub const LIBRARY_COUNTING: &str = "Counting songs…";
pub const LIBRARY_HIDDEN: &str = "Not shown in your library";
pub const RENAME_TITLE: &str = "Rename this computer";
pub const RENAME_BUTTON: &str = "Rename";
pub const RENAME_EMPTY: &str = "A device needs a name. Type one and try again.";
pub const RENAME_TOOLTIP: &str = "Rename this computer";
pub const REMOVE_BUTTON: &str = "Remove";
pub const REMOVE_TOOLTIP: &str = "Remove this device";
pub const UNDO_BUTTON: &str = "Undo";
pub const UNDONE: &str = "Undone.";

pub const STATUS_NOT_SYNCED: &str = "Not synced yet";
pub const STATUS_JUST_NOW: &str = "Synced just now";

/// "Show arch's music in my library"
pub fn show_music_title(name: &str) -> String {
    format!("Show {name}'s music in my library")
}

/// "7,412 songs"
pub fn songs_text(count: usize) -> String {
    let digits = count.to_string();
    let mut grouped = String::new();
    for (index, digit) in digits.chars().enumerate() {
        if index > 0 && (digits.len() - index) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(digit);
    }
    let noun = if count == 1 { "song" } else { "songs" };
    format!("{grouped} {noun}")
}

/// Why the server's music cannot be fetched right now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LibraryTrouble {
    /// The server does not answer.
    Unreachable,
    /// The server no longer accepts this device.
    SignedOut,
}

/// The Library row of the server's page.
pub fn library_line(
    visible: bool,
    songs: Option<usize>,
    trouble: Option<LibraryTrouble>,
    name: &str,
) -> String {
    let Some(count) = songs.filter(|_| visible) else {
        return if visible { LIBRARY_COUNTING } else { LIBRARY_HIDDEN }.to_owned();
    };
    match trouble {
        None => songs_text(count),
        Some(LibraryTrouble::Unreachable) => {
            format!("{} · {}", songs_text(count), unreachable_line(name))
        }
        Some(LibraryTrouble::SignedOut) => {
            format!("{} · {}", songs_text(count), revoked_title(name))
        }
    }
}

/// The subtitle of the server's row in Preferences: the status line, then the song count.
pub fn row_subtitle(status: &str, visible: bool, songs: Option<usize>) -> String {
    match (visible, songs) {
        (true, Some(count)) => format!("{status} · {}", songs_text(count)),
        _ => status.to_owned(),
    }
}

/// "Rename this computer" explanation.
pub fn rename_body(server: &str) -> String {
    format!("The name shows on the device list of every phone and computer connected to {server}.")
}

/// "Remove Pixel?"
pub fn remove_title(device: &str) -> String {
    format!("Remove {device}?")
}

/// What removing another device does.
pub fn remove_body(device: &str, server: &str) -> String {
    format!("{device} stops syncing with {server}. Its playlists and history stay on it, and {server} keeps its copy.")
}

/// A list of playlist names in a sentence: "A", "A and B", "A, B and C", "A, B, C and 2 more".
pub fn names_in_a_sentence(names: &[String]) -> String {
    match names {
        [] => String::new(),
        [only] => only.clone(),
        [first, second] => format!("{first} and {second}"),
        [first, second, third] => format!("{first}, {second} and {third}"),
        [first, second, third, rest @ ..] => {
            format!("{first}, {second}, {third} and {} more", rest.len())
        }
    }
}

/// The playlists line of the first-connect summary.
pub fn merge_playlists_line(names: &[String]) -> String {
    let (verb, noun) = if names.len() == 1 {
        ("was", "is now one")
    } else {
        ("were", "are now one each")
    };
    format!(
        "We combined your playlists. {} {verb} on both devices and {noun}.",
        names_in_a_sentence(names)
    )
}

/// The loves line of the first-connect summary.
pub fn merge_loves_line(count: usize) -> String {
    if count == 1 {
        "1 song is now loved here.".to_owned()
    } else {
        format!("{count} songs are now loved here.")
    }
}

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

/// "arch is out of disk space"
pub fn disk_full_title(name: &str) -> String {
    format!("{name} is out of disk space")
}

pub const DISK_FULL_BODY: &str = "Free some up and Flaccy retries by itself.";

/// The line for a server with no disk space left.
pub fn disk_full_line(name: &str) -> String {
    format!("{}. {DISK_FULL_BODY}", disk_full_title(name))
}

/// "arch no longer accepts this device"
pub fn revoked_title(name: &str) -> String {
    format!("{name} no longer accepts this device")
}

pub const REVOKED_BODY: &str = "Disconnect it, then add the server again.";

/// The line for a server that stopped accepting this device.
pub fn revoked_line(name: &str) -> String {
    format!("{}. {REVOKED_BODY}", revoked_title(name))
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

/// "Is Tailscale on? Open Tailscale and connect on this device and on arch, then try again."
pub fn cant_reach_body(name: &str) -> String {
    format!("Is Tailscale on? Open Tailscale and connect on this device and on {name}, then try again.")
}

/// "Can't find arch"
pub fn cant_find_title(name: &str) -> String {
    format!("Can't find {name}")
}

pub const CANT_FIND_BODY: &str =
    "Check the name on the server with `tailscale status`, or paste the link from the server.";
pub const CODE_REFUSED_TITLE: &str = "That code didn't work";

/// "A code works once and expires after 10 minutes. On arch, run `flaccy-server enroll` for a new one."
pub fn code_refused_body(name: &str) -> String {
    format!("A code works once and expires after 10 minutes. On {name}, run `flaccy-server enroll` for a new one.")
}
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

#[cfg(test)]
mod tests {
    use super::*;

    fn names(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn song_counts_group_thousands_and_agree_with_their_noun() {
        assert_eq!(songs_text(0), "0 songs");
        assert_eq!(songs_text(1), "1 song");
        assert_eq!(songs_text(999), "999 songs");
        assert_eq!(songs_text(7_412), "7,412 songs");
        assert_eq!(songs_text(1_234_567), "1,234,567 songs");
    }

    #[test]
    fn the_merge_summary_reads_like_the_sheet_of_the_experience_contract() {
        assert_eq!(
            merge_playlists_line(&names(&["Road Trip", "Workout"])),
            "We combined your playlists. Road Trip and Workout were on both devices and are now one each."
        );
        assert_eq!(
            merge_playlists_line(&names(&["Road Trip"])),
            "We combined your playlists. Road Trip was on both devices and is now one."
        );
        assert_eq!(merge_loves_line(1), "1 song is now loved here.");
        assert_eq!(merge_loves_line(12), "12 songs are now loved here.");
    }

    #[test]
    fn long_lists_of_playlists_are_cut_short() {
        assert_eq!(names_in_a_sentence(&names(&["A", "B", "C"])), "A, B and C");
        assert_eq!(
            names_in_a_sentence(&names(&["A", "B", "C", "D", "E"])),
            "A, B, C and 2 more"
        );
    }

    #[test]
    fn the_server_row_adds_the_song_count_only_while_the_music_shows() {
        assert_eq!(
            row_subtitle("Synced just now", true, Some(40)),
            "Synced just now · 40 songs"
        );
        assert_eq!(row_subtitle("Synced just now", false, Some(40)), "Synced just now");
        assert_eq!(row_subtitle("Synced just now", true, None), "Synced just now");
    }

    #[test]
    fn the_library_line_names_what_is_wrong() {
        assert_eq!(library_line(true, Some(3), None, "arch"), "3 songs");
        assert_eq!(library_line(false, Some(3), None, "arch"), "Not shown in your library");
        assert_eq!(library_line(true, None, None, "arch"), "Counting songs…");
        assert_eq!(
            library_line(true, Some(3), Some(LibraryTrouble::Unreachable), "arch"),
            "3 songs · Can't reach arch. Is Tailscale on?"
        );
        assert_eq!(
            library_line(true, Some(3), Some(LibraryTrouble::SignedOut), "arch"),
            "3 songs · arch no longer accepts this device"
        );
    }

    #[test]
    fn the_disk_and_device_lines_are_their_title_and_body_together() {
        assert_eq!(
            disk_full_line("arch"),
            "arch is out of disk space. Free some up and Flaccy retries by itself."
        );
        assert_eq!(
            revoked_line("arch"),
            "arch no longer accepts this device. Disconnect it, then add the server again."
        );
    }

    #[test]
    fn the_two_connected_bodies_name_the_switch_when_the_music_is_missing() {
        assert!(CONNECTED_BODY.ends_with("under Servers."));
        assert!(connected_body_no_library("arch").contains("turn on Show arch's music in my library."));
    }
}
