#!/usr/bin/env bash
# Installs a Debug simulator build on a fresh container, copies LIBRARY into Documents, runs
# --exercise-library-walk and screenshots the screen FLACCY_WALK_END names; a crash report lands
# in ~/Library/Logs/DiagnosticReports/flaccy-*.ips.
# Usage: walk.sh APP SIMULATOR LIBRARY END SHOT.png [landscape:0|1] [groupEditions:YES|NO]
set -euo pipefail
APP=$1; SIM=$2; LIB=$3; END=$4; SHOT=$5; LAND=${6:-0}; GROUP=${7:-YES}
U=$(xcrun simctl list devices | grep " $SIM (" | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl boot "$U" 2>/dev/null || true
xcrun simctl bootstatus "$U" -b >/dev/null
xcrun simctl terminate "$U" com.midgarcorp.flaccy 2>/dev/null || true
xcrun simctl uninstall "$U" com.midgarcorp.flaccy 2>/dev/null || true
xcrun simctl install "$U" "$APP"
D=$(xcrun simctl get_app_container "$U" com.midgarcorp.flaccy data)
mkdir -p "$D/Documents" "$D/Library/Logs"
cp -R "$LIB"/. "$D/Documents/"
PREFS="$D/Library/Preferences/com.midgarcorp.flaccy"
xcrun simctl spawn "$U" defaults write "$PREFS" flaccy.library.hadIndexedLibrary -bool YES
xcrun simctl spawn "$U" defaults write "$PREFS" groupAlbumEditions -bool "$GROUP"
SIMCTL_CHILD_FLACCY_WALK_END="$END" SIMCTL_CHILD_FLACCY_LANDSCAPE="$LAND" \
  xcrun simctl launch "$U" com.midgarcorp.flaccy --exercise-library-walk >/dev/null
n=0
until grep -q "LIBRARY WALK" "$D/Library/Logs/flaccy.log" 2>/dev/null || [ $n -ge 480 ]; do sleep 0.5; n=$((n+1)); done
grep -E "LIBRARY WALK|LibraryWalk" "$D/Library/Logs/flaccy.log" | tail -2
sleep 2.5
xcrun simctl io "$U" screenshot "$SHOT" >/dev/null && echo "$SHOT"
