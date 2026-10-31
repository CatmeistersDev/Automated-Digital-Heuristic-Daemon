#!/bin/bash
# test-extractor-checkpoint.sh — behavioral test for run-extractor.sh's chunk-level
# resume checkpoint (Phase 3 hardening, 2026-07-18). A scheduler timeout kills the
# whole process group mid-memo; this asserts a resumed run skips already-completed
# chunks (and doesn't lose their Canon files from the final "## Extracted" rebuild),
# a hash mismatch (edited transcript) discards a stale checkpoint and starts clean,
# and --force always discards regardless of match. Uses a fake invoke-agent.sh (no
# Ollama/network) that logs which chunk index it was called for and can be told to
# fail at a specific chunk, simulating a kill.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
not_contains() { ! printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/scripts" "$TV/Inbox/Voice" "$TV/Canon" "$TV/Thinking" "$TV/Meta"
cp "$SCRIPT_DIR/run-extractor.sh" "$TV/scripts/run-extractor.sh"
cp "$SCRIPT_DIR/extract-checkpoint.py" "$TV/scripts/extract-checkpoint.py"
EXTRACTOR="$TV/scripts/run-extractor.sh"

# Fake invoke-agent.sh: no LLM/network. Logs the chunk index it was asked to process
# (parsed out of the real prompt's "BEGIN TRANSCRIPT CHUNK N OF M" marker) to
# $FAKE_INVOKE_LOG, then either fails (if FAKE_FAIL_AT_CHUNK matches) or creates a
# distinguishable Canon/Actions/ note for that chunk index and succeeds.
cat > "$TV/scripts/invoke-agent.sh" <<'STUB'
#!/bin/bash
set -uo pipefail
PROMPT="$2"
IDX="$(printf '%s' "$PROMPT" | grep -oE 'BEGIN TRANSCRIPT CHUNK [0-9]+ OF' | head -n1 | grep -oE '[0-9]+')"
: "${FAKE_INVOKE_LOG:?}"
echo "$IDX" >> "$FAKE_INVOKE_LOG"
if [ -n "${FAKE_FAIL_AT_CHUNK:-}" ] && [ "$IDX" = "$FAKE_FAIL_AT_CHUNK" ]; then
    echo "stub: simulated failure (kill) at chunk $IDX" >&2
    exit 1
fi
mkdir -p Canon/Actions
printf -- '---\ntype: action\nname: Chunk%s Thing\nstatus: open\nfirst_mentioned: 2026-01-01\nsource: ai-extracted\nsource_agent: Extractor\nsource_date: 2026-01-01T00:00\n---\n# \xf0\x9f\x8e\xaf Chunk%s Thing\n\nOwner: [[Louise]]\n' "$IDX" "$IDX" > "Canon/Actions/Chunk${IDX} Thing.md"
exit 0
STUB
chmod +x "$TV/scripts/invoke-agent.sh"

note_with_raw() {   # $1 = path, $2 = line1, $3 = line2, $4 = line3
    printf -- '---\nstatus: transcribed\nsource: voice\n---\n\n# Raw\n%s\n%s\n%s\n' "$2" "$3" "$4" > "$1"
}

# ============================================================================
# Scenario A: chunk 3 "killed" (fails) -> checkpoint retains chunks 1,2 -> a
# second run resumes, skipping 1,2, only invoking chunk 3, and the final note
# still lists all three entities in "## Extracted".
# ============================================================================
NOTE_A="$TV/Inbox/Voice/note-a.md"
note_with_raw "$NOTE_A" "Alpha line one." "Bravo line two." "Charlie line three."

LOG1="$TV/invoke-calls-1.log"; : > "$LOG1"
OUT1="$(EXTRACT_CHUNK_CHARS=1 FAKE_INVOKE_LOG="$LOG1" FAKE_FAIL_AT_CHUNK=3 \
    VAULT_DIR="$TV" bash "$EXTRACTOR" "$NOTE_A" 2>&1)"
RC1=$?
check "run1: chunk 1 invoked"                  bash -c 'grep -qx 1 "$1"' _ "$LOG1"
check "run1: chunk 2 invoked"                  bash -c 'grep -qx 2 "$1"' _ "$LOG1"
check "run1: chunk 3 invoked (then fails)"     bash -c 'grep -qx 3 "$1"' _ "$LOG1"
check "run1: exits nonzero (chunk failure)"    [ "$RC1" -ne 0 ]
check "run1: status left unchanged (not extracted)" grep -qx 'status: transcribed' "$NOTE_A"
# The write-back always rebuilds "## Extracted" from whatever NEWER_FILES exist so far
# (only `status:` is gated on NOTE_FAIL) — so it lists chunks 1,2 (created before the
# chunk-3 failure) but NOT chunk 3 (never ran).
check "run1: Extracted (partial) lists chunk1 entity" grep -qF '[[Canon/Actions/Chunk1 Thing]]' "$NOTE_A"
check "run1: Extracted (partial) lists chunk2 entity" grep -qF '[[Canon/Actions/Chunk2 Thing]]' "$NOTE_A"
check "run1: Extracted (partial) does NOT list chunk3 entity" bash -c '! grep -qF "[[Canon/Actions/Chunk3 Thing]]" "$1"' _ "$NOTE_A"

CKPT_COUNT_A="$(find "$TV/Meta/.extract-progress" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
check "run1: exactly one checkpoint file written" [ "$CKPT_COUNT_A" = "1" ]
CKPT_FILE_A="$(find "$TV/Meta/.extract-progress" -name '*.json' 2>/dev/null | head -n1)"
check "run1: checkpoint records chunks 1,2 completed (not 3)" bash -c '
    python3 - "$1" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if sorted(d.get("completed_chunks", [])) == [1, 2] else 1)
PY
' _ "$CKPT_FILE_A"

LOG2="$TV/invoke-calls-2.log"; : > "$LOG2"
OUT2="$(EXTRACT_CHUNK_CHARS=1 FAKE_INVOKE_LOG="$LOG2" \
    VAULT_DIR="$TV" bash "$EXTRACTOR" "$NOTE_A" 2>&1)"
RC2=$?
check "run2 (resume): reports 2/3 checkpointed"  contains "$OUT2" "Resume: using 2/3 checkpointed chunks"
check "run2 (resume): chunk 1 NOT re-invoked"    bash -c '! grep -qx 1 "$1"' _ "$LOG2"
check "run2 (resume): chunk 2 NOT re-invoked"    bash -c '! grep -qx 2 "$1"' _ "$LOG2"
check "run2 (resume): chunk 3 invoked"           bash -c 'grep -qx 3 "$1"' _ "$LOG2"
check "run2 (resume): exits zero"                [ "$RC2" -eq 0 ]
check "run2 (resume): status flips to extracted" grep -qx 'status: extracted' "$NOTE_A"
check "run2 (resume): Extracted lists chunk1 entity" grep -qF '[[Canon/Actions/Chunk1 Thing]]' "$NOTE_A"
check "run2 (resume): Extracted lists chunk2 entity" grep -qF '[[Canon/Actions/Chunk2 Thing]]' "$NOTE_A"
check "run2 (resume): Extracted lists chunk3 entity" grep -qF '[[Canon/Actions/Chunk3 Thing]]' "$NOTE_A"
check "run2 (resume): checkpoint deleted on success" [ ! -f "$CKPT_FILE_A" ]

# ============================================================================
# Scenario B: checkpoint left behind by a failed chunk, then the transcript is
# EDITED before the next run -> hash mismatch discards the stale checkpoint and
# every chunk is re-invoked from scratch (no resume).
# ============================================================================
NOTE_B="$TV/Inbox/Voice/note-b.md"
note_with_raw "$NOTE_B" "One fish." "Two fish." "Red fish."

LOG3="$TV/invoke-calls-3.log"; : > "$LOG3"
EXTRACT_CHUNK_CHARS=1 FAKE_INVOKE_LOG="$LOG3" FAKE_FAIL_AT_CHUNK=2 \
    VAULT_DIR="$TV" bash "$EXTRACTOR" "$NOTE_B" >/dev/null 2>&1
CKPT_COUNT_B="$(find "$TV/Meta/.extract-progress" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
check "run1(B): checkpoint left behind"        [ "$CKPT_COUNT_B" -ge 1 ]

# Edit the transcript content -> different sha256 -> old checkpoint is now orphaned
# under its old hash and unreachable; the note's NEW hash has no checkpoint on disk,
# so this is exercised as "no checkpoint found for the new hash" (equivalent resume
# outcome to an explicit DISCARDED message when a checkpoint file happens to exist
# for the new hash — here it simply doesn't exist yet, which is the common case).
note_with_raw "$NOTE_B" "Blue fish edited." "Two fish." "Red fish."

LOG4="$TV/invoke-calls-4.log"; : > "$LOG4"
OUT4="$(EXTRACT_CHUNK_CHARS=1 FAKE_INVOKE_LOG="$LOG4" \
    VAULT_DIR="$TV" bash "$EXTRACTOR" "$NOTE_B" 2>&1)"
check "run2(B) edited transcript: no resume message" not_contains "$OUT4" "Resume: using"
check "run2(B) edited transcript: all 3 chunks re-invoked from scratch" bash -c '
    [ "$(sort -u "$1" | tr -d "\n")" = "123" ]
' _ "$LOG4"
check "run2(B) edited transcript: status flips to extracted" grep -qx 'status: extracted' "$NOTE_B"

# ============================================================================
# Scenario C: --force always discards an existing checkpoint, even one whose hash
# matches exactly (no edit) -> every chunk is re-invoked, nothing skipped.
# ============================================================================
NOTE_C="$TV/Inbox/Voice/note-c.md"
note_with_raw "$NOTE_C" "First line." "Second line." "Third line."

LOG5="$TV/invoke-calls-5.log"; : > "$LOG5"
EXTRACT_CHUNK_CHARS=1 FAKE_INVOKE_LOG="$LOG5" FAKE_FAIL_AT_CHUNK=2 \
    VAULT_DIR="$TV" bash "$EXTRACTOR" "$NOTE_C" >/dev/null 2>&1
CKPT_COUNT_C="$(find "$TV/Meta/.extract-progress" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
check "run1(C): checkpoint left behind"        [ "$CKPT_COUNT_C" -ge 1 ]

LOG6="$TV/invoke-calls-6.log"; : > "$LOG6"
OUT6="$(EXTRACT_CHUNK_CHARS=1 FAKE_INVOKE_LOG="$LOG6" \
    VAULT_DIR="$TV" bash "$EXTRACTOR" --force "$NOTE_C" 2>&1)"
check "run2(C) --force: no resume message"     not_contains "$OUT6" "Resume: using"
check "run2(C) --force: all 3 chunks re-invoked" bash -c '
    [ "$(sort -u "$1" | tr -d "\n")" = "123" ]
' _ "$LOG6"
check "run2(C) --force: status extracted"      grep -qx 'status: extracted' "$NOTE_C"

[ "$fail" -eq 0 ] && echo "test-extractor-checkpoint: PASS" || { echo "test-extractor-checkpoint: FAIL"; exit 1; }
