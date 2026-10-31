#!/usr/bin/env python3
"""
mechanical-checks.py — deterministic, LLM-free integrity checks shared by
run-health.sh (fast, scheduled hourly) and ci-check.sh (weekly gate). Phase 1
hardening, 2026-07-18.

Checks:
  (a) near-empty stub: a Canon/Thinking note whose body (frontmatter stripped) is
      under NEAR_EMPTY_CHARS characters (env-overridable, default 80). Excludes
      Canon/_stubs/ — those are INTENTIONAL stubs (see run-implementer.sh), not a
      quality problem.
  (b) manifest drift: cross-checks Meta/MANIFEST.md against the actual Canon/Thinking
      files it should be indexing, both directions —
        - a real note not listed anywhere in the manifest (manifest is stale)
        - a manifest [[wikilink]] entry with no corresponding note file (manifest is
          stale in the other direction — renamed/deleted note)
      Skipped entirely if Meta/MANIFEST.md doesn't exist yet.

Report-only: never deletes, edits, or "fixes" anything — it only prints findings.
One line per finding, tab-separated "SEVERITY<TAB>message" so callers can parse
robustly regardless of message content. Always exits 0 (it is a report generator,
not a gate — callers decide whether/how a finding affects their own exit status).

Usage: mechanical-checks.py [--vault DIR]
Env: NEAR_EMPTY_CHARS (default 80)
Stdlib only.
"""
import os
import re
import sys
import argparse

CANON_TYPES = ("People", "Organizations", "Places", "Projects", "Events",
               "Decisions", "Actions")


def strip_frontmatter(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            rest = text[end + 4:]
            nl = rest.find("\n")
            return rest[nl + 1:] if nl != -1 else ""
    return text


def iter_canon_thinking_notes(vault):
    """Yield (relpath, abspath) for every Canon/Thinking note, excluding
    Canon/_stubs/ (intentional stubs, not quality issues)."""
    for sub in ("Canon", "Thinking"):
        base = os.path.join(vault, sub)
        if not os.path.isdir(base):
            continue
        for root, dirs, files in os.walk(base):
            # prune _stubs/ from traversal (only meaningful directly under Canon/, but
            # cheap and harmless to filter unconditionally at every level)
            dirs[:] = [d for d in dirs if d != "_stubs"]
            for f in files:
                if f.endswith(".md"):
                    p = os.path.join(root, f)
                    # Forward slashes always, even on a Windows dev host: every other
                    # path convention in this codebase (grep patterns, wikilinks,
                    # Meta/MANIFEST.md) is POSIX-style, and the real runtime is a
                    # Linux container where os.sep is "/" anyway.
                    rel = os.path.relpath(p, vault).replace(os.sep, "/")
                    yield rel, p


def check_near_empty(vault, threshold):
    findings = []
    for rel, p in iter_canon_thinking_notes(vault):
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        body = strip_frontmatter(text).strip()
        n = len(body)
        if n < threshold:
            findings.append(
                f"WARN\tnear-empty stub: {rel} ({n} chars < {threshold})"
            )
    return findings


def check_manifest_drift(vault):
    manifest_path = os.path.join(vault, "Meta", "MANIFEST.md")
    if not os.path.isfile(manifest_path):
        return []

    try:
        manifest_text = open(manifest_path, encoding="utf-8", errors="replace").read()
    except OSError:
        return []

    manifest_names = set(re.findall(r'\[\[([^\]|]+)(?:\|[^\]]+)?\]\]', manifest_text))

    # Actual note basenames the manifest is supposed to index: the same 7 typed Canon
    # folders + all of Thinking (mirrors build-manifest.sh's own CANON list + Thinking
    # walk) — NOT every Canon/Thinking file (e.g. Canon/_stubs/ is deliberately outside
    # build-manifest.sh's index too).
    actual_names = set()
    for t in CANON_TYPES:
        d = os.path.join(vault, "Canon", t)
        if not os.path.isdir(d):
            continue
        for f in os.listdir(d):
            if f.endswith(".md"):
                actual_names.add(f[:-3])
    td = os.path.join(vault, "Thinking")
    if os.path.isdir(td):
        for root, _, files in os.walk(td):
            for f in files:
                if f.endswith(".md"):
                    actual_names.add(f[:-3])

    # The manifest's "recent" section legitimately wikilinks notes OUTSIDE the indexed
    # set (Inbox voice notes, Canon/Concepts/ legacy, Canon/_stubs/) — a name is only
    # "renamed/deleted" if no .md with that basename exists anywhere in the vault.
    # Without this, a freshly rebuilt manifest still WARNed hourly on 6 real notes
    # (found 2026-07-20).
    vault_wide_names = set()
    for root, dirs, files in os.walk(vault):
        dirs[:] = [d for d in dirs if d not in (".git", ".obsidian")]
        for f in files:
            if f.endswith(".md"):
                vault_wide_names.add(f[:-3])

    findings = []
    for name in sorted(actual_names - manifest_names):
        findings.append(
            f"WARN\tmanifest drift: {name} exists but is not listed in Meta/MANIFEST.md (stale manifest — rebuild it)"
        )
    for name in sorted(manifest_names - actual_names - vault_wide_names):
        findings.append(
            f"WARN\tmanifest drift: Meta/MANIFEST.md references [[{name}]] but no such note file exists (renamed/deleted — rebuild manifest)"
        )
    return findings


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--vault", default=os.environ.get("VAULT_DIR", os.getcwd()))
    args = ap.parse_args(argv)
    vault = args.vault

    threshold = int(os.environ.get("NEAR_EMPTY_CHARS", "80"))

    findings = []
    findings.extend(check_near_empty(vault, threshold))
    findings.extend(check_manifest_drift(vault))

    for line in findings:
        print(line)
    n_empty = sum(1 for l in findings if l.startswith("WARN\tnear-empty stub:"))
    n_drift = sum(1 for l in findings if l.startswith("WARN\tmanifest drift:"))
    print(f"SUMMARY\tmechanical-checks: {n_empty} near-empty stub(s), {n_drift} manifest drift issue(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
