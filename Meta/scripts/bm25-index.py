#!/usr/bin/env python3
"""
bm25-index.py — pure-stdlib Okapi BM25 lexical index over Canon/ + Thinking/ notes
(Phase 4a, ranked retrieval for the Researcher, 2026-07-18).

WHY: the Researcher's context-gathering stage (run-researcher.sh) was a naive
`grep -rilE` over Canon/Thinking with no ranking — whichever files matched first
(readdir order) won the top-8 slots, not the most relevant ones. This adds a real
lexical ranking (BM25, sparse/lexical — no embeddings, no vector DB, per the
project's hard constraint) while staying entirely stdlib and offline.

INDEX: chunk each note (~1000-char chunks on paragraph boundaries), tokenize
(lowercase, alnum word chars; `[[Name]]`/`[[Name|Alias]]` wikilinks and
`[text](url)` markdown links are unwrapped to their visible text before
tokenizing, so a wikilink indexes as its target words, not literal brackets/pipes).

HERMETIC CONTEXTUAL PREFIXING (tier-3, zero LLM calls): each chunk's INDEXED text
(not its displayed snippet) is prefixed with the note's title (filename without
extension) + frontmatter `type` + the note's first sentence, before tokenizing.
This helps term matching for chunks deep in a long note that don't repeat the
note's own subject in every paragraph. The chunk's stored `text` (used for query
snippets) stays the raw chunk content, un-prefixed.

INCREMENTAL: each note's whole-file SHA256 is recorded in the index. On `build`
(without --force), a note whose hash is unchanged is NOT re-chunked/re-tokenized —
its existing chunk/posting entries are kept as-is. A changed or new note has its
old entries (if any) removed first, then re-added. A note removed from disk (or
now excluded, e.g. moved under Canon/_stubs/) has its entries dropped too.

STORAGE: Meta/.bm25-index.json (VAULT-side, gitignored — derived state, safe to
delete/rebuild any time, never content). Chunk entries duplicate their own token
counts (`chunks[id]["tokens"]`) alongside the term->chunk `postings` map — a small
size trade-off that makes incremental removal O(chunk's own term count) instead of
a full postings scan. Atomic write: tempfile in the same dir + fsync + os.replace,
same convention as note-write-state.py / extract-checkpoint.py.

CLI:
  bm25-index.py build [--force]
  bm25-index.py query "search terms" [--top N]

Query output: best-first, one line per hit, `score\\trelpath\\tsnippet` (snippet =
first ~200 chars of the chunk's raw text, single line, whitespace-collapsed).
Deduplicates so a single note contributes at most 2 lines. A missing or corrupt
index file makes `query` print NOTHING and exit 10 — callers (run-researcher.sh)
treat exit 10 as "no index, fall back to grep".

Stdlib only.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
import re
import sys
import tempfile

K1_DEFAULT = 1.5
B_DEFAULT = 0.75
CHUNK_TARGET_CHARS = 1000
NOTE_ROOTS = ("Canon", "Thinking")
EXCLUDE_PREFIXES = ("Canon/_stubs/",)

WORD_RE = re.compile(r"[a-z0-9]+")
WIKILINK_RE = re.compile(r"\[\[([^\]|]+)(?:\|[^\]]+)?\]\]")
MDLINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
CODE_RE = re.compile(r"`([^`]*)`")
HEADING_RE = re.compile(r"^#+\s*", re.MULTILINE)
FM_KEY_RE = re.compile(r'^([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(.*)$')
SENTENCE_RE = re.compile(r'^(.{1,300}?[.!?])(\s|$)')

REQUIRED_KEYS = ("notes", "chunks", "postings", "df", "N", "total_len", "params")


# ── paths / vault ──────────────────────────────────────────────────────

def vault_dir():
    return os.environ.get("VAULT_DIR") or os.getcwd()


def index_path():
    return os.path.join(vault_dir(), "Meta", ".bm25-index.json")


# ── text processing ────────────────────────────────────────────────────

def strip_markdown(text):
    text = WIKILINK_RE.sub(r"\1", text)
    text = MDLINK_RE.sub(r"\1", text)
    text = CODE_RE.sub(r"\1", text)
    return text


def tokenize(text):
    text = strip_markdown(text).lower()
    return WORD_RE.findall(text)


def parse_note(text):
    """Return (frontmatter_fields, body_text). Missing/malformed frontmatter just
    yields ({}, whole text) — never raises."""
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            fm_text = text[3:end]
            body = text[end + 4:]
            if body.startswith("\n"):
                body = body[1:]
            fields = {}
            for line in fm_text.strip("\n").split("\n"):
                m = FM_KEY_RE.match(line)
                if m:
                    k = m.group(1).strip()
                    v = m.group(2).strip().strip('"').strip("'")
                    fields[k] = v
            return fields, body
    return {}, text


def first_sentence(body):
    plain = HEADING_RE.sub("", strip_markdown(body))
    plain = " ".join(plain.split())
    if not plain:
        return ""
    m = SENTENCE_RE.match(plain)
    return m.group(1) if m else plain[:150]


def chunk_body(body, target_size=CHUNK_TARGET_CHARS):
    paras = [p.strip() for p in re.split(r'\n\s*\n', body.strip()) if p.strip()]
    if not paras:
        return []
    chunks = []
    buf = ""
    for p in paras:
        candidate = (buf + "\n\n" + p) if buf else p
        if len(candidate) > target_size and buf:
            chunks.append(buf)
            buf = p
        else:
            buf = candidate
    if buf:
        chunks.append(buf)
    return chunks


def build_note_entries(relpath, text):
    """Chunk + tokenize one note. Returns a list of (chunk_id, snippet_text,
    term_freqs, chunk_len)."""
    fields, body = parse_note(text)
    title = os.path.splitext(os.path.basename(relpath))[0]
    ntype = fields.get("type", "")
    fs = first_sentence(body)
    prefix = " ".join(x for x in (title, ntype, fs) if x)
    entries = []
    for i, chunk_text in enumerate(chunk_body(body)):
        indexed_text = (prefix + "\n\n" + chunk_text) if prefix else chunk_text
        tokens = tokenize(indexed_text)
        if not tokens:
            continue
        tf = {}
        for t in tokens:
            tf[t] = tf.get(t, 0) + 1
        chunk_id = f"{relpath}::{i}"
        entries.append((chunk_id, chunk_text, tf, len(tokens)))
    return entries


def iter_note_relpaths(vault):
    out = []
    for root_name in NOTE_ROOTS:
        root = os.path.join(vault, root_name)
        if not os.path.isdir(root):
            continue
        for dirpath, _dirnames, filenames in os.walk(root):
            for fn in filenames:
                if not fn.endswith(".md"):
                    continue
                full = os.path.join(dirpath, fn)
                rel = os.path.relpath(full, vault).replace(os.sep, "/")
                if any(rel.startswith(p) for p in EXCLUDE_PREFIXES):
                    continue
                out.append(rel)
    return sorted(out)


# ── index storage ──────────────────────────────────────────────────────

def _empty_index():
    return {
        "version": 1,
        "params": {"k1": K1_DEFAULT, "b": B_DEFAULT},
        "notes": {},
        "chunks": {},
        "postings": {},
        "df": {},
        "N": 0,
        "total_len": 0,
    }


def _load_raw_index():
    """Best-effort load for `build` — missing/corrupt/wrong-shape file is treated
    as absent (start fresh), never raises."""
    path = index_path()
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _load_index_for_query():
    """Strict load for `query` — anything short of a well-formed index (missing
    file, corrupt JSON, missing expected keys) returns None, which the caller
    turns into exit code 10 ('no index, fall back to grep')."""
    data = _load_raw_index()
    if data is None:
        return None
    if not all(k in data for k in REQUIRED_KEYS):
        return None
    return data


def _atomic_save(index):
    path = index_path()
    dirpath = os.path.dirname(path)
    os.makedirs(dirpath, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=dirpath)
    try:
        # mkstemp defaults to 0600 — unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(index, fh, ensure_ascii=False)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def _remove_note(index, relpath):
    note_entry = index["notes"].pop(relpath, None)
    if not note_entry:
        return
    for chunk_id in note_entry.get("chunk_ids", []):
        chunk = index["chunks"].pop(chunk_id, None)
        if not chunk:
            continue
        index["total_len"] -= chunk.get("len", 0)
        index["N"] -= 1
        for term in chunk.get("tokens", {}):
            plist = index["postings"].get(term)
            if plist and chunk_id in plist:
                del plist[chunk_id]
                if not plist:
                    del index["postings"][term]
            if term in index["df"]:
                index["df"][term] -= 1
                if index["df"][term] <= 0:
                    del index["df"][term]


def _add_note(index, relpath, text, note_hash):
    chunk_ids = []
    for chunk_id, snippet, tf, length in build_note_entries(relpath, text):
        index["chunks"][chunk_id] = {"note": relpath, "text": snippet, "tokens": tf, "len": length}
        chunk_ids.append(chunk_id)
        index["N"] += 1
        index["total_len"] += length
        for term, freq in tf.items():
            index["postings"].setdefault(term, {})[chunk_id] = freq
            index["df"][term] = index["df"].get(term, 0) + 1
    index["notes"][relpath] = {"hash": note_hash, "chunk_ids": chunk_ids}


# ── BM25 scoring ────────────────────────────────────────────────────────

def score_query(index, query_text, top=8):
    terms = set(tokenize(query_text))
    N = index.get("N", 0)
    total_len = index.get("total_len", 0)
    if not terms or not N or not total_len:
        return []
    avgdl = total_len / N
    df = index.get("df", {})
    postings = index.get("postings", {})
    chunks = index.get("chunks", {})
    params = index.get("params", {}) or {}
    k1 = params.get("k1", K1_DEFAULT)
    b = params.get("b", B_DEFAULT)

    scores = {}
    for t in terms:
        d_f = df.get(t)
        if not d_f:
            continue
        idf = math.log(1 + (N - d_f + 0.5) / (d_f + 0.5))
        for chunk_id, tf in postings.get(t, {}).items():
            chunk = chunks.get(chunk_id)
            if not chunk:
                continue
            dl = chunk.get("len", 0) or 0
            denom = tf + k1 * (1 - b + b * (dl / avgdl if avgdl else 0))
            if denom <= 0:
                continue
            scores[chunk_id] = scores.get(chunk_id, 0.0) + idf * (tf * (k1 + 1)) / denom

    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    results = []
    per_note = {}
    for chunk_id, s in ranked:
        chunk = chunks.get(chunk_id)
        if not chunk:
            continue
        note = chunk.get("note")
        if per_note.get(note, 0) >= 2:
            continue
        per_note[note] = per_note.get(note, 0) + 1
        results.append((s, note, chunk.get("text", "")))
        if len(results) >= top:
            break
    return results


# ── CLI ─────────────────────────────────────────────────────────────────

def cmd_build(args):
    vault = vault_dir()
    index = None if args.force else _load_raw_index()
    if not isinstance(index, dict) or not all(k in index for k in REQUIRED_KEYS):
        index = _empty_index()

    current = set(iter_note_relpaths(vault))
    for rel in set(index["notes"].keys()) - current:
        _remove_note(index, rel)

    changed = 0
    unchanged = 0
    for rel in sorted(current):
        full = os.path.join(vault, rel)
        try:
            with open(full, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        h = hashlib.sha256(text.encode("utf-8")).hexdigest()
        existing = index["notes"].get(rel)
        if existing and existing.get("hash") == h:
            unchanged += 1
            continue
        if existing:
            _remove_note(index, rel)
        _add_note(index, rel, text, h)
        changed += 1

    index["built"] = datetime.datetime.now().isoformat(timespec="seconds")
    _atomic_save(index)
    print(f"bm25-index: {len(current)} notes ({changed} (re)indexed, {unchanged} unchanged), {index['N']} chunks")
    return 0


def cmd_query(args):
    index = _load_index_for_query()
    if index is None:
        return 10
    for score, note, text in score_query(index, args.terms, top=args.top):
        snippet = " ".join(text.split())[:200]
        print(f"{score:.4f}\t{note}\t{snippet}")
    return 0


def build_arg_parser():
    ap = argparse.ArgumentParser(description="Stdlib Okapi BM25 index over Canon/ + Thinking/ notes.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("build", help="build or incrementally refresh the index")
    p.add_argument("--force", action="store_true", help="full rebuild, ignore stored hashes")

    p = sub.add_parser("query", help="rank notes/chunks against search terms")
    p.add_argument("terms")
    p.add_argument("--top", type=int, default=8)

    return ap


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    if args.cmd == "build":
        return cmd_build(args)
    if args.cmd == "query":
        return cmd_query(args)
    return 1


if __name__ == "__main__":
    sys.exit(main())
