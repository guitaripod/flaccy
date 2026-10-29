<!-- DRAFT: edit these notes, then delete this line. scripts/server-release.sh publish refuses to run while it is here. -->
# Flaccy Server 1.0.0

Flaccy Server turns one music folder on a computer you own into an OpenSubsonic server, and keeps your playlists, loves, ratings and listening history in step across Flaccy on iPhone, Mac and Linux. It runs headless, sends no telemetry and makes no outbound requests unless you turn Last.fm on.

## What is in this release

- OpenSubsonic API under `/rest`: browse, search, stream the original file, covers, playlists, stars, ratings, play queue. Any Subsonic app works.
- Flaccy sync under `/flaccy/v1`: playlists, loves, ratings, preferences and listens per user, handed to every device they enrolled, with a live channel that pokes other devices and relays what is playing.
- Users and devices: roles admin, member, guest and pending; one-time enrollment codes with a QR code and link; per-device tokens that can be revoked; a tamper-evident audit trail (`audit verify`).
- Easy mode: listens on loopback and every Tailscale address of the machine and closes other connections unread. Host, origin and cross-site checks, login and enrollment lockouts, connection limits.
- `flaccy-server setup` (music folder, first scan, service, first QR code) and `flaccy-server doctor` (Tailscale, network, clock, disk, ffmpeg, databases, backups, devices).
- Nightly verified backups of the state and security databases, `restore`, and `export` to JSON, M3U8 and ListenBrainz-shaped JSONL.
- Optional Last.fm: bring in a history and scrobble for third-party apps. Off until you add a Last.fm API key.
- Conversion to AAC, Opus or MP3 through ffmpeg when you have it installed.

## Install

- Mac: `brew install guitaripod/tap/flaccy-server` (Apple silicon and Intel).
- Arch Linux: `yay -S flaccy-server-bin`.
- Debian, Ubuntu, Raspberry Pi OS: the `.deb`. Fedora and openSUSE: the `.rpm`. Both add a system service that runs as the `flaccy` user.
- Docker: `ghcr.io/guitaripod/flaccy-server`, or the `docker-amd64.tar.gz` attached here (`gunzip -c file | docker load`) if the registry image is not up yet.
- Anything else on Linux: the static `linux-x86_64` or `linux-aarch64` tarball, no libc needed.

Then run `flaccy-server setup` once. Verify downloads with `SHA256SUMS`.

## Known limits

- Easy mode is the only mode; `household` mode is refused at start.
- No built-in TLS. Use `tailscale serve` for HTTPS and set `behind_proxy = true`.
- No Windows service: `setup` tells you to run `flaccy-server serve` yourself.
- The macOS binaries are ad-hoc signed, not notarized. Homebrew installs them without a Gatekeeper prompt; a browser download needs `xattr -d com.apple.quarantine`.
- Syncing across Apple devices is part of Flaccy Pro; connecting, browsing and streaming are free.
