# flaccy-server packaging

Everything here is built by one script from the `apps/flaccy` directory:

    scripts/server-release.sh all

It reads the version from `linux/server/Cargo.toml`, refuses a dirty git tree
(`--allow-dirty` overrides) and writes to `~/.cache/flaccy-server-release/<version>/`.
It builds and verifies only; nothing is pushed unless `docker --push --publish` is given.
Needs `zig`, `cargo-zigbuild`, `cargo-deb`, `cargo-generate-rpm` and `docker`.

| Artifact | What it is | Command |
| --- | --- | --- |
| `flaccy-server-<v>-linux-{x86_64,aarch64}.tar.gz` | Fully static musl binary, user unit, README, LICENSE | `scripts/server-release.sh build` |
| `flaccy-server_<v>-1_{amd64,arm64}.deb` | Debian and Ubuntu package, system service as user `flaccy` | `scripts/server-release.sh deb` |
| `flaccy-server-<v>-1.{x86_64,aarch64}.rpm` | Fedora, RHEL and openSUSE package, same layout | `scripts/server-release.sh rpm` |
| `ghcr.io/guitaripod/flaccy-server:<v>` | Alpine image with ffmpeg, runs as uid 1000 | `scripts/server-release.sh docker` |
| `SHA256SUMS`, `packaging/PKGBUILD`, `packaging/flaccy-server.rb` | Checksums, and the two templates below filled in | `scripts/server-release.sh checksums` |

Sources in this directory:

- `PKGBUILD`: AUR package `flaccy-server-bin`, installs the static tarball.
- `homebrew/flaccy-server.rb`: formula for macOS arm64 and x86_64 with a launchd `service` block. The
  macOS tarballs are built on a Mac and copied into the release directory before `checksums`.
- `docker/`: `Dockerfile`, `entrypoint.sh`, and `compose.yaml` with a Tailscale sidecar
  (copy `env.example` to `.env` and add your own `TS_AUTHKEY`; `serve.json` publishes HTTPS on the tailnet).
- `systemd/`, `sysusers.d/`, `tmpfiles.d/`, `config.toml`, `scripts/`: the system service, its
  `flaccy` user, state directory, default `/etc/flaccy-server/config.toml` and package scripts.

Environment variables of the image: `FLACCY_MUSIC_FOLDER` (`/music`), `FLACCY_DATA_DIR` (`/data`),
`FLACCY_PORT` (`4545`), `FLACCY_BEHIND_PROXY` (`false`), `FLACCY_HOSTS` (comma separated host names
or `*.example.com` patterns, none by default) and `FLACCY_ADDRESS` (unset). They fill
`/data/config.toml` on every start unless a config file of your own is mounted there; the file
always has `mode = "easy"` and the port, and has `address` only when `FLACCY_ADDRESS` is set.

Easy mode is the default: the server listens on loopback and every Tailscale interface of the
container, following the interfaces as they come up, and closes connections from anywhere else.
In `compose.yaml` the server shares the Tailscale sidecar's network namespace (`network_mode:
service:tailscale`), so the sidecar's `tailscale0` interface is the container's own: devices
reach `http://flaccy:4545` over the tailnet, and `tailscale serve` reaches it on loopback for
HTTPS. The container healthcheck asks loopback, which Easy mode always binds. A plain
`docker run -p` has no Tailscale interface: set `FLACCY_ADDRESS=0.0.0.0` to listen on every
address (the `Host` check still refuses dotted names that are not on your `FLACCY_HOSTS` list or a
private suffix, so LAN names such as `nas.local` and addresses such as `192.168.1.5` work).

After installing a package: edit `/etc/flaccy-server/config.toml`, then
`sudo systemctl enable --now flaccy-server` and, to make an account or key,
`sudo -u flaccy flaccy-server --config /etc/flaccy-server/config.toml key add phone`.
