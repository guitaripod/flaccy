# CLAUDE.md

## Cross-client parity (read first)

**Flaccy is the product, not any single app.** It ships as four clients — iOS (`flaccy/`), macOS (`flaccyMac/`), watchOS (`flaccyWatch Watch App/`), and Linux (`linux/`, Rust + GTK) — and they must be **as great and in-sync as possible**. A feature, fix, or behavior that lands on one client is incomplete until it lands on the others (or the gap is deliberately recorded).

- **When you change behavior on one client, port it to all the others in the same unit of work.** If a client genuinely can't get it (platform limitation) or you can't verify it (e.g. no Xcode on this Linux box), say so explicitly and leave a tracked note — never silently ship a one-client fix.
- **Share logic, don't fork it.** The three Apple clients share `FlaccyCore` (pure Swift/Foundation where possible) — put cross-client logic there and route every call site through it instead of copy-pasting sorts/parsers. The Linux client is a separate Rust codebase, so it mirrors the same behavior in Rust; keep the two implementations semantically identical and cover both with tests.
- **Parity applies to behavior AND experience.** Ordering, grouping, metadata handling, naming, empty states, and the overall feel should match across clients, adapted to each platform's idioms (UIKit / AppKit / SwiftUI / GTK) — not reinvented.
- Pure shared logic (e.g. `FlaccyCore` ordering/parsing) can be compiled and unit-tested standalone on this Linux box via swiftly even when the full app can't build here — use that to verify cross-client logic before claiming it works.

### Recorded parity gaps

- **Vim-style list navigation (`j`/`k` scroll, `gg` top, `Shift+G` bottom) is Linux-only** (`linux/src/ui/window.rs` capture-phase keyboard handler + the `Ui` scroller registry). Deliberate platform idiom: AppKit lists already have native keyboard scrolling on macOS, and iOS navigates by touch with the A-Z section index. Search opens via Ctrl+F on Linux and Cmd+F on macOS only — there is deliberately no type-to-search. The cross-client *behavior* — changing any sort snaps the list back to the top — is implemented on all three clients.
- **Downloads (paste a YouTube/etc. link → best audio → library) is Linux-only** (`linux/src/downloads.rs`, `linux/src/ui/downloads.rs`, shipped 1.6.0). Deliberate: it shells out to `yt-dlp`/`ffmpeg`, which iOS/watchOS cannot run, and an App Store build that rips YouTube audio would violate App Review Guideline 5.2.3 regardless of implementation. If this ever comes to the Apple side, it needs a different design (e.g. user-provided files via the existing document-picker import, or a Mac-only build outside the App Store) — do not port the yt-dlp approach.

## Setup
1. Copy `flaccy/Secrets.swift.example` to `flaccy/Secrets.swift`
2. Fill in your API keys:
   - **Last.fm**: Create an app at https://www.last.fm/api/account/create
3. `Secrets.swift` is gitignored and will not be committed

## Key Technical Details
- **Database**: GRDB (SQLite) for library persistence, metadata, scrobble queue
- **AI**: Groq (llama-3.3-70b) via the flaccy-api proxy Worker (guitaripod/flaccy-api, flaccy-api.midgarcorp.cc) for music identification and metadata cleanup — no API key in the app
- **Scrobbling**: Last.fm API with ASWebAuthenticationSession OAuth
- **Audio**: AVQueuePlayer for gapless FLAC playback
- **UI Pattern**: Fully programmatic UIKit (no storyboards/XIBs)
- **Architecture**: MVVM pattern throughout
- **Target**: iOS 18, iPhone only
- **Scene Management**: Root view controller set programmatically in `SceneDelegate.scene(_:willConnectTo:options:)`

## Development Patterns
- Follow the existing programmatic UI approach - no Interface Builder
- Use UIStackView's heavily to simplify the layout code. UIStackView's are very configurable and performant.
- Always use the latest UIKit APIs like diffable datasource
- Use MVVM architecture for all screens
- UIKit only - No SwiftUI
- Keep view controllers focused - delegate business logic to view models. Use latest UIKit API like diffable datasource etc.
- Prefer Protocol-Oriented-Programming over Object-Oriented-Programming
- **Logging**: Use `AppLogger` for all logging - never use `print()` statements. AppLogger provides structured logging with categories (auth, database, content, sync, learning, gamification, purchases, ui, viewModel, mlx, performance, general)
- **Code Style**: Never use comments or MARK statements - code should be self-documenting through clear naming and structure

## UI/UX Guidelines
- Beautiful, modern design. You are a master iOS designer. Design of the year award winner app.
- Haptic feedback for all interactions, but according to Apple's Human Interface Guidelines
