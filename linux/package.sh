#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOTE="${FLACCY_BUILD_HOST:-marcus@arch}"
REMOTE_DIR="Dev/flaccy-linux"
OUT_DIR="/tmp/flaccy-release"
PKG="flaccy-linux-x86_64"
TARBALL="$PKG.tar.gz"

if [[ -z "${FLACCY_LASTFM_KEY:-}" || -z "${FLACCY_LASTFM_SECRET:-}" ]]; then
  echo "error: FLACCY_LASTFM_KEY and FLACCY_LASTFM_SECRET must be set in the environment" >&2
  exit 1
fi

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
