#!/usr/bin/env python3
"""Builds the App Store iPhone screenshot set for one or more locales.

  build_iphone_set.py --raw RAW_DIR --out OUT_DIR [--locales en,de,...] [--only hero,lyrics] [--watch-raw FILE]

RAW_DIR holds <locale>/dark/<screen>.png and <locale>/light/<screen>.png from capture_all_locales.sh.
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose as c  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

SLIDES = [
    dict(id="home", raw="home", accent=c.VIOLET, secondary=c.CORAL),
    dict(id="hero", raw="library", accent=c.CORAL, secondary=c.VIOLET),
    dict(id="eq", raw="equalizer", accent=c.TEAL, secondary=c.VIOLET),
    dict(id="nowplaying", raw="now-playing", accent=c.VIOLET, secondary=c.CORAL),
    dict(id="lyrics", raw="lyrics", accent=c.ROSE, secondary=c.BLUE),
    dict(id="share", raw="lyric-share", accent=c.CORAL, secondary=c.VIOLET),
    dict(id="scrobble", raw="charts", accent=c.AMBER, secondary=c.CORAL),
    dict(id="year", raw="year", accent=c.CORAL, secondary=c.AMBER),
    dict(id="watch", layout="watch", raw="now-playing", accent=c.BLUE, secondary=c.TEAL),
    dict(id="eqpro", raw="equalizer-advanced", accent=c.AMBER, secondary=c.TEAL),
]

LOCALES = ["en", "de", "es", "fr", "it", "ja", "ko", "pl", "pt-BR", "zh-Hans", "zh-Hant"]


def load_copy():
    deck = {"en": json.load(open(os.path.join(HERE, "copy_en.json")))}
    i18n = os.path.join(HERE, "copy_i18n.json")
    if os.path.exists(i18n):
        deck.update(json.load(open(i18n)))
    return deck


def parse_markers(entry):
    """'Your *quality.*' -> headline without asterisks and accent=['quality.']."""
    entry = dict(entry)
    accents = re.findall(r"\*(.+?)\*", entry["headline"])
    entry["headline"] = entry["headline"].replace("*", "")
    entry["accent"] = accents
    return entry


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--locales", default=",".join(LOCALES))
    parser.add_argument("--only", default="")
    parser.add_argument("--watch-raw", default="", help="comma-separated: now-playing,library screens")
    args = parser.parse_args()

    deck = load_copy()
    only = {s for s in args.only.split(",") if s}
    for locale in [x for x in args.locales.split(",") if x]:
        out_dir = os.path.join(args.out, locale)
        os.makedirs(out_dir, exist_ok=True)
        work = os.path.join(args.out, ".work", locale)
        dark = os.path.join(args.raw, locale, "dark")
        light = os.path.join(args.raw, locale, "light")
        for index, slide in enumerate(SLIDES):
            if only and slide["id"] not in only:
                continue
            copy = parse_markers(deck[locale][slide["id"]])
            target = os.path.join(out_dir, f"{index + 1:02d}-{slide['id']}.png")
            layout = slide.get("layout", "phone")
            if layout == "pair":
                c.compose_pair(slide, copy, locale, (light, dark), target, index, SLIDES, work)
            elif layout == "watch":
                watch_raws = [x for x in args.watch_raw.split(",") if x]
                if len(watch_raws) != 2 or not all(os.path.exists(x) for x in watch_raws):
                    print("skip watch slide: need --watch-raw A.png,B.png", flush=True)
                    continue
                c.compose_watch(slide, copy, locale, dark, watch_raws, target, index, SLIDES, work)
            else:
                c.compose_slide(slide, copy, locale, dark, target, index, SLIDES, work)
            print("wrote", target, flush=True)


if __name__ == "__main__":
    main()
