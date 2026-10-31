#!/bin/bash
# test-review-reject-cli.sh — behavioral test for Meta/scripts/review-reject.sh
# (Phase 2 hardening, 2026-07-18). Asserts the PRIMARY mechanism (running the CLI on
# a proposal file rejects every item it contains and flips its frontmatter status),
# single-item-key rejection, cap-triggered BLOCKED messaging, and the SECONDARY
# Obsidian-native mechanism (`status: rejected` + `## Feedback` -> `--sweep`, which
# is idempotent). No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
REJECT="$SCRIPT_DIR/review-reject.sh"
LIB="$SCRIPT_DIR/review-rejections.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -q -- "$2"; }

mkdir -p "$TV/Meta/review-queue"

# --- PRIMARY: rejecting a multi-item proposal FILE records every item + flips status ---
DEDUP_FILE="$TV/Meta/review-queue/2026-07-18-dedup-proposals.md"
cat > "$DEDUP_FILE" <<'EOF'
---
type: review-item
name: Entity merge proposals 2026-07-18
status: pending
source_agent: Dedup
---

# Proposed entity merges

CANONICAL: Funtime Corp
DUPLICATES: Funtime Corporation
WHY: exact normalized-text match

CANONICAL: Bob Smith
DUPLICATES: Bobby Smith
WHY: alias variant
EOF
OUT1="$(VAULT_DIR="$TV" bash "$REJECT" "$DEDUP_FILE" "not the same entity" 2>&1)"
check "records the first group" contains "$OUT1" "dedup:funtime corp+funtime corporation"
check "records the second group" contains "$OUT1" "dedup:bob smith+bobby smith"
check "file status flipped to rejected" bash -c 'grep -qE "^status: *rejected" "$1"' _ "$DEDUP_FILE"
check "both item keys now count 1" bash -c '
    export VAULT_DIR="$1"
    [ "$(python3 "$2" count --item-key "dedup:funtime corp+funtime corporation" | tr -d "\r")" -eq 1 ] &&
    [ "$(python3 "$2" count --item-key "dedup:bob smith+bobby smith" | tr -d "\r")" -eq 1 ]
' _ "$TV" "$LIB"

# --- direct item-key rejection (no file involved) ---
OUT2="$(VAULT_DIR="$TV" bash "$REJECT" "dedup:funtime corp+funtime corporation" "still no" 2>&1)"
check "item-key rejection recorded (count now 2)" contains "$OUT2" "(2/5 rejections)"

# --- cap-triggered BLOCKED messaging ---
for i in 1 2 3; do
    VAULT_DIR="$TV" bash "$REJECT" "dedup:funtime corp+funtime corporation" "no $i" >/dev/null 2>&1
done
OUT3="$(VAULT_DIR="$TV" bash "$REJECT" "dedup:funtime corp+funtime corporation" "final no" 2>&1)"
check "hits cap (5) and reports BLOCKED" contains "$OUT3" "BLOCKED"

# --- SECONDARY: Obsidian-native status: rejected + ## Feedback -> --sweep ---
STALE_FILE="$TV/Meta/review-queue/2026-07-18-groom-stale-actions.md"
cat > "$STALE_FILE" <<'EOF'
---
type: review-item
name: Stale actions 2026-07-18
status: rejected
source_agent: Groomer
---
# Stale open actions
- [[Get driving license]] — last activity 2026-05-01 (78d ago)

## Feedback
Already renewed, just not marked done.
EOF
SWEEP1="$(VAULT_DIR="$TV" bash "$REJECT" --sweep 2>&1)"
check "sweep records the stale-action rejection" contains "$SWEEP1" "stale-action:get driving license"
check "sweep captured the feedback text" bash -c '
    export VAULT_DIR="$1"
    python3 "$2" recent --item-key "stale-action:get driving license" | grep -q "Already renewed"
' _ "$TV" "$LIB"
check "swept note gets the marker comment" bash -c 'grep -qF "<!-- rejection-recorded -->" "$1"' _ "$STALE_FILE"

SWEEP2="$(VAULT_DIR="$TV" bash "$REJECT" --sweep 2>&1)"
check "sweep is idempotent (second sweep finds nothing new)" contains "$SWEEP2" "no newly-rejected"
check "no double-count from re-sweep" bash -c '
    export VAULT_DIR="$1"
    [ "$(python3 "$2" count --item-key "stale-action:get driving license" | tr -d "\r")" -eq 1 ]
' _ "$TV" "$LIB"

# --- whole-file rejection fallback: a proposal file with no recognized item shape ---
PLAIN_FILE="$TV/Meta/review-queue/2026-07-18-broken-links.md"
cat > "$PLAIN_FILE" <<'EOF'
---
type: review-item
name: Dangling wikilinks 2026-07-18
status: pending
---

# Dangling wikilinks

- some-note.md: dangling [[Somewhere]] (flagged for human)
EOF
OUT4="$(VAULT_DIR="$TV" bash "$REJECT" "$PLAIN_FILE" "not relevant" 2>&1)"
check "falls back to a whole-file item key" contains "$OUT4" "file:$PLAIN_FILE"

[ "$fail" -eq 0 ] && echo "test-review-reject-cli: PASS" || { echo "test-review-reject-cli: FAIL"; exit 1; }
