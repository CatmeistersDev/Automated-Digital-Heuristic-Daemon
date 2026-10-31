#!/bin/bash
# test-implementer-severity.sh — behavioral test for the B1 review-log severity wiring
# in run-implementer.sh. Asserts: [BLOCKER]/[HIGH] findings are escalated to a
# review-queue file, [MEDIUM]/[LOW] are not, the byte-offset cursor makes a rerun
# idempotent (no duplicate escalations), and new findings appended after the first
# run ARE picked up. Exit 0 = pass, 1 = fail. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
IMPL="$SCRIPT_DIR/run-implementer.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Canon" "$TV/Meta/AI-Reflections"
TODAY="$(date +%Y-%m-%d)"
ESC="$TV/Meta/review-queue/$TODAY-review-escalations.md"

cat > "$TV/Meta/AI-Reflections/review-log.md" <<'EOF'
## Review: 20260719-090000 — 2026-07-19 - Voice - fixture.md
### Mechanical checks
- [BLOCKER] missing ## Extracted section in fixture.md
- [HIGH] broken wikilink [[Nowhere]] in fixture.md
- [MEDIUM] missing source_agent in fixture.md
- [LOW] missing type emoji in fixture.md
### Missed entities (model judgment)
[MEDIUM] Louise
EOF

VAULT_DIR="$TV" bash "$IMPL" >"$TV/run1.log" 2>&1

check "escalation file created"                    test -f "$ESC"
check "BLOCKER finding escalated"                  grep -q "missing ## Extracted section" "$ESC"
check "HIGH finding escalated"                     grep -q "broken wikilink" "$ESC"
check "MEDIUM finding NOT escalated"               bash -c '! grep -q "missing source_agent" "'"$ESC"'"'
check "LOW finding NOT escalated"                  bash -c '! grep -q "missing type emoji" "'"$ESC"'"'
check "review header carried into escalation"      grep -q "20260719-090000" "$ESC"
check "escalation file is a pending review-item"   grep -q "^status: pending" "$ESC"
check "cursor file written"                        test -s "$TV/Meta/.implementer-review-cursor"

# --- Rerun without new findings: cursor must prevent duplicates -------------------
N_BEFORE="$(grep -c "missing ## Extracted section" "$ESC")"
VAULT_DIR="$TV" bash "$IMPL" >"$TV/run2.log" 2>&1
N_AFTER="$(grep -c "missing ## Extracted section" "$ESC")"
check "rerun adds no duplicate escalations" test "$N_BEFORE" = "$N_AFTER"

# --- Append a NEW finding: must be picked up from the cursor ----------------------
cat >> "$TV/Meta/AI-Reflections/review-log.md" <<'EOF'

## Review: 20260719-100000 — 2026-07-19 - Voice - fixture2.md
### Mechanical checks
- [HIGH] status is not 'extracted' in fixture2.md
EOF
VAULT_DIR="$TV" bash "$IMPL" >"$TV/run3.log" 2>&1
check "new post-cursor HIGH finding escalated" grep -q "status is not 'extracted'" "$ESC"
check "old finding still not duplicated" test "$(grep -c 'missing ## Extracted section' "$ESC")" = "$N_BEFORE"

[ "$fail" -eq 0 ] && echo "test-implementer-severity: PASS" || { echo "test-implementer-severity: FAIL"; exit 1; }
