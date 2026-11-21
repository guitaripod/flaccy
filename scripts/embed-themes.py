#!/usr/bin/env python3
"""Writes the built-in themes' theme.toml files into FlaccyCore.

The documents in linux/data/themes are the one home of the built-in themes.
The Linux client embeds them with include_str!; the Apple clients read the
Swift file this script writes, and a Rust test fails when the two differ.

    python3 scripts/embed-themes.py
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
THEMES = ROOT / "linux" / "data" / "themes"
BUILTIN = ROOT / "linux" / "src" / "theme" / "builtin.rs"
OUT = ROOT / "Core" / "FlaccyCore" / "Sources" / "FlaccyCore" / "Themes" / "BuiltinThemeDocuments.swift"


def ids() -> list[str]:
    return re.findall(r'include_str!\("\.\./\.\./data/themes/([a-z0-9-]+)/theme\.toml"\)', BUILTIN.read_text())


def main() -> None:
    entries = []
    for theme in ids():
        document = (THEMES / theme / "theme.toml").read_text()
        if '"""#' in document:
            raise SystemExit(f"{theme}: theme.toml holds the sequence that ends a Swift raw string")
        entries.append(f'        ("{theme}", #"""\n{document}"""#),')
    OUT.write_text(
        "extension ThemeLibrary {\n\n"
        "    /// The theme.toml of every theme that ships in the app, in gallery order.\n"
        "    /// Written by scripts/embed-themes.py from linux/data/themes, their one\n"
        "    /// home; a Rust test fails when this copy differs from them.\n"
        "    static let builtinDocuments: [(id: String, document: String)] = [\n"
        + "\n".join(entries)
        + "\n    ]\n}\n"
    )
    print(f"wrote {OUT.relative_to(ROOT)} ({len(entries)} themes)")


if __name__ == "__main__":
    main()
