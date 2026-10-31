#!/usr/bin/env python3
"""
freshness-lint.py — flags stale present-tense volatile claims in Canon/+Thinking
note bodies (Phase 4b). Modeled on obsidian-second-brain's freshness lint.

A "volatile claim" is a line matching patterns like "currently", "right now",
"as of now", "at the moment", "is currently", "has N open", "there are N" that
does NOT carry a "(as of YYYY-MM-DD)" freshness stamp on the SAME line. Such a
line is a fact that will silently rot — worth a human glance to confirm it's
still true or add a stamp.

Exempt (never flagged):
  - frontmatter
  - a note whose frontmatter `type:` is reflection, event, or ai-reflection
    (point-in-time by nature — "currently" there just describes that moment)
  - lines under a "## YYYY-MM-DD" dated heading (any level, e.g. "## 2026-07-01")
  - lines under a "## Evolution" heading (each entry is already individually dated)
  - lines under a "# Raw" heading (verbatim transcript, shell-owned, read-only)
  - lines inside ``` code fences

Report-only: never edits/deletes anything. One line per finding:
  relpath:lineno: <claim excerpt>

Usage: freshness-lint.py [--vault DIR] [--limit N]
Stdlib only.
"""
import argparse
import os
import re
import sys

VOLATILE_RE = re.compile(
    r"\b(currently|right now|as of now|at the moment|is currently|"
    r"has \d+ open|there (?:is|are) \d+)\b",
    re.IGNORECASE,
)
STAMP_RE = re.compile(r"\(as of \d{4}-\d{2}-\d{2}\)", re.IGNORECASE)
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
DATED_HEADING_RE = re.compile(r"^#{1,6}\s+\d{4}-\d{2}-\d{2}\b")
EVOLUTION_HEADING_RE = re.compile(r"^#{1,6}\s+Evolution\b", re.IGNORECASE)
RAW_HEADING_RE = re.compile(r"^#\s+Raw\b")
EXEMPT_TYPES = {"reflection", "event", "ai-reflection"}


def iter_notes(vault):
    """Yield (relpath, abspath) for every Canon/Thinking note, excluding
    Canon/_stubs/ (intentional stubs, not content)."""
    for sub in ("Canon", "Thinking"):
        base = os.path.join(vault, sub)
        if not os.path.isdir(base):
            continue
        for root, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d != "_stubs"]
            for f in files:
                if f.endswith(".md"):
                    p = os.path.join(root, f)
                    rel = os.path.relpath(p, vault).replace(os.sep, "/")
                    yield rel, p


def frontmatter_type(text):
    if not text.startswith("---"):
        return ""
    end = text.find("\n---", 3)
    if end == -1:
        return ""
    for line in text[3:end].splitlines():
        s = line.strip()
        if s.startswith("type:"):
            return s.split(":", 1)[1].strip().strip('"').strip("'")
    return ""


def body_lines_with_offset(text):
    """Return (lines, offset) where offset is the 0-based index of the first
    body line in the original file (for accurate line numbers)."""
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        for i in range(1, len(lines)):
            if lines[i].strip() == "---":
                return lines[i + 1:], i + 1
    return lines, 0


def find_findings(rel, text):
    findings = []
    if frontmatter_type(text) in EXEMPT_TYPES:
        return findings

    body_lines, offset = body_lines_with_offset(text)
    in_fence = False
    in_raw = False
    dated_container = False

    for i, line in enumerate(body_lines):
        stripped = line.strip()

        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue

        m = HEADING_RE.match(line)
        if m:
            in_raw = bool(RAW_HEADING_RE.match(line))
            dated_container = bool(
                DATED_HEADING_RE.match(line) or EVOLUTION_HEADING_RE.match(line)
            )
            continue

        if in_raw or dated_container:
            continue
        if STAMP_RE.search(line):
            continue

        if VOLATILE_RE.search(line):
            lineno = offset + i + 1
            findings.append((rel, lineno, stripped[:120]))

    return findings


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", default=os.environ.get("VAULT_DIR", os.getcwd()))
    ap.add_argument("--limit", type=int, default=0,
                     help="cap total findings printed (0 = unlimited)")
    args = ap.parse_args(argv)

    all_findings = []
    for rel, p in iter_notes(args.vault):
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        all_findings.extend(find_findings(rel, text))

    all_findings.sort(key=lambda f: (f[0], f[1]))
    if args.limit > 0:
        all_findings = all_findings[: args.limit]

    for rel, lineno, excerpt in all_findings:
        print(f"{rel}:{lineno}: {excerpt}")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
