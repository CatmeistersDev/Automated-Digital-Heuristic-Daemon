#!/usr/bin/env python3
"""
lineage.py — walks the derived_from: frontmatter lineage convention (Phase 4b).

Convention: any Canon/Thinking note may declare `derived_from:` as a list of
wikilink strings (same block-list shape as `linked:`/`mentions:`), pointing at
the note(s) it was derived from:

    ---
    derived_from:
      - "[[Some Origin Note]]"
    ---

Set by run-researcher.sh (a research note's derived_from is the action that
triggered it, when one exists) and by graduate.sh's ONE-WAY `graduated_from`
field for promotion lineage (a different, narrower field — not walked here).

Usage:
  lineage.py <note>          # walk UP: <note>'s ancestor chain (what it derives
                              # from, and what THAT derives from, ...)
  lineage.py <note> --down   # walk DOWN: notes that declare <note> (directly or
                              # transitively) as their derived_from — a reverse,
                              # grep-based scan of the whole vault

<note> may be a bare name, a relative path, or a path with .md — resolved
case-insensitively against Canon/+Thinking/ note basenames. Cycle-safe. Stdlib
only.
"""
import argparse
import os
import re
import sys

WIKILINK_RE = re.compile(r"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]")


def strip_quotes(s):
    s = s.strip()
    if len(s) >= 2 and s[0] == s[-1] and s[0] in ("'", '"'):
        return s[1:-1]
    return s


def parse_frontmatter_list(text, key):
    """Parse a YAML block-list value for `key:` (same shape as `linked:`), plus a
    simple inline `key: [a, b]` form. Frontmatter-only."""
    if not text.startswith("---"):
        return []
    end = text.find("\n---", 3)
    fm = text[3:end] if end != -1 else text[3:]
    lines = fm.splitlines()
    out = []
    for i, line in enumerate(lines):
        m = re.match(rf"^{re.escape(key)}\s*:\s*(.*)$", line)
        if not m:
            continue
        rest = m.group(1).strip()
        if rest.startswith("["):
            inner = rest.strip("[]")
            for part in inner.split(","):
                part = strip_quotes(part.strip())
                if part:
                    out.append(part)
        elif rest:
            out.append(strip_quotes(rest))
        j = i + 1
        while j < len(lines) and re.match(r"^\s*-\s+", lines[j]):
            item = re.sub(r"^\s*-\s+", "", lines[j]).strip()
            out.append(strip_quotes(item))
            j += 1
        break
    return out


def basename_of(name):
    name = name.strip().split("/")[-1]
    if name.endswith(".md"):
        name = name[:-3]
    return name


def wikilink_targets(values):
    targets = []
    for v in values:
        m = WIKILINK_RE.search(v)
        if m:
            targets.append(basename_of(m.group(1)))
        elif v.strip():
            targets.append(basename_of(v))
    return targets


def build_index(vault):
    """basename (lowercase) -> relpath, for every Canon/Thinking note."""
    idx = {}
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
                    idx[f[:-3].lower()] = rel
    return idx


def read_text(vault, rel):
    try:
        with open(os.path.join(vault, rel), encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def resolve_note_arg(vault, note_arg, idx):
    if not os.path.isabs(note_arg):
        p = os.path.join(vault, note_arg)
        if os.path.isfile(p):
            return os.path.relpath(p, vault).replace(os.sep, "/")
    if os.path.isfile(note_arg):
        return os.path.relpath(note_arg, vault).replace(os.sep, "/")
    return idx.get(basename_of(note_arg).lower())


def walk_up(vault, start_rel, idx):
    """Ancestor chain: start -> its derived_from target -> ... Cycle-safe."""
    chain = []
    seen = set()
    cur = start_rel
    while cur and cur not in seen:
        seen.add(cur)
        chain.append(cur)
        values = parse_frontmatter_list(read_text(vault, cur), "derived_from")
        nxt = None
        for t in wikilink_targets(values):
            resolved = idx.get(t.lower())
            if resolved:
                nxt = resolved
                break
        cur = nxt
    return chain


def walk_down(vault, start_rel, idx):
    """Reverse scan: every note whose derived_from mentions start_rel, directly
    or transitively (BFS). Cycle-safe."""
    reverse = {}
    for rel in set(idx.values()):
        values = parse_frontmatter_list(read_text(vault, rel), "derived_from")
        for t in wikilink_targets(values):
            reverse.setdefault(t.lower(), []).append(rel)

    result = []
    seen = {start_rel}
    frontier = [basename_of(start_rel).lower()]
    while frontier:
        name = frontier.pop(0)
        for c in sorted(reverse.get(name, [])):
            if c in seen:
                continue
            seen.add(c)
            result.append(c)
            frontier.append(basename_of(c).lower())
    return result


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("note")
    ap.add_argument("--down", action="store_true")
    ap.add_argument("--vault", default=os.environ.get("VAULT_DIR", os.getcwd()))
    args = ap.parse_args(argv)

    idx = build_index(args.vault)
    start_rel = resolve_note_arg(args.vault, args.note, idx)
    if not start_rel:
        print(f"Note not found: {args.note}", file=sys.stderr)
        return 1

    if args.down:
        chain = walk_down(args.vault, start_rel, idx)
        if not chain:
            print(f"(no derivatives found for {start_rel})")
            return 0
        for rel in chain:
            print(rel)
        return 0

    chain = walk_up(args.vault, start_rel, idx)
    if len(chain) <= 1:
        print(f"(no derived_from lineage for {start_rel})")
        return 0
    for rel in chain:
        print(rel)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
