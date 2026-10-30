# flaccy-server

flaccy-server turns one person's music folder into an OpenSubsonic server. It
indexes the folder with the same library code as Flaccy and answers the
Subsonic REST API, so Flaccy on iPhone, Mac and Linux works with it, and so
does any Subsonic app. It runs headless: no GTK, no GStreamer.

It never phones home. It makes no outbound network requests and sends no
telemetry; it listens on this machine's Tailscale addresses and loopback, or the address you
configure, and reads your folder.

Licensed GPL-3.0.

## Quickstart

The short way, on a machine with Tailscale: install flaccy-server (below), then run

    flaccy-server setup

It asks where your music is, scans it, starts the server as a service (a systemd user unit on
Linux, a launchd agent on a Mac), and prints a QR code and link that enroll your first device.
`--yes` takes every default and asks nothing; `--music PATH`, `--name NAME` and `--port N` answer
the questions up front. Run it again at any time: it keeps your setup and only prints a new code.
`flaccy-server doctor` checks Tailscale, the network, the clock, the disk, ffmpeg, the databases,
backups and the enrolled devices, one line each, and exits 1 when something needs fixing.

The same steps by hand:

1. Install flaccy-server (below) and put your music folder in
   `~/.config/flaccy-server/config.toml`: `music_folder = "/home/you/Music"`.
2. Run `flaccy-server serve`, or start the service unit described below. The server
   listens in plain HTTP on this machine's Tailscale addresses and on loopback, and
   closes connections from anywhere else before reading them.
3. Run `flaccy-server enroll --user you`. On a server with no users yet this makes
   `you` its admin. It prints a QR code, a link and a one-time code, valid for ten
   minutes.
4. In Flaccy, add a server and scan the QR code, or open the link on the device. The
   device receives a token of its own, shown once.

The server keeps each user's playlists, loves, ratings, preferences and listens and
hands them to every device they enrolled; the wire contract is
`docs/server/PROTOCOL.md` and the calls live under `/flaccy/v1`. The OpenSubsonic API
under `/rest` keeps working for any Subsonic app, with the account described below.
What a Subsonic app stars, rates, plays, saves as a playlist or queues is the same data:
each API key writes as its own device (`opensubsonic:<key name>`), so a star in a
Subsonic app reaches the Flaccy apps of the same user and the other way round. The
playlists, stars, ratings, saved queue and plays the single-user server kept before
(in `library.sqlite`) are copied to the first admin once, the first time this version
starts; the old tables stay where they were.
A Flaccy device token also works as an OpenSubsonic API key, so the app can add the library without a second key.

## Install

On Arch, from the AUR (installs `/usr/bin/flaccy-server` and the user unit):

    yay -S flaccy-server-bin

Debian, Ubuntu, Fedora and openSUSE: install the `.deb` or `.rpm` from the `server-v*`
release on https://github.com/guitaripod/flaccy/releases. It adds a system service that runs as the
`flaccy` user; edit `/etc/flaccy-server/config.toml`, then `sudo systemctl enable --now flaccy-server`.
Run the commands below as `sudo -u flaccy flaccy-server --config /etc/flaccy-server/config.toml ...`.

Any other Linux (x86_64 or aarch64, any libc): download `flaccy-server-<version>-linux-<arch>.tar.gz`
from the same release. The binary is fully static; copy it somewhere on your `PATH`.

Docker, with the music folder mounted at `/music`:

    docker run -d -p 4545:4545 -e FLACCY_ADDRESS=0.0.0.0 -v /path/to/music:/music:ro -v flaccy-data:/data ghcr.io/guitaripod/flaccy-server

`FLACCY_ADDRESS=0.0.0.0` listens on every address, which a published port needs; without it the
image runs Easy mode and listens only on loopback and the container's Tailscale interface.

`packaging/docker/compose.yaml` adds a Tailscale sidecar. Or build from a checkout:

    cargo install --path linux/server

which puts `flaccy-server` in `~/.cargo/bin`, where the bundled user unit expects it.

Converting a song to another format needs `ffmpeg` on the `PATH` of the
server. Playing the original file does not. Three conversions run at once; a request that
finds them all busy for 20 seconds is answered `503` with `Retry-After`.

## Configure

The configuration lives at `~/.config/flaccy-server/config.toml` (on a Mac,
`~/Library/Application Support/flaccy-server/config.toml`):

    music_folder = "/home/you/Music"
    address = "127.0.0.1"
    port = 4545
    data_dir = "/home/you/.local/share/flaccy-server"
    behind_proxy = false
    mode = "easy"
    hosts = ["music.example.org"]
    backup_dir = "/mnt/nas/flaccy"

Only `music_folder` is required. `address` defaults to `127.0.0.1`, `port` to
`4545` and `data_dir` to `~/.local/share/flaccy-server` (on a Mac,
`~/Library/Application Support/flaccy-server`), which holds the library
database (`library.sqlite`), the users, devices and audit trail (`security.sqlite`),
the sync state (`state.sqlite`), the credentials file, the cover cache and
`flaccy.log`.

`mode` is `"easy"`, the default and the only mode in this release; `"household"` is
refused when the file loads. In easy mode `address` is superseded by the tailnet
binding: leave it at `127.0.0.1` and the server listens on loopback and every
Tailscale address of the machine, following the interfaces as they change. Set
`address` to anything else and the server listens only there (for example `0.0.0.0` in
a container), without the tailnet binding.

`hosts` (default none) lists names clients may put in the server URL besides the ones the server
always answers to: any IP address, a name without a dot (`arch`), `localhost`, this machine's own
names, and names ending in `.ts.net`, `.local`, `.lan`, `.home.arpa` or `.internal`. An entry is
an exact name or `*.example.com` for everything under a domain. The server answers
`403 browser_refused`, on `/rest` as well, to any other dotted name in `Host` (which is how a
DNS-rebinding page reaches a server), to a request that carries an `Origin` header, and to one a
page on another site made (`Sec-Fetch-Site: cross-site`). It never enables CORS, so a web page
cannot use it; use an app. Behind a proxy on your own domain, add the name the proxy forwards.

`behind_proxy` (default `false`) tells the server that a reverse proxy on this
machine, such as `tailscale serve`, is the only thing connecting to it. Failed
logins are then counted against the first address in `X-Forwarded-For` rather
than the proxy's address. Leave it `false` when clients connect directly: any
client can send any `X-Forwarded-For` value, so turning it on for a directly
reachable server lets a guesser dodge the lockout.

## Devices, users and the audit trail

    flaccy-server enroll --user NAME [--url URL] [--ttl 10m] [--json]
    flaccy-server user add NAME [--role member]
    flaccy-server user list
    flaccy-server user role NAME ROLE
    flaccy-server device list [--user NAME]
    flaccy-server device revoke ID
    flaccy-server audit verify
    flaccy-server status [--json]

`enroll` makes a code that works once and prints it with a `flaccy://server?...` link
and a QR code. `--url` is how the device reaches the server (default
`http://<this machine's name>:<port>`) and `--ttl` how long the code lasts (seconds,
or a number with `s`, `m` or `h`, at most 24 hours). With `--json` it prints
`{link, code, url, user, expiresAt}` and nothing else. A user must exist before
being enrolled, except on a server with no users, where the first enrollment creates
an admin.

Roles are `admin`, `member`, `guest` and `pending`. Members keep their own playlists,
loves, ratings and listens and can edit household playlists; guests read what is
shared with the household and store nothing; a pending user's devices may do nothing
until an admin gives the user a role. `device revoke` takes effect on the device's
next request. `audit verify` walks the hash chain that records every user, device and
role change and names the first entry that was edited or removed. `status` adds the
users, devices, change head, listen count and database sizes to its report, and
`--json` prints it as one JSON document.

A device token that matches nothing counts against the sender's address: ten in ten
minutes lock that address for ten minutes (`429`, `Retry-After`). Five wrong
enrollment codes in a minute from one address pause enrolling for that address for a minute,
and sixty from all addresses together pause it for everyone; one address's lock never blocks
another.

## Backups and restore

    flaccy-server backup [--to DIR]
    flaccy-server restore FILE
    flaccy-server export --user NAME --format json|m3u8|jsonl --out DIR

While `serve` runs it backs up at about 03:30 local time (plus or minus ten minutes)
into `backup_dir`, `<data_dir>/backups` unless you set it; point it at another disk
or a mounted share with `backup_dir = "/mnt/nas/flaccy"`, or turn the nightly backup
off with `backup_dir = ""`. A server that was off at 03:30 backs up five minutes
after it next starts. Each backup is `state-YYYYMMDD-HHMMSS.sqlite` (playlists,
loves, ratings, history) and `security-YYYYMMDD-HHMMSS.sqlite` (users, devices,
token hashes), made with SQLite's online backup, checked with
`PRAGMA integrity_check` and mode 0600. Keep the `security-` files as private as the
data folder; the `state-` files hold no secrets. Last.fm connections are not backed up;
reconnect with `flaccy-server lastfm connect`. The last 14 days and 8 weeks are
kept and older files are deleted only after a newer backup verified. `library.sqlite`
is not backed up: a scan rebuilds it. `backup` makes one now, while the server runs,
and `status` shows the last result under "Last backup". A failing nightly backup
logs a warning once a day and never stops the server.

`restore FILE` takes a `state-*.sqlite` and needs the server stopped: it refuses
while `serve` holds `server.lock` in the data folder. It checks the file, keeps
the current one as `state.before-restore-<time>.sqlite`, swaps the backup in, and
changes the server's incarnation. Users, devices, tokens and revocations stay as
they are. If `security.sqlite` is lost as well, copy a `security-*.sqlite` to the data
folder as `security.sqlite` first and restore after, so the new incarnation is the one
that stays. Devices see the new incarnation, then send again whatever the backup lacks.

`export` writes one user's data: `json` is one document of playlists, loves,
ratings, preferences and player sessions; `m3u8` is one playlist file per playlist
with paths relative to the output folder; `jsonl` is the listens in the shape
ListenBrainz imports. Exports never contain tokens or Last.fm keys.

## Set up the OpenSubsonic account and a client

Choose the account password (at least 8 characters):

    flaccy-server password set

Make an API key for each device. The key is shown once; store it now.

    flaccy-server key add "iPhone" --url https://<machine>.<tailnet>.ts.net

With `--url` the command prints a QR code. In Flaccy, add a server and scan
it. Other commands: `flaccy-server key list`, `flaccy-server key revoke <name>`
(the device is refused from its next request), `flaccy-server scan` (index the
folder once and exit) and `flaccy-server status`.

## HTTPS with Tailscale

Flaccy can use plain http on a network you trust, but over the internet use
HTTPS. With Tailscale, let `tailscale serve` terminate TLS and forward to the
server on the same machine:

    tailscale serve --bg http://127.0.0.1:4545

Then set `behind_proxy = true` in `config.toml`, so lockouts count clients,
not the proxy, and list the proxy's public name under `hosts`
(`hosts = ["<machine>.<tailnet>.ts.net"]`), because the proxy forwards it as the `Host`.
Restart the server.

## Run it as a service

`flaccy-server setup` installs it for you. By hand on Linux:

    mkdir -p ~/.config/systemd/user
    cp apps/flaccy/linux/server/flaccy-server.service ~/.config/systemd/user/
    systemctl --user enable --now flaccy-server

The unit restarts the server after a failure and runs `flaccy-server serve`
from `~/.cargo/bin`. Edit `ExecStart` if the binary lives elsewhere. It sets `LimitNOFILE=65536`;
without it the server logs a warning at start when the open-files limit is below what 512
connections need.

The server holds at most 512 connections, 64 per source address; the next one is closed unread
(logged once a minute), and when the server is full a device with few connections takes the place
of an idle connection of the address holding the most. A connection must deliver a request head
within 10 seconds of opening or of its first byte, and may idle 75 seconds between requests, so
stalled sockets cannot keep devices out.

By default a user service stops when you log out. `setup` offers to keep it running; by hand:

    loginctl enable-linger $USER

On a Mac `setup` writes `~/Library/LaunchAgents/cc.midgarcorp.flaccy-server.plist` and starts it
with `launchctl`. On Windows it says so and you run `flaccy-server serve` yourself.

While running, the server tidies itself once a day: it drops the stored results of mutations
older than 30 days (and beyond the newest 1,000 per device), empties the write-ahead logs and
refreshes the query statistics. A stop request (SIGTERM or Ctrl-C) closes the live sockets, lets
requests in flight finish and closes the databases.

## The live channel

`GET /flaccy/v1/live` is a WebSocket that tells a device when another device changed something
(a poke, after which it pulls) and relays what is playing and play, pause or skip commands between
one user's devices. See `docs/server/PROTOCOL.md` section 9. It needs a device token.

## Versions of a song

A re-export saved over an existing file keeps its song id, so playlists and
play counts survive it. The server gives each new mix of a song a higher
`flaccyRevision`; a client that sees the number go up knows a new mix arrived
and can fetch it. Playlist entries carry the same number.

## Last.fm

Two optional features, both off until `lastfm_api_key = "..."` is in `config.toml`
(or `FLACCY_LASTFM_KEY` is in the server's environment).

History: set the account whose history the server brings in, and Flaccy apps
that see the `lastfm.history` feature stop syncing it themselves.

    flaccy-server lastfm account --user marcus marcus_fm

The server reads the public history one page a second, resumes after a restart
and checks for late scrobbles once a day.

Scrobbling for other apps: plays that third-party OpenSubsonic clients report can
be sent to your Last.fm account by the server. Flaccy apps scrobble for themselves
and are never sent twice.

    flaccy-server lastfm connect --user marcus
    flaccy-server lastfm status
    flaccy-server lastfm disconnect --user marcus

If Last.fm stops accepting the connection the relay pauses, `lastfm status`
says why, and `lastfm connect` again resumes it.

## Troubleshooting

The server answers Subsonic error codes. Find the code your client shows:

- **0**: something failed that has no code of its own. For a conversion
  message that names ffmpeg, install it (`pacman -S ffmpeg` or
  `apt install ffmpeg`), make sure it is on the server's `PATH`, or ask the
  client for the original file (`format=raw`).
- **10**: the request left out a parameter. Usually the client is missing its
  user name, password, token or API key; check what the client has saved.
- **40**: the user name, password or token is wrong, or the server has no
  account yet (run `flaccy-server password set`). After ten failed logins
  of the same kind (passwords, or unknown API keys) within ten minutes the message reads "Too many failed logins from <address>."
  A good login with a different key does not clear it. Wait ten minutes, then check the credentials. If every client hits this
  at once behind a proxy, set `behind_proxy = true`.
- **41**: flaccy-server never sends this code. If you see it, the address you
  are using is not this server.
- **43**: the request carries both an API key and a user name. Send the key
  alone.
- **44**: the API key is unknown or was revoked. Make a new one with
  `flaccy-server key add <name>` and pair the device again.
- **50**: the user may not do that: a guest changes nothing, and only a
  household playlist's owner can delete it or change who sees it. Ask the admin
  for the `member` role.
- **70**: the song, album or playlist no longer exists, usually because the
  folder was rescanned. Refresh the client's library and pick it again.

Cover pictures are limited to 16 megapixels and 8192 pixels on a side (`413 too_large`), 50 MB per
user in all; `getCoverArt` sizes round up to 64, 128, 256, 512 or 1024 pixels, and images no
playlist uses as a cover are deleted a week after their upload by the daily tidy.

The log is `flaccy.log` in the data folder. A lockout is written there when it
starts, with the address it applies to.
