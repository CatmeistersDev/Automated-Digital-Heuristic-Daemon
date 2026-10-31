#!/bin/bash
# test-thinker-conflict-stubs.sh — behavioral test for
# Meta/scripts/thinker-conflict-stubs.py (Phase 4b). Asserts: a CONFLICT line
# becomes a propose-only review-queue stub (correct frontmatter, emoji H1,
# involved-notes wikilinks pulled out), non-CONFLICT narrative text is ignored,
# a second CONFLICT line with the SAME topic slug is deduped against an
# already-queued stub (any date), and no narrative -> zero files created. No
# network / no model — this is the deterministic post-pass factored OUT of
# run-thinker.sh specifically so it's testable without a live Ollama call.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
STUBS="$SCRIPT_DIR/thinker-conflict-stubs.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Meta/review-queue"

# --- ordinary narrative with ONE CONFLICT line ---
NARR1="$TV/narr1.txt"
cat > "$NARR1" <<'EOF'
You've mentioned wanting to slow down twice this month, which is a real pattern.
CONFLICT: The Wheelie Mammoth Job timeline — [[The Wheelie Mammoth Job]] says Q3 launch but [[The Wheelie Mammoth Job]] note says Q4 for the same milestone.
One concrete suggestion: revisit The Wheelie Mammoth Job plan this week.
EOF

OUT1="$(python3 "$STUBS" --vault "$TV" --narrative-file "$NARR1" --agent Thinker --date 2026-07-18 2>&1)"
check "prints the created stub relpath" contains "$OUT1" "Meta/review-queue/2026-07-18-conflict-the-wheelie-mammoth-job-timeline.md"

STUB="$TV/Meta/review-queue/2026-07-18-conflict-the-wheelie-mammoth-job-timeline.md"
check "stub file exists"                    [ -f "$STUB" ]
check "stub has type: review-item"          bash -c 'grep -q "^type: review-item" "$1"' _ "$STUB"
check "stub has status: open"               bash -c 'grep -q "^status: open" "$1"' _ "$STUB"
check "stub has source_agent: Thinker"      bash -c 'grep -q "^source_agent: Thinker" "$1"' _ "$STUB"
check "stub H1 has the conflict emoji"      bash -c 'grep -q "^# ⚖️ Conflict: The Wheelie Mammoth Job timeline" "$1"' _ "$STUB"
check "stub body includes the full description" bash -c 'grep -qF "Q3 launch but" "$1"' _ "$STUB"
check "stub lists involved notes"           bash -c 'grep -qF "[[The Wheelie Mammoth Job]]" "$1"' _ "$STUB"
check "stub lists both involved notes"      bash -c 'grep -qF "[[The Wheelie Mammoth Job]]" "$1"' _ "$STUB"
check "non-CONFLICT narrative text NOT queued as its own stub" bash -c '
    [ "$(find "$1/Meta/review-queue" -name "*.md" | wc -l | tr -d " ")" -eq 1 ]
' _ "$TV"

# --- a SECOND run with a CONFLICT line of the SAME topic (different date) is
# deduped by slug against the already-queued stub, regardless of date ---
NARR2="$TV/narr2.txt"
cat > "$NARR2" <<'EOF'
CONFLICT: The Wheelie Mammoth Job timeline — restating the same tension again this week.
EOF
OUT2="$(python3 "$STUBS" --vault "$TV" --narrative-file "$NARR2" --agent Thinker --date 2026-07-25 2>&1)"
check "dedup: second run prints nothing (no new stub)" [ -z "$(printf '%s' "$OUT2" | tr -d '[:space:]')" ]
check "dedup: still exactly one conflict stub total" bash -c '
    [ "$(find "$1/Meta/review-queue" -name "*.md" | wc -l | tr -d " ")" -eq 1 ]
' _ "$TV"

# --- a DIFFERENT topic creates a distinct stub ---
NARR3="$TV/narr3.txt"
cat > "$NARR3" <<'EOF'
CONFLICT: Budget mismatch — [[Q3 Budget]] and [[Q3 Forecast]] disagree on headcount.
EOF
OUT3="$(python3 "$STUBS" --vault "$TV" --narrative-file "$NARR3" --agent Mirror --date 2026-07-25 2>&1)"
check "different topic gets its own stub" contains "$OUT3" "conflict-budget-mismatch.md"
check "different-topic stub uses the passed agent name" bash -c '
    grep -q "^source_agent: Mirror" "$1/Meta/review-queue/2026-07-25-conflict-budget-mismatch.md"
' _ "$TV"

# --- no CONFLICT lines at all -> zero files created, zero output ---
TV2="$(mktemp -d)"
NARR4="$TV2/narr4.txt"
cat > "$NARR4" <<'EOF'
Just an ordinary reflection with no contradictions this week.
EOF
OUT4="$(python3 "$STUBS" --vault "$TV2" --narrative-file "$NARR4" --agent Thinker --date 2026-07-18 2>&1)"
check "no CONFLICT lines: no output" [ -z "$(printf '%s' "$OUT4" | tr -d '[:space:]')" ]
check "no CONFLICT lines: no review-queue dir created" [ ! -d "$TV2/Meta/review-queue" ]
rm -rf "$TV2"

# --- stdin mode (no --narrative-file) works too ---
TV3="$(mktemp -d)"
OUT5="$(printf 'CONFLICT: Stdin path — this one came via stdin.\n' | python3 "$STUBS" --vault "$TV3" --agent Thinker --date 2026-07-18 2>&1)"
check "stdin mode creates a stub too" contains "$OUT5" "conflict-stdin-path.md"
rm -rf "$TV3"

[ "$fail" -eq 0 ] && echo "test-thinker-conflict-stubs: PASS" || { echo "test-thinker-conflict-stubs: FAIL"; exit 1; }
