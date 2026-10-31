#!/usr/bin/env python3
"""Writes a FLAC library shaped like the ones people really scan: Artist/Album
folders, every track carrying its album's embedded cover, and covers from a
600 px JPEG up to a 3000 px PNG scan, plus albums with no cover at all.

Usage: make-flac-library.py OUT_DIR [--albums 50] [--tracks 10] [--seconds 20] [--uniform-cover 600]
Push it into the scan bench with `devicectl device copy to ... --destination
"Documents/Bench FLAC"` and launch with `--bench-scan --bench-fresh`.
"""
import argparse
import random
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image

COVERS = [
    ("jpeg", 1200),
    ("jpeg", 3000),
    ("png", 3000),
    ("jpeg", 600),
    (None, 0),
]


def cover(path: Path, kind: str, size: int, rng: random.Random) -> None:
    base = Image.linear_gradient("L").resize((size, size)).convert("RGB")
    tint = Image.new("RGB", (size, size), tuple(rng.randrange(256) for _ in range(3)))
    noise = Image.effect_noise((size, size), 40).convert("RGB")
    image = Image.blend(Image.blend(base, tint, 0.5), noise, 0.2 if kind == "png" else 0.35)
    if kind == "png":
        image.save(path, "PNG")
    else:
        image.save(path, "JPEG", quality=92)


def template(path: Path, seconds: int, hires: bool) -> None:
    rate = "96000" if hires else "44100"
    sample = "s32" if hires else "s16"
    subprocess.run(
        [
            "ffmpeg", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", f"sine=frequency=440:duration={seconds}:sample_rate={rate}",
            "-ac", "2", "-sample_fmt", sample, *(["-bits_per_raw_sample", "24"] if hires else []),
            str(path),
        ],
        check=True,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("out", type=Path)
    parser.add_argument("--albums", type=int, default=50)
    parser.add_argument("--tracks", type=int, default=10)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--uniform-cover", type=int, default=0, help="give every album a JPEG cover of this size")
    args = parser.parse_args()

    rng = random.Random(7)
    if args.out.exists():
        shutil.rmtree(args.out)
    args.out.mkdir(parents=True)
    work = Path(tempfile.mkdtemp())
    templates = {False: work / "cd.flac", True: work / "hires.flac"}
    for hires, path in templates.items():
        template(path, args.seconds, hires)

    for album in range(args.albums):
        artist = f"Bench Artist {album % 17 + 1:02d}"
        title = f"Bench Album {album + 1:03d}"
        kind, size = ("jpeg", args.uniform_cover) if args.uniform_cover else COVERS[album % len(COVERS)]
        art = None
        if kind:
            art = work / f"cover{album}.{'png' if kind == 'png' else 'jpg'}"
            cover(art, kind, size, rng)
        folder = args.out / artist / f"{title} (20{album % 25:02d})"
        folder.mkdir(parents=True)
        hires = album % 4 == 0
        for track in range(1, args.tracks + 1):
            song = folder / f"{track:02d} - Bench Song {track}.flac"
            shutil.copyfile(templates[hires], song)
            tags = [
                f"--set-tag=TITLE=Bench Song {track}",
                f"--set-tag=ARTIST={artist}",
                f"--set-tag=ALBUMARTIST={artist}",
                f"--set-tag=ALBUM={title}",
                f"--set-tag=TRACKNUMBER={track}",
                f"--set-tag=DATE=20{album % 25:02d}",
            ]
            command = ["metaflac", "--remove-all-tags", *tags]
            if art:
                command.append(f"--import-picture-from=3||||{art}")
            subprocess.run([*command, str(song)], check=True)
        print(f"{folder.relative_to(args.out)}: {kind or 'no'} cover {size or ''}", flush=True)
    shutil.rmtree(work)
    return 0


if __name__ == "__main__":
    sys.exit(main())
