#!/bin/bash
# test-review-queue-list.sh — behavioral test for Meta/scripts/review-queue-list.sh
# (Phase 2 hardening, 2026-07-18). Asserts: an empty queue is reported cleanly, a
# heavily-rejected item's file sorts before a never-rejected one (rejection count
# descending), and a file whose item hit the cap is tagged [BLOCKED]. Read-only —
# asserts nothing is written. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
LISTSH="$SCRIPT_DIR/review-queue-list.sh"
LIB="$SCRIPT_DIR/review-rejections.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

# --- empty queue ---
mkdir -p "$TV/Meta/review-queue"
EMPTY_OUT="$(VAULT_DIR="$TV" bash "$LISTSH" 2>&1)"
check "empty queue reported cleanly" [ "$EMPTY_OUT" = "Review queue is empty." ]
check "empty queue: read-only (dir untouched)" [ -d "$TV/Meta/review-queue" ]

# --- two proposals, one heavily rejected, one untouched ---
cat > "$TV/Meta/review-queue/2026-07-10-dedup-proposals.md" <<'EOF'
---
type: review-item
source_agent: Dedup
---
CANONICAL: Old Corp
DUPLICATES: Old Corporation
WHY: exact normalized-text match
EOF
cat > "$TV/Meta/review-queue/2026-07-18-groom-stale-actions.md" <<'EOF'
---
type: review-item
source_agent: Groomer
---
- [[Untouched Action]] — last activity 2026-06-01 (47d ago)
EOF

export VAULT_DIR="$TV"
for i in 1 2 3; do
    python3 "$LIB" record --item-key "dedup:old corp+old corporation" --agent Dedup --proposal-file x --feedback "no $i" >/dev/null
done
unset VAULT_DIR

OUT="$(VAULT_DIR="$TV" bash "$LISTSH" 2>&1)"
check "rejected file listed with its count" bash -c 'printf "%s" "$1" | grep -q "\[3 rejection(s)\].*dedup-proposals"' _ "$OUT"
check "untouched file listed with no count prefix" bash -c 'printf "%s" "$1" | grep -qE "^Meta/review-queue/.*stale-actions.md$"' _ "$OUT"
check "rejected file sorts before the untouched one" bash -c '
    printf "%s\n" "$1" > "$2/order.txt"
    d=$(grep -n "dedup-proposals" "$2/order.txt" | cut -d: -f1)
    s=$(grep -n "stale-actions" "$2/order.txt" | cut -d: -f1)
    [ "$d" -lt "$s" ]
' _ "$OUT" "$TV"
check "not yet [BLOCKED] at count 3 (cap 5)" bash -c '! printf "%s" "$1" | grep -q "BLOCKED"' _ "$OUT"

# --- push past the cap -> [BLOCKED] tag appears ---
export VAULT_DIR="$TV"
for i in 4 5; do
    python3 "$LIB" record --item-key "dedup:old corp+old corporation" --agent Dedup --proposal-file x --feedback "no $i" >/dev/null
done
unset VAULT_DIR
OUT2="$(VAULT_DIR="$TV" bash "$LISTSH" 2>&1)"
check "[BLOCKED] tag appears once cap is hit" bash -c 'printf "%s" "$1" | grep -q "\[BLOCKED\]"' _ "$OUT2"

[ "$fail" -eq 0 ] && echo "test-review-queue-list: PASS" || { echo "test-review-queue-list: FAIL"; exit 1; }
