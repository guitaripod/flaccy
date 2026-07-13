# Flaccy for Linux

Lossless music player. GTK4/libadwaita, gapless GStreamer playback, MPRIS, Last.fm scrobbling.

An adaptive theme engine retints the whole app with the dominant color of whatever's
playing — ambient gradient backdrops, glass surfaces, a glowing now-playing pulse — or
pick one of seven curated palettes in Preferences. Works in light and dark.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh
```

Installs to `~/.local` (no sudo). x86_64, glibc ≥ 2.34 (Ubuntu 22.04+, Debian 12+, Fedora 35+, current Arch). On older or musl-based distros, build from source. Requires system GTK4, libadwaita, and GStreamer:

- Arch: `sudo pacman -S gtk4 libadwaita gstreamer gst-plugins-base gst-plugins-good`
- Debian/Ubuntu: `sudo apt install libgtk-4-1 libadwaita-1-0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good`
- Fedora: `sudo dnf install gtk4 libadwaita gstreamer1 gstreamer1-plugins-base gstreamer1-plugins-good`

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

Requires Rust 1.85+, gtk4/libadwaita/gstreamer development headers. Set `FLACCY_LASTFM_KEY` and `FLACCY_LASTFM_SECRET` at build time to enable Last.fm scrobbling — without them the app works fine but scrobbling is disabled.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh -s -- --uninstall
```

(or `./install.sh --uninstall` from a source checkout / extracted tarball; `pacman -R flaccy-bin` for the AUR package)

## License

GPL-3.0-only. See [LICENSE](LICENSE).
