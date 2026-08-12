# Flaccy for Linux

Lossless music player. GTK4/libadwaita, gapless GStreamer playback, MPRIS, Last.fm scrobbling.

An adaptive theme engine retints the whole app with the dominant color of whatever's
playing — ambient gradient backdrops, glass surfaces, a glowing now-playing pulse — or
pick one of seven curated palettes in Preferences. Works in light and dark.

Downloads (sidebar → Downloads, or Ctrl+D): paste a YouTube / YouTube Music /
SoundCloud / Bandcamp link — a song, an album, or a whole playlist — and Flaccy pulls
the best available audio, tags it (title, artist, album, track number, cover art), and
drops it straight into your library. Requires `yt-dlp` and `ffmpeg`; the page walks you
through the one-minute setup if they're missing.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh
```

Installs to `~/.local` (no sudo). x86_64, glibc ≥ 2.39 (Ubuntu 24.04+, Fedora 40+, Debian 13+, current Arch). On older or musl-based distros, use the AUR package (Arch) or build from source. Requires system GTK4, libadwaita, and GStreamer:

- Arch: `sudo pacman -S gtk4 libadwaita gstreamer gst-plugins-base gst-plugins-good gst-libav`
- Debian/Ubuntu: `sudo apt install libgtk-4-1 libadwaita-1-0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav`
- Fedora: `sudo dnf install gtk4 libadwaita gstreamer1 gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-libav`

`gst-libav` supplies the AAC/M4A/ALAC (and other ffmpeg-backed) decoders — without it, FLAC and MP3 play but AAC/M4A files won't. Flaccy names the missing codec in a toast if you hit one.

### Arch (AUR)

```sh
yay -S flaccy-bin
```

## Build from source

```sh
cd linux
cargo build --release
./install.sh
```

Requires Rust 1.85+, gtk4/libadwaita/gstreamer development headers.

Last.fm scrobbling needs its API credentials at build time. Either export `FLACCY_LASTFM_KEY` and `FLACCY_LASTFM_SECRET`, or drop them in `~/.config/flaccy/build-keys.env` (`FLACCY_KEYS_FILE` overrides the path) so every local build picks them up without the keys ever touching the working copy:

```sh
FLACCY_LASTFM_KEY=<32 hex>
FLACCY_LASTFM_SECRET=<32 hex>
```

Without them the app works fine and the scrobbling UI is hidden. A value that isn't a real 32-character hex credential is treated the same way rather than compiled in — a placeholder would otherwise build an app that offers scrobbling and then fails every submission with "Invalid method signature".

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh -s -- --uninstall
```

(or `./install.sh --uninstall` from a source checkout / extracted tarball; `pacman -R flaccy-bin` for the AUR package)

## License

GPL-3.0-only. See [LICENSE](LICENSE).
