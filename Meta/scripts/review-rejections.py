#!/usr/bin/env python3
"""
review-rejections.py — rejection-feedback memory for Meta/review-queue/
(Phase 2 hardening, 2026-07-18). Gives proposal-generating agents (Dedup, Groomer,
...) a memory of past human rejections so they stop re-proposing things the human
already said no to.

State lives in the VAULT (VAULT_DIR), not baked into the image, so it survives
image rebuilds — same convention as Meta/.manifest-hash-cache.json / Meta/.scheduler-
heartbeat (see .gitignore):
  Meta/.review-rejections.jsonl  — append-only history of every recorded rejection
  Meta/.review-unblocks.jsonl    — append-only history of every human unblock action

A rejection record: {item_key, agent, feedback, timestamp, proposal_file}
An unblock record:   {item_key, timestamp, note}

"Effective" rejection count for an item key = rejections recorded AFTER its most
recent unblock (or all of them, if it was never unblocked). This lets a human clear
a block (Meta/scripts/review-unblock.sh) without erasing history — old rejections
stay in the log, they just stop counting toward the cap until a NEW rejection lands.

Item-key scheme:
  dedup:<name1>+<name2>[+...]   — sorted, lowercased, whitespace-normalized names of
                                   every entry in a proposed merge group (canonical +
                                   duplicates). Group identity, not "who's canonical".
  stale-action:<name>           — lowercased, whitespace-normalized action note name.
  file:<path>                   — fallback when a proposal file has no structured
                                   items the parser recognizes (whole-file rejection).

Stdlib only. Usable as a library (import review_rejections) or as a CLI — see
`python3 review-rejections.py -h` and per-subcommand `-h` for the full list.
"""
import argparse
import datetime
import json
import os
import re
import sys
import tempfile

DEFAULT_CAP = 5


def vault_dir():
    return os.environ.get("VAULT_DIR") or os.getcwd()


def rejections_path():
    return os.path.join(vault_dir(), "Meta", ".review-rejections.jsonl")


def unblocks_path():
    return os.path.join(vault_dir(), "Meta", ".review-unblocks.jsonl")


def default_cap():
    try:
        return int(os.environ.get("REVIEW_REJECTION_CAP", str(DEFAULT_CAP)))
    except ValueError:
        return DEFAULT_CAP


def _atomic_append(path, obj):
    # Append-only JSONL, written via a full atomic rewrite (temp file same dir +
    # fsync + os.replace) so a kill mid-write can never leave a torn/partial last
    # line — the same pattern run-implementer.sh and lib-agent.sh use for notes.
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            lines = fh.readlines()
    lines.append(json.dumps(obj, ensure_ascii=False) + "\n")
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=os.path.dirname(path) or ".")
    try:
        # mkstemp defaults to 0600 — unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.writelines(lines)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _load_jsonl(path):
    out = []
    if not os.path.exists(path):
        return out
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def normalize_name(name):
    return re.sub(r"\s+", " ", name.strip().lower())


def dedup_key(names):
    norm = sorted({normalize_name(n) for n in names if n and n.strip()})
    return "dedup:" + "+".join(norm)


def stale_key(name):
    return "stale-action:" + normalize_name(name)


def record_rejection(item_key, agent, proposal_file, feedback=""):
    # microseconds, not seconds: effective_rejections() filters strictly-after the
    # last unblock, and an unblock + a new rejection can land within the same wall
    # second on a fast box — a seconds-granularity tie would wrongly exclude the
    # new rejection (lexicographic ISO compare stays correct across both formats)
    _atomic_append(rejections_path(), {
        "item_key": item_key,
        "agent": agent or "unknown",
        "feedback": feedback or "",
        "timestamp": datetime.datetime.now().isoformat(timespec="microseconds"),
        "proposal_file": proposal_file or "",
    })


def record_unblock(item_key, note=""):
    _atomic_append(unblocks_path(), {
        "item_key": item_key,
        "timestamp": datetime.datetime.now().isoformat(timespec="microseconds"),
        "note": note or "",
    })


def _last_unblock_ts(item_key):
    ts = None
    for rec in _load_jsonl(unblocks_path()):
        if rec.get("item_key") == item_key:
            t = rec.get("timestamp", "")
            if ts is None or t > ts:
                ts = t
    return ts


def effective_rejections(item_key):
    """All rejection records for item_key, newest-first, filtered to those recorded
    after the most recent unblock (if any)."""
    cutoff = _last_unblock_ts(item_key)
    recs = [r for r in _load_jsonl(rejections_path()) if r.get("item_key") == item_key]
    if cutoff:
        recs = [r for r in recs if r.get("timestamp", "") > cutoff]
    recs.sort(key=lambda r: r.get("timestamp", ""), reverse=True)
    return recs


def rejection_count(item_key):
    return len(effective_rejections(item_key))


def is_blocked(item_key, cap):
    return rejection_count(item_key) >= cap


def recent_feedback_block(item_key, n=3):
    recs = [r for r in effective_rejections(item_key)[:n] if r.get("feedback")]
    if not recs:
        return ""
    lines = ["PREVIOUS REJECTIONS — do not re-propose unless these concerns are addressed:"]
    for r in recs:
        lines.append(f"- ({r.get('timestamp', '?')}) {r.get('feedback', '').strip()}")
    return "\n".join(lines)


def all_item_keys():
    keys = set()
    for r in _load_jsonl(rejections_path()):
        k = r.get("item_key")
        if k:
            keys.add(k)
    return sorted(keys)


def relevant_dedup_context(candidate_names, max_total=20):
    """Combined PREVIOUS REJECTIONS block for every stored dedup:... item key whose
    FULL name-set is still a subset of candidate_names this run (i.e. every member
    of a previously-rejected group is still a live candidate)."""
    cand = {normalize_name(n) for n in candidate_names}
    blocks = []
    for key in all_item_keys():
        if not key.startswith("dedup:"):
            continue
        names = set(key[len("dedup:"):].split("+"))
        if not names or not names.issubset(cand):
            continue
        recs = effective_rejections(key)
        if not recs:
            continue
        latest = recs[0]
        fb = latest.get("feedback", "").strip()
        label = " / ".join(sorted(names))
        if fb:
            blocks.append(f"- Group [{label}] rejected ({latest.get('timestamp', '?')}): {fb}")
        else:
            blocks.append(
                f"- Group [{label}] was previously rejected ({latest.get('timestamp', '?')}) "
                "— no reason given, but do not re-propose it."
            )
        if len(blocks) >= max_total:
            break
    if not blocks:
        return ""
    return "PREVIOUS REJECTIONS — do not re-propose unless these concerns are addressed:\n" + "\n".join(blocks)


def filter_exact_groups(prefilter_json_text):
    """Drop exact-hash dedup groups (from dedup-prefilter.py's exact_groups) whose
    dedup_key has ANY prior rejection — deterministic paths suppress outright, no
    cap wait. Returns the same CANONICAL/DUPLICATES/WHY text block shape run-dedup.sh
    already builds from exact_groups."""
    data = json.loads(prefilter_json_text) if prefilter_json_text.strip() else {}
    survivors = []
    suppressed = 0
    for g in data.get("exact_groups", []):
        names = [g.get("canonical", "")] + list(g.get("duplicates", []))
        key = dedup_key(names)
        if rejection_count(key) > 0:
            suppressed += 1
            continue
        survivors.append(g)
    blocks = []
    for g in survivors:
        dups = ", ".join(g.get("duplicates", []))
        blocks.append(
            f"CANONICAL: {g.get('canonical', '')}\nDUPLICATES: {dups}\n"
            f"WHY: exact normalized-text match ({g.get('type', '?')}, pre-filter, no LLM — CERTAIN)"
        )
    if suppressed:
        print(f"Dedup: suppressed {suppressed} previously-rejected exact-match group(s)", file=sys.stderr)
    return "\n\n".join(blocks)


def filter_candidates(prefilter_json_text, cap):
    """Drop candidate names (from dedup-prefilter.py's candidates dict) that belong
    ONLY to an already-blocked (cap+ rejections) dedup group, so a blocked pair can't
    be re-sent to the LLM. Returns the same 'Type:\\nName\\n...' text shape run-dedup.sh
    already builds from candidates."""
    data = json.loads(prefilter_json_text) if prefilter_json_text.strip() else {}
    candidates = data.get("candidates", {})
    suppressed_names = set()
    for t, names in candidates.items():
        nameset = {normalize_name(n) for n in names}
        for key in all_item_keys():
            if not key.startswith("dedup:"):
                continue
            gnames = set(key[len("dedup:"):].split("+"))
            if gnames and gnames.issubset(nameset) and is_blocked(key, cap):
                suppressed_names |= gnames
    out = []
    total_suppressed = 0
    for t, names in candidates.items():
        kept = [n for n in names if normalize_name(n) not in suppressed_names]
        total_suppressed += len(names) - len(kept)
        if kept:
            out.append(f"{t}:")
            out.extend(kept)
            out.append("")
    if total_suppressed:
        print(f"Dedup: suppressed {total_suppressed} candidate name(s) belonging to blocked group(s)", file=sys.stderr)
    return "\n".join(out)


def parse_frontmatter(text):
    fm = {}
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            for line in text[3:end].splitlines():
                if ":" in line and not line.strip().startswith("-"):
                    k, v = line.split(":", 1)
                    fm[k.strip()] = v.strip().strip('"').strip("'")
    return fm


def extract_dedup_groups(text):
    """Parse CANONICAL:/DUPLICATES:/WHY: blocks (dedup proposal shape) out of a
    proposal note's body."""
    groups = []
    canonical = None
    dups = []
    for line in text.splitlines():
        s = line.strip()
        m = re.match(r"^CANONICAL:\s*(.+)$", s, re.IGNORECASE)
        if m:
            if canonical is not None:
                groups.append((canonical, dups))
            canonical = m.group(1).strip()
            dups = []
            continue
        m = re.match(r"^DUPLICATES:\s*(.+)$", s, re.IGNORECASE)
        if m and canonical is not None:
            dups = [d.strip() for d in m.group(1).split(",") if d.strip()]
    if canonical is not None:
        groups.append((canonical, dups))
    return groups


def extract_stale_names(text):
    """Parse '- [[Note Name]] — last activity ...' bullets (groomer stale-action
    proposal shape) out of a proposal note's body."""
    names = []
    for line in text.splitlines():
        m = re.match(r"^-\s*\[\[([^\]]+)\]\]", line.strip())
        if m:
            names.append(m.group(1).strip())
    return names


def extract_item_keys(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    fm = parse_frontmatter(text)
    agent = fm.get("source_agent", "unknown")
    keys = []
    for canonical, dups in extract_dedup_groups(text):
        names = [canonical] + dups
        if any(n.strip() for n in names):
            keys.append(dedup_key(names))
    for name in extract_stale_names(text):
        keys.append(stale_key(name))
    return agent, sorted(set(keys))


def build_arg_parser():
    ap = argparse.ArgumentParser(description="Rejection-feedback memory for Meta/review-queue/.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("record", help="record a rejection for an item key")
    p.add_argument("--item-key", required=True)
    p.add_argument("--agent", default="unknown")
    p.add_argument("--proposal-file", default="")
    p.add_argument("--feedback", default="")

    p = sub.add_parser("count", help="print the effective rejection count for an item key")
    p.add_argument("--item-key", required=True)

    p = sub.add_parser("blocked", help="exit 0 if blocked (count >= cap), 1 otherwise")
    p.add_argument("--item-key", required=True)
    p.add_argument("--cap", type=int, default=None)

    p = sub.add_parser("recent", help="print a PREVIOUS REJECTIONS prompt block for an item key")
    p.add_argument("--item-key", required=True)
    p.add_argument("--n", type=int, default=3)

    p = sub.add_parser("unblock", help="reset the counting window for an item key")
    p.add_argument("--item-key", required=True)
    p.add_argument("--note", default="")

    p = sub.add_parser("list-blocked", help="list all item keys currently at/over the cap")
    p.add_argument("--cap", type=int, default=None)

    p = sub.add_parser("relevant-context", help="dedup-specific combined PREVIOUS REJECTIONS block")
    p.add_argument("--names-file", required=True)
    p.add_argument("--max-total", type=int, default=20)

    p = sub.add_parser("filter-exact-groups", help="reads prefilter JSON on stdin, drops rejected exact groups")

    p = sub.add_parser("filter-candidates", help="reads prefilter JSON on stdin, drops blocked candidate names")
    p.add_argument("--cap", type=int, default=None)

    p = sub.add_parser("extract-item-keys", help="print 'agent<TAB>item_key' lines for a proposal file")
    p.add_argument("--file", required=True)

    p = sub.add_parser("get-frontmatter", help="print one frontmatter value from a note")
    p.add_argument("--file", required=True)
    p.add_argument("--key", required=True)

    p = sub.add_parser("normalize-dedup-key", help="build a dedup:... item key from comma-separated names")
    p.add_argument("--names", required=True)

    p = sub.add_parser("normalize-stale-key", help="build a stale-action:... item key from a note name")
    p.add_argument("--name", required=True)

    return ap


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    cap = getattr(args, "cap", None)
    if cap is None:
        cap = default_cap()

    if args.cmd == "record":
        record_rejection(args.item_key, args.agent, args.proposal_file, args.feedback)
        print(rejection_count(args.item_key))
        return 0
    if args.cmd == "count":
        print(rejection_count(args.item_key))
        return 0
    if args.cmd == "blocked":
        b = is_blocked(args.item_key, cap)
        print("blocked" if b else "not-blocked")
        return 0 if b else 1
    if args.cmd == "recent":
        print(recent_feedback_block(args.item_key, args.n))
        return 0
    if args.cmd == "unblock":
        record_unblock(args.item_key, args.note)
        print(f"unblocked: {args.item_key}")
        return 0
    if args.cmd == "list-blocked":
        for key in all_item_keys():
            c = rejection_count(key)
            if c >= cap:
                print(f"{key}\t{c}")
        return 0
    if args.cmd == "relevant-context":
        with open(args.names_file, encoding="utf-8") as fh:
            names = [line.strip() for line in fh if line.strip()]
        print(relevant_dedup_context(names, args.max_total))
        return 0
    if args.cmd == "filter-exact-groups":
        print(filter_exact_groups(sys.stdin.read()))
        return 0
    if args.cmd == "filter-candidates":
        print(filter_candidates(sys.stdin.read(), cap))
        return 0
    if args.cmd == "extract-item-keys":
        agent, keys = extract_item_keys(args.file)
        for k in keys:
            print(f"{agent}\t{k}")
        return 0
    if args.cmd == "get-frontmatter":
        with open(args.file, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
        print(parse_frontmatter(text).get(args.key, ""))
        return 0
    if args.cmd == "normalize-dedup-key":
        names = [n.strip() for n in args.names.split(",")]
        print(dedup_key(names))
        return 0
    if args.cmd == "normalize-stale-key":
        print(stale_key(args.name))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
