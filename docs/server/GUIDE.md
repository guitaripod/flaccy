# Flaccy Server in ten minutes

Flaccy Server keeps your playlists, loves and listening history in step across your iPhone, Mac and Linux, and shares the music on one computer with the others. It runs on a computer you own, your devices reach it through Tailscale, and nothing leaves your network. It is free and open source.

## What you need

- A computer that stays on and holds your music: a Mac, a Linux box, a Raspberry Pi, a NAS that runs Docker.
- [Tailscale](https://tailscale.com/download) (its free personal plan is enough) signed in on that computer and on each device that will connect.
- Flaccy on the devices. Syncing playlists, loves and history across Apple devices is part of Flaccy Pro; connecting, browsing and streaming are free, and the Linux app is free.

## 1. Install the server

| Where | Command |
|---|---|
| Mac | In Flaccy for Mac: Settings → Servers → **Share this Mac's library** (no terminal), or `brew install guitaripod/tap/flaccy-server` |
| Arch Linux | `yay -S flaccy-server-bin` |
| Debian, Ubuntu, Raspberry Pi OS | download the `.deb` from the latest `server-v…` release, then `sudo apt install ./flaccy-server_….deb` |
| Fedora | `sudo dnf install ./flaccy-server-….rpm` |
| Docker, Unraid, Synology, QNAP | `docker compose up -d` with the file in `linux/server/packaging/docker/` (it includes the Tailscale sidecar) |
| Anything else on Linux | unpack the static tarball and run `./flaccy-server` |

## 2. Set it up

    flaccy-server setup

It asks where your music is, scans it, starts the server in the background, keeps it running after you log out, and prints a QR code.

## 3. Connect a device

On the iPhone: Settings → Servers → Add → **Flaccy Server**, then scan the code. On a Mac or Linux: open the link `setup` printed, or paste it. The code works once and expires in ten minutes; `flaccy-server enroll` makes another.

Your server's music appears in your library under Servers. Playlists you already have, songs you loved and your listening history are combined with what the other devices have, and a card tells you what was merged.

## What happens when something is off

- **Tailscale is off on your phone:** Flaccy keeps working; changes queue and go when the server is reachable again. The status line under the server says what to do.
- **The server is off:** same. Nothing is lost.
- **You lose a device:** `flaccy-server device list`, then `flaccy-server device revoke <id>`; it stops working at its next request.
- **You get a new phone:** add the server again. Your playlists and history come back.

## Everyday commands

    flaccy-server status           what is running, who is connected
    flaccy-server doctor           checks Tailscale, the network, disk, ffmpeg and the databases
    flaccy-server enroll           a new code for another device
    flaccy-server user add NAME    another person in your household (their own playlists and history)
    flaccy-server backup           a verified backup now (a nightly one runs by itself)
    flaccy-server export --user NAME --format json|m3u8|jsonl --out DIR

Backups go to `backup_dir` (default: a `backups` folder in the server's data folder). Restoring is `flaccy-server restore FILE` with the server stopped; your devices notice and re-send anything newer than the backup.

## Privacy

The server stores your music index, playlists, loves, ratings and listens in files on your computer. It sends nothing anywhere: no telemetry, no accounts, no cloud. Connections arrive only over Tailscale. Last.fm is optional: `flaccy-server lastfm connect` lets the server scrobble plays from other Subsonic apps and import your history.

## Troubleshooting

| You see | Do this |
|---|---|
| Can't reach the server | Open Tailscale on the device and on the server's computer; run `tailscale status` and `flaccy-server doctor` on the server |
| That code didn't work | Codes work once and last ten minutes; run `flaccy-server enroll` again |
| The clock on the server is wrong | Fix the date and time on the server's computer (`timedatectl set-ntp true` on Linux) |
| Out of disk space | Free space on the server's computer; Flaccy retries by itself |
| A device was removed | Add the server again from that device |

More: `linux/server/README.md` (configuration and every command), `docs/server/PROTOCOL.md` (how it works).
