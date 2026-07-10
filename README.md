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
| **iPhone** | The full app: gapless playback, AI organization, scrobbling, charts, Year in Music, wantlist, lyrics, stations | [App Store](https://apps.apple.com/app/id6787493695) |
| **Apple Watch** | Standalone phone-free player — sync tracks, play offline through AirPods | Bundled with the iOS app |
| **Mac** | Native AppKit app with Liquid Glass: full feature parity plus folder watching, menu bar player, media keys, multi-column sorting, keyboard-first browsing | Mac App Store — in review |
| **Linux** | Native GTK4/libadwaita player: gapless GStreamer playback, MPRIS media keys, scrobbling, synced lyrics, listening stats | `curl -fsSL https://raw.githubusercontent.com/guitaripod/flaccy/master/linux/get-flaccy.sh \| sh` or `yay -S flaccy-bin` |

## Features

### Playback
- **Gapless playback** across all supported formats — FLAC, M4A, AAC, ALAC, MP3, WAV, AIFF, CAF
- **Quality badges** — codec, bit depth, and sample rate on every track (FLAC · 24/96)
- **Shuffle & repeat** — history-aware weighted shuffle, repeat all, repeat one
- **Autoplay continuation** — the queue never ends; flaccy extends it from your own library
- **Sleep timer**, **AirPlay**, and **queue persistence** across launches
- Media keys, Control Center, and lock-screen controls (MPRIS on Linux)

### Library
- **Albums, Songs, Artists, Playlists** with search, sorting, and filter chips (Lossless / Hi-Res / Loved)
- **AI organization** — messy folder names and scene releases identified and cleaned automatically
- **Folder watching** (Mac) — files you add appear instantly, indexed in place from any folder
- **Context menus everywhere** — play next, queue, station, playlist, share, lyrics

### Last.fm
- **Scrobbling** with offline write-ahead queue and automatic retry — identical semantics on every platform
- **Loved tracks**, **charts by period**, listening clock, streak heatmap
- **Recap & Year in Music** — shareable story cards and posters (full-resolution export on Mac)
- Artist bios, album metadata enrichment, similar-artist discovery

### Discovery
- **Stations** — start a radio queue from any song, artist, or your whole library
- **Suggested playlists** — Heavy Rotation, On Repeat, Rediscover
- **Wantlist** — tracks albums you're hunting for, resolves automatically when you acquire them
- **Songlink sharing** — share any track as a universal link (Spotify, YouTube, Tidal, Apple Music…)

### Synced Lyrics
- LRCLIB karaoke-style scrolling, current line highlighted, click/tap any line to seek

## Repository layout

```
flaccy/                 iOS app (programmatic UIKit, MVVM) — many files shared with the Mac target
flaccyMac/              macOS app (programmatic AppKit, Liquid Glass, MVVM)
flaccyWatch Watch App/  standalone watchOS app (SwiftUI + Observation)
FlaccyCore/             shared SPM package: models, playback protocol, scanner, logging, sync contract
linux/                  Linux app (Rust, GTK4 + libadwaita + GStreamer + rusqlite)
scripts/                target generators (ruby xcodeproj): add_mac_target.rb, add_watch_target.rb
```

## Setup (Apple platforms)

```
git clone https://github.com/guitaripod/flaccy.git
cd flaccy
cp flaccy/Secrets.swift.example flaccy/Secrets.swift
# Edit Secrets.swift with your Last.fm API key (optional — app works without it)
open flaccy.xcodeproj
```

- [Last.fm](https://www.last.fm/api/account/create) — scrobbling, artist bios, album art, charts
- **MusicKit** — enable in the Apple Developer portal (Identifiers → your App ID → App Services → MusicKit). Used for Songlink sharing and Apple Music artwork fallback; degrades gracefully without it.
- AI metadata cleanup needs no key — it goes through the flaccy-api proxy Worker.

## Setup (Linux)

```
cd linux && cargo build --release
```

GTK4, libadwaita ≥ 1.7, and GStreamer (base + good plugins) required. Building without `FLACCY_LASTFM_KEY`/`FLACCY_LASTFM_SECRET` env vars just disables scrobbling. See [linux/README.md](linux/README.md).

## Stack

Apple: Programmatic UIKit & AppKit · SwiftUI (watch) · MVVM · GRDB (SQLite) · AVQueuePlayer · MusicKit · Combine — one dependency: [GRDB.swift](https://github.com/groue/GRDB.swift)

Linux: Rust · gtk4-rs + libadwaita · GStreamer (playbin3) · rusqlite · lofty · mpris-server

## Requirements

iOS 18.6+ / watchOS 11+ / macOS 26+ · Xcode 26+ — Linux: any distro with GTK 4.14+ (x86_64 prebuilt, or build from source)
