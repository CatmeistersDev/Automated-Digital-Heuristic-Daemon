#!/usr/bin/env python3
"""
dedup-mentions.py — collapse exact-duplicate entries in a note's frontmatter
`mentions:` array, in place, preserving order and leaving every other line
byte-for-byte untouched.

WHY: an action note's `mentions:` array gets a new entry every time a memo
references that action again (see CLAUDE.md / .claude/skills/vault-extractor).
The append is model/shell driven and not itself idempotent — a retried chunk,
the periodic no-arg catch-up sweep re-processing a stranded memo, or a second
extraction pass over the same transcript can add the same source filename to
the array more than once. This is a deterministic, LLM-free guard run after
extraction: it never invents or drops a mention, it only drops an entry that
is an EXACT duplicate (byte-for-byte, including any quoting) of one already
kept, keeping the first occurrence and original order.

Usage: dedup-mentions.py FILE [FILE ...]
Stdlib only. Best-effort per file: a file that can't be parsed/read is skipped
with a stderr note; it never aborts the batch. Exit code is always 0.
"""
import os
import sys
import json
import hashlib
import tempfile
import datetime


def dedup_mentions_block(lines):
    """Given a note's lines (each including its trailing newline), find a
    top-level `mentions:` key inside the leading frontmatter block (between
    the first two bare '---' lines) and drop exact-duplicate '  - value' list
    entries directly under it, keeping the first occurrence and original
    order. Returns (new_lines, changed)."""
    if not lines or lines[0].rstrip("\n") != "---":
        return lines, False

    fm_end = None
    for i in range(1, len(lines)):
        if lines[i].rstrip("\n") == "---":
            fm_end = i
            break
    if fm_end is None:
        return lines, False

    mentions_idx = None
    for i in range(1, fm_end):
        if lines[i].rstrip("\n").startswith("mentions:"):
            mentions_idx = i
            break
    if mentions_idx is None:
        return lines, False

    # Collect the contiguous list-item lines immediately following the key
    # (any leading whitespace, then "- "). Stops at the first non-list-item
    # line (next key, blank line, or the closing '---').
    item_lines = []
    j = mentions_idx + 1
    while j < fm_end:
        stripped = lines[j].rstrip("\n").strip()
        if stripped.startswith("- ") or stripped == "-":
            item_lines.append(j)
            j += 1
        else:
            break
    if not item_lines:
        return lines, False

    seen = set()
    keep = []
    for idx in item_lines:
        key = lines[idx].rstrip("\n").strip()
        if key in seen:
            continue
        seen.add(key)
        keep.append(idx)

    if len(keep) == len(item_lines):
        return lines, False  # no duplicates

    new_lines = (
        lines[: mentions_idx + 1]
        + [lines[idx] for idx in keep]
        + lines[item_lines[-1] + 1 :]
    )
    return new_lines, True


def _atomic_write_lines(path, lines):
    dirpath = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=dirpath)
    try:
        # mkstemp defaults to 0600 — unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
        # newline="" on both the read (below) and this write: each line already carries
        # its own original terminator (from readlines()), so text-mode's universal-
        # newline translation must be disabled here — otherwise a "\n"-terminated line
        # would be rewritten as the platform's os.linesep, breaking the byte-for-byte
        # preservation this tool exists to guarantee.
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.writelines(lines)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


# Note write-state (hand-edit detection, Phase 3 hardening 2026-07-18) — same state
# file/schema as Meta/scripts/note-write-state.py and ollama_agent.py's harness hooks
# (duplicated here, not imported: same self-contained-script convention every small
# state helper in this codebase already follows). This is an additive/non-destructive
# edit (collapses exact-duplicate mentions entries only) so a hand-edit is never a
# reason to skip it — just refresh the recorded hash so the NEXT agent write against
# this note (e.g. a later extraction pass) compares against accurate state instead of
# flagging a false hand-edit for a change dedup-mentions itself just made.
def _note_state_path():
    vault = os.environ.get("VAULT_DIR") or os.getcwd()
    return os.path.join(vault, "Meta", ".note-write-state.json")


def _note_state_load():
    path = _note_state_path()
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _note_state_record(relpath, content):
    try:
        vault = os.environ.get("VAULT_DIR") or os.getcwd()
        state = _note_state_load()
        pruned = {rp: e for rp, e in state.items() if os.path.isfile(os.path.join(vault, rp))}
        pruned[relpath] = {
            "hash": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            "updated": datetime.datetime.now().isoformat(timespec="seconds"),
            "agent": "Extractor",
        }
        path = _note_state_path()
        dirpath = os.path.dirname(path)
        os.makedirs(dirpath, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=dirpath)
        try:
            os.chmod(tmp, 0o644)  # mkstemp's 0600 default is unreadable cross-identity under NFS+LXC
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(pruned, f, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except Exception:
            try:
                os.remove(tmp)
            except OSError:
                pass
    except Exception:
        pass   # best-effort bookkeeping only — never let it break the real dedup write


def main(argv):
    vault = os.environ.get("VAULT_DIR") or os.getcwd()
    for path in argv[1:]:
        try:
            with open(path, "r", encoding="utf-8", newline="") as f:
                lines = f.readlines()
        except OSError as e:
            print(f"dedup-mentions: skip {path}: {e}", file=sys.stderr)
            continue

        new_lines, changed = dedup_mentions_block(lines)
        if not changed:
            continue

        try:
            _atomic_write_lines(path, new_lines)
        except OSError as e:
            print(f"dedup-mentions: failed to write {path}: {e}", file=sys.stderr)
            continue
        print(f"dedup-mentions: collapsed duplicate mentions in {path}")

        try:
            full = path if os.path.isabs(path) else os.path.join(vault, path)
            relpath = os.path.relpath(os.path.realpath(full), os.path.realpath(vault)).replace(os.sep, "/")
            if relpath.endswith(".md") and (relpath.startswith("Canon/") or relpath.startswith("Thinking/")):
                _note_state_record(relpath, "".join(new_lines))
        except Exception:
            pass

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
