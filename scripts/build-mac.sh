#!/usr/bin/env bash
# Sync the working tree to the Mac and compile the Apple clients there.
# The Linux box authors; the Mac (over Tailscale) owns the iOS/macOS/watchOS SDKs.
# The Mac keeps its own gitignored flaccy/Secrets.swift, so the sync must never
# delete it; everything else mirrors this tree exactly, uncommitted work included.
#
#   scripts/build-mac.sh            # build iOS + macOS + watchOS
#   scripts/build-mac.sh ios        # one platform only: ios | mac | watch
set -euo pipefail

ONLY="${1:-all}"

RSYNC_EXCLUDES=(
    --exclude '.git'
    --exclude 'build'
    --exclude 'build-*'
    --exclude 'DerivedData'
    --exclude '.build'
    --exclude 'linux/target'
    --exclude 'flaccy/Secrets.swift'
)

if [[ "$(uname -n)" != "macbook" ]]; then
    rsync -az --delete "${RSYNC_EXCLUDES[@]}" ~/Dev/rust/flaccy/ macbook:Dev/ios/flaccy/
fi

ssh macbook "ONLY=$(printf %q "$ONLY") bash -l" <<'REMOTE'
set -euo pipefail
cd ~/Dev/ios/flaccy

build_one() {
    local scheme=$1 dest=$2 log=/tmp/flaccy-build-$3.log
    if ! xcodebuild -project flaccy.xcodeproj -scheme "$scheme" -destination "$dest" \
        -configuration Debug -derivedDataPath "build/dd-$3" \
        CODE_SIGNING_ALLOWED=NO build > "$log" 2>&1; then
        grep -E "error:" "$log" | sort -u | tail -30
        echo "** $scheme BUILD FAILED **"
        exit 1
    fi
    echo "** $scheme BUILD SUCCEEDED **"
}

case "$ONLY" in
    ios)   build_one flaccy "generic/platform=iOS Simulator" ios ;;
    mac)   build_one flaccyMac "platform=macOS" mac ;;
    watch) build_one "flaccyWatch Watch App" "generic/platform=watchOS Simulator" watch ;;
    all)
        build_one flaccy "generic/platform=iOS Simulator" ios
        build_one flaccyMac "platform=macOS" mac
        build_one "flaccyWatch Watch App" "generic/platform=watchOS Simulator" watch
        ;;
    *) echo "unknown platform: $ONLY (use ios|mac|watch)"; exit 2 ;;
esac
REMOTE
