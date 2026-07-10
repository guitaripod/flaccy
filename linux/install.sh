#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY="$HERE/target/release/flaccy"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"

if [[ ! -x "$BINARY" ]]; then
  echo "error: $BINARY not found — run 'cargo build --release' first" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$APP_DIR"
install -m 755 "$BINARY" "$BIN_DIR/flaccy"
sed -e "s|^Exec=flaccy$|Exec=$BIN_DIR/flaccy|" \
    -e "s|^TryExec=flaccy$|TryExec=$BIN_DIR/flaccy|" \
    "$HERE/data/cc.midgarcorp.Flaccy.desktop" > "$APP_DIR/cc.midgarcorp.Flaccy.desktop"
chmod 644 "$APP_DIR/cc.midgarcorp.Flaccy.desktop"

for size in 16 32 48 64 128 256 512; do
  src="$HERE/data/icons/hicolor/${size}x${size}/apps/cc.midgarcorp.Flaccy.png"
  dest="$ICON_BASE/${size}x${size}/apps"
  if [[ -f "$src" ]]; then
    mkdir -p "$dest"
    install -m 644 "$src" "$dest/cc.midgarcorp.Flaccy.png"
  fi
done

if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$APP_DIR" || true
fi
if command -v gtk-update-icon-cache >/dev/null 2>&1; then
  gtk-update-icon-cache -q -t "$ICON_BASE" 2>/dev/null || true
fi
if command -v gtk4-update-icon-cache >/dev/null 2>&1; then
  gtk4-update-icon-cache -q -t "$ICON_BASE" 2>/dev/null || true
fi

echo "installed: $BIN_DIR/flaccy"
echo "desktop entry: $APP_DIR/cc.midgarcorp.Flaccy.desktop"
echo "icons: $ICON_BASE/{16..512}/apps/cc.midgarcorp.Flaccy.png"
