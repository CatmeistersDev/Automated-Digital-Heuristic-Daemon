#!/usr/bin/env python3
"""
note-write-state.py — stored-vs-live SHA256 tracking for Canon/Thinking notes
(Phase 3 hardening, 2026-07-18).

WHY: the vault's append-only discipline ("update an existing note with append_file,
never write_file") has always been a PROMPT convention, not an enforced one. This
gives it a technical backstop: record the SHA256 of a Canon/Thinking note every time
an AGENT writes it; before the NEXT agent write, compare the note's live on-disk
content to that stored hash. A mismatch means a human (or some untracked writer)
touched the file since — evidence the append-only discipline exists to protect.

This is the standalone CLI counterpart of the same tracking ollama_agent.py's
tool_write_file/tool_append_file do inline for the model's own tool calls (duplicated
implementation, not imported — same convention as review-rejections.py's atomic-write
helper, which is likewise duplicated rather than shared across scripts). Both write
the SAME state file with the SAME schema, so records interoperate regardless of which
one wrote them:

  Meta/.note-write-state.json — {"<vault-relpath>": {"hash": "<sha256 hex>",
                                                        "updated": "<iso ts>",
                                                        "agent": "<name>"}}

Used by deterministic (non-LLM) write sites that are cheap to hook: the Implementer's
wikilink-fix pass (run-implementer.sh) and the Extractor's post-chunk mentions-dedup
pass (dedup-mentions.py). Both are additive/non-destructive edits by design, so they
never REFUSE on a hand-edit — they log it (informational) and keep going, then refresh
the hash. Only ollama_agent.py's write_file enforces a hard refusal (an LLM-authored
write_file over an existing note is the one path this whole mechanism exists to catch).

State lives in the VAULT (VAULT_DIR), not baked into the image, same convention as
Meta/.manifest-hash-cache.json / Meta/.review-rejections.jsonl. Bounded: `record` and
`prune` both drop entries for notes no longer on disk (cheap, done on every save).

Stdlib only.
"""
import argparse
import datetime
import hashlib
import json
import os
import sys
import tempfile


def vault_dir():
    return os.environ.get("VAULT_DIR") or os.getcwd()


def state_path():
    return os.path.join(vault_dir(), "Meta", ".note-write-state.json")


def _load():
    path = state_path()
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        # corrupt state file is treated as empty, never propagated as an error —
        # this bookkeeping must never be the reason a real note write fails.
        return {}


def _atomic_save(state):
    vd = vault_dir()
    # Bounded state: drop entries for notes that no longer exist. Cheap — done on
    # every save, not a separate maintenance pass.
    pruned = {rp: entry for rp, entry in state.items()
              if os.path.isfile(os.path.join(vd, rp))}
    path = state_path()
    dirpath = os.path.dirname(path)
    os.makedirs(dirpath, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=dirpath)
    try:
        # mkstemp defaults to 0600 — unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
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
        raise


def sha256_text(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def relpath_of(path):
    vd = os.path.realpath(vault_dir())
    full = os.path.realpath(path) if os.path.isabs(path) else os.path.realpath(os.path.join(vd, path))
    return os.path.relpath(full, vd).replace(os.sep, "/")


def cmd_check(args):
    """Print MATCH / MISMATCH / UNKNOWN / MISSING for --path's live on-disk content
    vs. its stored hash. Never raises — any read failure degrades to UNKNOWN."""
    rp = relpath_of(args.path)
    full = os.path.join(vault_dir(), rp)
    if not os.path.isfile(full):
        print("MISSING")
        return 0
    entry = _load().get(rp)
    if not entry:
        print("UNKNOWN")
        return 0
    try:
        with open(full, encoding="utf-8", errors="replace") as f:
            live = f.read()
    except OSError:
        print("UNKNOWN")
        return 0
    print("MATCH" if entry.get("hash") == sha256_text(live) else "MISMATCH")
    return 0


def cmd_record(args):
    """Hash --path's CURRENT on-disk content and store it as the new baseline. A
    missing file just drops any stale entry instead of erroring (e.g. a note that
    was deleted/renamed since it was last recorded)."""
    rp = relpath_of(args.path)
    full = os.path.join(vault_dir(), rp)
    state = _load()
    if not os.path.isfile(full):
        state.pop(rp, None)
        _atomic_save(state)
        return 0
    with open(full, encoding="utf-8", errors="replace") as f:
        live = f.read()
    state[rp] = {
        "hash": sha256_text(live),
        "updated": datetime.datetime.now().isoformat(timespec="seconds"),
        "agent": args.agent or os.environ.get("AGENT_NAME", ""),
    }
    _atomic_save(state)
    return 0


def cmd_prune(args):
    """Rewrite the state file, dropping entries for notes no longer on disk."""
    _atomic_save(_load())
    return 0


def build_arg_parser():
    ap = argparse.ArgumentParser(description="Stored-vs-live hash tracking for Canon/Thinking notes.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("check", help="compare a note's live content to its stored hash")
    p.add_argument("--path", required=True)

    p = sub.add_parser("record", help="record a note's current on-disk content as the new stored hash")
    p.add_argument("--path", required=True)
    p.add_argument("--agent", default="")

    sub.add_parser("prune", help="drop entries for notes that no longer exist on disk")

    return ap


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    if args.cmd == "check":
        return cmd_check(args)
    if args.cmd == "record":
        return cmd_record(args)
    if args.cmd == "prune":
        return cmd_prune(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
