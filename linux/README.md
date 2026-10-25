# Flaccy for Linux

Lossless music player. GTK4/libadwaita, gapless GStreamer playback, a built-in equalizer, MPRIS, Last.fm scrobbling.

Home (the first page in the sidebar, and where Flaccy opens): resume the album or playlist
you were in, jump back into what you played lately, start a mix built from your own
listening or the endless Library Radio, see what's new in your library and what you were
playing on this day in earlier years. Customize Home (main menu) reorders or hides any of
it, and Preferences → Open at launch keeps opening where you left off instead.

Equalizer (Ctrl+E): drag the curve or switch to Advanced for up to ten bands, 16 presets
always in view beside the curve (hover one to hear it, click to keep it),
Equalizer APO / AutoEq import, a profile per output (it follows your default sink) and a
level-matched Hold to compare. With it off or flat the audio passes through untouched.

Album artwork (right-click an album → Edit Artwork…, or the pencil on its cover): frame any
cover in a square window — drag, wheel-zoom around the pointer, pinch, double-click for
2.5×, arrow keys and +/− to nudge, 0 to fit — with live album, list and player previews and
a warning when the crop is too small to stay sharp. Pick a picture from a file, the
clipboard (image, file or link), a drop, the images in the album's folders, the art
embedded in its tracks, or a search of Apple Music, Deezer and the Cover Art Archive.
Dropping an image on a cover or an album tile opens the editor with it already framed.
Nothing is written until Save; Use Original Artwork puts the files' own art back.

Lyrics (Now Playing → Lyrics, or the sidebar): synced lines from lrclib, or from a `.lrc` / `.elrc`
file beside the song or embedded in its tags. A line whose words are timed fills in as it is
sung, with a soft edge inside the word you are on; an instrumental gap of four seconds or more
shows three beats that light across it. The clock button shifts the lyrics earlier or later in
0.1 s steps, remembered per song, for tracks whose timestamps run off the singing. Click a line
to seek.

An adaptive theme engine retints the whole app with the dominant color of whatever's
playing — ambient gradient backdrops, glass surfaces, a glowing now-playing pulse — or
pick one of seven curated palettes in Preferences. Works in light and dark.

Music video mode (Now Playing → Video): Flaccy finds the song's official music video,
streams the picture, and locks it to the lossless file playing from your disk — your
audio, its video, in step to within a frame or two. It works out the video's head start
by listening to both recordings once, so a cold open or a spoken intro lines up on its
own; nudge buttons and a full candidate list are there when you disagree. Deciding which
result is the real music video — rather than a lyric video, a live take or a re-upload —
is done by a scorer that weighs the uploader, the wording and the reach, with a local
Ollama model breaking ties when the top two are close. Requires `yt-dlp`; Ollama is
optional and everything works without it.

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

Last.fm scrobbling needs the public API key at build time. Either export `FLACCY_LASTFM_KEY`, or drop it in `~/.config/flaccy/build-keys.env` (`FLACCY_KEYS_FILE` overrides the path) so every local build picks it up without the key ever touching the working copy:

```sh
FLACCY_LASTFM_KEY=<32 hex>
```

There is no secret to build with: requests are signed by flaccy-api (`POST /v1/lastfm/sign`, keyed by an anonymous device id kept in `~/.config/flaccy/device-id`), so scrobbling needs network access to it.

Without the key the app works fine and the scrobbling UI is hidden. A value that isn't a real 32-character hex credential is treated the same way rather than compiled in — a placeholder would otherwise build an app that offers scrobbling and then fails every submission.

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh | sh -s -- --uninstall
```

(or `./install.sh --uninstall` from a source checkout / extracted tarball; `pacman -R flaccy-bin` for the AUR package)

## License

GPL-3.0-only. See [LICENSE](LICENSE).
