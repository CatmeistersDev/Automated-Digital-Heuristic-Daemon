#!/bin/bash
# test-dedup-mentions.sh — behavioral test for Meta/scripts/dedup-mentions.py.
# Asserts: an exact-duplicate entry in an action note's frontmatter `mentions:` array is
# collapsed, order + the first occurrence are preserved, and every other line in the file
# (frontmatter and body) is left byte-for-byte unchanged. Also asserts a note with no
# duplicates is left completely untouched (idempotent / no-op). No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
DEDUP="$SCRIPT_DIR/dedup-mentions.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Canon/Actions"

DUP="$TV/Canon/Actions/Dup Action.md"
cat > "$DUP" <<'EOF'
---
type: action
name: Dup Action
status: open
priority: medium
first_mentioned: 2026-03-16
mentions:
  - 2026-03-16 - Voice - arcade.md
  - 2026-03-20 - Voice - followup.md
  - 2026-03-16 - Voice - arcade.md
owner: "[[Louise]]"
---

# 🎯 Dup Action

Owner: [[Louise]]
EOF
cp "$DUP" "$TV/before-dup.md"   # byte-for-byte reference for the untouched-lines check

CLEAN="$TV/Canon/Actions/Clean Action.md"
cat > "$CLEAN" <<'EOF'
---
type: action
name: Clean Action
status: open
first_mentioned: 2026-03-16
mentions:
  - 2026-03-16 - Voice - arcade.md
---

# 🎯 Clean Action
EOF
cp "$CLEAN" "$TV/before-clean.md"

python3 "$DEDUP" "$DUP" "$CLEAN"

check "duplicate mentions entry collapsed (2 lines, not 3)" \
    [ "$(grep -c '^  - ' "$DUP")" -eq 2 ]
check "first-occurrence entry kept" \
    grep -qx '  - 2026-03-16 - Voice - arcade.md' "$DUP"
check "the other distinct entry kept" \
    grep -qx '  - 2026-03-20 - Voice - followup.md' "$DUP"
check "order preserved (arcade before followup)" \
    [ "$(grep -n '^  - ' "$DUP" | head -1 | grep -c arcade)" -eq 1 ]
check "sibling frontmatter field (owner) untouched" \
    grep -qxF 'owner: "[[Louise]]"' "$DUP"
check "body content untouched" \
    grep -qxF 'Owner: [[Louise]]' "$DUP"
# Everything except the removed duplicate line should be identical to the original.
check "no unrelated byte changes vs. original" \
    [ "$(diff "$TV/before-dup.md" "$DUP" | grep -c '^< ')" -eq 1 ]

check "note with no duplicates left byte-for-byte untouched" \
    diff -q "$TV/before-clean.md" "$CLEAN" >/dev/null

# --- note write-state hook (Phase 3 hardening, 2026-07-18): with VAULT_DIR set and a
# vault-relative path (how run-extractor.sh actually invokes this — cwd=VAULT_DIR,
# args from `find Canon Thinking ...`), a note that changed gets its hash recorded in
# Meta/.note-write-state.json; the untouched Clean Action does NOT get a spurious entry. ---
mkdir -p "$TV/vault/Canon/Actions" "$TV/vault/Meta"
cp "$TV/before-dup.md" "$TV/vault/Canon/Actions/Dup Action.md"   # fresh copy WITH the duplicate ($DUP was already deduped above)
( cd "$TV/vault" && VAULT_DIR="$TV/vault" python3 "$DEDUP" "Canon/Actions/Dup Action.md" >/dev/null )
STATE_FILE="$TV/vault/Meta/.note-write-state.json"
check "state file written when VAULT_DIR + vault-relative path are used" test -f "$STATE_FILE"
check "state file records the changed note's hash" bash -c '
    python3 - "$1" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if "Canon/Actions/Dup Action.md" in d else 1)
PY
' _ "$STATE_FILE"
check "state file agent field is Extractor" bash -c '
    python3 - "$1" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("Canon/Actions/Dup Action.md", {}).get("agent") == "Extractor" else 1)
PY
' _ "$STATE_FILE"

[ "$fail" -eq 0 ] && echo "test-dedup-mentions: PASS" || { echo "test-dedup-mentions: FAIL"; exit 1; }
