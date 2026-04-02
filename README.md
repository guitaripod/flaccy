<p align="center">
  <h1 align="center">flaccy</h1>
  <p align="center">FLAC player for iOS. AI-organized. Last.fm connected.</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS%2018.6+-blue?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.0-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/Groq%20LLM-purple" alt="AI">
  <img src="https://img.shields.io/badge/Last.fm-red?logo=lastdotfm" alt="Last.fm">
</p>

<p align="center">
  <img src="screenshot.png" alt="flaccy" width="100%">
</p>

Drop your FLAC files onto your iPhone via USB or the Files app. flaccy scans the directory structure, sends file paths to a Groq LLM to identify artists, albums, and track names, then fetches cover art from Last.fm and iTunes. No manual tagging.

## What it does

- **Plays FLAC** with background audio, lock screen controls, AirPlay, and Live Activity on Dynamic Island
- **AI library organization** — Groq's llama-3.3-70b identifies music from file paths and scene release names, cleans metadata, assigns correct track numbers
- **Last.fm scrobbling** — in-app OAuth, automatic scrobbles, offline queue with retry
- **Synced lyrics** — fetched from LRCLIB, karaoke-style scrolling display with tap-to-seek
- **Album art** — cascade: Last.fm → iTunes Search API, cached in SQLite
- **Artist profiles** — bios from Last.fm, tappable artist names everywhere
- **Queue management** — play next, add to queue, drag to reorder, swipe to remove
- **Playlists** — create, reorder, long-press tracks to add
- **Shuffle, repeat, sleep timer** with countdown in the floating mini player
- **Search** across albums, artists, songs — searching a track name surfaces its album
- **Queue persistence** — kill the app, relaunch, resume where you left off

## Setup

```
git clone https://github.com/guitaripod/flaccy.git
cd flaccy
cp flaccy/Secrets.swift.example flaccy/Secrets.swift
# Edit Secrets.swift with your API keys
open flaccy.xcodeproj
```

**API keys** (both optional — app works without them):
- [Last.fm](https://www.last.fm/api/account/create) — for scrobbling, artist bios, album art
- [Groq](https://console.groq.com/keys) — for AI metadata cleanup

## Stack

Programmatic UIKit · MVVM · GRDB (SQLite) · AVQueuePlayer · ActivityKit · Combine

One dependency: [GRDB.swift](https://github.com/groue/GRDB.swift)

## Requirements

iOS 18.6+ · iPhone · Xcode 26+
