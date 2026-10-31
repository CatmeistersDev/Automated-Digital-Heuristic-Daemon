#!/usr/bin/env python3
"""
boundary-score.py — graph frontier scoring over the Canon/+Thinking wikilink
graph (Phase 4b, per claude-obsidian's "boundary" idea).

Builds the wikilink graph: an edge note A -> note B exists when A's body
contains `[[B]]` (outside code fences), resolved case-insensitively to note
basenames. Then for every note:

  boundary_score = (out_degree - in_degree) * recency_weight

recency_weight has a 30-day halflife on file mtime: 0.5 ** (age_days / 30).
A HIGH score means a note that's been touched recently but isn't well
backlinked yet — a "frontier" note worth integrating into the rest of the
vault with more links.

CLI: prints the top N (default 15) as
  score<TAB>relpath<TAB>out_degree<TAB>in_degree

Report-only. Stdlib only.
"""
import argparse
import os
import re
import sys
import time

WIKILINK_RE = re.compile(r"\[\[([^\]]+)\]\]")


def iter_notes(vault):
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


def strip_code_fences(text):
    out = []
    in_fence = False
    for line in text.splitlines():
        if line.strip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        out.append(line)
    return "\n".join(out)


def extract_link_names(text):
    names = []
    for m in WIKILINK_RE.finditer(text):
        inner = m.group(1).strip()
        if "|" in inner:
            inner = inner.split("|", 1)[0]
        inner = inner.split("/")[-1].strip()
        if inner.endswith(".md"):
            inner = inner[:-3]
        inner = inner.strip()
        if inner:
            names.append(inner)
    return names


def build_graph(vault):
    """Returns (relpaths, out_links, in_degree, mtimes)."""
    basename_index = {}   # lowercase basename -> relpath
    bodies = {}            # relpath -> fence-stripped text
    mtimes = {}
    for rel, p in iter_notes(vault):
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        basename = os.path.splitext(os.path.basename(rel))[0]
        basename_index[basename.lower()] = rel
        bodies[rel] = strip_code_fences(text)
        try:
            mtimes[rel] = os.path.getmtime(p)
        except OSError:
            mtimes[rel] = time.time()

    out_links = {rel: set() for rel in bodies}
    for rel, text in bodies.items():
        for name in extract_link_names(text):
            target = basename_index.get(name.lower())
            if target and target != rel:
                out_links[rel].add(target)

    in_degree = {rel: 0 for rel in bodies}
    for rel, targets in out_links.items():
        for t in targets:
            in_degree[t] += 1

    return bodies, out_links, in_degree, mtimes


def recency_weight(mtime, now, halflife_days=30.0):
    age_days = max(0.0, (now - mtime) / 86400.0)
    return 0.5 ** (age_days / halflife_days)


def compute_scores(vault, now=None):
    bodies, out_links, in_degree, mtimes = build_graph(vault)
    now = now if now is not None else time.time()
    rows = []
    for rel in bodies:
        out_deg = len(out_links[rel])
        in_deg = in_degree.get(rel, 0)
        w = recency_weight(mtimes[rel], now)
        score = (out_deg - in_deg) * w
        rows.append((score, rel, out_deg, in_deg))
    rows.sort(key=lambda r: (-r[0], r[1]))
    return rows


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vault", default=os.environ.get("VAULT_DIR", os.getcwd()))
    ap.add_argument("--top", type=int, default=15)
    args = ap.parse_args(argv)

    rows = compute_scores(args.vault)
    for score, rel, out_deg, in_deg in rows[: args.top]:
        print(f"{score:.3f}\t{rel}\t{out_deg}\t{in_deg}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
