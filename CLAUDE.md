# CLAUDE.md

## Setup
1. Copy `flaccy/Secrets.swift.example` to `flaccy/Secrets.swift`
2. Fill in your API keys:
   - **Last.fm**: Create an app at https://www.last.fm/api/account/create
   - **Groq**: Get a key at https://console.groq.com/keys
3. `Secrets.swift` is gitignored and will not be committed

## Key Technical Details
- **Database**: GRDB (SQLite) for library persistence, metadata, scrobble queue
- **AI**: Groq API (llama-3.3-70b) for music identification and metadata cleanup
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
