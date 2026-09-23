#!/usr/bin/env python3
"""Every string the compiler extracts must be in the catalog, in every locale.

Xcode records each `String(localized:)` key it compiles in a `.stringsdata`
file beside the object code. A key the catalog does not carry — including one
that differs only in how its format specifiers are spelled, such as a
hand-written `%1$lld` where the compiler emits `%lld` — silently renders in
English for every locale. This compares the two and names the gaps.

Runs on the Mac after `scripts/build-mac.sh` has built into `build/dd-*`; the
watch app keeps its own catalog and is skipped. Only the newest record per
source file and target counts, because every architecture and SDK an earlier
build compiled for keeps its stale copy, and a record whose source is gone is
ignored. Exits non-zero only with
`--strict`, so a build can report gaps without failing on them; `--unused`
also lists catalog entries no compiled code asks for any more.

Usage: python3 scripts/check-strings.py [--strict] [--unused] build/dd-ios build/dd-mac
"""
import json
import pathlib
import plistlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "flaccy" / "Localizable.xcstrings"
SOURCE_DIRS = (str(ROOT / "flaccy") + "/", str(ROOT / "flaccyMac") + "/")


def extracted_keys(build_dirs):
    newest = {}
    for build_dir in build_dirs:
        for path in pathlib.Path(build_dir).rglob("*.stringsdata"):
            raw = path.read_bytes()
            try:
                data = json.loads(raw)
            except ValueError:
                data = plistlib.loads(raw)
            source = data.get("source", "")
            if not source.startswith(SOURCE_DIRS) or not pathlib.Path(source).exists():
                continue
            slot = (source, path.parents[2].name)
            mtime = path.stat().st_mtime
            if slot not in newest or mtime > newest[slot][0]:
                newest[slot] = (mtime, data)
    keys = {}
    for (source, _), (_, data) in newest.items():
        for entry in data.get("tables", {}).get("Localizable", []):
            keys.setdefault(entry["key"], set()).add(source[len(str(ROOT)) + 1:])
    return keys


def is_translated(localization):
    unit = localization.get("stringUnit")
    if unit is not None:
        return unit.get("state") == "translated"
    variations = localization.get("variations", {})
    units = [v.get("stringUnit", {}) for kind in variations.values() for v in kind.values()]
    substitutions = localization.get("substitutions", {})
    for substitution in substitutions.values():
        for kind in substitution.get("variations", {}).values():
            units.extend(v.get("stringUnit", {}) for v in kind.values())
    return bool(units) and all(u.get("state") == "translated" for u in units)


def main():
    flags = {a for a in sys.argv[1:] if a.startswith("--")}
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    strict = "--strict" in flags
    if not args:
        sys.exit(__doc__)
    keys = extracted_keys(args)
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))["strings"]
    locales = sorted({l for entry in catalog.values() for l in entry.get("localizations", {})} - {"en"})

    missing = sorted(k for k in keys if k not in catalog)
    incomplete = {}
    for key in sorted(k for k in keys if k in catalog):
        entry = catalog[key]
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        gaps = [l for l in locales if l not in localizations or not is_translated(localizations[l])]
        if gaps:
            incomplete[key] = gaps

    unused = sorted(k for k in catalog if k not in keys)
    print(f"check-strings: {len(keys)} keys compiled, {len(missing)} missing from the catalog, "
          f"{len(incomplete)} not translated into every locale ({', '.join(locales)}), "
          f"{len(unused)} catalog entries unused")
    for key in missing:
        print(f"  MISSING    {key!r}  ({', '.join(sorted(keys[key]))})")
    for key, gaps in incomplete.items():
        print(f"  INCOMPLETE {key!r}  lacks {', '.join(gaps)}")
    if "--unused" in flags:
        for key in unused:
            print(f"  UNUSED     {key!r}")
    if strict and (missing or incomplete):
        sys.exit(1)


if __name__ == "__main__":
    main()
