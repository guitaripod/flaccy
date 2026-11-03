# Flaccy Server 1.2.0

This release carries each song's own volume between your devices.

## What changed

- **A song's volume follows it everywhere.** Flaccy now lets you raise or lower any one song, from −12 to +12 dB in half-decibel steps, for the records mastered too quiet or too loud next to the rest. The server keeps that level as `gain/<songKey>` beside your playlists, loves and plays, so a song you turned up on Linux plays at the same level on every Flaccy connected to it. Levels are checked on the way in: a whole number of tenths of a decibel, at most 24 dB either way. A server older than 1.2.0 refuses the key, and the level then stays on the device that set it.

## Install

- Mac: `brew install guitaripod/tap/flaccy-server` (Apple silicon and Intel).
- Arch Linux: `yay -S flaccy-server-bin`.
- Debian, Ubuntu, Raspberry Pi OS: the `.deb`. Fedora and openSUSE: the `.rpm`. Both add a system service that runs as the `flaccy` user.
- Docker: `ghcr.io/guitaripod/flaccy-server`, or the `docker-amd64.tar.gz` attached here (`gunzip -c file | docker load`) if the registry image is not up yet.
- Anything else on Linux: the static `linux-x86_64` or `linux-aarch64` tarball, no libc needed.

Then run `flaccy-server setup` once. Verify downloads with `SHA256SUMS`. An existing 1.0.0 or 1.1.0 install upgrades in place; its databases are not changed.

## Known limits

- Flaccy for Linux sets song volumes from 1.27.0; the iPhone and Mac apps from their next release.
- Easy mode is the only mode; `household` mode is refused at start.
- No built-in TLS. Use `tailscale serve` for HTTPS and set `behind_proxy = true`.
- No Windows service: `setup` tells you to run `flaccy-server serve` yourself.
- The macOS binaries are ad-hoc signed, not notarized. Homebrew installs them without a Gatekeeper prompt; a browser download needs `xattr -d com.apple.quarantine`.
- Syncing across Apple devices is part of Flaccy Pro; connecting, browsing and streaming are free.
- Songs whose title or artist has Nordic `ø æ` or Cyrillic `й ё` get a different song key on iPhone and Mac than on Linux, so their loves, ratings and volumes do not merge across the two until a later release.
- A song re-exported before its audio has been fingerprinted in the background is taken as the first version rather than flagged as a new mix.
- A Mac may ask whether to allow incoming connections the first time another device connects; until you choose Allow, other devices time out.
