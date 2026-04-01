<p align="center">
  <h1 align="center">flaccy</h1>
  <p align="center">A FLAC music player for iOS with AI-powered library management</p>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2018.6+-blue?logo=apple" alt="Platform">
  <img src="https://img.shields.io/badge/swift-5.0-orange?logo=swift" alt="Swift">
  <img src="https://img.shields.io/badge/UIKit-programmatic-green" alt="UIKit">
  <img src="https://img.shields.io/badge/AI-Groq%20LLM-purple" alt="AI">
  <img src="https://img.shields.io/badge/scrobbling-Last.fm-red?logo=lastdotfm" alt="Last.fm">
</p>

---

<p align="center">
  <img src="screenshot.png" alt="flaccy screenshots" width="100%">
</p>

flaccy is a native iOS music player built for audiophiles who collect FLAC files. It uses AI to automatically identify, organize, and clean up music metadata from messy file collections — no manual tagging required.

## Features

**Playback**
- Gapless FLAC playback via AVQueuePlayer
- Background audio with lock screen and Control Center controls
- Shuffle, repeat (off/all/one), queue management
- Sleep timer (15/30/45/60 min or end of track)
- AirPlay support
- Accurate scrubbing with chaseTime pattern

**Library**
- Import FLAC files via Files app or USB/Lightning file transfer
- Recursive directory scanning
- 3-column album grid, artist browsing, songs list, playlists
- Search across albums, artists, and track titles
- Recently played albums
- Album detail with hero artwork, play/shuffle, track listing

**AI-Powered Metadata**
- Groq LLM (llama-3.3-70b) identifies music from file paths and cleans up track names
- Batched per-album analysis with automatic rate limit retry
- Album art fetched from Last.fm and iTunes Search API
- Artist info and album metadata enrichment

**Last.fm Integration**
- In-app OAuth via ASWebAuthenticationSession
- Automatic scrobbling (4 min or 50% threshold)
- Now playing updates
- Offline scrobble queue with retry

**UI/UX**
- Programmatic UIKit — no storyboards
- Floating mini player with album-tinted progress fill
- Swipe gestures on now playing artwork to skip tracks
- Context menus on albums (play, shuffle, play next, add to queue)
- Toast notifications for user feedback
- Haptic feedback throughout

## Setup

1. Clone the repo
2. Copy `flaccy/Secrets.swift.example` to `flaccy/Secrets.swift`
3. Fill in your API keys:
   - **Last.fm** — create an app at [last.fm/api/account/create](https://www.last.fm/api/account/create)
   - **Groq** — get a key at [console.groq.com/keys](https://console.groq.com/keys)
4. Open `flaccy.xcodeproj` in Xcode
5. Build and run

Both API keys are optional — the app works without them, just without AI metadata cleanup and scrobbling.

## Architecture

```
Models:        Track, Album, ArtistItem, LibraryItem
Database:      DatabaseManager (GRDB — tracks, artists, albumInfo, scrobbles, playlists)
Services:      MetadataService, MetadataEnrichmentService, LastFMService, GroqService, ImageCache
Audio:         AudioPlayer (AVQueuePlayer, gapless, scrobbling, remote commands)
ViewModels:    LibraryViewModel, NowPlayingViewModel
Views:         LibraryVC, AlbumDetailVC, ArtistAlbumsVC, NowPlayingVC, QueueVC, PlaylistDetailVC, SettingsVC
```

## Dependencies

- [GRDB.swift](https://github.com/groue/GRDB.swift) — SQLite database

No other third-party dependencies.

## Requirements

- iOS 18.6+
- iPhone only
- Xcode 26+

