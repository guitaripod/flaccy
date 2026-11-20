#!/usr/bin/env python3
"""Reads the ACCESSORY PROBE lines a FLACCY_ACCESSORY_PROBE=1 run wrote to
flaccy.log and reports, for every move of the tab accessory, the largest
single-frame jump of each mini player part: its place measured from the edge
of the accessory it sits nearer, and its opacity. Exits 1 when a visible part jumps.

    python3 scripts/accessory-morph-check.py <flaccy.log> [max-points] [max-alpha]
"""

import re
import sys

PART = re.compile(r"(\w+)=(-?[\d.]+),(-?[\d.]+),(-?[\d.]+),([\d.]+)")
CHANGE = re.compile(r"ACCESSORY PROBE \d+ change (.*)")


def moves(lines):
    current = None
    last = None
    for line in lines:
        change = CHANGE.search(line)
        if change:
            if current:
                yield current
            current = {"label": change.group(1).strip(), "frames": [last] if last else []}
        elif "ACCESSORY PROBE " in line:
            last = {m[0]: tuple(float(v) for v in m[1:]) for m in PART.findall(line)}
            if current is not None:
                current["frames"].append(last)
    if current:
        yield current


def edge(frame, name):
    """The edge of the accessory the part sits nearer in `frame`: a part
    pinned to the trailing edge rides the capsule as it narrows, which is
    not a jump."""
    left, _, width, _ = frame["self"]
    x, _, part_width, _ = frame[name]
    return "left" if x - left <= (left + width) - (x + part_width) else "right"


def measured(frame, name, side):
    left, _, width, _ = frame["self"]
    x, _, part_width, _ = frame[name]
    return x - left if side == "left" else (left + width) - (x + part_width)


def main():
    path = sys.argv[1]
    max_points = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0
    max_alpha = float(sys.argv[3]) if len(sys.argv) > 3 else 0.5
    with open(path, encoding="utf-8", errors="replace") as handle:
        found = list(moves(handle))
    if not found:
        print("no accessory moves logged")
        return 1
    failed = False
    for move in found:
        frames = [f for f in move["frames"] if "self" in f]
        print(f"move {move['label']}: {len(frames)} frames")
        parts = sorted({name for f in frames for name in f if name != "self"})
        for name in parts:
            worst_x, worst_a = 0.0, 0.0
            first = next((f for f in frames if name in f), None)
            side = edge(first, name) if first else "left"
            for before, after in zip(frames, frames[1:]):
                if name not in before or name not in after:
                    continue
                visible = max(before[name][3], after[name][3]) > 0.05
                relative = lambda f: measured(f, name, side)
                if visible and before[name][3] > 0.05 and after[name][3] > 0.05:
                    worst_x = max(worst_x, abs(relative(after) - relative(before)))
                worst_a = max(worst_a, abs(after[name][3] - before[name][3]))
            jumped = worst_x > max_points or worst_a > max_alpha
            failed |= jumped
            print(f"  {name:7s} largest step {worst_x:6.1f} pt  opacity {worst_a:4.2f}{'  JUMP' if jumped else ''}")
    print("ACCESSORY MORPH", "FAILED" if failed else "PASSED")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
