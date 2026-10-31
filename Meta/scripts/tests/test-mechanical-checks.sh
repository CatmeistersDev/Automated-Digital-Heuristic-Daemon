#!/bin/bash
# test-mechanical-checks.sh — behavioral test for Meta/scripts/mechanical-checks.py
# (Phase 1 hardening, 2026-07-18). Asserts: a near-empty Canon note is flagged, an
# intentional stub under Canon/_stubs/ is NOT flagged, a file missing from
# Meta/MANIFEST.md is flagged as drift, a manifest entry with no backing file is
# flagged as drift the other direction, and nothing is flagged for a clean vault.
# Report-only: never writes/deletes anything. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
CHECK="$SCRIPT_DIR/mechanical-checks.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Canon/People" "$TV/Canon/_stubs" "$TV/Thinking" "$TV/Meta"

# Near-empty note (body under the 80-char default threshold)
cat > "$TV/Canon/People/Tiny.md" <<'EOF'
---
type: person
name: Tiny
source: ai-extracted
---
# 👤 Tiny

Hi.
EOF

# Healthy, well-populated note
cat > "$TV/Canon/People/Full.md" <<'EOF'
---
type: person
name: Full
source: ai-extracted
---
# 👤 Full

Full is a long-time collaborator with a substantial history of notes and context
that comfortably clears any reasonable near-empty threshold check.
EOF

# Intentional stub under Canon/_stubs/ — must be EXCLUDED even though tiny
cat > "$TV/Canon/_stubs/Ghost.md" <<'EOF'
---
type: stub
name: Ghost
status: stub
---
# 🌱 Ghost

Stub.
EOF

# Manifest lists Full but NOT Tiny (drift: Tiny exists, manifest doesn't know) and
# references a note "Deleted Person" that no longer has a backing file (drift the
# other direction).
cat > "$TV/Meta/MANIFEST.md" <<'EOF'
---
type: index
---
# Vault Manifest

## Canon

### People (2)
- [[Full]]
- [[Deleted Person]]
EOF

OUT="$(VAULT_DIR="$TV" python3 "$CHECK" 2>&1)"

check "flags near-empty Tiny.md"                    bash -c 'printf "%s" "$1" | grep -q "near-empty stub: Canon/People/Tiny.md"' _ "$OUT"
check "does NOT flag Full.md as near-empty"         bash -c '! printf "%s" "$1" | grep -q "near-empty stub: Canon/People/Full.md"' _ "$OUT"
check "does NOT flag Canon/_stubs/Ghost.md"         bash -c '! printf "%s" "$1" | grep -q "_stubs/Ghost.md"' _ "$OUT"
check "flags Tiny.md missing from manifest"         bash -c 'printf "%s" "$1" | grep -q "manifest drift: Tiny exists but is not listed"' _ "$OUT"
check "flags Deleted Person as manifest ghost"      bash -c 'printf "%s" "$1" | grep -q "manifest drift:.*\[\[Deleted Person\]\].*no such note file"' _ "$OUT"
check "prints a SUMMARY line"                       bash -c 'printf "%s" "$1" | grep -q "^SUMMARY"' _ "$OUT"
check "makes zero writes to the fixture vault"      bash -c '[ -f "$1/Canon/_stubs/Ghost.md" ] && [ -f "$1/Canon/People/Tiny.md" ]' _ "$TV"

# --- near-empty threshold is env-overridable ---
OUT2="$(VAULT_DIR="$TV" NEAR_EMPTY_CHARS=1 python3 "$CHECK" 2>&1)"
check "NEAR_EMPTY_CHARS=1 no longer flags Tiny.md"  bash -c '! printf "%s" "$1" | grep -q "near-empty stub: Canon/People/Tiny.md"' _ "$OUT2"

# --- no Meta/MANIFEST.md at all: drift check skipped cleanly, no crash ---
rm -f "$TV/Meta/MANIFEST.md"
OUT3="$(VAULT_DIR="$TV" python3 "$CHECK" 2>&1)"
check "missing manifest: no drift findings, no crash"  bash -c '! printf "%s" "$1" | grep -q "^WARN.*manifest drift"' _ "$OUT3"
check "missing manifest: near-empty check still runs"  bash -c 'printf "%s" "$1" | grep -q "near-empty stub: Canon/People/Tiny.md"' _ "$OUT3"

[ "$fail" -eq 0 ] && echo "test-mechanical-checks: PASS" || { echo "test-mechanical-checks: FAIL"; exit 1; }
