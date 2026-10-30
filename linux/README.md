# Flaccy for Linux

Lossless music player: GTK4/libadwaita, gapless GStreamer playback, MPRIS, Last.fm scrobbling. Free and GPL.

- **Home** opens where you left off, with mixes built from your own listening, Library Radio and On This Day; Customize Home reorders or hides any of it.
- **Equalizer** (Ctrl+E): drag the curve or use up to ten parametric bands, 16 presets you hover to hear, AutoEq and Equalizer APO import, a profile per output; untouched audio when off or flat.
- **Artwork editor** (right-click an album → Edit Artwork…): frame any cover from a file, the clipboard, a drop, the album's own images or a search of Apple Music, Deezer and the Cover Art Archive.
- **Lyrics** from lrclib or `.lrc`/`.elrc` files, filling word by word when word-timed, with per-song timing offsets. **Share Lyrics** saves a short video of chosen lines over the song (needs `ffmpeg`) or a still card.
- **Flaccy Server** (Preferences → Servers → Add Flaccy Server): open the `flaccy://server` link or type the address and code the server printed; playlists, loves and history sync for free, and its music joins your library. See the [setup guide](https://midgarcorp.cc/flaccy/server).
- **Other servers**: add an OpenSubsonic server such as Navidrome; its songs stream through a local cache (2 GB by default) so gapless playback and the equalizer still work, and Download keeps any of them on this computer.
- **Music video mode** (Now Playing → Video): the official video, streamed and locked to your own audio within a frame or two. Needs `yt-dlp`; a local Ollama model breaks ties when choosing the video.
- **Downloads** (Ctrl+D): paste a YouTube, SoundCloud or Bandcamp link and get tagged audio in your library. Needs `yt-dlp` and `ffmpeg`.
- **Adaptive theme** that retints the app to what is playing, or one of seven palettes.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh
```

Installs to `~/.local` (no sudo). x86_64, glibc ≥ 2.39 (Ubuntu 24.04+, Fedora 40+, Debian 13+, current Arch). On older or musl-based distros, use the AUR package (Arch) or build from source. Requires system GTK4, libadwaita, and GStreamer:

- Arch: `sudo pacman -S gtk4 libadwaita gstreamer gst-plugins-base gst-plugins-good gst-libav`
- Debian/Ubuntu: `sudo apt install libgtk-4-1 libadwaita-1-0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav`
- Fedora: `sudo dnf install gtk4 libadwaita gstreamer1 gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-libav`

`gst-libav` supplies the AAC/M4A/ALAC (and other ffmpeg-backed) decoders — without it, FLAC and MP3 play but AAC/M4A files won't. Flaccy names the missing codec in a toast if you hit one. Optional: `ffmpeg` for Share Lyrics video export.

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

Last.fm scrobbling needs the public API key at build time. Either export `FLACCY_LASTFM_KEY`, or drop it in `~/.config/flaccy/build-keys.env` (`FLACCY_KEYS_FILE` overrides the path) so every local build picks it up without the key ever touching the working copy:

```sh
FLACCY_LASTFM_KEY=<32 hex>
```

There is no secret to build with: requests are signed by flaccy-api (`POST /v1/lastfm/sign`, keyed by an anonymous device id kept in `~/.config/flaccy/device-id`), so scrobbling needs network access to it.

Without the key, or with anything but a real 32-character hex key, the app works and the scrobbling UI is hidden.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh -s -- --uninstall
```

(or `./install.sh --uninstall` from a source checkout / extracted tarball; `pacman -R flaccy-bin` for the AUR package)

## License

GPL-3.0-only. See [LICENSE](LICENSE).
