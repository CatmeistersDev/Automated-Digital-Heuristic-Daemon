#!/bin/bash
# test-manifest-cache.sh — behavioral test for build-manifest.sh's incremental
# content-hash cache (Phase 1 hardening, 2026-07-18). Asserts: a cache sidecar is
# written, a no-change rerun hits the cache and produces byte-identical MANIFEST.md
# output, a content change is detected and reflected, and --force bypasses the cache
# entirely. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
BM="$SCRIPT_DIR/build-manifest.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

TODAY="$(date +%Y-%m-%d)"
mkdir -p "$TV/Canon/People" "$TV/Canon/Actions" "$TV/Thinking" "$TV/Meta"

cat > "$TV/Canon/People/Tina.md" <<EOF
---
type: person
name: Tina
created: $TODAY
source: ai-extracted
---
# 👤 Tina

Tina works on The Wheelie Mammoth Job project.
EOF

cat > "$TV/Canon/Actions/Ship it.md" <<EOF
---
type: action
name: Ship it
status: open
first_mentioned: $TODAY
---
# 🎯 Ship it

Owner: [[Louise]]
EOF

cat > "$TV/Thinking/Idea.md" <<EOF
---
type: concept
name: Idea
created: $TODAY
source: ai-extracted
---
# 💡 Idea

A half-formed thought.
EOF

CACHE="$TV/Meta/.manifest-hash-cache.json"
MANIFEST="$TV/Meta/MANIFEST.md"

# --- run 1: cold cache -> everything re-parsed, cache file written ---
RUN1="$(VAULT_DIR="$TV" bash "$BM" 2>&1)"
check "run 1 writes MANIFEST.md"               test -f "$MANIFEST"
check "run 1 writes hash cache sidecar"        test -f "$CACHE"
check "run 1 reports 1 open action"            contains "$RUN1" "1 open actions"
check "run 1 reports re-parses (cold cache)"   bash -c 'printf "%s" "$1" | grep -qE "hash cache: 0 unchanged.* [1-9][0-9]* re-parsed"' _ "$RUN1"
cp "$MANIFEST" "$TV/manifest-after-run1.md"

# --- run 2: nothing changed -> cache hits, MANIFEST.md byte-identical ---
RUN2="$(VAULT_DIR="$TV" bash "$BM" 2>&1)"
check "run 2 hits the cache (unchanged > 0)"   bash -c 'printf "%s" "$1" | grep -qE "hash cache: [1-9][0-9]* unchanged"' _ "$RUN2"
check "run 2 MANIFEST.md is byte-identical"    diff -q "$TV/manifest-after-run1.md" "$MANIFEST" >/dev/null

# --- run 3: change one note's frontmatter (status) -> cache miss for that note, output reflects it ---
cat > "$TV/Canon/Actions/Ship it.md" <<EOF
---
type: action
name: Ship it
status: done
first_mentioned: $TODAY
---
# 🎯 Ship it

Owner: [[Louise]]
EOF
RUN3="$(VAULT_DIR="$TV" bash "$BM" 2>&1)"
check "run 3 detects the status change (0 open actions)" contains "$RUN3" "0 open actions"
check "run 3 still shows some cache hits (other notes unchanged)" bash -c 'printf "%s" "$1" | grep -qE "hash cache: [1-9][0-9]* unchanged"' _ "$RUN3"
check "run 3 MANIFEST.md content changed"      bash -c '! diff -q "$1" "$2" >/dev/null' _ "$TV/manifest-after-run1.md" "$MANIFEST"

# --- run 4: --force bypasses the cache entirely (0 unchanged) ---
RUN4="$(VAULT_DIR="$TV" bash "$BM" --force 2>&1)"
check "run 4 --force reports forced full scan"  contains "$RUN4" "forced full scan"
check "run 4 --force has zero cache hits"       contains "$RUN4" "hash cache: 0 unchanged"

[ "$fail" -eq 0 ] && echo "test-manifest-cache: PASS" || { echo "test-manifest-cache: FAIL"; exit 1; }
