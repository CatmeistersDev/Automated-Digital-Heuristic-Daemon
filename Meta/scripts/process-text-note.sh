#!/bin/bash
# process-text-note.sh (LOCAL)
# Dropped text/markdown file -> Inbox wrapper note -> run-extractor.sh -> archive -> notify.
# Mirrors process-voice-memo.sh's shape (wrap -> chain extraction -> archive -> notify) for
# plain-text drops instead of audio, so the vault owner can drop a note/question-list/pasted
# article into Inbox/Text/_drop/ and have it ingested like a voice memo without hand-formatting
# frontmatter. No transcription step, so no bounded-retry DLQ counter — unreadable/empty/
# non-UTF-8 input fails once and is quarantined immediately (see quarantine() below).
#
# Usage: process-text-note.sh /path/to/dropped-file.(md|txt|pdf)
#
# Clippings lane: drops arriving via Inbox/Text/_drop-noextract/
# and ALL .pdf drops are filed to Clippings/ (kepano convention: others' content, verbatim,
# agent-read-only) instead of Inbox/, as type: clipping / status: filed. This also keeps
# them out of the 2-hourly no-arg run-extractor.sh sweep, which greps Inbox/ for
# `status: inbox` and would otherwise extract a noextract note ~2h after it was
# deliberately skipped. The lane is decided by DROP PATH (or .pdf extension), not by the
# TEXTNOTE_NO_EXTRACT env var — that var only skips the extraction chain (tests use it to
# run LLM-free). Both clipping triggers force TEXTNOTE_NO_EXTRACT=1 themselves. PDFs are
# converted to text in-image via pymupdf; a PDF pymupdf cannot read is quarantined.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-/vault}"
cd "$VAULT_DIR" || { echo "FATAL: cannot cd to $VAULT_DIR" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: $0 <text-file>"; exit 1; }
BASE="$(basename "$SRC")"

# Skip Syncthing temp/partial/hidden files (the watcher may fire on these)
case "$BASE" in
    .*|*.tmp|*.part|*~|*.syncthing.*) echo "skip (temp/hidden): $BASE"; exit 0 ;;
esac
# Only handle known text extensions
IS_PDF=0
CLIP=0
case "${BASE,,}" in
    *.md|*.txt) : ;;
    *.pdf) IS_PDF=1 ;;   # PDFs are reference material -> Clippings, never extracted
    *) echo "skip (not text): $BASE"; exit 0 ;;
esac
case "$SRC" in
    */_drop-noextract/*) CLIP=1 ;;   # reference-material drop dir -> Clippings
esac
if [ "$IS_PDF" = 1 ]; then CLIP=1; fi
if [ "$CLIP" = 1 ]; then TEXTNOTE_NO_EXTRACT=1; fi
[ -f "$SRC" ] || { echo "skip (not found, likely already processed): $SRC"; exit 0; }

# Wait for the file to stop growing (Syncthing/editor may still be writing it) — same
# pattern as process-voice-memo.sh's settle loop, kept here too so this script is safe
# to invoke standalone, not just from the scheduler's watcher (which adds its own delay).
prev=-1; for _ in 1 2 3 4 5; do
    cur=$(stat -c %s "$SRC" 2>/dev/null || echo 0)
    [ "$cur" = "$prev" ] && [ "$cur" -gt 0 ] && break
    prev="$cur"; sleep 2
done

DROP_DIR="$VAULT_DIR/Inbox/Text/_drop"
PROCESSED_DIR="$VAULT_DIR/Inbox/Text/_processed"
FAILED_DIR="$VAULT_DIR/Inbox/Text/_failed"
mkdir -p "$VAULT_DIR/Inbox" "$DROP_DIR" "$PROCESSED_DIR" "$FAILED_DIR"

quarantine() {   # $1 = one-line reason. Parks the original + sidecar in _failed; alerts once.
    mkdir -p "$FAILED_DIR"
    {
        echo "file: $BASE"
        echo "quarantined: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "reason: $1"
    } > "$FAILED_DIR/${BASE}.reason.txt" 2>/dev/null
    mv "$SRC" "$FAILED_DIR/" 2>/dev/null || true
    /bin/bash "$SCRIPT_DIR/notify.sh" "🚫 Text note quarantined: $BASE" \
        "$1 — moved to Inbox/Text/_failed/ (see ${BASE}.reason.txt). Fix and drop again to retry." high "no_entry,rotating_light" 2>/dev/null || true
}

DATE="$(date +%Y-%m-%d)"

# --- Read, validate, sanitize, and atomically write the wrapper note (all in one python
# process so the (possibly large) file content never round-trips through a bash variable —
# only a two-line status is passed back). Prints "OK\n<note path relative to VAULT_DIR>" or
# "FAIL\n<one-line reason>".
RESULT="$(python3 - "$SRC" "$VAULT_DIR" "$DATE" "$BASE" "$CLIP" "$IS_PDF" <<'PY'
import os
import re
import sys
import tempfile
import time
import unicodedata

src, vault_dir, today, orig_base, clip, is_pdf = sys.argv[1:7]
clip = clip == "1"
is_pdf = is_pdf == "1"

# --- read + validate -------------------------------------------------------------
try:
    with open(src, "rb") as f:
        data = f.read()
except OSError as e:
    print("FAIL")
    print(f"unreadable: {e}")
    sys.exit(0)

if len(data) == 0:
    print("FAIL")
    print("empty file")
    sys.exit(0)

if is_pdf:
    # PDF -> plain text via pymupdf (in the image via constraints.txt). Page texts are
    # joined with a page marker so long documents stay navigable. A PDF with no
    # extractable text (pure scan, no OCR layer) is quarantined, not filed empty.
    # Import as `pymupdf` first: newer releases print a deprecation warning on STDOUT for
    # `import fitz`, which corrupts this block's OK/FAIL protocol and quarantined every PDF.
    try:
        import pymupdf as fitz
    except ImportError:
        try:
            import fitz  # older pymupdf
        except ImportError:
            fitz = None
    if fitz is None:
        print("FAIL")
        print("pdf support requires pymupdf (not installed in this image)")
        sys.exit(0)
    try:
        doc = fitz.open(stream=data, filetype="pdf")
        pages = [page.get_text().strip() for page in doc]
        doc.close()
    except Exception as e:
        print("FAIL")
        print(f"pdf unreadable by pymupdf: {e}")
        sys.exit(0)
    text = "\n\n".join(
        f"<!-- page {i} -->\n{p}" for i, p in enumerate(pages, 1) if p
    )
    if not text.strip():
        print("FAIL")
        print("pdf has no extractable text (scanned image without OCR layer?)")
        sys.exit(0)
else:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        print("FAIL")
        print(f"non-UTF-8-decodable: {e}")
        sys.exit(0)

# --- sanitize the basename for the note filename ---------------------------------
# Strip path separators/control chars, drop characters illegal in Windows filenames
# (this vault is also reached over SMB as a Windows share), collapse whitespace, keep
# it human-readable. Falls back to a timestamp slug if nothing printable survives.
stem = os.path.splitext(orig_base)[0]
stem = stem.replace("/", "-").replace("\\", "-")
stem = "".join(ch for ch in stem if unicodedata.category(ch) != "Cc")
stem = re.sub(r'[<>:"|?*]', "", stem)
stem = re.sub(r"\s+", " ", stem).strip(" .")
stem = stem[:80].strip(" .")
if not stem:
    stem = "note-" + time.strftime("%H%M%S")

# Destination: extraction-bound notes go to Inbox/ (swept by run-extractor.sh);
# noextract-dir/PDF reference material goes to Clippings/ as type: clipping with
# status: filed — outside the Inbox sweep, agent-read-only (harness-enforced).
if clip:
    dest_dir = os.path.join(vault_dir, "Clippings")
    rel_prefix = "Clippings/"
    name_fmt = "{today} - {stem}"
    note_type, note_status = "clipping", "filed"
else:
    dest_dir = os.path.join(vault_dir, "Inbox")
    rel_prefix = "Inbox/"
    name_fmt = "{today} - Text - {stem}"
    note_type, note_status = "text-note", "inbox"
os.makedirs(dest_dir, exist_ok=True)

def note_path(s):
    return os.path.join(dest_dir, name_fmt.format(today=today, stem=s) + ".md")

candidate_stem = stem
note = note_path(candidate_stem)
n = 2
while os.path.exists(note):
    candidate_stem = f"{stem}-{n}"
    note = note_path(candidate_stem)
    n += 1

def yaml_dq(s):
    # Minimal YAML double-quoted-scalar escaping — enough for arbitrary filenames.
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

name_value = name_fmt.format(today=today, stem=candidate_stem)
frontmatter = (
    "---\n"
    f"name: {yaml_dq(name_value)}\n"
    f"created: {today}\n"
    f"type: {note_type}\n"
    "source: human\n"
    f"status: {note_status}\n"
    f"original_file: {yaml_dq(orig_base)}\n"
    "---\n"
    "\n"
    "# Raw\n"
)
# Byte-exact: the decoded text is appended verbatim (no reformatting/stripping), same
# rule as the voice pipeline's "# Raw" — this is source evidence. If the dropped file
# itself starts with its own YAML frontmatter, it stays embedded here as plain text,
# not merged into the wrapper's frontmatter above.
body = frontmatter + text

# Atomic write: temp file in the SAME dir + fsync + os.replace. newline="" disables
# Python's universal-newline translation on write so whatever line endings the
# original had (LF/CRLF/mixed) are reproduced exactly, not silently rewritten.
fd, tmp_path = tempfile.mkstemp(prefix=".tmp-textnote-", dir=dest_dir)
try:
    # mkstemp defaults to 0600 -- unreadable to the vault's own later reads once the
    # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
    os.chmod(tmp_path, 0o644)
    with os.fdopen(fd, "w", encoding="utf-8", newline="") as tf:
        tf.write(body)
        tf.flush()
        os.fsync(tf.fileno())
    os.replace(tmp_path, note)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise

print("OK")
print(rel_prefix + os.path.basename(note))
PY
)"
PY_RC=$?

if [ "$PY_RC" -ne 0 ] || [ -z "$RESULT" ]; then
    quarantine "internal error building the wrapper note (see stderr/logs)"
    exit 0
fi
STATUS="$(printf '%s\n' "$RESULT" | sed -n '1p')"
PAYLOAD="$(printf '%s\n' "$RESULT" | sed -n '2p')"

if [ "$STATUS" = "FAIL" ]; then
    quarantine "$PAYLOAD"
    exit 0
fi
if [ "$STATUS" != "OK" ] || [ -z "$PAYLOAD" ]; then
    quarantine "internal error: unexpected wrapper output"
    exit 0
fi

REL_NOTE="$PAYLOAD"
NOTE="$VAULT_DIR/$REL_NOTE"
echo "  created: $REL_NOTE"

# Archive the original so the watcher won't reprocess it. Collision-safe (two drops of
# the same filename on different days would otherwise clobber each other in _processed).
TARGET="$PROCESSED_DIR/$BASE"
if [ -e "$TARGET" ]; then
    STEM="${BASE%.*}"; EXT="${BASE##*.}"
    n=2
    while [ -e "$PROCESSED_DIR/${STEM}-${n}.${EXT}" ]; do n=$((n+1)); done
    TARGET="$PROCESSED_DIR/${STEM}-${n}.${EXT}"
fi
mv "$SRC" "$TARGET" 2>/dev/null || echo "  ⚠ could not move original to _processed: $SRC" >&2
REL_PROCESSED="Inbox/Text/_processed/$(basename "$TARGET")"

# git runs as root in the container against a vault owned by another user -> trust it
# (same setup run-extractor.sh does before its own commit).
git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# For agent_stage_and_commit()/agent_ignored_among() below (the same gitignore-swallow
# guard run-extractor.sh's commit step uses). Sourced defensively — a missing/broken
# lib-agent.sh must never break note filing, only skip the extra safety net + commit.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
fi

SCRIPT_RC=0
if git -C "$VAULT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 && command -v agent_stage_and_commit >/dev/null 2>&1; then
    if agent_stage_and_commit "TextNote" "wrap: $(basename "$NOTE")" "$REL_NOTE" "$REL_PROCESSED"; then
        echo "  committed: $(basename "$NOTE")"
    else
        echo "  ⚠ COMMIT FAILED/BLOCKED for $(basename "$NOTE")" >&2
        /bin/bash "$SCRIPT_DIR/notify.sh" "🛑 TextNote commit failed" "$(basename "$NOTE"): note filed on disk but git commit failed or was blocked — see scheduler.log" high "warning" 2>/dev/null || true
        SCRIPT_RC=1
    fi
else
    echo "  (skipping commit: not a git work tree or lib-agent.sh unavailable)"
fi

# Chain extraction exactly like the voice pipeline does, unless explicitly skipped
# (tests, or reference-material drops the vault owner wants to file without Canon churn).
EXTRACT_RC=0
if [ "${TEXTNOTE_NO_EXTRACT:-0}" = "1" ]; then
    echo "  TEXTNOTE_NO_EXTRACT=1 — skipping extraction chain"
else
    echo "[$(date +%H:%M:%S)] Extracting..."
    /bin/bash "$SCRIPT_DIR/run-extractor.sh" "$REL_NOTE" || EXTRACT_RC=$?
    echo "[$(date +%H:%M:%S)] Done: $(basename "$NOTE") (extract rc=$EXTRACT_RC)"
fi

# Notify (ntfy/Discord, no-op if unconfigured). Report the TRUE outcome: if extraction
# failed, run-extractor left the note as status: inbox for the 2-hourly catch-up retry.
EXTRACTED_LIST="$(sed -n '/^## Extracted/,$p' "$NOTE" 2>/dev/null | grep -oE '\[\[[^]]+\]\]' | tr -d '[]' | paste -sd',' - | sed 's/,/, /g' | cut -c1-180)"
if [ "$CLIP" = 1 ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "📎 Clipping filed: $(basename "$NOTE" .md)" "reference material -> Clippings/ (no extraction)" default "paperclip" "$REL_NOTE" 2>/dev/null || true
elif [ "${TEXTNOTE_NO_EXTRACT:-0}" = "1" ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "📝 Text note filed: $(basename "$NOTE" .md)" "extraction skipped (TEXTNOTE_NO_EXTRACT=1)" default "memo,pencil" "$REL_NOTE" 2>/dev/null || true
elif [ "$EXTRACT_RC" -ne 0 ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "⚠️ Text note filed but extraction FAILED: $(basename "$NOTE" .md)" "left as 'inbox' for retry (rc=$EXTRACT_RC)" high "warning" "$REL_NOTE" 2>/dev/null || true
else
    /bin/bash "$SCRIPT_DIR/notify.sh" "✅ Text note processed: $(basename "$NOTE" .md)" "${EXTRACTED_LIST:-filed}" default "white_check_mark,memo" "$REL_NOTE" 2>/dev/null || true
fi

exit "$SCRIPT_RC"
