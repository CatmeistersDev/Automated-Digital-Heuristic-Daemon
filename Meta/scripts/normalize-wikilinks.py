#!/usr/bin/env python3
"""normalize-wikilinks.py — rewrite wikilinks to clean [[Name]] form. Deterministic, no LLM.

  [[Canon/People/Louise.md|Louise]] -> [[Louise]]
  [[Canon/Decisions/Tolerate Malicious Intent]] -> [[Tolerate Malicious Intent]]
  [[Name]] -> unchanged

Usage: normalize-wikilinks.py [VAULT_DIR]   (default: $VAULT_DIR or cwd)
"""
import os, re, sys

VAULT = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("VAULT_DIR", ".")
pat = re.compile(r'\[\[([^\]]+)\]\]')


def repl(m):
    inner = m.group(1).strip()
    if '|' in inner:                # [[target|alias]] -> keep alias
        inner = inner.split('|')[-1]
    else:                           # [[path/Name.md]] -> Name
        inner = inner.split('/')[-1]
        if inner.endswith('.md'):
            inner = inner[:-3]
    return f'[[{inner.strip()}]]'


changed = 0
for sub in ("Canon", "Thinking", "Inbox", "Meta/AI-Reflections", "Meta/operations"):
    base = os.path.join(VAULT, sub)
    if not os.path.isdir(base):
        continue
    for root, _, files in os.walk(base):
        for fn in files:
            if not fn.endswith(".md"):
                continue
            p = os.path.join(root, fn)
            try:
                t = open(p, encoding="utf-8").read()
            except Exception:
                continue
            n = pat.sub(repl, t)
            if n != t:
                open(p, "w", encoding="utf-8").write(n)
                changed += 1
print(f"normalized wikilinks in {changed} file(s)")
