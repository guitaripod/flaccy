#!/usr/bin/env python3
"""Regenerates Flaccy's own symbolic icons from Phosphor Icons (MIT).

Every glyph the Linux client draws comes from this one set, under a
`flaccy-*-symbolic` name no desktop icon theme defines, so the app looks the
same under Adwaita, Breeze or anything else.

    npm pack @phosphor-icons/core && tar xzf phosphor-icons-core-*.tgz
    python3 linux/data/icons/build-icons.py package/assets

Icons listed in KEPT are drawn by hand and left alone.
"""
import re
import sys
from pathlib import Path

OUT = Path(__file__).resolve().parent / "hicolor" / "scalable" / "actions"
KEPT = {"flaccy-skip-back-15", "flaccy-skip-forward-15"}

ICONS = {
    "play": "play-fill",
    "pause": "pause-fill",
    "stop": "stop-fill",
    "skip-forward": "skip-forward-fill",
    "skip-back": "skip-back-fill",
    "shuffle": "shuffle-bold",
    "repeat": "repeat-bold",
    "repeat-one": "repeat-once-bold",
    "play-in-order": "arrow-line-right-bold",
    "add": "plus-bold",
    "remove": "minus-bold",
    "check": "check-bold",
    "check-circle": "check-circle-fill",
    "close": "x-bold",
    "more": "dots-three-outline-fill",
    "refresh": "arrows-clockwise-bold",
    "sync": "arrows-clockwise-bold",
    "undo": "arrow-counter-clockwise-bold",
    "edit": "pencil-simple-bold",
    "copy": "copy-bold",
    "paste": "clipboard-text-bold",
    "trash": "trash-bold",
    "clean": "broom-bold",
    "link": "link-bold",
    "share": "export-bold",
    "share-link": "share-network-bold",
    "download": "download-simple-bold",
    "folder-open": "folder-open-bold",
    "search": "magnifying-glass-bold",
    "zoom-in": "magnifying-glass-plus-bold",
    "zoom-out": "magnifying-glass-minus-bold",
    "fullscreen": "arrows-out-bold",
    "restore": "arrows-in-bold",
    "menu": "list-bold",
    "sidebar": "sidebar-simple-bold",
    "drag-handle": "dots-six-vertical-bold",
    "chevron-right": "caret-right-bold",
    "chevron-left": "caret-left-bold",
    "chevron-down": "caret-down-bold",
    "chevron-up": "caret-up-bold",
    "locate": "crosshair-simple-bold",
    "pin": "push-pin-fill",
    "show": "eye-bold",
    "hide": "eye-slash-bold",
    "home": "house-bold",
    "album": "vinyl-record-bold",
    "disc": "disc-bold",
    "song": "music-notes-bold",
    "artists": "users-bold",
    "playlist": "playlist-bold",
    "queue": "queue-bold",
    "stats": "chart-bar-bold",
    "wantlist": "star-fill",
    "guide": "lightbulb-bold",
    "heart": "heart-fill",
    "lyrics": "quotes-fill",
    "align-center": "text-align-center-bold",
    "align-left": "text-align-left-bold",
    "meaning": "book-open-text-bold",
    "timing": "timer-bold",
    "sleep-timer": "moon-bold",
    "equalizer": "faders-bold",
    "comments": "chat-circle-text-bold",
    "thumb-up": "thumbs-up-bold",
    "station": "broadcast-bold",
    "video": "monitor-play-bold",
    "image": "image-bold",
    "globe": "globe-bold",
    "server": "hard-drives-bold",
    "offline": "cloud-slash-bold",
    "loading": "circle-notch-bold",
    "working": "gear-six-bold",
    "settings": "gear-six-bold",
    "recent": "clock-counter-clockwise-bold",
    "sun": "sun-bold",
    "info": "info-bold",
    "warning": "warning-fill",
    "error": "x-circle-fill",
    "speaker": "speaker-hifi-bold",
    "headphones": "headphones-bold",
    "bluetooth": "bluetooth-bold",
    "audio-interface": "waveform-bold",
    "volume-high": "speaker-high-fill",
    "volume-medium": "speaker-low-fill",
    "volume-low": "speaker-none-fill",
    "volume-muted": "speaker-x-fill",
    "layout-list": "rows-bold",
    "layout-table": "list-numbers-bold",
    "layout-columns": "columns-bold",
    "window-minimize": "minus-bold",
    "window-maximize": "square-bold",
    "window-restore": "copy-simple-bold",
    "appearance": "palette-bold",
    "bell": "bell-bold",
    "prepare": "cloud-arrow-down-bold",
    "library": "books-bold",
    "tag": "tag-bold",
    "lastfm": "broadcast-bold",
    "sound": "waveform-bold",
    "startup": "rocket-launch-bold",
    "playback": "play-circle-bold",
    "about": "info-bold",
}


def build(assets: Path) -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    wanted = {f"flaccy-{name}-symbolic.svg" for name in ICONS}
    for name, source in ICONS.items():
        weight = source.rsplit("-", 1)[1]
        svg = (assets / weight / f"{source}.svg").read_text()
        paths = re.findall(r"<path[^>]*\sd=\"([^\"]+)\"", svg)
        if not paths:
            sys.exit(f"{source}: no path")
        body = "".join(f'<path fill="#2e3436" d="{d}"/>' for d in paths)
        (OUT / f"flaccy-{name}-symbolic.svg").write_text(
            '<?xml version="1.0" encoding="UTF-8"?>\n'
            '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 256 256">'
            f"{body}</svg>\n"
        )
    for stale in OUT.glob("*.svg"):
        if stale.name not in wanted and stale.stem.removesuffix("-symbolic") not in KEPT:
            stale.unlink()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    build(Path(sys.argv[1]))
