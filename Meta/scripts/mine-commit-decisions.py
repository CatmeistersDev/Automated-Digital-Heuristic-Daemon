#!/usr/bin/env python3
"""
mine-commit-decisions.py — mines the VAULT git log for decision-signal commit
subjects (regex-based, no LLM) and proposes them as Decision candidates for a
human to turn into a Canon/Decisions/ note. Phase 4b.

Runs `git log --format=%H%x09%ad%x09%s --date=short` against the VAULT repo
(--vault / VAULT_DIR / cwd), not this CODE repo. Subjects matching a
decision-signal phrase ("switch to", "adopt", "replace X with Y", "decided",
"instead of", "retire", "drop ... in favor of") are candidates.

Default (no --queue): propose-only, prints EVERY matching commit as
  hash<TAB>date<TAB>subject
Zero writes.

--queue: additionally dedups against (a) existing Canon/Decisions/ note names
(a candidate whose subject clearly overlaps an existing decision's name is
assumed already captured) and (b) previously-queued commit hashes, tracked in
Meta/.decision-mine-state.json (same "state sidecar in the vault, not the
image" convention as review-rejections.py / bm25-index.py). Then
writes/appends a review-queue note.

NOT scheduled — human/on-demand tool. Stdlib only.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

DECISION_SIGNAL_RE = re.compile(
    r"\b(switch(?:ed|ing)?\s+to|adopt(?:ed|ing)?|replace[sd]?\s+\S.*\s+with\s+|"
    r"decided|instead of|retire[sd]?|drop(?:ped|ping)?\s+.*\s+in favor of)\b",
    re.IGNORECASE,
)


def state_path(vault):
    return os.path.join(vault, "Meta", ".decision-mine-state.json")


def load_state(vault):
    try:
        with open(state_path(vault), encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            return data
    except Exception:
        pass
    return {"seen_hashes": []}


def _atomic_write_json(path, obj):
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=d)
    try:
        # mkstemp defaults to 0600 — unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, indent=2, sort_keys=True)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def save_state(vault, state):
    _atomic_write_json(state_path(vault), state)


def git_log(vault):
    try:
        out = subprocess.run(
            ["git", "log", "--format=%H%x09%ad%x09%s", "--date=short"],
            cwd=vault, capture_output=True, text=True, timeout=60,
        )
    except Exception as e:
        print(f"git log failed: {e}", file=sys.stderr)
        return []
    if out.returncode != 0:
        print(f"git log failed: {out.stderr.strip()}", file=sys.stderr)
        return []
    commits = []
    for line in out.stdout.splitlines():
        parts = line.split("\t", 2)
        if len(parts) == 3:
            commits.append(tuple(parts))
    return commits


def find_candidates(commits):
    return [(h, d, s) for (h, d, s) in commits if DECISION_SIGNAL_RE.search(s)]


def existing_decision_names(vault):
    d = os.path.join(vault, "Canon", "Decisions")
    names = set()
    if os.path.isdir(d):
        for f in os.listdir(d):
            if f.endswith(".md"):
                names.add(f[:-3].strip().lower())
    return names


def _words(s):
    return set(re.findall(r"[a-z0-9]+", s.lower()))


def overlaps_existing(subject, existing_names):
    subj_words = _words(subject)
    for name in existing_names:
        name_words = _words(name)
        if not name_words:
            continue
        overlap = len(name_words & subj_words) / len(name_words)
        if overlap >= 0.6:
            return True
    return False


def build_arg_parser():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vault", default=os.environ.get("VAULT_DIR", os.getcwd()))
    ap.add_argument("--queue", action="store_true",
                     help="dedup + write/append a review-queue note")
    ap.add_argument("--limit", type=int, default=0,
                     help="cap NEW candidates written by --queue (0 = unlimited)")
    return ap


def main(argv):
    args = build_arg_parser().parse_args(argv)
    vault = args.vault

    commits = git_log(vault)
    candidates = find_candidates(commits)

    if not args.queue:
        for h, d, s in candidates:
            print(f"{h}\t{d}\t{s}")
        return 0

    state = load_state(vault)
    seen = set(state.get("seen_hashes", []))
    existing = existing_decision_names(vault)

    new_candidates = []
    for h, d, s in candidates:
        if h in seen:
            continue
        if overlaps_existing(s, existing):
            continue
        new_candidates.append((h, d, s))

    if args.limit > 0:
        new_candidates = new_candidates[: args.limit]

    if not new_candidates:
        print("No new decision candidates to queue.")
        return 0

    today = datetime.date.today().isoformat()
    out_dir = os.path.join(vault, "Meta", "review-queue")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{today}-decision-candidates.md")
    out_rel = os.path.relpath(out_path, vault).replace(os.sep, "/")

    rows = []
    for h, d, s in new_candidates:
        short = h[:10]
        s_esc = s.replace("|", "\\|")
        rows.append(f"| `{short}` | {d} | {s_esc} |")

    if os.path.exists(out_path):
        # Same-day re-run with genuinely new commits: APPEND a new dated block
        # rather than overwrite (would silently drop earlier candidates from
        # today). Newly-appended hashes still get dedup'd against seen_hashes on
        # the NEXT run either way.
        now = datetime.datetime.now().strftime("%H:%M")
        with open(out_path, "a", encoding="utf-8") as fh:
            fh.write(f"\n## Additional candidates ({now})\n\n")
            fh.write("| Hash | Date | Subject |\n|---|---|---|\n")
            fh.write("\n".join(rows) + "\n")
    else:
        lines = [
            "---", "type: review-item", f"name: Decision candidates {today}",
            "status: pending", "source_agent: mine-commit-decisions",
            f"created: {today}", "---", "",
            f"# 📋 Decision candidates from git log — {today}", "",
            "> ⚠️ PROPOSALS ONLY — mined from commit subjects via regex, nothing "
            "created in Canon. Review each; if it represents a real decision, "
            "create a Canon/Decisions/ note yourself.",
            "",
            f"> Disagree with all of these? Run `Meta/scripts/review-reject.sh \"{out_rel}\" \"why\"`.",
            "",
            "| Hash | Date | Subject |", "|---|---|---|",
        ]
        lines.extend(rows)
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")

    state["seen_hashes"] = sorted(seen | {h for h, _, _ in new_candidates})
    save_state(vault, state)
    print(f"Decision candidates queued: {out_rel} ({len(new_candidates)} new)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
