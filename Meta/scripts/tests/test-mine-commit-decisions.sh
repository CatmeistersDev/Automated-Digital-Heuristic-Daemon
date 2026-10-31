#!/bin/bash
# test-mine-commit-decisions.sh — behavioral test for Meta/scripts/mine-commit-decisions.py
# (Phase 4b). Asserts: decision-signal commit subjects are found (and neutral ones
# aren't), plain mode is propose-only (prints, writes nothing), --queue writes a
# review-queue note and records seen hashes so a second --queue run doesn't
# re-propose the same commit, and a candidate overlapping an existing
# Canon/Decisions/ note name is dedup'd out of --queue. Uses a real throwaway git
# repo (git log needs one) but never touches this repo. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
MINER="$SCRIPT_DIR/mine-commit-decisions.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
not_contains() { ! printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Canon/Decisions" "$TV/Meta"
git -C "$TV" init -q
git -C "$TV" config user.email "test@local"
git -C "$TV" config user.name "Test"

commit() {
    echo "x" >> "$TV/file.txt"
    git -C "$TV" add file.txt
    git -C "$TV" commit -q -m "$1"
}

commit "switch to Wonder Wharf for ticketing"
commit "fix a typo in the README"
commit "decided to retire the old backup script"
commit "replace Family Funtime Corporation with Wonder Wharf for tickets"
commit "instead of Postgres, use SQLite for the cache"
commit "bump dependency version"

# --- plain mode: propose-only, prints matches, ignores neutral commits ---
OUT1="$(VAULT_DIR="$TV" python3 "$MINER" 2>&1)"
check "finds 'switch to' candidate"       contains "$OUT1" "switch to Wonder Wharf for ticketing"
check "finds 'decided'/'retire' candidate" contains "$OUT1" "decided to retire the old backup script"
check "finds 'replace...with' candidate"  contains "$OUT1" "replace Family Funtime Corporation with Wonder Wharf for tickets"
check "finds 'instead of' candidate"      contains "$OUT1" "instead of Postgres, use SQLite for the cache"
check "does NOT flag neutral commit"      not_contains "$OUT1" "fix a typo"
check "does NOT flag unrelated commit"    not_contains "$OUT1" "bump dependency version"
check "plain mode writes nothing"         bash -c '[ -z "$(find "$1/Meta/review-queue" -type f 2>/dev/null)" ]' _ "$TV"

# --- --queue: writes a review-queue note, records state ---
OUT2="$(VAULT_DIR="$TV" python3 "$MINER" --queue 2>&1)"
QFILE="$(find "$TV/Meta/review-queue" -type f -name '*-decision-candidates.md' | head -1)"
check "--queue creates a review-queue file"  [ -n "$QFILE" ]
check "queue note has type: review-item"     bash -c 'grep -q "^type: review-item" "$1"' _ "$QFILE"
check "queue note lists switch-to candidate" bash -c 'grep -qF "switch to Wonder Wharf" "$1"' _ "$QFILE"
check "state file created"                    [ -f "$TV/Meta/.decision-mine-state.json" ]
check "reports N new"                         contains "$OUT2" "new)"

# --- second --queue run: already-seen hashes are not re-proposed ---
OUT3="$(VAULT_DIR="$TV" python3 "$MINER" --queue 2>&1)"
check "second --queue run finds nothing new" contains "$OUT3" "No new decision candidates"

# --- dedup against an existing Canon/Decisions/ note name (excluded) alongside a
# genuinely new, non-overlapping candidate in the SAME run (still queued) ---
cat > "$TV/Canon/Decisions/Switch ticketing to Wonder Wharf.md" <<'EOF'
---
type: decision
name: Switch ticketing to Wonder Wharf
source: human
created: 2026-01-01
---
# ⚖️ Switch ticketing to Wonder Wharf
Already captured.
EOF
commit "switch to Zendesk instead of Wonder Wharf"
commit "decided to adopt Kubernetes for orchestration"
OUT4="$(VAULT_DIR="$TV" python3 "$MINER" --queue 2>&1)"
check "new non-overlapping candidate still queued" contains "$OUT4" "new)"
QFILE2="$(find "$TV/Meta/review-queue" -type f -name '*-decision-candidates.md' | head -1)"
check "new non-overlapping candidate present in queue file" bash -c '
    grep -qF "decided to adopt Kubernetes" "$1"
' _ "$QFILE2"
check "existing-decision-overlap candidate excluded from queue file" bash -c '
    ! grep -qF "switch to Zendesk instead of Wonder Wharf" "$1"
' _ "$QFILE2"

[ "$fail" -eq 0 ] && echo "test-mine-commit-decisions: PASS" || { echo "test-mine-commit-decisions: FAIL"; exit 1; }
