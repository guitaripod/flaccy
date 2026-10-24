#!/usr/bin/env python3
"""Captures the seeded demo screens from a booted iPhone simulator, one launch per screen.

Every screen is one `FLACCY_ROUTE` (see `DemoRouter` in App/DemoMode.swift). The app
must already be installed on the simulator; this only launches, waits, and shoots.

  capture_iphone.py --udid UDID --out DIR [--lang de] [--appearance dark|light] [--only a,b]
"""
import argparse
import os
import subprocess
import time

APP = "com.midgarcorp.flaccy"

SCREENS = {
    "library":      dict(env={}, wait=14),
    "songs":        dict(env={"FLACCY_ROUTE": "songs"}, wait=10),
    "artists":      dict(env={"FLACCY_ROUTE": "artists"}, wait=10),
    "playlists":    dict(env={"FLACCY_ROUTE": "playlists"}, wait=10),
    "album":        dict(env={"FLACCY_ROUTE": "album", "FLACCY_ALBUM": "Parallax Hours"}, wait=10),
    "artist":       dict(env={"FLACCY_ROUTE": "artist"}, wait=12),
    "now-playing":  dict(env={"FLACCY_ROUTE": "now-playing", "FLACCY_PLAYING": "1", "FLACCY_EQ": "1"}, wait=14),
    "equalizer":          dict(env={"FLACCY_ROUTE": "equalizer", "FLACCY_PLAYING": "1"}, wait=16),
    "equalizer-advanced": dict(env={"FLACCY_ROUTE": "equalizer-advanced", "FLACCY_PLAYING": "1"}, wait=16),
    "equalizer-presets":  dict(env={"FLACCY_ROUTE": "equalizer-presets", "FLACCY_PLAYING": "1"}, wait=16),
    "equalizer-outputs":  dict(env={"FLACCY_ROUTE": "equalizer-outputs", "FLACCY_PLAYING": "1"}, wait=16),
    "equalizer-import":   dict(env={"FLACCY_ROUTE": "equalizer-import", "FLACCY_PLAYING": "1"}, wait=16),
    "lyrics":       dict(env={"FLACCY_ROUTE": "lyrics", "FLACCY_PLAYING": "1"}, wait=18),
    "queue":        dict(env={"FLACCY_ROUTE": "queue"}, wait=12),
    "charts":       dict(env={"FLACCY_ROUTE": "charts"}, wait=12),
    "year":         dict(env={"FLACCY_ROUTE": "year", "FLACCY_YEAR": "2026"}, wait=12),
    "settings":     dict(env={"FLACCY_ROUTE": "settings"}, wait=10),
    "listening":    dict(env={"FLACCY_ROUTE": "listening-guide"}, wait=10),
    "enrichment":   dict(env={"FLACCY_ROUTE": "enrichment"}, wait=10),
    "wantlist":     dict(env={"FLACCY_ROUTE": "wantlist"}, wait=10),
    "watch-sync":   dict(env={"FLACCY_ROUTE": "watch-sync"}, wait=12, extra=["--demo-watch-sync"]),
    "paywall":      dict(env={"FLACCY_ROUTE": "paywall"}, wait=10),
    "debut":        dict(env={"FLACCY_DEBUT": "1"}, wait=9, extra=["--debut"]),
}


def run(*args, env=None, check=True):
    return subprocess.run(args, env=env, check=check, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--udid", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--lang", default="en")
    parser.add_argument("--locale", default=None)
    parser.add_argument("--appearance", default="dark")
    parser.add_argument("--only", default="")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    run("xcrun", "simctl", "ui", args.udid, "appearance", args.appearance)
    names = [n for n in args.only.split(",") if n] or list(SCREENS)
    locale = args.locale or args.lang.replace("-", "_")

    for name in names:
        screen = SCREENS[name]
        env = dict(os.environ)
        for key, value in screen["env"].items():
            env["SIMCTL_CHILD_" + key] = value
        launch = ["xcrun", "simctl", "launch", "--terminate-running-process", args.udid, APP,
                  "--seed-screenshots", "-AppleLanguages", f"({args.lang})", "-AppleLocale", locale,
                  "-albumSort", "title", "-artistDetailAlbumSort", "title"] + screen.get("extra", [])
        subprocess.run(launch, env=env, check=True, capture_output=True)
        time.sleep(screen["wait"])
        target = os.path.join(args.out, f"{name}.png")
        run("xcrun", "simctl", "io", args.udid, "screenshot", target)
        print("shot", name, flush=True)


if __name__ == "__main__":
    main()
