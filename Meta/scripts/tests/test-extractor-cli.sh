#!/bin/bash
# test-extractor-cli.sh — behavioral test for run-extractor.sh's --dry-run and --force
# flags (Phase 1 hardening, 2026-07-18). Uses notes with an EMPTY transcript body so
# get_transcript() yields zero chunks -> the real script runs its full arg-parsing +
# status write-back logic with ZERO invoke-agent.sh/LLM calls (no stubbing needed, no
# network). Exit 0 = pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
EXTRACTOR="$SCRIPT_DIR/run-extractor.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Inbox/Voice" "$TV/Canon" "$TV/Thinking" "$TV/Meta"

note_with_status() {
    # $1 = path, $2 = status value, no body -> empty transcript, zero LLM calls
    printf -- '---\nstatus: %s\nsource: voice\n---\n' "$2" > "$1"
}

note_with_status "$TV/Inbox/Voice/note1.md" "transcribed"
note_with_status "$TV/Inbox/Voice/note2.md" "inbox"
note_with_status "$TV/Inbox/Voice/note3.md" "extracted"
note_with_status "$TV/Inbox/Voice/note4.md" "extracted"
note_with_status "$TV/Inbox/Voice/note5.md" "reviewed"
note_with_status "$TV/Inbox/Voice/note6.md" "reviewed"

# --- --dry-run (no arg): sweeps inbox|transcribed only, zero writes ---
OUT1="$(VAULT_DIR="$TV" bash "$EXTRACTOR" --dry-run 2>&1)"
check "dry-run sweep reports 2 memos"        contains "$OUT1" "2 memo(s) would be processed"
check "dry-run sweep lists note1"            contains "$OUT1" "note1.md"
check "dry-run sweep lists note2"            contains "$OUT1" "note2.md"
check "dry-run sweep excludes extracted note3" bash -c '! printf "%s" "$1" | grep -q note3.md' _ "$OUT1"
check "dry-run makes zero writes (no MANIFEST.md)" test ! -f "$TV/Meta/MANIFEST.md"
check "dry-run creates no Canon files"       bash -c '[ -z "$(find "$1/Canon" -name "*.md" 2>/dev/null)" ]' _ "$TV"

# --- --dry-run <note> already extracted, no --force: explains explicit-arg semantics ---
OUT2="$(VAULT_DIR="$TV" bash "$EXTRACTOR" --dry-run "$TV/Inbox/Voice/note4.md" 2>&1)"
check "dry-run explicit note reports WOULD PROCESS"  contains "$OUT2" "WOULD PROCESS"
check "dry-run explicit note shows its status"       contains "$OUT2" "status: extracted"
check "dry-run explicit note hints at --force"       contains "$OUT2" "--force"

# --- --dry-run --force <note>: distinct forced message ---
OUT3="$(VAULT_DIR="$TV" bash "$EXTRACTOR" --dry-run --force "$TV/Inbox/Voice/note4.md" 2>&1)"
check "dry-run --force reports forced"               contains "$OUT3" "WOULD PROCESS (forced)"

# --- --dry-run on a missing note: NOT FOUND, exit 1 ---
set +e
OUT4="$(VAULT_DIR="$TV" bash "$EXTRACTOR" --dry-run "$TV/Inbox/Voice/nope.md" 2>&1)"
RC4=$?
set -e
check "dry-run missing note reports NOT FOUND"       contains "$OUT4" "NOT FOUND"
check "dry-run missing note exits nonzero"           [ "$RC4" -eq 1 ]

# --- --force actually reprocesses and resets an ARBITRARY prior status to extracted ---
VAULT_DIR="$TV" bash "$EXTRACTOR" --force "$TV/Inbox/Voice/note5.md" >/dev/null 2>&1
check "--force resets status: reviewed -> extracted"  grep -qx 'status: extracted' "$TV/Inbox/Voice/note5.md"
check "--force still appends ## Extracted section"    grep -q '^## Extracted' "$TV/Inbox/Voice/note5.md"

# --- plain positional arg (no --force) leaves an unusual status untouched: existing
# behavior must stay byte-compatible — only inbox/transcribed ever flip to extracted ---
VAULT_DIR="$TV" bash "$EXTRACTOR" "$TV/Inbox/Voice/note6.md" >/dev/null 2>&1
check "plain arg does NOT reset status: reviewed"     grep -qx 'status: reviewed' "$TV/Inbox/Voice/note6.md"
check "plain arg still appends ## Extracted section"  grep -q '^## Extracted' "$TV/Inbox/Voice/note6.md"

[ "$fail" -eq 0 ] && echo "test-extractor-cli: PASS" || { echo "test-extractor-cli: FAIL"; exit 1; }
