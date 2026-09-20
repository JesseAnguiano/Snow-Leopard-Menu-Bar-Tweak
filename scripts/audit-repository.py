#!/usr/bin/env python3
"""Release hygiene audit for the public source tree.

The audit is intentionally dependency-free so it can run with the Python bundled
with Xcode Command Line Tools. It rejects machine-specific paths, personal-looking
email addresses, common author/XMP metadata in artwork, and generated build output.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]

TEXT_SUFFIXES = {
    ".c", ".command", ".h", ".inc", ".json", ".m", ".md", ".plist",
    ".py", ".sh", ".txt", ".yml", ".yaml",
}
TEXT_NAMES = {".editorconfig", ".gitattributes", ".gitignore", "LICENSE", "Makefile"}
SKIP_DIRS = {".git", "build", "dist", "__pycache__"}
ALLOWED_EMAILS = {"git@github.com"}
EMAIL_RE = re.compile(
    r"(?<![\w.+-])[A-Z0-9._%+-]+@[A-Z][A-Z0-9.-]*\.[A-Z]{2,}(?![\w.-])",
    re.I,
)

TEXT_PATH_MARKERS = (
    "/Users/",
    "/home/",
    "file:///Users/",
    "file:///home/",
    "\\\\Users\\",
)
BINARY_PATH_MARKERS = tuple(marker.encode("utf-8") for marker in TEXT_PATH_MARKERS)
DOCUMENT_METADATA_MARKERS = (
    b"/Author",
    b"/Creator",
    b"/CreationDate",
    b"/ModDate",
    b"<x:xmpmeta",
    b"<rdf:RDF",
    b"<stRef:filePath>",
    b"photoshop:AuthorsPosition",
    b"dc:creator",
)


def iter_public_files():
    for path in ROOT.rglob("*"):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        if any(part in SKIP_DIRS for part in rel.parts):
            continue
        yield path, rel


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def audit_text(path: Path, rel: Path) -> None:
    text = path.read_text(encoding="utf-8", errors="replace")
    if path.name != Path(__file__).name:
        for marker in TEXT_PATH_MARKERS:
            if marker in text:
                fail(f"machine-specific path marker {marker!r} in {rel}")
    emails = {match.group(0) for match in EMAIL_RE.finditer(text)} - ALLOWED_EMAILS
    if emails:
        fail(f"personal-looking email address in {rel}: {sorted(emails)}")


def audit_binary(path: Path, rel: Path) -> None:
    data = path.read_bytes()
    for marker in BINARY_PATH_MARKERS:
        if marker in data:
            fail(f"machine-specific path embedded in {rel}: {marker!r}")

    suffix = path.suffix.lower()
    if suffix in {".pdf", ".png", ".tif", ".tiff", ".jpg", ".jpeg"}:
        found = [marker.decode("ascii", errors="replace") for marker in DOCUMENT_METADATA_MARKERS if marker in data]
        if found:
            fail(f"author/XMP metadata marker in {rel}: {found}")


def main() -> None:
    count = 0
    for path, rel in iter_public_files():
        count += 1
        if (
            path.suffix.lower() in TEXT_SUFFIXES
            or path.name in TEXT_NAMES
            or path.name.endswith(".blacklist")
        ):
            audit_text(path, rel)
        else:
            audit_binary(path, rel)

    print(f"Repository privacy/release audit passed ({count} files).")


if __name__ == "__main__":
    main()
