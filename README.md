<p align="center">
  <h1 align="center">flaccy</h1>
  <p align="center">Lossless music player for iPhone, Apple Watch, Mac, and Linux. AI-organized. Last.fm connected. Share anywhere.</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS%2018.6+-blue?logo=apple" alt="iOS">
  <img src="https://img.shields.io/badge/watchOS%2011+-blue?logo=apple" alt="watchOS">
  <img src="https://img.shields.io/badge/macOS%2026+-blue?logo=apple" alt="macOS">
  <img src="https://img.shields.io/badge/Linux%20(GTK4)-yellow?logo=linux&logoColor=white" alt="Linux">
  <img src="https://img.shields.io/badge/Swift-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/rust-2021-brown?logo=rust" alt="Rust">
  <img src="https://img.shields.io/badge/Last.fm-red?logo=lastdotfm" alt="Last.fm">
</p>

<p align="center">
  <img src="screenshot.png" alt="flaccy" width="100%">
</p>

Point flaccy at your music files. It scans the directory structure, sends file paths to an LLM (Groq llama-3.3-70b via a proxy — no API key needed) to identify artists, albums, and track names, then fetches cover art and metadata from Last.fm and Apple Music. No manual tagging.

## Platforms

| Platform | What it is | Get it |
|---|---|---|
| **iPhone** | The full app: gapless playback, a real equalizer, AI organization, scrobbling, charts, Year in Music, wantlist, lyrics, stations | [App Store](https://apps.apple.com/app/id6787493695) |
| **Apple Watch** | Standalone phone-free player — sync tracks, play offline through AirPods | Bundled with the iOS app |
| **Mac** | Native AppKit app with Liquid Glass and an adaptive artwork palette that tints the whole window to what's playing: full feature parity plus the equalizer in its own window, folder watching, menu bar player, media keys, multi-column sorting, keyboard-first browsing | [Mac App Store](https://apps.apple.com/app/id6789594504) |
| **Linux** | Native GTK4/libadwaita player with an adaptive theme engine, gapless GStreamer playback, a built-in equalizer, MPRIS media keys, scrobbling, synced lyrics, listening stats | `curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh \| sh` or `yay -S flaccy-bin` |

## Features

### Home
- **Opens where you left off** — Continue resumes the album or playlist you were in, with a track-by-track progress bar and the time left
- **Jump Back In** — the albums, playlists, mixes and radios you started lately, one tap from playing
- **Made for You** — Heavy Rotation, Crate Dig, On Repeat, Rediscover, Tonight's Spin and an endless Library Radio, built from your own listening
- **On This Day** — the album you played most on this date in an earlier year, beside This Week's listening at a glance
- **Yours to arrange** — reorder or hide any section (Edit Home on iPhone, Customize Home on Mac and Linux); the desktop apps can keep opening where you left off
- **Worked out on your device** from your library and play history, offline

### Playback
- **Gapless playback** across all supported formats — FLAC, M4A, AAC, ALAC, MP3, WAV, AIFF, CAF
- **Quality badges** — codec, bit depth, and sample rate on every track (FLAC · 24/96)
- **Shuffle & repeat** — history-aware weighted shuffle, repeat all, repeat one
- **Autoplay continuation** — the queue never ends; flaccy extends it from your own library
- **Sleep timer**, **AirPlay**, and **queue persistence** across launches
- Media keys, Control Center, and lock-screen controls (MPRIS on Linux)

### Equalizer
- **Drag the curve** and hear it change (Simple: ten ISO bands, the curve passes through every point you place), or switch to **Advanced** for up to ten bells, shelves, high-pass, low-pass and notch filters with adjustable Q and a live spectrum behind the curve
- **16 presets you can hear before you keep them** — point at one on the Mac and Linux (or hold and slide across the strip on iPhone) and it plays at once, level-matched, with its curve drawn over yours; click to keep it — plus your own saved profiles, and **import and export of Equalizer APO and AutoEq text** to tune for your headphones
- **A profile per output** — AirPods, a wired DAC and the speakers each keep their own setting and switch when the route does
- **Automatic headroom** so boosts never clip, a **level-matched Hold to compare**, undo for every gesture, and no processing at all while it is off or flat (bit-perfect)
- iPhone, Mac (⌥⌘E) and Linux (Ctrl+E); not on Apple Watch

### Library
- **Albums, Songs, Artists, Playlists** with search, sorting, and quick-pivot chips (Favorites / Lossless / Recently Added / Recently Played / Rediscover) — on Mac and Linux the Songs list adds **Most Played over any time range** (7 days to all time), Play / Shuffle / Save as Playlist for whatever list is on screen, and a live song count and duration
- **AI organization** — messy folder names and scene releases identified and cleaned automatically (7-day trial, then one-time lifetime purchase via StoreKit)
- **Popular on every artist page** — Last.fm top tracks intersected with what you own (top 5)
- **Folder watching** (Mac) — files you add appear instantly, indexed in place from any folder
- **Context menus everywhere** — play next, queue, station, playlist, share, lyrics

### Last.fm
- **Scrobbling** with offline write-ahead queue and automatic retry — identical semantics on every platform
- **Loved tracks**, **charts by period** (Mac and Linux open on the last 7 days and show how plays and minutes moved against the period before), listening clock, streak heatmap
- **Recap & Year in Music** — shareable story cards and posters (full-resolution export on Mac)
- Artist bios, album metadata enrichment, similar-artist discovery

### Discovery
- **Stations** — start a radio queue from any song, artist, or your whole library
- **Suggested playlists** — Heavy Rotation, Crate Dig, On Repeat, Rediscover, and Tonight's Spin — built from your scrobble history intersected with the tracks you own
- **Wantlist** — tracks albums you're hunting for, resolves automatically when you acquire them
- **Songlink sharing** — share any track as a universal link (Spotify, YouTube, Tidal, Apple Music…)

### Synced Lyrics
- **Word by word** — a line whose words are timed fills in as it is sung, with a soft edge inside the word you are on. Timing comes from lrclib's Lyricsfile format (word timing is still rare there) or your own enhanced `.lrc`/`.elrc` files
- **Lines know where they end** — a line stops being lit when it ends, an instrumental gap of four seconds or more shows three beats that light across it, backing vocals are smaller, and a `♪` line is a break rather than a lyric
- **Timing control** — a clock button shifts the lyrics Earlier or Later in 0.1 s steps, remembered per song, for tracks whose timestamps run off the singing
- **Karaoke-style scrolling** that follows the singer; click/tap any line to seek
- **Finds lyrics for messy tags** — your `.lrc`/`.elrc` sidecar or embedded tag wins, then lrclib, which is also tried without "(Remastered)", "- 2011 Remaster" and featuring credits and asked again once when it is busy; same resolution on every client

### Music videos (Linux)
- **Video lens in Now Playing** — the song's official music video, streamed, with your lossless file still doing the playing
- **Locked to your audio** — the video's head start is measured by correlating both recordings' onsets, then held to within a frame or two for the whole song
- **Knows a music video from a lyric video** — uploader, wording, reach and runtime are scored together; a local Ollama model breaks ties, and nothing plays when nothing convinces

### Downloads (Linux)
- **Paste a link, get the music** — YouTube / YouTube Music / SoundCloud / Bandcamp — song, album, or playlist — best audio pulled via `yt-dlp`/`ffmpeg`, tagged, and dropped straight into your library (sidebar → Downloads, or Ctrl+D)

### Adaptive design
- **Color of what's playing** — Mac and Linux extract the dominant palette from the current cover and retint the whole app; ambient backdrops, glass surfaces, and accent everything follow the music
- **Liquid Glass** (Mac, AppKit `NSGlassEffectView`) and a **runtime theme engine** (Linux — Adaptive plus seven curated palettes)
- Immersive Now Playing over a blurred, palette-washed cover on every platform; light and dark throughout

## Repository layout

```
App/, Features/, Resources/  iOS app (programmatic UIKit, MVVM), shared with the Mac where not excluded
Platforms/mac/          macOS app (programmatic AppKit, Liquid Glass, MVVM)
Platforms/watch/        standalone watchOS app (SwiftUI + Observation)
Tests/                  unit and UI test targets
Core/FlaccyCore/        shared SPM package: LibraryScanner, TrackOrdering, LibraryLoadProgress,
                        AudioMetadataReader, MediaItem, AudioPlaybackEngine, logging categories, SyncProtocol
linux/                  Linux app (Rust, GTK4 + libadwaita + GStreamer + rusqlite + lofty + mpris-server)
marketing/              App Store screenshots (localized, 10 languages)
Design/                 app icon and screenshot compositors
scripts/                build-mac.sh (rsync + xcodebuild bridge), rc-setup.py, check-strings.py
project.yml             XcodeGen spec (iOS + Mac + Watch + test targets); flaccy.xcodeproj is generated and gitignored
```

## Setup (Apple platforms)

```
git clone https://github.com/guitaripod/flaccy.git
cd flaccy
cp App/Secrets.swift.example App/Secrets.swift
# Edit Secrets.swift with your Last.fm API key (optional — app works without it; the shared secret is never in the app, flaccy-api signs requests)
xcodegen generate
open flaccy.xcodeproj
```

- [Last.fm](https://www.last.fm/api/account/create) — scrobbling, artist bios, album art, charts
- **MusicKit** — enable in the Apple Developer portal (Identifiers → your App ID → App Services → MusicKit). Used for Songlink sharing and Apple Music artwork fallback; degrades gracefully without it.
- AI metadata cleanup needs no key — it goes through the flaccy-api proxy Worker (Groq llama-3.3-70b) and is gated behind the 7-day trial / lifetime purchase.
- Verify the Mac target from Linux: `scripts/build-mac.sh [ios|mac|watch]` rsyncs and builds over Tailscale.

## Setup (Linux)

```
cd linux
cargo build --release
./install.sh
```

Requires Rust 1.85+, GTK 4.18+, libadwaita ≥ 1.7, and GStreamer (base + good + `gst-libav` for AAC/M4A/ALAC). Without `gst-libav` FLAC and MP3 play but AAC/M4A won't — flaccy toasts the missing codec. Optional: `yt-dlp` + `ffmpeg` for Downloads and music videos, `ollama` to break ties when picking a video.

Building without the `FLACCY_LASTFM_KEY` env var just hides scrobbling (Last.fm requests are signed by flaccy-api, so there is no secret to supply). The key can also live in `~/.config/flaccy/build-keys.env` (`FLACCY_KEYS_FILE` overrides the path) so every local build picks it up without touching the working copy. See [linux/README.md](linux/README.md).

## Stack

Apple: Programmatic UIKit & AppKit · SwiftUI (watch) · MVVM · GRDB (SQLite) · AVQueuePlayer · MusicKit · StoreKit · Combine — dependencies: [GRDB.swift](https://github.com/groue/GRDB.swift), MidgarKit (`packages/MidgarKit` in the monorepo, by path), and local `FlaccyCore` SPM

Linux: Rust · gtk4-rs + libadwaita · GStreamer (playbin3 + gtk4 paintable) · rusqlite · lofty · mpris-server · cairo · serde/toml · image (jpeg/png/webp/bmp) — optional `yt-dlp`/`ffmpeg`/`ollama` at runtime

## Requirements

iOS 18.6+ / watchOS 11+ / macOS 26+ · Xcode 26+ — Linux: any distro with GTK 4.18+ / libadwaita 1.7+ / GStreamer + gst-libav (x86_64 prebuilt glibc ≥ 2.39, or build from source with Rust 1.85+)

## License

GPL-3.0-only
