<p align="center">
  <h1 align="center">flaccy</h1>
  <p align="center">Lossless music player for iOS. AI-organized. Last.fm connected. Share anywhere.</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS%2018.6+-blue?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.0-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/Groq%20LLM-purple" alt="AI">
  <img src="https://img.shields.io/badge/Last.fm-red?logo=lastdotfm" alt="Last.fm">
  <img src="https://img.shields.io/badge/MusicKit-pink?logo=apple" alt="MusicKit">
</p>

<p align="center">
  <img src="screenshot.png" alt="flaccy" width="100%">
</p>

Drop your music files onto your iPhone via USB or the Files app. flaccy scans the directory structure, sends file paths to a Groq LLM to identify artists, albums, and track names, then fetches cover art and metadata from Last.fm and Apple Music. No manual tagging.

## Features

### Playback
- **Gapless playback** with AVQueuePlayer across all supported formats
- **Audio formats** — FLAC, M4A, AAC, ALAC, MP3, WAV, AIFF, CAF
- **Shuffle & repeat** — shuffle queue, repeat all, repeat one
- **Sleep timer** — 15/30/45/60 minutes or end of current track
- **AirPlay** streaming to external speakers and devices
- **Dynamic Island** Live Activity with real-time track info
- **Queue persistence** — kill the app, relaunch, resume where you left off

### Library
- **Albums, Songs, Artists, Playlists** — four browsable tabs with search across all
- **Sorting** — albums by title/artist/year/recently added; songs by title/artist/recently played/date added; artists by name/album count
- **Alphabetical index** — quick-jump scrubber on list views
- **Recently played** — horizontal album carousel on the albums tab
- **Playlists** — create, reorder tracks, long-press to add from anywhere
- **Context menus everywhere** — play next, add to queue, add to playlist, share

### AI Library Organization
- **Groq LLM** (llama-3.3-70b) identifies music from file paths and scene release names
- Cleans metadata, assigns correct track numbers, identifies artists and albums
- Runs only on unanalyzed tracks — skips what's already been processed

### Last.fm
- **Scrobbling** — in-app OAuth, automatic scrobbles with offline queue and batch retry
- **Now playing** updates in real-time as you listen
- **Charts** — your Last.fm top tracks by period (week/month/3 months/6 months/year/all time), matched against your local library with play/shuffle
- **Artist bios** and album metadata enrichment

### Synced Lyrics
- Fetched from LRCLIB with karaoke-style scrolling display
- Current line highlighted, tap any line to seek
- Falls back to plain text lyrics or instrumental indicator

### Sharing via Songlink
- **Share any track or album** to streaming platforms via song.link
- Uses **MusicKit** to find tracks on Apple Music, then Songlink resolves links for Spotify, YouTube, Tidal, Amazon Music, Deezer, SoundCloud, and more
- **Streaming links sheet** — tap a platform to share its specific link, copy the universal link, or open the share sheet
- Available from every context menu, album headers, and the now playing screen

### Now Playing
- Full-screen artwork with swipe gestures (left/right for next/previous)
- Progress scrubbing with time display
- Tappable artist name navigates to artist detail
- Controls: AirPlay, sleep timer, share, lyrics, queue

### Album Art
- Cascade: embedded artwork → Last.fm → Apple Music (via MusicKit)
- Lazy loading — artwork fetched on demand per album, cached in memory
- SQLite-backed persistent storage

## Setup

```
git clone https://github.com/guitaripod/flaccy.git
cd flaccy
cp flaccy/Secrets.swift.example flaccy/Secrets.swift
# Edit Secrets.swift with your API keys
open flaccy.xcodeproj
```

**API keys** (both optional — app works without them):
- [Last.fm](https://www.last.fm/api/account/create) — scrobbling, artist bios, album art, charts
- [Groq](https://console.groq.com/keys) — AI metadata cleanup

**MusicKit** — enable in Apple Developer portal (Identifiers → your App ID → App Services → MusicKit). Required for Songlink sharing and Apple Music artwork fallback.

## Stack

Programmatic UIKit · MVVM · GRDB (SQLite) · AVQueuePlayer · MusicKit · ActivityKit · Combine

One dependency: [GRDB.swift](https://github.com/groue/GRDB.swift)

## Requirements

iOS 18.6+ · iPhone · Xcode 26+
