#!/usr/bin/env python3
"""
extract-checkpoint.py — chunk-level checkpoint sidecar for run-extractor.sh
(Phase 3 hardening, 2026-07-18).

WHY: run-extractor.sh feeds a long transcript to the model in ~9k-char inline
chunks (sequential, one agent call each). A scheduler timeout kills the whole
process group mid-memo; the periodic no-arg catch-up sweep then finds the memo
still at status: inbox|transcribed and re-runs EVERY chunk from scratch, even
the ones that already succeeded and already wrote real Canon/Thinking files.

This gives the shell loop in run-extractor.sh a durable, per-note checkpoint:
which chunk indices are done, and which Canon/Thinking files each of those
completed chunks created (needed so the final "## Extracted" rebuild is
complete even when some of those files were written by an EARLIER process
that got killed, not by this invocation). Keyed by a SHA256 of the exact
transcript text being chunked, so an edited transcript (re-corrected, or a
manual fix) invalidates the checkpoint automatically instead of silently
resuming against stale chunk boundaries.

State lives in the VAULT (not baked into the image), same convention as
Meta/.manifest-hash-cache.json / Meta/.review-rejections.jsonl:
  Meta/.extract-progress/<sha256-of-transcript>.json

Checkpoint shape:
  {
    "note": "Inbox/Voice/2026-07-16 - foo.md",
    "transcript_hash": "<sha256>",
    "total_chunks": 5,
    "completed_chunks": [1, 2, 3],
    "files_by_chunk": {"1": ["Canon/People/Tina.md"], "2": [], "3": [...]},
    "updated": "2026-07-18T10:00:00"
  }

Feature-degrade: a missing/corrupt/absent checkpoint is always treated as "no
checkpoint" (fresh start) — this script never raises out to the caller for a
bad state file, it just discards it and starts clean.

Stdlib only.
"""
import argparse
import datetime
import json
import os
import sys
import tempfile


def _atomic_write_json(path, obj):
    dirpath = os.path.dirname(path) or "."
    os.makedirs(dirpath, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=dirpath)
    try:
        # mkstemp defaults to 0600 — unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(obj, fh, ensure_ascii=False)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _load(path):
    """Best-effort load. Returns None if the file is missing OR unreadable/corrupt
    (corrupt is treated identically to absent — never propagates a parse error)."""
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        if not isinstance(data, dict):
            return None
        return data
    except Exception:
        return None


def _discard(path):
    try:
        os.remove(path)
    except OSError:
        pass


def cmd_load(args):
    """Print resume info for stdout consumption by run-extractor.sh:
      - no checkpoint / corrupt checkpoint -> prints nothing, exit 0
      - checkpoint exists but transcript_hash != --hash -> discards the file,
        prints DISCARDED alone, exit 0
      - checkpoint matches -> line 1 = comma-separated completed chunk indices
        (may be empty), remaining lines = union of every file path recorded
        across those completed chunks (deduped, first-seen order)
    """
    data = _load(args.checkpoint)
    if data is None:
        return 0
    if data.get("transcript_hash") != args.hash:
        _discard(args.checkpoint)
        print("DISCARDED")
        return 0
    completed = sorted({int(i) for i in data.get("completed_chunks", [])})
    files_by_chunk = data.get("files_by_chunk", {}) or {}
    seen = set()
    files = []
    for idx in completed:
        for f in files_by_chunk.get(str(idx), []) or []:
            if f not in seen:
                seen.add(f)
                files.append(f)
    print(",".join(str(i) for i in completed))
    for f in files:
        print(f)
    return 0


def cmd_mark_chunk(args):
    """Record chunk --chunk as completed (idempotent — overwrites that chunk's
    file list if called again), preserving every previously-completed chunk's
    entry. Starts a fresh checkpoint if none exists or the stored hash doesn't
    match (caller is expected to have already resolved/discarded a stale
    checkpoint via `load` before the chunk loop starts, but this stays safe
    even if that didn't happen)."""
    data = _load(args.checkpoint)
    if not data or data.get("transcript_hash") != args.hash:
        data = {
            "note": args.note,
            "transcript_hash": args.hash,
            "total_chunks": args.total,
            "completed_chunks": [],
            "files_by_chunk": {},
        }
    files = []
    if args.files_file and os.path.isfile(args.files_file):
        with open(args.files_file, encoding="utf-8") as fh:
            files = [line.rstrip("\n") for line in fh if line.strip()]
    completed = set(data.get("completed_chunks", []))
    completed.add(args.chunk)
    data["completed_chunks"] = sorted(completed)
    data.setdefault("files_by_chunk", {})[str(args.chunk)] = files
    data["note"] = args.note
    data["total_chunks"] = args.total
    data["updated"] = datetime.datetime.now().isoformat(timespec="seconds")
    _atomic_write_json(args.checkpoint, data)
    return 0


def cmd_discard(args):
    """Delete the checkpoint file if present. Always exit 0 (idempotent —
    discarding an already-absent checkpoint is not an error)."""
    _discard(args.checkpoint)
    return 0


def build_arg_parser():
    ap = argparse.ArgumentParser(description="Chunk-level checkpoint sidecar for run-extractor.sh.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("load", help="print resume info, or DISCARDED on hash mismatch")
    p.add_argument("--checkpoint", required=True)
    p.add_argument("--hash", required=True)

    p = sub.add_parser("mark-chunk", help="record one chunk as completed")
    p.add_argument("--checkpoint", required=True)
    p.add_argument("--hash", required=True)
    p.add_argument("--note", default="")
    p.add_argument("--total", type=int, required=True)
    p.add_argument("--chunk", type=int, required=True)
    p.add_argument("--files-file", default="", help="path to a file of one relpath per line (may not exist -> empty list)")

    p = sub.add_parser("discard", help="delete the checkpoint file if present")
    p.add_argument("--checkpoint", required=True)

    return ap


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    if args.cmd == "load":
        return cmd_load(args)
    if args.cmd == "mark-chunk":
        return cmd_mark_chunk(args)
    if args.cmd == "discard":
        return cmd_discard(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
