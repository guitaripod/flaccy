#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HOME/.local/bin"
APP_DIR="$HOME/.local/share/applications"
ICON_BASE="$HOME/.local/share/icons/hicolor"
APP_ID="cc.midgarcorp.Flaccy"
SIZES=(16 32 48 64 128 256 512)

refresh_caches() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" 2>/dev/null || true
  fi
  for cache in gtk-update-icon-cache gtk4-update-icon-cache; do
    if command -v "$cache" >/dev/null 2>&1; then
      "$cache" -q -t "$ICON_BASE" 2>/dev/null || true
    fi
  done
}

if [[ "${1:-}" == "--uninstall" ]]; then
  rm -f "$BIN_DIR/flaccy" "$APP_DIR/$APP_ID.desktop"
  for size in "${SIZES[@]}"; do
    rm -f "$ICON_BASE/${size}x${size}/apps/$APP_ID.png"
  done
  refresh_caches
  echo "uninstalled: flaccy binary, desktop entry, and icons removed"
  exit 0
fi

BINARY="$HERE/flaccy"
if [[ ! -x "$BINARY" ]]; then
  BINARY="$HERE/target/release/flaccy"
fi
if [[ ! -x "$BINARY" ]]; then
  echo "error: flaccy binary not found next to install.sh or in target/release — run 'cargo build --release' first" >&2
  exit 1
fi

mkdir -p "$BIN_DIR" "$APP_DIR"
install -m 755 "$BINARY" "$BIN_DIR/flaccy"
sed -e "s|^Exec=flaccy$|Exec=$BIN_DIR/flaccy|" \
    -e "s|^TryExec=flaccy$|TryExec=$BIN_DIR/flaccy|" \
    "$HERE/data/$APP_ID.desktop" > "$APP_DIR/$APP_ID.desktop"
chmod 644 "$APP_DIR/$APP_ID.desktop"

for size in "${SIZES[@]}"; do
  src="$HERE/data/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
  dest="$ICON_BASE/${size}x${size}/apps"
  if [[ -f "$src" ]]; then
    mkdir -p "$dest"
    install -m 644 "$src" "$dest/$APP_ID.png"
  fi
done

refresh_caches

echo "installed: $BIN_DIR/flaccy"
echo "desktop entry: $APP_DIR/$APP_ID.desktop"
echo "icons: $ICON_BASE/{16..512}/apps/$APP_ID.png"
