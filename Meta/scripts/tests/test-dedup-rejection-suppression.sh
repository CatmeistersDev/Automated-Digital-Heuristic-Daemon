#!/bin/bash
# test-dedup-rejection-suppression.sh — behavioral test for run-dedup.sh's rejection-
# feedback integration (Phase 2 hardening, 2026-07-18). Builds a fixture vault with an
# exact-duplicate People pair, runs the Dedup agent (model stubbed) end-to-end,
# rejects the resulting proposal via review-reject.sh, then re-runs Dedup and asserts
# the previously-rejected exact-hash group is suppressed OUTRIGHT (no cap wait) and
# the run cleanly reports "no duplicate entities proposed". No network / no real model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
DEDUP="$SCRIPT_DIR/run-dedup.sh"
REJECT="$SCRIPT_DIR/review-reject.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -q -- "$2"; }

mkdir -p "$TV/Canon/People"
cat > "$TV/Canon/People/Exact One.md" <<'EOF'
---
type: person
name: Exact One
---
# 👤 Exact One

Identical body text for the exact-normalized-hash duplicate check.
EOF
cat > "$TV/Canon/People/Exact Two.md" <<'EOF'
---
type: person
name: Exact Two
---
# 👤 Exact One

Identical body text for the exact-normalized-hash duplicate check.
EOF

RUN1="$(VAULT_DIR="$TV" bash "$DEDUP" 2>&1)"
PROP_FILE="$TV/Meta/review-queue/$(date +%Y-%m-%d)-dedup-proposals.md"
check "run 1: proposal file created" [ -f "$PROP_FILE" ]
check "run 1: proposes the exact-match group" bash -c 'grep -q "CANONICAL: Exact One" "$1"' _ "$PROP_FILE"
check "run 1: header documents how to reject" bash -c 'grep -q "review-reject.sh" "$1"' _ "$PROP_FILE"

REJ_OUT="$(VAULT_DIR="$TV" bash "$REJECT" "$PROP_FILE" "these are two different people, keep both" 2>&1)"
check "rejection recorded" contains "$REJ_OUT" "dedup:exact one+exact two"
rm -f "$PROP_FILE"

RUN2="$(VAULT_DIR="$TV" bash "$DEDUP" 2>&1)"
check "run 2: reports the suppression" contains "$RUN2" "suppressed 1 previously-rejected exact-match group"
check "run 2: no new proposal file written" [ ! -f "$PROP_FILE" ]
check "run 2: exits cleanly with 'no duplicate entities' / 'no Canon entities'" bash -c '
    printf "%s" "$1" | grep -qE "no duplicate entities proposed|No Canon entities to check"
' _ "$RUN2"

[ "$fail" -eq 0 ] && echo "test-dedup-rejection-suppression: PASS" || { echo "test-dedup-rejection-suppression: FAIL"; exit 1; }
