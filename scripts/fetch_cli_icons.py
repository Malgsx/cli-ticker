#!/usr/bin/env python3
"""Download Simple Icons for every registry entry and rasterize them as
monochrome template PNGs (black on transparent; AppKit tints them).

Dev-only: the PNGs are committed, so `./cli build` does not need this script.
Requires: pip install cairosvg
"""
import json
import pathlib
import urllib.request

import cairosvg

SIMPLE_ICONS_VERSION = "16.32.0"
ROOT = pathlib.Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "Assets" / "CLIRegistry" / "registry.json"
ICONS = ROOT / "Assets" / "CLIRegistry" / "icons"
SIZE = 32


def main() -> None:
    entries = json.loads(REGISTRY.read_text())["clis"]
    slugs = sorted({entry["icon"] for entry in entries if entry.get("icon")})
    ICONS.mkdir(parents=True, exist_ok=True)
    for slug in slugs:
        url = f"https://cdn.jsdelivr.net/npm/simple-icons@{SIMPLE_ICONS_VERSION}/icons/{slug}.svg"
        with urllib.request.urlopen(url) as response:
            svg = response.read()
        cairosvg.svg2png(bytestring=svg, write_to=str(ICONS / f"{slug}.png"), output_width=SIZE, output_height=SIZE)
        print(f"{slug}.png")


if __name__ == "__main__":
    main()
