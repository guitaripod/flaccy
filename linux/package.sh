#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${FLACCY_BUILD_HOST:-marcus@arch}"
REMOTE_DIR="Dev/flaccy-linux"
OUT_DIR="/tmp/flaccy-release"
PKG="flaccy-linux-x86_64"
TARBALL="$PKG.tar.gz"

KEYS_FILE="${FLACCY_KEYS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/flaccy/build-keys.env}"
if [[ -z "${FLACCY_LASTFM_KEY:-}" || -z "${FLACCY_LASTFM_SECRET:-}" ]] && [[ -f "$KEYS_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$KEYS_FILE"
  set +a
fi

for name in FLACCY_LASTFM_KEY FLACCY_LASTFM_SECRET; do
  value="${!name:-}"
  # A placeholder builds a release that shows the scrobbling UI and then fails
  # every signed call with "Invalid method signature" — refuse to ship one.
  if [[ ! "$value" =~ ^[0-9a-fA-F]{32}$ ]] || [[ -z "${value//${value:0:1}/}" ]]; then
    echo "error: $name must be a real 32-character hex credential (set it, or put it in $KEYS_FILE)" >&2
    exit 1
  fi
done

echo "Syncing sources to $REMOTE:$REMOTE_DIR..."
rsync -a --delete --exclude target \
  "$HERE/Cargo.toml" "$HERE/Cargo.lock" "$HERE/src" "$HERE/data" \
  "$HERE/install.sh" "$HERE/README.md" "$HERE/LICENSE" \
  "$REMOTE:$REMOTE_DIR/"

echo "Building release on $REMOTE..."
ssh "$REMOTE" "FLACCY_LASTFM_KEY='$FLACCY_LASTFM_KEY' FLACCY_LASTFM_SECRET='$FLACCY_LASTFM_SECRET' bash -s" <<'REMOTE_BUILD'
set -euo pipefail
cd ~/Dev/flaccy-linux
cargo build --release
rm -rf /tmp/flaccy-pkg
mkdir -p /tmp/flaccy-pkg/flaccy-linux-x86_64
cp target/release/flaccy install.sh README.md LICENSE /tmp/flaccy-pkg/flaccy-linux-x86_64/
cp -r data /tmp/flaccy-pkg/flaccy-linux-x86_64/
chmod 755 /tmp/flaccy-pkg/flaccy-linux-x86_64/flaccy /tmp/flaccy-pkg/flaccy-linux-x86_64/install.sh
cd /tmp/flaccy-pkg
tar -czf flaccy-linux-x86_64.tar.gz flaccy-linux-x86_64
sha256sum flaccy-linux-x86_64.tar.gz > flaccy-linux-x86_64.tar.gz.sha256
sha256sum flaccy-linux-x86_64.tar.gz
REMOTE_BUILD

mkdir -p "$OUT_DIR"
scp "$REMOTE:/tmp/flaccy-pkg/$TARBALL" "$REMOTE:/tmp/flaccy-pkg/$TARBALL.sha256" "$OUT_DIR/"
echo "Artifacts in $OUT_DIR:"
ls -l "$OUT_DIR"
cat "$OUT_DIR/$TARBALL.sha256"
