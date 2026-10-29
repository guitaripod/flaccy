#!/usr/bin/env bash
# Captures the iPhone marketing screens in every store locale (dark set, then a light pair).
# usage: capture_all_locales.sh UDID OUTDIR [lang ...]   (no languages = all eleven)
set -euo pipefail
UDID="$1"; OUT="$2"; HERE="$(cd "$(dirname "$0")" && pwd)"
DARK="songs,now-playing,lyrics,lyric-share,playlists,charts,year,artist,wantlist,album,queue,library"
LIGHT="songs,now-playing"
declare -a LOCALES=("en:en_US" "de:de_DE" "es:es_ES" "fr:fr_FR" "it:it_IT" "ja:ja_JP" "ko:ko_KR" "pl:pl_PL" "pt-BR:pt_BR" "zh-Hans:zh_CN" "zh-Hant:zh_TW")
WANT=("${@:3}")
for pair in "${LOCALES[@]}"; do
  lang="${pair%%:*}"; loc="${pair##*:}"
  if [ ${#WANT[@]} -gt 0 ] && [[ ! " ${WANT[*]} " =~ " $lang " ]]; then continue; fi
  python3 "$HERE/capture_iphone.py" --udid "$UDID" --out "$OUT/$lang/dark" --lang "$lang" --locale "$loc" --appearance dark --only "$DARK"
  python3 "$HERE/capture_iphone.py" --udid "$UDID" --out "$OUT/$lang/light" --lang "$lang" --locale "$loc" --appearance light --only "$LIGHT"
  echo "done $lang"
done
xcrun simctl ui "$UDID" appearance dark
