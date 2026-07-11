#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:?usage: demo-seed.sh <music-root>}"
command -v ffmpeg >/dev/null || { echo "ffmpeg is required" >&2; exit 1; }
mkdir -p "$ROOT"

seed_album() {
  local artist="$1" album="$2" year="$3" c0="$4" c1="$5"
  shift 5
  local dir="$ROOT/$artist/$album"
  mkdir -p "$dir"
  local cover="$dir/.cover.png"
  ffmpeg -y -v error -f lavfi \
    -i "gradients=s=600x600:c0=$c0:c1=$c1:x0=60:y0=40:x1=560:y1=580:n=2" \
    -frames:v 1 "$cover"
  local n=0 entry title freq dur num tmp
  for entry in "$@"; do
    n=$((n + 1))
    title="${entry%%|*}"
    freq="${entry##*|}"
    dur=$((26 + (n * 7) % 15))
    num=$(printf '%02d' "$n")
    tmp="$dir/.tmp.flac"
    ffmpeg -y -v error -f lavfi -i "sine=frequency=$freq:duration=$dur" \
      -af "afade=t=in:d=1.5,afade=t=out:st=$((dur - 3)):d=3" \
      -sample_fmt s16 -c:a flac "$tmp"
    ffmpeg -y -v error -i "$tmp" -i "$cover" -map 0:a -map 1:v -c copy \
      -metadata TITLE="$title" \
      -metadata ARTIST="$artist" \
      -metadata ALBUMARTIST="$artist" \
      -metadata ALBUM="$album" \
      -metadata DATE="$year" \
      -metadata TRACKNUMBER="$n" \
      -metadata:s:v title="Album cover" \
      -metadata:s:v comment="Cover (front)" \
      -disposition:v:0 attached_pic \
      "$dir/$num - $title.flac"
    rm -f "$tmp"
  done
  rm -f "$cover"
  echo "seeded: $artist — $album ($n tracks)"
}

seed_album "Meridian Wolde" "Parallax Hours" 2024 0x1B1B34 0x9D4EDD \
  "Slow Machine|220" "Glass Corridor|277" "Parallax Hours|330" "Night Arithmetic|392"
seed_album "Marisol Vane" "Ember & Ash" 2023 0x7F1D1D 0xF59E0B \
  "Ember & Ash|247" "Tinderbox|311" "Ash Garden|370"
seed_album "Kestrel Vale" "Aurorae" 2025 0x032C22 0x34D399 \
  "Aurorae|262" "Ionosphere|294" "Polar Low|349" "Zenith|415"
seed_album "Novaeu" "Paper Cities" 2022 0x44506B 0xE7E5E4 \
  "Paper Cities|233" "Origami Streets|262" "Fold|311"
seed_album "Virelle" "Cassini" 2024 0x0C1445 0xC2A878 \
  "Cassini|196" "Rings|247" "Huygens Descent|294"
seed_album "Solveig" "Midnatt" 2023 0x0F172A 0x38BDF8 \
  "Midnatt|208" "Sommarnatt|262" "Frost|330"
seed_album "The Hollowmen" "Ravine" 2021 0x292524 0x84CC16 \
  "Ravine|175" "Switchback|220" "Riverbed|262" "Cairn|294"
seed_album "Meridian Wolde" "Vantablack Sun" 2022 0x0B0B12 0xF472B6 \
  "Vantablack Sun|233" "Afterimage|277" "Umbra|311" "Heliopause|349"
seed_album "Meridian Wolde" "Field Lines" 2020 0x102A43 0x60A5FA \
  "Field Lines|208" "Magnet School|247" "Solenoid|294"
seed_album "Kestrel Vale" "Overwinter" 2023 0x1C1917 0xA8A29E \
  "Overwinter|196" "Snowline|233" "Thaw|277" "Firn|330"
seed_album "The Hollowmen" "Meltwater" 2024 0x134E4A 0x2DD4BF \
  "Meltwater|220" "Confluence|262" "Oxbow|311"
seed_album "Cobalt Fields" "Signal Bloom" 2024 0x14235C 0x5FA8FF \
  "Signal Bloom|305" "Static Garden|278" "Lowband|246" "Nightshift|331"
seed_album "Ashgrove" "Lantern Year" 2019 0x3A2E14 0xE6C36F \
  "Lantern Year|223" "Threshing Song|254" "Hollow Oak|211"
seed_album "Halden Reef" "Tidal Glass" 2023 0x0C333A 0x63E0D0 \
  "Tidal Glass|356" "Neap|278" "Springtide|341" "Estuary|299"
seed_album "Corvid & Crane" "Ledger of Small Hours" 2022 0x352A16 0xDDBE76 \
  "Ledger|232" "Magpie Song|258" "Rooksmoor|214" "Tallow Light|271"
seed_album "Ptolemy Sound" "Almagest" 2024 0x151E5A 0x6E9BFF \
  "Almagest|312" "Epicycle|287" "Retrograde|264" "Zenith Rise|331"
seed_album "Aster Bloom" "Greenhouse Hymns" 2023 0x2A1748 0xCF9CFF \
  "Greenhouse Hymns|251" "Peony|268" "Terrarium|239" "Chlorophyll|292"
seed_album "Bright Antares" "Southern Cross" 2021 0x103628 0x93E6B6 \
  "Southern Cross|372" "Coalsack|314" "Acrux|398"
seed_album "Odessa Grey" "Saltwater Gospel" 2022 0x431A28 0xFF93A8 \
  "Saltwater Gospel|274" "Brine|248" "Harbor Lantern|291" "Low Country|236"
seed_album "Fenwick Lyle" "Radio Silence" 2023 0x3C2A12 0xF0BE63 \
  "Radio Silence|227" "Shortwave|241" "Dead Air|213" "Carrier Tone|258"
seed_album "Selkie" "Longshore Drift" 2024 0x123640 0x7FD6C4 \
  "Longshore Drift|269" "Sealskin|244" "Foreshore|288"

echo "demo catalog ready at $ROOT"

seed_gap_track() {
  local artist="$1" album="$2" year="$3" title="$4" freq="$5" num="$6"
  local dir="$ROOT/$artist/$album"
  mkdir -p "$dir"
  local dur=$((26 + (num * 7) % 15))
  local padded
  padded=$(printf '%02d' "$num")
  ffmpeg -y -v error -f lavfi -i "sine=frequency=$freq:duration=$dur" \
    -af "afade=t=in:d=1.5,afade=t=out:st=$((dur - 3)):d=3" \
    -sample_fmt s16 -c:a flac \
    -metadata TITLE="$title" -metadata ARTIST="$artist" \
    -metadata ALBUMARTIST="$artist" -metadata ALBUM="$album" \
    -metadata DATE="$year" -metadata TRACKNUMBER="$num" \
    "$dir/$padded - $title.flac"
}

seed_lossy_album() {
  local artist="$1" album="$2" year="$3"
  shift 3
  local dir="$ROOT/$artist/$album"
  mkdir -p "$dir"
  local n=0 entry title freq dur num
  for entry in "$@"; do
    n=$((n + 1))
    title="${entry%%|*}"
    freq="${entry##*|}"
    dur=$((26 + (n * 7) % 15))
    num=$(printf '%02d' "$n")
    ffmpeg -y -v error -f lavfi -i "sine=frequency=$freq:duration=$dur" \
      -af "afade=t=in:d=1.5,afade=t=out:st=$((dur - 3)):d=3" \
      -c:a libmp3lame -q:a 2 \
      -metadata TITLE="$title" -metadata ARTIST="$artist" \
      -metadata ALBUMARTIST="$artist" -metadata ALBUM="$album" \
      -metadata DATE="$year" -metadata TRACKNUMBER="$n" \
      "$dir/$num - $title.mp3"
  done
  echo "seeded (mp3): $artist — $album ($n tracks)"
}

seed_gap_track "Novaeu" "Statuary" 2021 "Statuary" 220 1
seed_gap_track "Novaeu" "Statuary" 2021 "Plinth" 262 2
seed_gap_track "Novaeu" "Statuary" 2021 "Colonnade" 330 9
echo "seeded (gap): Novaeu — Statuary (3 of 9 tracks)"
seed_lossy_album "Virelle" "First Transmissions" 2019 \
  "First Transmissions|196" "Carrier Wave|247" "Static Bloom|294"
