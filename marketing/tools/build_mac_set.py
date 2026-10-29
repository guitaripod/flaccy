#!/usr/bin/env python3
"""Builds the Mac App Store screenshot set (2880x1800) from 2x window captures.

  build_mac_set.py --raw RAW_DIR --out OUT_DIR [--locales en] [--only library,lyrics]

RAW_DIR holds <name>.png window captures (en) or <locale>/<name>.png for other locales.
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
    dict(id="library", raw="library-albums", accent=c.CORAL, secondary=c.VIOLET),
    dict(id="eq", raw="equalizer-simple", accent=c.TEAL, secondary=c.VIOLET),
    dict(id="lyrics", raw="nowplaying-lyrics", accent=c.VIOLET, secondary=c.CORAL),
    dict(id="share", raw="lyric-share", accent=c.CORAL, secondary=c.VIOLET),
    dict(id="queue", raw="queue", accent=c.TEAL, secondary=c.BLUE),
    dict(id="scrobble", raw="charts", accent=c.ROSE, secondary=c.AMBER),
    dict(id="eqpro", raw="equalizer-advanced", accent=c.AMBER, secondary=c.TEAL),
    dict(id="year", raw="year-in-music", accent=c.CORAL, secondary=c.AMBER),
    dict(id="themes", raw="library-light", accent=c.BLUE, secondary=c.VIOLET, mac_color="Space Black"),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--locales", default="en")
    parser.add_argument("--only", default="")
    args = parser.parse_args()

    deck = {"en": json.load(open(os.path.join(HERE, "copy_mac_en.json")))}
    i18n = os.path.join(HERE, "copy_mac_i18n.json")
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
            window = os.path.join(raw_dir, slide["raw"] + ".png")
            if not os.path.exists(window):
                print("skip", slide["id"], "no", window, flush=True)
                continue
            copy = parse_markers(deck[locale][slide["id"]])
            target = os.path.join(out_dir, f"{index + 1:02d}-{slide['id']}.png")
            c.compose_mac(slide, copy, locale, window, target, index, SLIDES, os.path.join(args.out, ".work", locale))
            print("wrote", target, flush=True)


if __name__ == "__main__":
    main()
