#!/usr/bin/env python3
"""Erzeugt die App-Icons aus einer einzigen Geometrie-Definition.

Das Motiv ist der Akzent-Chip aus dem Fenster selbst: ein Quadrat in #ec3013,
das die mittleren 75 % einer transparenten Flaeche einnimmt. Transparenter Grund
statt heller Kachel, damit es auf heller und dunkler Taskbar gleich aussieht.

    python3 tools/make-icons.py

Schreibt nach crates/gui/assets/:
    icon.ico   Multi-Size fuer die Win32-Resource (Explorer, Verknuepfung, Taskbar)
    icon.png   256x256, Rueckfall fuer Icon-Themes ohne SVG
    icon.svg   fuer hicolor/scalable unter Linux

WICHTIG: `icon_rgba()` in crates/gui/src/main.rs erzeugt dasselbe Motiv zur
Laufzeit. Wird INSET oder ACCENT hier geaendert, muss es dort mitgezogen werden.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ACCENT = (236, 48, 19, 255)   # --accent, identisch zur Website
INSET = 0.125                 # je Seite -> Quadrat nimmt 75 % der Kante ein
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
    # Pillow legt alle angeforderten Groessen in eine .ico-Datei.
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
