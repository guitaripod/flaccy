#!/bin/sh
set -eu

REPO="guitaripod/flaccy"
ASSET="flaccy-linux-x86_64.tar.gz"
APP_ID="cc.midgarcorp.Flaccy"

fail() {
  echo "error: $*" >&2
  exit 1
}

if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$HOME/.local/bin/flaccy" "$HOME/.local/share/applications/$APP_ID.desktop"
  for size in 16 32 48 64 128 256 512; do
    rm -f "$HOME/.local/share/icons/hicolor/${size}x${size}/apps/$APP_ID.png"
  done
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
  echo "uninstalled: flaccy binary, desktop entry, and icons removed"
  exit 0
fi

arch="$(uname -m)"
[ "$arch" = "x86_64" ] || fail "unsupported architecture '$arch' — prebuilt binaries are x86_64 only. Build from source: https://github.com/$REPO/tree/master/linux"
[ "$(uname -s)" = "Linux" ] || fail "this installer is for Linux"

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

if command -v sha256sum >/dev/null 2>&1; then
  SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then
  SHA_CMD="shasum -a 256"
else
  fail "sha256sum (or shasum) is required"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

base="https://github.com/$REPO/releases/latest/download"
echo "Downloading $ASSET (latest release)..."
curl -fsSL -o "$tmp/$ASSET" "$base/$ASSET" || fail "download failed — check https://github.com/$REPO/releases"
curl -fsSL -o "$tmp/$ASSET.sha256" "$base/$ASSET.sha256" || fail "checksum download failed"

echo "Verifying sha256..."
expected="$(awk '{print $1}' "$tmp/$ASSET.sha256")"
actual="$($SHA_CMD "$tmp/$ASSET" | awk '{print $1}')"
[ "$expected" = "$actual" ] || fail "sha256 mismatch (expected $expected, got $actual)"

tar -xzf "$tmp/$ASSET" -C "$tmp"
dir="$tmp/flaccy-linux-x86_64"
[ -x "$dir/install.sh" ] || fail "tarball layout unexpected: install.sh missing"

echo "Installing to ~/.local (no sudo)..."
sh "$dir/install.sh"

bin="$HOME/.local/bin/flaccy"
missing="$(ldd "$bin" 2>/dev/null | awk '/not found/{print $1}')" || true
if [ -n "${missing:-}" ]; then
  echo ""
  echo "WARNING: missing runtime libraries:"
  echo "$missing" | sed 's/^/  /'
  echo "Install the GTK4/libadwaita/GStreamer runtime for your distro:"
  echo "  Arch:          sudo pacman -S gtk4 libadwaita gstreamer gst-plugins-base gst-plugins-good gst-libav"
  echo "  Debian/Ubuntu: sudo apt install libgtk-4-1 libadwaita-1-0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-libav"
  echo "  Fedora:        sudo dnf install gtk4 libadwaita gstreamer1 gstreamer1-plugins-base gstreamer1-plugins-good gstreamer1-libav"
fi

echo ""
echo "Flaccy installed:"
echo "  binary:  $bin"
echo "  desktop: ~/.local/share/applications/$APP_ID.desktop"
echo "  icons:   ~/.local/share/icons/hicolor/*/apps/$APP_ID.png"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "  note: ~/.local/bin is not on your PATH — launch via the app menu or add it" ;;
esac
echo ""
echo "Launch: flaccy   (or find 'Flaccy' in your app menu)"
echo "Uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/master/linux/get-flaccy.sh | sh -s -- --uninstall"

exit 0
