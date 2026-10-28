#!/usr/bin/env python3
"""Merge several PDFs into one file, entirely offline.

Usage:
  pdf_merger.py -o out.pdf a.pdf b.pdf c.pdf
  pdf_merger.py -o out.pdf a.pdf:1-3,7 b.pdf:2-    # page ranges (1-based)
  pdf_merger.py -o out.pdf --sort scans/           # every *.pdf in a folder
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from pypdf import PdfReader, PdfWriter


def parse_ranges(spec: str, total: int) -> list[int]:
    """'1-3,7,9-' -> zero-based page indices. Open end means last page."""
    pages: list[int] = []
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        lo, sep, hi = part.partition("-")
        start = int(lo) if lo else 1
        end = (int(hi) if hi else total) if sep else start
        if not (1 <= start <= end <= total):
            raise ValueError(f"range '{part}' outside 1-{total}")
        pages.extend(range(start - 1, end))
    return pages


def expand(args: list[str], sort: bool) -> list[tuple[Path, str | None]]:
    items: list[tuple[Path, str | None]] = []
    for arg in args:
        path_str, _, spec = arg.partition(":")
        # Don't mis-split a Windows drive letter like C:\file.pdf
        if len(path_str) == 1 and spec[:1] in ("\\", "/"):
            path_str, spec = arg, ""
        p = Path(path_str)
        if p.is_dir():
            found = [f for f in p.iterdir() if f.suffix.lower() == ".pdf"]
            items.extend((f, None) for f in sorted(found, key=lambda f: f.name.lower()))
        else:
            items.append((p, spec or None))
    if sort:
        items.sort(key=lambda it: it[0].name.lower())
    return items


def merge(items: list[tuple[Path, str | None]], output: Path) -> int:
    writer = PdfWriter()
    for path, spec in items:
        reader = PdfReader(path)
        if reader.is_encrypted and not reader.decrypt(""):
            raise ValueError(f"{path} is password-protected")
        total = len(reader.pages)
        indices = parse_ranges(spec, total) if spec else range(total)
        for i in indices:
            writer.add_page(reader.pages[i])
        writer.add_outline_item(path.stem, len(writer.pages) - len(list(indices)))
    with output.open("wb") as fh:
        writer.write(fh)
    return len(writer.pages)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+", help="PDF files, folders, or file.pdf:range")
    ap.add_argument("-o", "--output", required=True, type=Path)
    ap.add_argument("--sort", action="store_true", help="sort all inputs by filename")
    ap.add_argument("-f", "--force", action="store_true", help="overwrite output")
    a = ap.parse_args()

    if a.output.exists() and not a.force:
        print(f"error: {a.output} exists (use --force)", file=sys.stderr)
        return 1
    items = expand(a.inputs, a.sort)
    if not items:
        print("error: no PDFs found", file=sys.stderr)
        return 1
    missing = [p for p, _ in items if not p.is_file()]
    if missing:
        print("error: not found: " + ", ".join(map(str, missing)), file=sys.stderr)
        return 1
    if any(p.resolve() == a.output.resolve() for p, _ in items):
        print("error: output is also an input", file=sys.stderr)
        return 1
    try:
        n = merge(items, a.output)
    except Exception as e:  # corrupt PDF, bad range, encrypted
        print(f"error: {e}", file=sys.stderr)
        return 1
    print(f"Merged {len(items)} file(s), {n} pages -> {a.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
