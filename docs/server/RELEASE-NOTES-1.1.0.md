# Flaccy Server 1.1.0

This release makes Flaccy Server run properly on a Mac, makes a sync push far cheaper, and makes the first scan of a big library show music within a minute instead of after hours.

## What changed

- **A Mac is a first-class home for the server.** macOS starts every process, a launchd agent included, with room for only 256 open files, so the server now raises its own limit at start and says so in the log. A socket path too long for the system is refused with the fix instead of "path must be shorter than SUN_LEN". The configuration and data folders named in messages and in the README are the ones the system really uses (`~/Library/Application Support/flaccy-server` on a Mac). `setup` tells you to choose Allow when macOS asks whether the server may accept incoming connections, and says where your music will show up. The test suites and a 40-minute chaos soak with eight clients now run on a Mac too.
- **A commit that survives a power cut on a Mac.** macOS `fsync` stops at the drive's cache, so the sync and security databases now flush the drive as well (`fullfsync`).
- **A push costs one commit, not one per change.** A 500-mutation push takes 5 ms instead of 389 ms on a Linux NVMe disk, and 13 ms instead of 1.8 s on a Mac. First connect of a large history is correspondingly quicker.
- **The first scan shows music early.** Tags are read eight files at a time, what is indexed is listed in the apps while the scan goes on, and the library is complete as soon as the tags are read: 7,412 songs on an exFAT SD card were listed in about a minute (the old scan had indexed 2,350 in 27 minutes, with nothing visible). Audio that has no checksum of its own (every MP3, Opus and WAV file, and any FLAC whose encoder left its MD5 empty) is fingerprinted afterwards in the background, a minute at a time, so new files in the music folder are never kept waiting behind it.
- **You can see how far a scan is.** The log says so every fifteen seconds, `flaccy-server status` shows `Scanning:` and the songs still to fingerprint, and the OpenSubsonic call `getScanStatus` answers for apps.

## Install

- Mac: `brew install guitaripod/tap/flaccy-server` (Apple silicon and Intel).
- Arch Linux: `yay -S flaccy-server-bin`.
- Debian, Ubuntu, Raspberry Pi OS: the `.deb`. Fedora and openSUSE: the `.rpm`. Both add a system service that runs as the `flaccy` user.
- Docker: `ghcr.io/guitaripod/flaccy-server`, or the `docker-amd64.tar.gz` attached here (`gunzip -c file | docker load`) if the registry image is not up yet.
- Anything else on Linux: the static `linux-x86_64` or `linux-aarch64` tarball, no libc needed.

Then run `flaccy-server setup` once. Verify downloads with `SHA256SUMS`. An existing 1.0.0 install upgrades in place; its databases are not changed.

## Known limits

- Easy mode is the only mode; `household` mode is refused at start.
- No built-in TLS. Use `tailscale serve` for HTTPS and set `behind_proxy = true`.
- No Windows service: `setup` tells you to run `flaccy-server serve` yourself.
- The macOS binaries are ad-hoc signed, not notarized. Homebrew installs them without a Gatekeeper prompt; a browser download needs `xattr -d com.apple.quarantine`.
- Syncing across Apple devices is part of Flaccy Pro; connecting, browsing and streaming are free.
- Songs whose title or artist has Nordic `ø æ` or Cyrillic `й ё` get a different song key on iPhone and Mac than on Linux, so their loves and ratings do not merge across the two until a later release.
- A song re-exported before its audio has been fingerprinted in the background is taken as the first version rather than flagged as a new mix.
- A Mac may ask whether to allow incoming connections the first time another device connects; until you choose Allow, other devices time out.
