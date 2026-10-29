#!/usr/bin/env python3
"""Swap .png references in cartoon.json for matching .jpeg files, then move the stale PNGs to to_delete/.

Run from the cartoon folder (the one containing cartoon.json and images/):
    python3 png_to_jpeg.py            # do it
    python3 png_to_jpeg.py --dry-run  # just report
    python3 png_to_jpeg.py --all      # also move paired PNGs that cartoon.json doesn't reference

cartoon.json is edited as text, so its formatting is preserved; a backup is saved as cartoon.json.bak.
"""
import argparse, re, shutil, sys
from pathlib import Path

IMAGES = Path("images")
JSON_FILE = Path("cartoon.json")
TO_DELETE = Path("to_delete")
JPEG_EXTS = (".jpeg", ".jpg")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="report only; change nothing")
    ap.add_argument("--all", action="store_true", help="also move paired PNGs not referenced in cartoon.json")
    args = ap.parse_args()

    if not IMAGES.is_dir() or not JSON_FILE.is_file():
        sys.exit("Run this from the folder that contains cartoon.json and images/.")

    # 1. PNGs in images/ that have an identically named JPEG
    pairs = {}  # stem -> jpeg filename
    for png in IMAGES.iterdir():
        if png.suffix.lower() != ".png":
            continue
        for ext in JPEG_EXTS:
            jpg = next((p for p in IMAGES.iterdir()
                        if p.stem == png.stem and p.suffix.lower() == ext), None)
            if jpg:
                pairs[png.stem] = (png, jpg)
                break
    print(f"PNG/JPEG pairs in images/: {len(pairs)}")
    if not pairs:
        return

    # 2. Replace matching .png references in cartoon.json
    text = JSON_FILE.read_text(encoding="utf-8")
    replaced = set()

    def swap(m):
        prefix, stem, ext = m.group(1), m.group(2), m.group(3)
        if stem in pairs:
            replaced.add(stem)
            return f'"{prefix}{stem}{pairs[stem][1].suffix}"'
        return m.group(0)

    # any JSON string ending in <name>.png, keeping whatever path prefix it has (images/, res://..., etc.)
    new_text = re.sub(r'"((?:[^"\\]|\\.)*?[/\\]?)([^"/\\]+)(\.png)"', swap, text, flags=re.IGNORECASE)
    count = len(re.findall(r'\.png"', text, re.IGNORECASE)) - len(re.findall(r'\.png"', new_text, re.IGNORECASE))

    for stem in sorted(replaced):
        print(f"  {stem}.png -> {pairs[stem][1].name}")
    print(f"References replaced in {JSON_FILE}: {count} ({len(replaced)} distinct images)")

    unreferenced = sorted(set(pairs) - replaced)
    if unreferenced:
        print(f"Paired PNGs not referenced in {JSON_FILE}: {len(unreferenced)}"
              + ("" if args.all else " (left in place; use --all to move them too)"))
        for stem in unreferenced:
            print(f"  {stem}.png")

    to_move = sorted(replaced | (set(unreferenced) if args.all else set()))

    if args.dry_run:
        print(f"Dry run: would move {len(to_move)} PNG(s) to {TO_DELETE}/ and rewrite {JSON_FILE}.")
        return

    # 3. Write JSON (with backup), then move the stale PNGs
    if replaced:
        shutil.copy2(JSON_FILE, JSON_FILE.with_suffix(".json.bak"))
        JSON_FILE.write_text(new_text, encoding="utf-8")
    TO_DELETE.mkdir(exist_ok=True)
    for stem in to_move:
        png = pairs[stem][0]
        dest = TO_DELETE / png.name
        if dest.exists():
            dest = TO_DELETE / f"{png.stem}_dup{png.suffix}"
        shutil.move(str(png), str(dest))
    print(f"Moved {len(to_move)} PNG(s) to {TO_DELETE}/")

if __name__ == "__main__":
    main()
