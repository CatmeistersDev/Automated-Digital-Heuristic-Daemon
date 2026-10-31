#!/usr/bin/env python3
"""
dedup-prefilter.py — deterministic pre-stage for run-dedup.sh, run BEFORE any LLM
call (Phase 1 hardening, 2026-07-18).

  (a) EXACT: normalized-text SHA256 (lowercase, whitespace-collapsed, frontmatter
      stripped) of every candidate note's body. Two notes of the SAME type sharing a
      hash are byte-identical after normalization -> flagged as a CERTAIN duplicate
      group, no LLM needed.
  (b) CANDIDATE FILTER: for notes that did NOT exact-match, pairwise token-set Jaccard
      similarity WITHIN THE SAME TYPE ONLY (an Organization is never compared to a
      Person). Only a note that appears in at least one pair >= DEDUP_JACCARD_THRESHOLD
      (default 0.3, env-overridable) is worth a model's attention; everything else is
      skipped entirely — the LLM only ever sees plausible candidates, never the whole
      vault's entity list.

Emits ONE JSON object to stdout:
  {"exact_groups": [{"type": "People", "canonical": "Name1", "duplicates": ["Name2"]}],
   "candidates": {"<Type>": ["NameA", "NameB", ...]},
   "stats": {"pairs_total": N, "exact": N, "sent_to_llm": N, "skipped": N}}

Read-only over Canon/ — never merges, deletes, or writes anything.
Stdlib only.
"""
import os
import re
import sys
import json
import hashlib

TYPES = ("People", "Organizations", "Places", "Projects", "Events")
JACCARD_THRESHOLD = float(os.environ.get("DEDUP_JACCARD_THRESHOLD", "0.3"))


def strip_frontmatter(text):
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            rest = text[end + 4:]
            nl = rest.find("\n")
            return rest[nl + 1:] if nl != -1 else ""
    return text


def normalize(text):
    body = strip_frontmatter(text).lower()
    return re.sub(r"\s+", " ", body).strip()


def tokenize(normalized_text):
    return set(re.findall(r"[a-z0-9']+", normalized_text))


def jaccard(a, b):
    if not a and not b:
        return 0.0
    union = len(a | b)
    return (len(a & b) / union) if union else 0.0


def load_notes(vault):
    by_type = {}
    for t in TYPES:
        d = os.path.join(vault, "Canon", t)
        if not os.path.isdir(d):
            continue
        entries = []
        for f in sorted(os.listdir(d)):
            if not f.endswith(".md"):
                continue
            p = os.path.join(d, f)
            try:
                text = open(p, encoding="utf-8", errors="replace").read()
            except OSError:
                continue
            norm = normalize(text)
            entries.append({
                "name": f[:-3],
                "hash": hashlib.sha256(norm.encode("utf-8")).hexdigest(),
                "tokens": tokenize(norm),
            })
        if entries:
            by_type[t] = entries
    return by_type


def main():
    vault = os.environ.get("VAULT_DIR", os.getcwd())
    by_type = load_notes(vault)

    exact_groups = []
    candidates = {}
    pairs_total = 0
    exact_dup_count = 0
    handled_names = set()   # canonical + duplicates from exact groups
    candidate_names = set()

    for t, entries in by_type.items():
        # (a) exact-hash groups
        by_hash = {}
        for e in entries:
            by_hash.setdefault(e["hash"], []).append(e["name"])
        exact_names_this_type = set()
        for names in by_hash.values():
            if len(names) < 2:
                continue
            exact_groups.append({"type": t, "canonical": names[0], "duplicates": names[1:]})
            exact_dup_count += len(names) - 1
            exact_names_this_type.update(names)
        handled_names.update(exact_names_this_type)

        # (b) Jaccard pre-filter over the notes NOT already absorbed into an exact group
        remaining = [e for e in entries if e["name"] not in exact_names_this_type]
        surviving = set()
        n = len(remaining)
        for i in range(n):
            for j in range(i + 1, n):
                pairs_total += 1
                if jaccard(remaining[i]["tokens"], remaining[j]["tokens"]) >= JACCARD_THRESHOLD:
                    surviving.add(remaining[i]["name"])
                    surviving.add(remaining[j]["name"])
        if surviving:
            candidates[t] = sorted(surviving)
            candidate_names.update(surviving)

    total_notes = sum(len(v) for v in by_type.values())
    skipped = total_notes - len(handled_names) - len(candidate_names)

    result = {
        "exact_groups": exact_groups,
        "candidates": candidates,
        "stats": {
            "pairs_total": pairs_total,
            "exact": exact_dup_count,
            "sent_to_llm": len(candidate_names),
            "skipped": skipped,
        },
    }
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
