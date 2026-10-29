# Embedding the server in the Mac app

The sandboxed Flaccy Mac app hosts `flaccy-server` in its own process ("Share this Mac's library"), because no Developer ID exists for a separate daemon. Code: `linux/server/src/embed.rs` (Rust API), `linux/server-embed-ffi` (UniFFI), `Core/FlaccyServerEmbed` (Swift package, macOS only). Build the XCFramework with `scripts/server-core/build-embed.sh`; `swift test` runs in `Core/FlaccyServerEmbed` on the Mac.

## API
- Rust: `EmbeddedServer::start(EmbedConfig { music_folder, data_dir, name, port, ffmpeg, log_dir }) -> Result<Handle, EmbedError>` checks the folder, takes the data-folder lock and returns at once; the databases, migrations and listener come up on the server's own threads, so a failure there shows as `state: error` in the status, not as an error from `start`.
- `Handle`: `wait_until_running(timeout)`, `is_running()`, `bound_addresses()`, `status_json()`, `create_enrollment(user) -> {link, code, url, user, expiresAt}` (owner `owner`, an admin, unless a user is named; ten minutes), `stop()` (stops accepting, gives open requests ten seconds, empties the write-ahead logs, joins the threads).
- Same code as `serve`: `hosting::run` opens the state, runs the scanner and watcher, nightly backup, maintenance and Last.fm workers, binds loopback plus the tailnet addresses (Easy mode) and closes the databases. Differences: no signal handlers, nothing printed, `flaccy.log` in `log_dir`, the name replaces the host name in `hello` and enrollment links, one embedded server per process.
- UniFFI: `embed_start(configJson)`, `embed_stop()`, `embed_status()`, `embed_enroll(user)`, `embed_version()`; all JSON, all throwing, idempotent. Swift: `FlaccyServerHost().start(musicFolder:name:)`, `status()`, `enroll(user:)`, `stop()`. Status `state` is starting, running, stopped or error, with `addresses`, `urls`, `deviceCount`, `songCount`, `lastError`.

## Entitlements (flaccyMac)
Added: `com.apple.security.network.server` (incoming connections; without it `bind` fails with EPERM). Already present and used: `app-sandbox`, `network.client`, `files.user-selected.read-write`, `files.bookmarks.app-scope`. Nothing else is needed: the data and log folders live in the container.

## Folder access contract
The caller resolves its security-scoped bookmark and calls `startAccessingSecurityScopedResource()` before `start`, and keeps it open until `stop()` has returned; the server reads and watches the folder with ordinary file calls and never sees a bookmark. If access ends early, scans fail and the status reports it.

## Shutdown
Call `stop()` from `applicationShouldTerminate` (reply `.terminateLater`, stop off the main thread, then reply). It takes at most ten seconds plus a moment; killing the app instead is safe for the databases (SQLite journals) but drops open requests. Sharing off in settings is the same call.

## Not available
ffmpeg conversion (a sandboxed app cannot bundle or find one; `stream` with a format other than `raw` answers an OpenSubsonic error, a bit-rate limit alone sends the original), the `setup`, `doctor`, `service`, `password`, `key`, `backup`, `restore` and `export` commands (the app owns those flows), Household mode, a custom bind address, the configuration file, and signal-driven shutdown.

## In the Mac app
- Settings → Servers → **Share this Mac's library** is a switch kept in `UserDefaults` (`flaccy.mac.shareLibrary`); the server starts at launch while it is on. `LibrarySharing` in this package owns the life of the server: it holds the music folder open through the library's security-scoped bookmark until `stop()` has returned, starts on the port used last time (so paired devices keep working), then 4545 and the next free ones, checks the server every five seconds and starts it again after sleep or a crash (three tries), and restarts it when the library folder changes. The first time the switch goes on, a sheet says what sharing means.
- The app side is `Platforms/mac/Sharing` (folder access, port probe, the enroller) and `Platforms/mac/UI/Servers` (the section, the Add a device sheet with its QR code, the Add Flaccy Server and detail sheets, the merge summary). `applicationShouldTerminate` stops the server before the app quits.
- The Mac enrolls itself as a device of its own server over loopback with a code from `enroll()`, through the same engine as any other server, so its playlists, loves and plays sync like a phone's. It does this only when it syncs with no Flaccy Server or with its own: the engine follows one server, and sharing never takes it over. Its own server is never added to the library as a remote one (`FlaccyServerLibrary.isThisDevicesOwn`), since its songs are already there.
- Without Tailscale the server listens on loopback only; the section says so and offers Tailscale's download. If a code was made a minute ago (and not more than ten) and no device has joined, the section and the Add a device sheet add the hint to choose Allow when macOS asks about incoming connections. The status gives no count of connections, so this is a guess from the device count.
- An ad-hoc signed test build under another bundle id needs its own entry in System Settings → Network → Firewall, or `socketfilterfw --add <app>` and `--unblockapp <app>` (remove it with `--remove` afterwards): until the firewall's prompt is answered, other devices time out while this Mac still reaches the server on loopback.
