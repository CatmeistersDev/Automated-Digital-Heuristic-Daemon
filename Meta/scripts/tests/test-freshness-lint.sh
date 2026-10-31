#!/bin/bash
# test-freshness-lint.sh — behavioral test for Meta/scripts/freshness-lint.py
# (Phase 4b). Asserts: an unstamped volatile claim is flagged with the right
# relpath:lineno, a stamped one is not, reflection/event/ai-reflection notes are
# exempt wholesale, lines under a dated "## YYYY-MM-DD" heading or "## Evolution"
# are exempt, code-fenced and "# Raw" lines are exempt, and --limit caps output.
# Report-only: never writes/deletes anything. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
LINT="$SCRIPT_DIR/freshness-lint.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
not_contains() { ! printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Canon/Projects" "$TV/Canon/Organizations" "$TV/Thinking"

# --- unstamped volatile claim on a plain project note: flagged ---
cat > "$TV/Canon/Projects/The Dune Buggy Job.md" <<'EOF'
---
type: project
name: The Dune Buggy Job
source: ai-extracted
---
# 📁 The Dune Buggy Job

The Dune Buggy Job currently has 3 open integrations pending review.
EOF

# --- same claim shape, but WITH a freshness stamp: not flagged ---
cat > "$TV/Canon/Organizations/Funtime.md" <<'EOF'
---
type: organization
name: Funtime
source: ai-extracted
---
# 🏢 Funtime

Funtime currently has 5 employees (as of 2026-06-01).
EOF

# --- reflection type: exempt wholesale, even with an unstamped claim ---
cat > "$TV/Thinking/Feeling.md" <<'EOF'
---
type: reflection
name: Feeling
source: voice
---
# 💭 Feeling

Right now I feel there are 12 things on my plate.
EOF

# --- claim under a dated "## YYYY-MM-DD" heading: exempt ---
cat > "$TV/Canon/Projects/The Wheelie Mammoth Job.md" <<'EOF'
---
type: project
name: The Wheelie Mammoth Job
source: ai-extracted
---
# 📁 The Wheelie Mammoth Job

## 2026-06-15

There are 4 blockers right now on this project.

## Status

The Wheelie Mammoth Job currently has no active blockers.
EOF

# --- claim under "## Evolution": exempt; claim outside it (own heading): flagged ---
cat > "$TV/Canon/Projects/Beacon.md" <<'EOF'
---
type: project
name: Beacon
source: ai-extracted
---
# 📁 Beacon

## Evolution

**2026-06-01** — Beacon currently has 2 milestones remaining · human

## Notes

Beacon currently has 2 milestones remaining.
EOF

# --- code fence + "# Raw" section: exempt ---
cat > "$TV/Canon/Projects/Fenced.md" <<'EOF'
---
type: project
name: Fenced
source: ai-extracted
---
# 📁 Fenced

```
this project currently has 99 open items
```

# Raw

there are 50 raw mentions right now in this transcript
EOF

OUT="$(VAULT_DIR="$TV" python3 "$LINT" 2>&1)"

check "flags unstamped claim with correct relpath:lineno" \
    contains "$OUT" "Canon/Projects/The Dune Buggy Job.md:8: The Dune Buggy Job currently has 3 open integrations pending review."
check "does NOT flag stamped claim"              not_contains "$OUT" "Canon/Organizations/Funtime.md"
check "does NOT flag reflection-type note"        not_contains "$OUT" "Thinking/Feeling.md"
check "does NOT flag claim under dated heading"   not_contains "$OUT" "There are 4 blockers"
check "DOES flag claim outside the dated heading" contains "$OUT" "The Wheelie Mammoth Job currently has no active blockers"
check "does NOT flag claim inside Evolution"      not_contains "$OUT" "**2026-06-01**"
check "DOES flag same claim outside Evolution"    contains "$OUT" "Canon/Projects/Beacon.md"
check "does NOT flag claim inside code fence"     not_contains "$OUT" "99 open items"
check "does NOT flag claim under # Raw"           not_contains "$OUT" "50 raw mentions"
check "makes zero writes to the fixture vault"    bash -c '[ -f "$1/Canon/Projects/The Wheelie Mammoth Job.md" ]' _ "$TV"

# --- --limit caps total findings printed ---
OUT_LIMITED="$(VAULT_DIR="$TV" python3 "$LINT" --limit 1 2>&1)"
N_LINES="$(printf '%s\n' "$OUT_LIMITED" | grep -c '.')"
check "--limit 1 prints exactly one finding" [ "$N_LINES" -eq 1 ]

[ "$fail" -eq 0 ] && echo "test-freshness-lint: PASS" || { echo "test-freshness-lint: FAIL"; exit 1; }
