# Flaccy Server 1.3.0

This release lets devices on your Wi-Fi connect without Tailscale.

## What changed

- **Your Wi-Fi is enough.** With `lan = true`, which `flaccy-server setup` now sets for you, the server also listens on this computer's local network addresses, so an iPhone, Mac or Linux computer on the same Wi-Fi connects directly. Tailscale stays the way to listen away from home, and a server that has both gives new devices the tailnet address first and this network's as the fallback.
- **Encrypted, and checked by key.** Devices on the local network talk to the server over TLS. The server makes one key the first time (`lan-key.der` in the data folder) and devices pin it when they are added, so another machine on the network cannot pose as your server or read a device's sign-in. Tailscale connections are unchanged.
- **Setup without Tailscale.** `flaccy-server setup` no longer stops when Tailscale is missing: it shares on this network, says how to add Tailscale later, counts songs while it scans, and prints the QR code for the iPhone and the link to paste on a Mac or Linux. `--no-lan` keeps a server to Tailscale only.
- **The right name on the network.** Links use the name your computer actually answers to over Bonjour (avahi's, which may be `arch-2.local` when another machine is called `arch`), and its address as the fallback. `lan_name` picks the name yourself. `flaccy-server doctor` shows the address devices are given and no longer fails a server that shares on this network for lacking Tailscale.

## Install

- Mac: `brew install guitaripod/tap/flaccy-server` (Apple silicon and Intel).
- Arch Linux: `yay -S flaccy-server-bin`.
- Debian, Ubuntu, Raspberry Pi OS: the `.deb`. Fedora and openSUSE: the `.rpm`. Both add a system service that runs as the `flaccy` user.
- Docker: `ghcr.io/guitaripod/flaccy-server`, or the `docker-amd64.tar.gz` attached here (`gunzip -c file | docker load`) if the registry image is not up yet. Sharing on the local network from a container needs host networking.
- Anything else on Linux: the static `linux-x86_64` or `linux-aarch64` tarball, no libc needed.

Then run `flaccy-server setup` once. Verify downloads with `SHA256SUMS`. An existing install upgrades in place and keeps working over Tailscale; add `lan = true` to its configuration (or run `setup` again) to share on your Wi-Fi.

## Known limits

- Devices need Flaccy releases from this month to connect over the local network; older ones still connect over Tailscale.
- Keep `lan-key.der` with the data folder when you move the server. A new key means every device on the local network has to be added again.
- Easy mode is the only mode; `household` mode is refused at start.
- No Windows service: `setup` tells you to run `flaccy-server serve` yourself.
- The macOS binaries are ad-hoc signed, not notarized. Homebrew installs them without a Gatekeeper prompt; a browser download needs `xattr -d com.apple.quarantine`.
- Syncing across Apple devices is part of Flaccy Pro; connecting, browsing and streaming are free.
- A Mac may ask whether to allow incoming connections the first time another device connects; until you choose Allow, other devices time out. An iPhone asks once to find devices on the local network; choose Allow.
