#!/bin/bash
# test-graduate.sh — behavioral test for Meta/scripts/graduate.sh (Phase 4b).
# Asserts: promoting a Thinking/ note to project|decision|belief creates the new
# note in the right folder with correct frontmatter/emoji/graduated_from lineage
# and copied body; the origin gets status: graduated + an appended graduation
# line while its ORIGINAL content is fully preserved (append-only, never
# rewritten); and the script refuses when the target already exists. No network
# / no model (deterministic shell + python only).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
GRADUATE="$SCRIPT_DIR/graduate.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Thinking" "$TV/Canon/Projects" "$TV/Canon/Decisions"

cat > "$TV/Thinking/Rework the pricing model.md" <<'EOF'
---
type: emerging
name: Rework the pricing model
created: 2026-06-01
source: ai-extracted
linked:
  - "[[Louise]]"
---

# 🌱 Rework the pricing model

Half-formed idea: maybe move to usage-based pricing instead of flat tiers.
Needs more thought before committing.
EOF

# --- promote to project ---
OUT1="$(VAULT_DIR="$TV" bash "$GRADUATE" "Thinking/Rework the pricing model.md" project 2>&1)"
TARGET="$TV/Canon/Projects/Rework the pricing model.md"
check "reports the created path"           contains "$OUT1" "Canon/Projects/Rework the pricing model.md"
check "target note created"                [ -f "$TARGET" ]
check "target has type: project"           bash -c 'grep -q "^type: project" "$1"' _ "$TARGET"
check "target has correct emoji H1"        bash -c 'grep -qF "# 📁 Rework the pricing model" "$1"' _ "$TARGET"
check "target has graduated_from lineage"  bash -c 'grep -qF "graduated_from: \"[[Rework the pricing model]]\"" "$1"' _ "$TARGET"
check "target has source: human"           bash -c 'grep -q "^source: human" "$1"' _ "$TARGET"
check "target body carries origin content" bash -c 'grep -qF "usage-based pricing" "$1"' _ "$TARGET"
check "target body has no duplicate H1"    bash -c '[ "$(grep -c "^# " "$1")" -eq 1 ]' _ "$TARGET"
check "target has provenance comment"      bash -c 'grep -qF "graduated from [[Rework the pricing model]]" "$1"' _ "$TARGET"

ORIGIN="$TV/Thinking/Rework the pricing model.md"
check "origin flipped to status: graduated" bash -c 'grep -q "^status: graduated" "$1"' _ "$ORIGIN"
check "origin got the Graduated-to line"    bash -c 'grep -qF "Graduated to [[Rework the pricing model]] on" "$1"' _ "$ORIGIN"
check "origin ORIGINAL content preserved"   bash -c 'grep -qF "Half-formed idea" "$1"' _ "$ORIGIN"
check "origin frontmatter type untouched"   bash -c 'grep -q "^type: emerging" "$1"' _ "$ORIGIN"
check "origin linked: array preserved"      bash -c 'grep -qF "[[Louise]]" "$1"' _ "$ORIGIN"

# --- refuses when target already exists ---
set +e
OUT2="$(VAULT_DIR="$TV" bash "$GRADUATE" "Thinking/Rework the pricing model.md" project 2>&1)"
RC2=$?
set -e
check "refuses when target already exists" [ "$RC2" -ne 0 ]
check "refusal message names the target"   contains "$OUT2" "already exists"

# --- promote to belief: stays in Thinking/, not Canon/. Uses an origin whose
# filename differs from its frontmatter name so the new belief note (named after
# the frontmatter name) doesn't collide with the origin file, also in Thinking/. ---
cat > "$TV/Thinking/emerging-idea-perfection.md" <<'EOF'
---
type: emerging
name: Speed beats perfection
created: 2026-06-02
source: human
---

# 🌱 Speed beats perfection

Recurring theme in my notes: shipping fast matters more than polishing.
EOF
OUT3="$(VAULT_DIR="$TV" bash "$GRADUATE" "Thinking/emerging-idea-perfection.md" belief 2>&1)"
BTARGET="$TV/Thinking/Speed beats perfection.md"
check "belief target created in Thinking/, not Canon/" [ -f "$BTARGET" ]
check "belief target reported"             contains "$OUT3" "Thinking/Speed beats perfection.md"
check "belief target has type: belief"     bash -c 'grep -q "^type: belief" "$1"' _ "$BTARGET"
check "belief target has correct emoji"    bash -c 'grep -qF "# 🪨 Speed beats perfection" "$1"' _ "$BTARGET"
check "belief origin (different filename) preserved, not deleted" \
    [ -f "$TV/Thinking/emerging-idea-perfection.md" ]
check "belief origin flipped to graduated" bash -c 'grep -q "^status: graduated" "$1"' _ "$TV/Thinking/emerging-idea-perfection.md"

# --- refuses a colliding same-name-in-Thinking belief promotion (target == origin) ---
cat > "$TV/Thinking/Already Named Belief.md" <<'EOF'
---
type: emerging
name: Already Named Belief
created: 2026-06-02
source: human
---
# 🌱 Already Named Belief
Would collide with itself if promoted to belief without renaming.
EOF
set +e
OUT3B="$(VAULT_DIR="$TV" bash "$GRADUATE" "Thinking/Already Named Belief.md" belief 2>&1)"
RC3B=$?
set -e
check "refuses same-name belief collision (target == origin)" [ "$RC3B" -ne 0 ]

# --- promote to decision with a differently-named origin (avoid same-name collision) ---
cat > "$TV/Thinking/On switching ticket systems.md" <<'EOF'
---
type: reflection
name: Switch to Wonder Wharf
created: 2026-06-03
source: voice
---

# 💭 On switching ticket systems

Thinking it through out loud: Wonder Wharf looks like the right call for tickets.
EOF
OUT4="$(VAULT_DIR="$TV" bash "$GRADUATE" "Thinking/On switching ticket systems.md" decision 2>&1)"
DTARGET="$TV/Canon/Decisions/Switch to Wonder Wharf.md"
check "decision target created in Canon/Decisions/" [ -f "$DTARGET" ]
check "decision target has correct emoji"           bash -c 'grep -qF "# ⚖️ Switch to Wonder Wharf" "$1"' _ "$DTARGET"
check "decision origin note untouched (not deleted)" [ -f "$TV/Thinking/On switching ticket systems.md" ]

[ "$fail" -eq 0 ] && echo "test-graduate: PASS" || { echo "test-graduate: FAIL"; exit 1; }
