#!/bin/bash
# test-lineage.sh — behavioral test for Meta/scripts/lineage.py (Phase 4b).
# Asserts: --up (default) walks the ancestor chain via derived_from:, --down
# reverse-walks derivatives, a cycle in derived_from: doesn't infinite-loop, bare
# name / path-with-.md resolution both work, and a note with no derived_from
# reports cleanly instead of erroring. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
LINEAGE="$SCRIPT_DIR/lineage.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Canon/Actions" "$TV/Thinking/Research"

# Chain: C (research) derived_from B (research) derived_from A (action, no lineage)
cat > "$TV/Canon/Actions/Book dentist appointment.md" <<'EOF'
---
type: action
name: Book dentist appointment
status: open
source: voice
first_mentioned: 2026-06-01
---
# 🎯 Book dentist appointment
Reminder.
EOF

cat > "$TV/Thinking/Research/first-pass.md" <<'EOF'
---
type: research
name: first-pass
source: ai-generated
derived_from:
  - "[[Book dentist appointment]]"
---
# 🔬 first-pass
Initial research.
EOF

cat > "$TV/Thinking/Research/deeper-dive.md" <<'EOF'
---
type: research
name: deeper-dive
source: ai-generated
derived_from:
  - "[[first-pass]]"
---
# 🔬 deeper-dive
Follow-up research.
EOF

# --- walk UP from the deepest note: full ancestor chain ---
OUT_UP="$(VAULT_DIR="$TV" python3 "$LINEAGE" "Thinking/Research/deeper-dive.md" 2>&1)"
check "up-chain includes deeper-dive itself"  contains "$OUT_UP" "Thinking/Research/deeper-dive.md"
check "up-chain includes first-pass"          contains "$OUT_UP" "Thinking/Research/first-pass.md"
check "up-chain includes the root action"     contains "$OUT_UP" "Canon/Actions/Book dentist appointment.md"
check "up-chain order: deeper-dive before first-pass" bash -c '
    a=$(printf "%s\n" "$1" | grep -n "deeper-dive" | head -1 | cut -d: -f1)
    b=$(printf "%s\n" "$1" | grep -n "first-pass" | head -1 | cut -d: -f1)
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
' _ "$OUT_UP"

# --- resolve by bare name too ---
OUT_UP_BARE="$(VAULT_DIR="$TV" python3 "$LINEAGE" "deeper-dive" 2>&1)"
check "bare-name resolution works"            contains "$OUT_UP_BARE" "Canon/Actions/Book dentist appointment.md"

# --- root action has no derived_from: reports cleanly, not an error ---
OUT_ROOT="$(VAULT_DIR="$TV" python3 "$LINEAGE" "Book dentist appointment" 2>&1)"
check "no-lineage note reports cleanly"       contains "$OUT_ROOT" "no derived_from lineage"

# --- walk DOWN from the root action: finds both derivatives, transitively ---
OUT_DOWN="$(VAULT_DIR="$TV" python3 "$LINEAGE" "Book dentist appointment" --down 2>&1)"
check "down-walk finds direct derivative first-pass"      contains "$OUT_DOWN" "Thinking/Research/first-pass.md"
check "down-walk finds transitive derivative deeper-dive" contains "$OUT_DOWN" "Thinking/Research/deeper-dive.md"

OUT_DOWN_LEAF="$(VAULT_DIR="$TV" python3 "$LINEAGE" "deeper-dive" --down 2>&1)"
check "leaf note has no derivatives"          contains "$OUT_DOWN_LEAF" "no derivatives found"

# --- cycle safety: A derived_from B, B derived_from A must not infinite-loop ---
mkdir -p "$TV/Thinking/Cycle"
cat > "$TV/Thinking/Cycle/Loop A.md" <<'EOF'
---
type: emerging
name: Loop A
source: human
derived_from:
  - "[[Loop B]]"
---
# 🌱 Loop A
EOF
cat > "$TV/Thinking/Cycle/Loop B.md" <<'EOF'
---
type: emerging
name: Loop B
source: human
derived_from:
  - "[[Loop A]]"
---
# 🌱 Loop B
EOF
OUT_CYCLE="$(VAULT_DIR="$TV" timeout 10 python3 "$LINEAGE" "Loop A" 2>&1)"
RC_CYCLE=$?
check "cycle terminates (no timeout/hang)"    [ "$RC_CYCLE" -ne 124 ]
check "cycle chain includes both notes once"  bash -c '
    [ "$(printf "%s\n" "$1" | grep -c "Loop A.md")" -eq 1 ] &&
    [ "$(printf "%s\n" "$1" | grep -c "Loop B.md")" -eq 1 ]
' _ "$OUT_CYCLE"

# --- missing note: clean error, nonzero exit ---
set +e
OUT_MISSING="$(VAULT_DIR="$TV" python3 "$LINEAGE" "Nope Nonexistent" 2>&1)"
RC_MISSING=$?
set -e
check "missing note exits nonzero"            [ "$RC_MISSING" -ne 0 ]
check "missing note reports Note not found"   contains "$OUT_MISSING" "Note not found"

[ "$fail" -eq 0 ] && echo "test-lineage: PASS" || { echo "test-lineage: FAIL"; exit 1; }
