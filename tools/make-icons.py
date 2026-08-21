#!/usr/bin/env python3
"""Builds the app icons from a single definition of the shape.

The motif is the accent chip the window itself uses: a square in #ec3013 covering the
middle 75% of a transparent canvas. Transparent rather than a light tile, so it looks
the same on a light taskbar and a dark one - a tile inverts its character between the
two, and one of the two always looks wrong.

    python3 tools/make-icons.py

Writes into crates/gui/assets/:
    icon.ico   multi-size, for the Win32 resource (Explorer, shortcut, taskbar)
    icon.png   256x256, fallback for icon themes without SVG support
    icon.svg   for hicolor/scalable on Linux

Keep in step with `icon_rgba()` in crates/gui/src/main.rs, which draws the same shape
at runtime. Change INSET or ACCENT here and it has to change there too.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ACCENT = (236, 48, 19, 255)   # --accent, the same value the website uses
INSET = 0.125                 # per side, so the square covers 75% of the edge
ICO_SIZES = [16, 24, 32, 48, 64, 128, 256]

OUT = Path(__file__).resolve().parent.parent / "crates" / "gui" / "assets"


def square(size: int) -> Image.Image:
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    a = round(size * INSET)
    ImageDraw.Draw(im).rectangle([a, a, size - a - 1, size - a - 1], fill=ACCENT)
    return im


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    big = square(256)
    big.save(OUT / "icon.png")
    # Pillow packs every requested size into the one .ico file.
    big.save(OUT / "icon.ico", format="ICO",
             sizes=[(s, s) for s in ICO_SIZES])
    pct = INSET * 100
    (OUT / "icon.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32">\n'
        f'  <rect x="{pct/100*32:g}" y="{pct/100*32:g}" '
        f'width="{(1-2*INSET)*32:g}" height="{(1-2*INSET)*32:g}" '
        f'fill="#{ACCENT[0]:02x}{ACCENT[1]:02x}{ACCENT[2]:02x}"/>\n'
        '</svg>\n', encoding="utf-8")
    for f in ("icon.ico", "icon.png", "icon.svg"):
        p = OUT / f
        print(f"  {p.relative_to(OUT.parent.parent.parent)}  {p.stat().st_size} B")


if __name__ == "__main__":
    main()
