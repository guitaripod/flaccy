# flaccy-server

flaccy-server turns one person's music folder into an OpenSubsonic server. It
indexes the folder with the same library code as Flaccy and answers the
Subsonic REST API, so Flaccy on iPhone, Mac and Linux works with it, and so
does any Subsonic app. It runs headless: no GTK, no GStreamer.

It never phones home. It makes no outbound network requests and sends no
telemetry; it listens on the address you configure and reads your folder.

Licensed GPL-3.0.

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

    docker run -d -p 4545:4545 -v /path/to/music:/music:ro -v flaccy-data:/data ghcr.io/guitaripod/flaccy-server

`packaging/docker/compose.yaml` adds a Tailscale sidecar. Or build from a checkout:

    cargo install --path linux/server

which puts `flaccy-server` in `~/.cargo/bin`, where the bundled user unit expects it.

Converting a song to another format needs `ffmpeg` on the `PATH` of the
server. Playing the original file does not.

## Configure

The configuration lives at `~/.config/flaccy-server/config.toml`:

    music_folder = "/home/you/Music"
    address = "127.0.0.1"
    port = 4545
    data_dir = "/home/you/.local/share/flaccy-server"
    behind_proxy = false

Only `music_folder` is required. `address` defaults to `127.0.0.1`, `port` to
`4545` and `data_dir` to `~/.local/share/flaccy-server`, which holds the library
database, the credentials file, the cover cache and `flaccy.log`.

`behind_proxy` (default `false`) tells the server that a reverse proxy on this
machine, such as `tailscale serve`, is the only thing connecting to it. Failed
logins are then counted against the first address in `X-Forwarded-For` rather
than the proxy's address. Leave it `false` when clients connect directly: any
client can send any `X-Forwarded-For` value, so turning it on for a directly
reachable server lets a guesser dodge the lockout.

## Set up the account and a client

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
not the proxy, and restart the server.

## Run it as a service

    mkdir -p ~/.config/systemd/user
    cp apps/flaccy/linux/server/flaccy-server.service ~/.config/systemd/user/
    systemctl --user enable --now flaccy-server

The unit restarts the server after a failure and runs `flaccy-server serve`
from `~/.cargo/bin`. Edit `ExecStart` if the binary lives elsewhere.

By default a user service stops when you log out. To keep it running:

    loginctl enable-linger $USER

## Versions of a song

A re-export saved over an existing file keeps its song id, so playlists and
play counts survive it. The server gives each new mix of a song a higher
`flaccyRevision`; a client that sees the number go up knows a new mix arrived
and can fetch it. Playlist entries carry the same number.

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
  within ten minutes the message reads "Too many failed logins from <address>."
  Wait ten minutes, then check the credentials. If every client hits this
  at once behind a proxy, set `behind_proxy = true`.
- **41**: flaccy-server never sends this code. If you see it, the address you
  are using is not this server.
- **43**: the request carries both an API key and a user name. Send the key
  alone.
- **44**: the API key is unknown or was revoked. Make a new one with
  `flaccy-server key add <name>` and pair the device again.
- **70**: the song, album or playlist no longer exists, usually because the
  folder was rescanned. Refresh the client's library and pick it again.

The log is `flaccy.log` in the data folder. A lockout is written there when it
starts, with the address it applies to.
