#!/bin/bash
# test-groomer-rejection-block.sh — behavioral test for run-groomer.sh's Part B
# (stale open actions) rejection-feedback integration (Phase 2 hardening,
# 2026-07-18). Builds a fixture vault with one very-stale open action, runs the
# Groomer twice: first run surfaces it to review-queue; after REVIEW_REJECTION_CAP
# rejections are recorded for its item key, the second run must suppress it (not
# list it again) and report the suppression count. No network / no model (Part A
# ephemera-digest never triggers since the fixture has no old briefings/retros).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
GROOM="$SCRIPT_DIR/run-groomer.sh"
LIB="$SCRIPT_DIR/review-rejections.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -q -- "$2"; }

mkdir -p "$TV/Canon/Actions"
cat > "$TV/Canon/Actions/Get driving license.md" <<'EOF'
---
type: action
name: Get driving license
status: open
first_mentioned: 2026-01-01
---
# 🎯 Get driving license
EOF

OUT_FILE="$TV/Meta/review-queue/$(date +%Y-%m-%d)-groom-stale-actions.md"

RUN1="$(VAULT_DIR="$TV" GROOM_STALE_DAYS=1 bash "$GROOM" 2>&1)"
check "run 1: surfaces the stale action" [ -f "$OUT_FILE" ]
check "run 1: lists the action" bash -c 'grep -q "Get driving license" "$1"' _ "$OUT_FILE"
check "run 1: header documents how to reject" bash -c 'grep -q "review-reject.sh" "$1"' _ "$OUT_FILE"

export VAULT_DIR="$TV"
for i in 1 2 3 4 5; do
    python3 "$LIB" record --item-key "stale-action:get driving license" --agent Groomer --proposal-file x --feedback "leave it, I know ($i)" >/dev/null
done
unset VAULT_DIR
rm -f "$OUT_FILE"

RUN2="$(VAULT_DIR="$TV" GROOM_STALE_DAYS=1 bash "$GROOM" 2>&1)"
check "run 2: no proposal file (fully suppressed)" [ ! -f "$OUT_FILE" ]
check "run 2: reports the suppression" contains "$RUN2" "suppressed"
check "run 2: reports no stale open actions" contains "$RUN2" "no stale open actions"

[ "$fail" -eq 0 ] && echo "test-groomer-rejection-block: PASS" || { echo "test-groomer-rejection-block: FAIL"; exit 1; }
