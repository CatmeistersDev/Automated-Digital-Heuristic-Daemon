#!/usr/bin/env python3
"""
normalize-properties.py — Deterministic property normalization for Bases-ready frontmatter.

Track A1 of Meta/Ultimate-Vault-Plan-2026-07-19.md. Bases dashboards filter on
properties; this pass makes the properties uniform enough to filter on.

What it normalizes (report by default, --fix applies):
  Actions:
    - missing priority        -> priority: medium
    - status outside enum     -> known synonyms mapped (closed->done, cancelled/canceled->dropped,
                                 wip/in_progress->in-progress); unknown values reported only
    - missing owner           -> owner: "[[Louise]]" (override with NORMALIZE_OWNER env)
    - missing first_mentioned -> copied from created
  All Canon types:
    - non-ISO dates in date fields -> known formats rewritten to YYYY-MM-DD
      (YYYY/MM/DD, DD.MM.YYYY, ISO datetime kept as-is for *_date fields)
  NEVER invents facts: no fabricated due dates, no guessed statuses.

Writes are atomic (temp file in same dir + os.replace) per the Phase-0 write-safety rule.

Usage:
  python3 normalize-properties.py           # report only
  python3 normalize-properties.py --fix     # apply fixes
  python3 normalize-properties.py --json    # machine-readable report

Exit code: 0 clean (or all fixed), 1 if unfixed issues remain.
"""

import os
import re
import sys
import json
import tempfile
from datetime import date

VAULT_DIR = os.environ.get("VAULT_DIR", "/vault")
DEFAULT_OWNER = os.environ.get("NORMALIZE_OWNER", "[[Louise]]")

STATUS_ENUM = {"open", "in-progress", "done", "dropped"}
STATUS_SYNONYMS = {
    "closed": "done",
    "complete": "done",
    "completed": "done",
    "cancelled": "dropped",
    "canceled": "dropped",
    "wip": "in-progress",
    "in_progress": "in-progress",
    "inprogress": "in-progress",
}
PRIORITY_ENUM = {"high", "medium", "low"}

DATE_FIELDS = [
    "created", "updated", "due", "start", "first_mentioned", "born",
    "date", "date_start", "date_end", "founded", "birthday", "met_at",
]

CANON_DIRS = [
    "Canon/Actions", "Canon/Organizations", "Canon/People", "Canon/Projects",
    "Canon/Places", "Canon/Events", "Canon/Decisions", "Canon/Concepts",
    "Canon/Reflections", "Canon/Beliefs",
]


def split_frontmatter(content):
    """Return (fm_lines, body_start_idx) or (None, None) if no frontmatter.

    body_start_idx points at the "\n" that precedes the closing "---".
    Handles both LF and CRLF files; caller strips "\r" per line.
    """
    m = re.match(r'^---\r?\n', content)
    if not m:
        return None, None
    end = content.find("\n---", m.end() - 1)
    if end == -1:
        return None, None
    return content[m.end():end].split("\n"), end


def parse_fields(fm_lines):
    fields = {}
    for i, line in enumerate(fm_lines):
        m = re.match(r'^(\w[\w_-]*)\s*:\s*(.*)', line)
        if m:
            v = m.group(2).strip()
            if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
                v = v[1:-1]
            fields[m.group(1)] = (v, i)
    return fields


def iso_rewrite(value):
    """Rewrite a known non-ISO date format to YYYY-MM-DD, or None if not rewritable."""
    v = value.strip()
    if re.match(r'^\d{4}-\d{2}-\d{2}$', v) or re.match(r'^\d{4}-\d{2}$', v) or re.match(r'^\d{4}$', v):
        return None  # already fine
    m = re.match(r'^(\d{4})/(\d{1,2})/(\d{1,2})$', v)
    if m:
        return "{}-{:0>2}-{:0>2}".format(m.group(1), m.group(2), m.group(3))
    m = re.match(r'^(\d{1,2})\.(\d{1,2})\.(\d{4})$', v)
    if m:
        return "{}-{:0>2}-{:0>2}".format(m.group(3), m.group(2), m.group(1))
    return None


def atomic_write(path, content):
    d = os.path.dirname(os.path.abspath(path))
    fd, tmp = tempfile.mkstemp(dir=d, suffix=".tmp")
    try:
        # mkstemp defaults to 0600 — unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def process_file(path, do_fix):
    """Return (issues, fixed_count). Each issue: (level, message, fixed_bool)."""
    issues = []
    try:
        with open(path, "r", encoding="utf-8", newline="") as f:
            content = f.read()
    except (OSError, UnicodeDecodeError) as e:
        return [("error", "unreadable: {}".format(e), False)], 0

    nl = "\r\n" if "\r\n" in content[:500] else "\n"
    fm_lines, fm_end = split_frontmatter(content)
    if fm_lines is None:
        return [("warning", "no frontmatter", False)], 0

    # Work on a normalized (LF) copy of the fm lines for editing
    fm_lines = [l.rstrip("\r") for l in fm_lines]
    fields = parse_fields(fm_lines)
    ntype = fields.get("type", ("", -1))[0]
    changed = False

    def set_line(idx, key, value):
        nonlocal changed
        fm_lines[idx] = "{}: {}".format(key, value)
        changed = True

    def append_line(key, value):
        nonlocal changed
        fm_lines.append("{}: {}".format(key, value))
        changed = True

    if ntype == "action":
        # priority
        if "priority" not in fields:
            issues.append(("fix", "missing priority -> medium", do_fix))
            if do_fix:
                append_line("priority", "medium")
        elif fields["priority"][0] not in PRIORITY_ENUM:
            issues.append(("warning", "priority '{}' outside enum".format(fields["priority"][0]), False))

        # status
        if "status" in fields:
            sv = fields["status"][0]
            if sv not in STATUS_ENUM:
                if sv in STATUS_SYNONYMS:
                    issues.append(("fix", "status '{}' -> '{}'".format(sv, STATUS_SYNONYMS[sv]), do_fix))
                    if do_fix:
                        set_line(fields["status"][1], "status", STATUS_SYNONYMS[sv])
                else:
                    issues.append(("warning", "status '{}' outside enum, no known mapping".format(sv), False))
        else:
            issues.append(("warning", "missing status", False))

        # owner
        if "owner" not in fields:
            issues.append(("fix", "missing owner -> {}".format(DEFAULT_OWNER), do_fix))
            if do_fix:
                append_line("owner", '"{}"'.format(DEFAULT_OWNER))

        # first_mentioned
        if "first_mentioned" not in fields and "created" in fields:
            issues.append(("fix", "missing first_mentioned -> created ({})".format(fields["created"][0]), do_fix))
            if do_fix:
                append_line("first_mentioned", fields["created"][0])

    # date normalization (all types)
    for df in DATE_FIELDS:
        if df in fields:
            val, idx = fields[df]
            if not val:
                continue
            new = iso_rewrite(val)
            if new:
                issues.append(("fix", "date {} '{}' -> '{}'".format(df, val, new), do_fix))
                if do_fix:
                    set_line(idx, df, new)
            elif not re.match(r'^\d{4}(-\d{2}(-\d{2})?)?$', val):
                issues.append(("warning", "date {} '{}' not ISO, no known rewrite".format(df, val), False))

    fixed = 0
    if changed and do_fix:
        # content[fm_end:] starts with "\n---" — original body bytes untouched.
        # For CRLF files re-add the "\r" the last fm line contributed before "\n---".
        tail_cr = "\r" if nl == "\r\n" else ""
        new_content = "---" + nl + nl.join(fm_lines) + tail_cr + content[fm_end:]
        atomic_write(path, new_content)
        fixed = sum(1 for lvl, _, f in issues if lvl == "fix" and f)

    return issues, fixed


def main():
    args = sys.argv[1:]
    do_fix = "--fix" in args
    json_out = "--json" in args

    results = {}
    total_fixed = 0
    for sub in CANON_DIRS:
        d = os.path.join(VAULT_DIR, sub)
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".md"):
                continue
            path = os.path.join(d, fn)
            issues, fixed = process_file(path, do_fix)
            total_fixed += fixed
            if issues:
                results[os.path.join(sub, fn)] = issues

    unfixed = sum(
        1 for iss in results.values() for lvl, _, f in iss
        if (lvl == "fix" and not f) or lvl in ("warning", "error")
    )

    if json_out:
        print(json.dumps({
            "fixed": total_fixed,
            "unfixed": unfixed,
            "files": {
                k: [{"level": l, "message": m, "applied": f} for l, m, f in v]
                for k, v in results.items()
            },
        }, indent=2))
    else:
        for k, iss in results.items():
            for lvl, msg, applied in iss:
                tag = "FIXED" if (lvl == "fix" and applied) else ("WOULD-FIX" if lvl == "fix" else lvl.upper())
                print("[{}] {}: {}".format(tag, k, msg))
        print("--")
        print("normalize-properties: {} fixed, {} remaining{}".format(
            total_fixed, unfixed, "" if do_fix else " (report mode, use --fix)"))

    return 1 if unfixed else 0


if __name__ == "__main__":
    sys.exit(main())
