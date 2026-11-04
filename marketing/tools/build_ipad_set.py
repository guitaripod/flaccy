#!/usr/bin/env python3
"""Builds the App Store iPad set (13-inch, 2752x2064 landscape) from native simulator captures.

  build_ipad_set.py --raw RAW_DIR --out OUT_DIR [--locales en] [--only home,lyrics]

RAW_DIR holds <name>.png landscape captures (en) or <locale>/<name>.png for other locales, taken on an
iPad Pro 13-inch simulator with --seed-screenshots, FLACCY_LANDSCAPE=1, FLACCY_SIDEBAR=1 and
FLACCY_HIDE_STATUS_BAR=1 (see docs/agent-notes.md, "iPad", for rotating an iPad simulator).
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose as c  # noqa: E402
from build_iphone_set import parse_markers  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

SLIDES = [
    dict(id="home", raw="home", accent=c.VIOLET, secondary=c.CORAL),
    dict(id="library", raw="library", accent=c.CORAL, secondary=c.VIOLET),
    dict(id="album", raw="album", accent=c.ROSE, secondary=c.VIOLET),
    dict(id="lyrics", raw="lyrics", accent=c.VIOLET, secondary=c.BLUE),
    dict(id="queue", raw="queue", accent=c.TEAL, secondary=c.BLUE),
    dict(id="scrobble", raw="charts", accent=c.AMBER, secondary=c.CORAL),
    dict(id="eq", raw="equalizer", accent=c.TEAL, secondary=c.VIOLET),
    dict(id="year", raw="year", accent=c.CORAL, secondary=c.AMBER),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--locales", default="en")
    parser.add_argument("--only", default="")
    args = parser.parse_args()

    deck = {"en": json.load(open(os.path.join(HERE, "copy_ipad_en.json")))}
    i18n = os.path.join(HERE, "copy_ipad_i18n.json")
    if os.path.exists(i18n):
        deck.update(json.load(open(i18n)))
    only = {s for s in args.only.split(",") if s}
    for locale in [x for x in args.locales.split(",") if x]:
        out_dir = os.path.join(args.out, locale)
        os.makedirs(out_dir, exist_ok=True)
        raw_dir = args.raw if locale == "en" else os.path.join(args.raw, locale)
        for index, slide in enumerate(SLIDES):
            if only and slide["id"] not in only:
                continue
            raw = os.path.join(raw_dir, slide["raw"] + ".png")
            if not os.path.exists(raw):
                print("skip", slide["id"], "no", raw, flush=True)
                continue
            copy = parse_markers(deck[locale][slide["id"]])
            target = os.path.join(out_dir, f"{index + 1:02d}-{slide['id']}.png")
            c.compose_ipad(slide, copy, locale, raw, target, index, SLIDES, os.path.join(args.out, ".work", locale))
            print("wrote", target, flush=True)


if __name__ == "__main__":
    main()
