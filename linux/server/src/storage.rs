//! Telling local disks from network drives and SD cards, and how much room is left, from mount tables and `df`.

use std::path::{Path, PathBuf};

const NETWORK_TYPES: [&str; 20] = [
    "nfs", "nfs4", "cifs", "smb", "smb2", "smb3", "smbfs", "afpfs", "9p", "ceph", "glusterfs", "lustre", "ncpfs", "afs", "davfs", "webdav",
    "vboxsf", "fuse.sshfs", "fuse.rclone", "fuse.davfs",
];
const SD_CARD_PREFIX: &str = "/dev/mmcblk";

/// One line of a mount table.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mount {
    /// The device or remote path.
    pub device: String,
    /// Where it is mounted.
    pub point: PathBuf,
    /// The file system type, lower case.
    pub kind: String,
}

/// What a data folder sits on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Medium {
    /// An ordinary local disk.
    Local,
    /// A network file system of this type.
    Network(String),
    /// An SD card.
    SdCard,
    /// The mount table did not say.
    Unknown,
}

fn unescape_octal(field: &str) -> String {
    let mut text = String::new();
    let mut rest = field;
    while let Some(at) = rest.find('\\') {
        text.push_str(&rest[..at]);
        let digits = rest.get(at + 1..at + 4).filter(|digits| digits.bytes().all(|b| (b'0'..=b'7').contains(&b)));
        match digits.and_then(|digits| u8::from_str_radix(digits, 8).ok()) {
            Some(byte) => {
                text.push(byte as char);
                rest = &rest[at + 4..];
            }
            None => {
                text.push('\\');
                rest = &rest[at + 1..];
            }
        }
    }
    text.push_str(rest);
    text
}

/// Reads `/proc/mounts`: `device point type options dump pass` with octal escapes.
pub fn parse_proc_mounts(text: &str) -> Vec<Mount> {
    text.lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            let (device, point, kind) = (fields.next()?, fields.next()?, fields.next()?);
            Some(Mount { device: unescape_octal(device), point: PathBuf::from(unescape_octal(point)), kind: kind.to_ascii_lowercase() })
        })
        .collect()
}

/// Reads the output of macOS `mount`: `device on /point (type, option, ...)`.
pub fn parse_mount_output(text: &str) -> Vec<Mount> {
    text.lines()
        .filter_map(|line| {
            let (device, rest) = line.split_once(" on ")?;
            let (point, options) = rest.rsplit_once(" (")?;
            let kind = options.trim_end_matches(')').split(',').next()?.trim().to_ascii_lowercase();
            Some(Mount { device: device.to_owned(), point: PathBuf::from(point), kind })
        })
        .collect()
}

/// The mount that holds `path`: the one with the longest matching mount point.
pub fn mount_holding<'a>(path: &Path, mounts: &'a [Mount]) -> Option<&'a Mount> {
    mounts.iter().filter(|mount| path.starts_with(&mount.point)).max_by_key(|mount| mount.point.components().count())
}

/// What `path` sits on according to `mounts`.
pub fn medium_of(path: &Path, mounts: &[Mount]) -> Medium {
    let Some(mount) = mount_holding(path, mounts) else {
        return Medium::Unknown;
    };
    if NETWORK_TYPES.contains(&mount.kind.as_str()) || mount.device.starts_with("//") {
        Medium::Network(mount.kind.clone())
    } else if mount.device.starts_with(SD_CARD_PREFIX) {
        Medium::SdCard
    } else {
        Medium::Local
    }
}

/// The space available in the output of `df -Pk <path>`, in bytes.
pub fn available_bytes(df_output: &str) -> Option<u64> {
    let line = df_output.lines().filter(|line| !line.trim().is_empty()).nth(1)?;
    let kilobytes: u64 = line.split_whitespace().rev().nth(2)?.parse().ok()?;
    Some(kilobytes.saturating_mul(1024))
}

#[cfg(test)]
mod tests {
    use super::*;

    const PROC_MOUNTS: &str = concat!(
        "/dev/nvme0n1p2 / ext4 rw,relatime 0 0\n",
        "/dev/mmcblk0p1 /boot vfat rw 0 0\n",
        "nas:/export/media /mnt/media nfs4 rw,relatime 0 0\n",
        "//nas/share /mnt/share cifs rw 0 0\n",
        "/dev/sda1 /mnt/with\\040space ext4 rw 0 0\n",
        "sshfs#me@host:/ /mnt/remote fuse.sshfs rw 0 0\n",
        "tmpfs /run tmpfs rw 0 0\n",
    );

    const MAC_MOUNT: &str = concat!(
        "/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)\n",
        "/dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, protected)\n",
        "//marcus@nas._smb._tcp.local/media on /Volumes/media (smbfs, nodev, nosuid, mounted by marcus)\n",
        "nas:/export on /Volumes/export (nfs, nodev, nosuid)\n",
    );

    fn medium(mounts: &[Mount], path: &str) -> Medium {
        medium_of(Path::new(path), mounts)
    }

    #[test]
    fn linux_mounts_classify_by_the_longest_mount_point() {
        let mounts = parse_proc_mounts(PROC_MOUNTS);
        assert_eq!(medium(&mounts, "/home/me/.local/share/flaccy-server"), Medium::Local);
        assert_eq!(medium(&mounts, "/mnt/media/flaccy"), Medium::Network("nfs4".to_owned()));
        assert_eq!(medium(&mounts, "/mnt/share"), Medium::Network("cifs".to_owned()));
        assert_eq!(medium(&mounts, "/mnt/remote/data"), Medium::Network("fuse.sshfs".to_owned()));
        assert_eq!(medium(&mounts, "/boot/flaccy"), Medium::SdCard);
        assert_eq!(medium(&mounts, "/mnt/with space/db"), Medium::Local);
        assert_eq!(medium(&[], "/anywhere"), Medium::Unknown);
    }

    #[test]
    fn mac_mount_output_classifies_the_same_way() {
        let mounts = parse_mount_output(MAC_MOUNT);
        assert_eq!(medium(&mounts, "/Users/me/Library/Application Support/flaccy-server"), Medium::Local);
        assert_eq!(medium(&mounts, "/Volumes/media/x"), Medium::Network("smbfs".to_owned()));
        assert_eq!(medium(&mounts, "/Volumes/export"), Medium::Network("nfs".to_owned()));
    }

    #[test]
    fn a_path_only_matches_whole_components() {
        let mounts = parse_proc_mounts("/dev/sda1 / ext4 rw 0 0\nnas:/x /mnt/media nfs rw 0 0\n");
        assert_eq!(medium(&mounts, "/mnt/media2/data"), Medium::Local);
    }

    #[test]
    fn df_output_gives_available_bytes() {
        let output = "Filesystem     1024-blocks      Used Available Capacity Mounted on\n/dev/nvme0n1p2  1000000000 400000000 600000000      40% /\n";
        assert_eq!(available_bytes(output), Some(600_000_000 * 1024));
        assert_eq!(available_bytes("garbage"), None);
        assert_eq!(available_bytes(""), None);
    }
}
