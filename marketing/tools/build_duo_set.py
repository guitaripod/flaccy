#!/usr/bin/env python3
"""Builds the App Store iPhone Duo set: ten slides across the four Duo screenshot sizes.

  build_duo_set.py --raw RAW_DIR --out OUT_DIR [--locales en,de] [--only home,book]

RAW_DIR holds the raw captures `capture.py` (iphone-duo skill) writes, named <screen>__<state>.png,
for en at its top level and for every other locale under <locale>/. Each capture is already the
size of its App Store slot (inner 2853x2007 or 2007x2853, outer 2034x1398 or 1398x2034), and the
slide keeps that size: caption on top, the Duo framed by `frames` below it.
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
    dict(id="home", raw="home-playing__inner-landscape", accent=c.VIOLET, secondary=c.CORAL),
    dict(id="book", raw="lyrics__book-landscape", accent=c.CORAL, secondary=c.VIOLET),
    dict(id="album", raw="now-playing__inner-landscape", accent=c.ROSE, secondary=c.VIOLET),
    dict(id="queue", raw="queue__inner-landscape", accent=c.TEAL, secondary=c.BLUE),
    dict(id="laptop", raw="now-playing__laptop-portrait", accent=c.VIOLET, secondary=c.TEAL),
    dict(id="scrobble", raw="charts__inner-portrait", accent=c.AMBER, secondary=c.CORAL),
    dict(id="tracks", raw="album-nq__book-landscape", accent=c.BLUE, secondary=c.VIOLET),
    dict(id="closed", raw="now-playing__outer-portrait", accent=c.CORAL, secondary=c.AMBER),
    dict(id="library", raw="library__outer-portrait", accent=c.TEAL, secondary=c.VIOLET),
    dict(id="landscape", raw="now-playing__outer-landscape", accent=c.ROSE, secondary=c.BLUE),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--locales", default="en")
    parser.add_argument("--only", default="")
    args = parser.parse_args()

    deck = {"en": json.load(open(os.path.join(HERE, "copy_duo_en.json")))}
    i18n = os.path.join(HERE, "copy_duo_i18n.json")
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
            c.compose_duo(slide, copy, locale, raw, target, index, SLIDES, os.path.join(args.out, ".work", locale))
            print("wrote", target, flush=True)


if __name__ == "__main__":
    main()
