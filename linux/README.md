# Flaccy for Linux

Lossless music player. GTK4/libadwaita, gapless GStreamer playback, MPRIS, Last.fm scrobbling.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh
```

Installs to `~/.local` (no sudo). x86_64 only. Requires system GTK4, libadwaita, and GStreamer:

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
