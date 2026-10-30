# Releasing Flaccy Server

Everything runs from `apps/flaccy` through `scripts/server-release.sh`. Artifacts land in `~/.cache/flaccy-server-release/<version>/`. Nothing is pushed or published without `--publish`; `publish` without it is a dry run.

## Steps

1. Bump `version` in `linux/server/Cargo.toml` (and `Cargo.lock`), write `docs/server/RELEASE-NOTES-<version>.md` (copy `RELEASE-NOTES-1.0.0.md`, edit, delete its `DRAFT:` line), commit on monorepo `master`.
2. Gate on the drills that are not part of `cargo test`: `cargo build --release -p flaccy-server --manifest-path linux/Cargo.toml`, then `cargo test --release --manifest-path linux/Cargo.toml -p flaccy-library --test server_sync -- --ignored` (5000-change page in 500 ms, 165,000-listen backfill inside a minute, restore reseed and cover against the real binary), `cargo test --release --manifest-path linux/Cargo.toml -p flaccy-server --test durability -- --ignored` (30 rounds of SIGKILL), and `scripts/server-soak.sh --minutes 30 --release --kills-until 0.05` on Linux (one server process lives the whole run, which is what the memory check judges). Run the same soak on the Mac (`ssh macbook`, a clone of the commit, same script and flags, `ps` gives the memory samples there) and read its "server memory plateaus" line before shipping the Mac binaries.
3. Build from that commit, clean tree: `scripts/server-release.sh build`, `deb`, `rpm`, `macos`, `docker`, then `checksums` (it fills `packaging/PKGBUILD` and `packaging/flaccy-server.rb` and writes `SHA256SUMS`). `build` needs zig and cargo-zigbuild, `deb` cargo-deb, `rpm` cargo-generate-rpm, `macos` ssh to `macbook` (cargo and rustup there; it runs the Rust test suites first, then builds in `~/Dev/builds/flaccy-server-release` and removes it).
4. Rehearse: `scripts/server-release.sh publish --version X.Y.Z` (same as `--dry-run`). It prints what every step would do and lists what blocks a real run.
5. Publish: `scripts/server-release.sh publish --version X.Y.Z --publish`.

Two connection-limit tests need 127.0.0.2 to 127.0.0.13 on the loopback, which only Linux has; they are ignored on a Mac. To run them there once: `for n in 2 3 4 5 6 7 8 9 10 11 12 13; do sudo ifconfig lo0 alias 127.0.0.$n; done`, `cargo test -p flaccy-server --test connection_limits -- --ignored`, then `for n in 2 3 4 5 6 7 8 9 10 11 12 13; do sudo ifconfig lo0 -alias 127.0.0.$n; done`.

Steps, in order: `verify-tree` (master, clean, version matches), `verify-artifacts` (files, SHA256SUMS, built from this commit, rendered templates), `release-notes`, `push-monorepo`, `push-subtree` (split of `apps/flaccy` to `guitaripod/flaccy` master, fast-forward only), `github-release` (`server-vX.Y.Z`, `--latest=false` because `get-flaccy.sh` reads `releases/latest`), `homebrew-tap`, `aur`, `docker`, `verify-release` (downloads every asset and checks its sha256, confirms the release is not latest, reads the tap formula, `git ls-remote` of the AUR repo).

## Credentials

- `gh` signed in as guitaripod with `repo`; `docker` also needs `write:packages` (`gh auth refresh -s write:packages`). Without it the `docker` step stops and prints that command; `--docker-fallback` attaches `flaccy-server-<v>-docker-amd64.tar.gz` to the release instead.
- SSH to GitHub with push rights to `guitaripod/flaccy`, `guitaripod/homebrew-tap` and the monorepo, and `git-lfs` on PATH.
- SSH key registered on the AUR account that maintains `flaccy-server-bin`; `makepkg` installed.

## Resume

Finished steps are recorded in `publish.state` and skipped on the next run, and each step also checks the remote (existing release, identical tap formula, identical PKGBUILD), so rerunning `--publish` after a failure continues where it stopped. `--only STEP` runs one step again, ignoring the record (`docker-tarball` is only reachable this way or through `--docker-fallback`). Deleting `publish.state` is safe.

## Rollback

- Release: `gh release delete server-vX.Y.Z -R guitaripod/flaccy --cleanup-tag --yes`. The pushed mirror commit stays.
- Homebrew: in a clone of `guitaripod/homebrew-tap`, `git revert` the `flaccy-server` commit and push.
- AUR: clone `ssh://aur@aur.archlinux.org/flaccy-server-bin.git`, `git revert` the last commit, push. AUR history is never rewritten.
- ghcr image: delete the version in the package settings on GitHub; the tarball asset goes with the release.
- Then delete `publish.state` lines for the steps you undid.

## Not covered

The script cannot notarize the macOS binaries (ad-hoc signed only) and does not test installs on the target systems; install each package once on a clean machine before announcing.
