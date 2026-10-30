<p align="center">
  <h1 align="center">flaccy</h1>
  <p align="center">The player for the music you own: iPhone, Apple Watch, Mac and Linux, with a free home server that keeps them in sync.</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS%2018.6+-blue?logo=apple" alt="iOS">
  <img src="https://img.shields.io/badge/watchOS%2011+-blue?logo=apple" alt="watchOS">
  <img src="https://img.shields.io/badge/macOS%2026+-blue?logo=apple" alt="macOS">
  <img src="https://img.shields.io/badge/Linux%20(GTK4)-yellow?logo=linux&logoColor=white" alt="Linux">
  <img src="https://img.shields.io/badge/Last.fm-red?logo=lastdotfm" alt="Last.fm">
</p>

<p align="center">
  <img src="screenshot.png" alt="flaccy" width="100%">
</p>

Point flaccy at your music. It plays FLAC, ALAC, WAV, AIFF, MP3 and AAC gaplessly, cleans up messy folder and file names with an AI pass (through the flaccy-api proxy, no key needed), and fills in artwork and metadata from Last.fm and Apple Music. No account, no upload, no streaming subscription.

## Platforms

| Platform | What it is | Get it |
|---|---|---|
| **iPhone + Apple Watch** | The full app, with a standalone Watch player that plays offline through AirPods | [App Store](https://apps.apple.com/app/id6787493695) |
| **Mac** | Native AppKit app with Liquid Glass, folder watching and a menu bar player; one purchase covers iPhone, Watch and Mac | [Mac App Store](https://apps.apple.com/app/id6787493695) |
| **Linux** | Native GTK4/libadwaita app with GStreamer, MPRIS and the same library, lyrics and equalizer; free | `yay -S flaccy-bin` or `curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh \| sh` |
| **Flaccy Server** | Free, GPL home server for the computer that holds your music, reached over Tailscale | [Setup guide](https://midgarcorp.cc/flaccy/server): `yay -S flaccy-server-bin`, `brew install guitaripod/tap/flaccy-server`, `.deb`/`.rpm`, Docker, or Share this Mac's library in Flaccy for Mac |

## Features

- **Flaccy Server.** Your computer becomes the home for playlists, loves and listening history, and streams its library to every device over your own Tailscale network. A new iPhone app asks where your music is and connects with one scan; the Mac can share its own library without a terminal. Playing from the server is free; syncing across Apple devices is Flaccy Pro; Linux syncs for free.
- **Home** opens where you left off: Continue, Jump Back In, mixes built from your own listening (Heavy Rotation, Crate Dig, On Repeat, Rediscover, Tonight's Spin, Library Radio) and On This Day. Every section can be reordered or hidden.
- **Playback.** Gapless across every format, codec and bit-depth badges, history-aware shuffle, endless autoplay from your own library, sleep timer, AirPlay, queue kept across launches, lock-screen and MPRIS controls.
- **Equalizer.** Drag the curve or use up to ten parametric filters, 16 presets you can audition before keeping, AutoEq and Equalizer APO import, one profile per output, automatic headroom, bit-perfect when flat. iPhone, Mac and Linux.
- **Library.** Albums, songs, artists and playlists with quick filters, Most Played over any range, folder watching on the Mac, and remote libraries from OpenSubsonic servers such as Navidrome.
- **Last.fm.** Scrobbling with an offline queue, your listening history in Stats, charts, a listening clock, Recap and Year in Music cards.
- **Synced lyrics** that fill word by word when the lyrics are word-timed, with per-song timing offsets and tap-to-seek. **Share Lyrics** turns chosen lines into a short video over the song itself, or a still card, in four templates and four sizes.
- **Discovery.** Stations from any song or artist, a wantlist that resolves when you own the album, and Songlink sharing.
- **Linux extras.** Music videos locked to your own audio, and Downloads from YouTube, SoundCloud and Bandcamp via `yt-dlp`.
- **Adaptive design.** The Mac and Linux apps retint to the cover that is playing; Liquid Glass on the Mac, a theme engine on Linux.

## Repository layout

```
App/ Features/ Resources/   iOS app (programmatic UIKit, MVVM), shared with the Mac where not excluded
Platforms/mac/              macOS app (AppKit)
Platforms/watch/            watchOS app (SwiftUI)
Core/FlaccyCore/            shared Swift package: library scanning, playback engine, models
Core/FlaccyServerCore/      the server's sync core, bound to Swift with UniFFI (Rust in linux/server-core)
Core/FlaccyServerEmbed/     the embedded server behind Share this Mac's library
linux/                      Linux app (Rust, GTK4, GStreamer), server/, server-core/ and their packaging
docs/server/                Flaccy Server protocol, experience and release notes
Tests/                      unit and UI tests
project.yml                 XcodeGen spec; flaccy.xcodeproj is generated and gitignored
```

## Build

Apple (Xcode 27, Rust from rustup):

```
cp App/Secrets.swift.example App/Secrets.swift   # optional Last.fm API key; requests are signed by flaccy-api
scripts/server-core/build.sh                      # FlaccyServerCore XCFramework
scripts/server-core/build-embed.sh                # FlaccyServerEmbed XCFramework (Mac)
xcodegen generate && open flaccy.xcodeproj
```

Linux (Rust 1.85+, GTK 4.18+, libadwaita 1.7+, GStreamer with `gst-libav` for AAC and ALAC):

```
cd linux && cargo build --release && ./install.sh
```

`yt-dlp` and `ffmpeg` are optional, for Downloads, music videos and Share Lyrics video. More in [linux/README.md](linux/README.md) and [docs/server/GUIDE.md](docs/server/GUIDE.md).

## License

GPL-3.0-only
