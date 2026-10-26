# server-core Swift package

`linux/server-core` (Rust, the sync engine) reaches the iOS and Mac apps as the Swift package `Core/FlaccyServerCore`, bound with UniFFI (proc-macro mode, uniffi 0.32) through the thin crate `linux/server-core-ffi`. The watch and `flaccyMacLegacy` do not link it.

## Build
`scripts/server-core/build.sh` takes no arguments.
- On the Mac it builds the crate for macOS (arm64+x86_64), iOS device and iOS simulator (arm64+x86_64) with `build-xcframework.sh`, strips debug symbols, generates the Swift bindings from the host library and installs both into the package. Rust comes from `~/.cargo/bin`; intermediate output goes to `$SERVER_CORE_BUILD_DIR` (default `~/Dev/builds/flaccy-server-core/out`).
- On arch it rsyncs `linux/`, `scripts/server-core/` and `Core/FlaccyServerCore/` to `macbook:Dev/builds/flaccy-server-core/app`, runs itself there, and pulls the result back.
- The release profile is set by environment in `build.sh` (opt-level 3, no LTO, `strip` off, panic=unwind): Cargo ignores `[profile]` in a workspace member, and the workspace root's `lto = "thin"` and `strip = true` would remove the symbols the bindgen reads.

## Artifacts
- `Core/FlaccyServerCore/Artifacts/FlaccyServerCoreFFI.xcframework` (about 21 MB) is gitignored. Without it SwiftPM cannot resolve the package, so `xcodegen` plus `xcodebuild` need a prior `build.sh`.
- `Sources/FlaccyServerCoreBindings/flaccy_server_core_ffi.swift` is generated and committed. Regenerate it with `build.sh` whenever `server-core-ffi` or `server-core::json_api` changes; a stale file against a new library fails the UniFFI checksum check at first call.
- The path is not named `build` or `.build`, so buildvm's rsync of the project folder carries it. The ship flow must run `scripts/server-core/build.sh` before `buildvm build`, so the artifact is never stale (the guest has no Rust).

## Tests
- `cargo test -p flaccy-server-core-ffi --manifest-path linux/Cargo.toml` runs the wrapped functions natively and checks that `Tests/FlaccyServerCoreTests/Resources/cases.json` is current. Rewrite it with `FLACCY_WRITE_SWIFT_CASES=1` on the same command.
- `swift test` in `Core/FlaccyServerCore` (macOS) replays those cases through `ServerCore` and compares canonical JSON.

## Swift API
`import FlaccyServerCore`, then the `ServerCore` namespace: `applyPlaylist`, `applyScalar`, `rebasePlaylist`, `rebaseLove`, `rebaseRating`, `rebaseScalar`, `rebaseSession`, `between`, `songKey`, `suppressedFlags`, `nextStamp`, `version`. Inputs and outputs are `Codable & Sendable` structs; failures throw `ServerCoreError`.
