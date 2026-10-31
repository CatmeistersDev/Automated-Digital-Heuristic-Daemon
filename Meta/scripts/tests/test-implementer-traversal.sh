#!/bin/bash
# test-implementer-traversal.sh — behavioral test for the Implementer's stub-creation
# path-traversal guard (run-implementer.sh). Wikilink targets are model/vault-derived
# (untrusted) input; a stub must never be written outside the vault. Exercises the real
# threat model the guard defends against: Canon/_stubs itself redirected via a symlink
# to a location outside the vault — a naive string-prefix check on the raw path would
# not catch this (the raw path string still looks like it's under "vault/Canon/_stubs"),
# but a realpath+containment check does. Exit 0 = pass. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
IMPL="$SCRIPT_DIR/run-implementer.sh"
TV="$(mktemp -d)"
OUT="$(mktemp -d)"   # deliberately OUTSIDE the fixture vault
RUNLOG="$(mktemp)"
trap 'rm -rf "$TV" "$OUT" "$RUNLOG"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Canon/Notes" "$TV/Canon" "$TV/Meta"
if ! ln -s "$OUT" "$TV/Canon/_stubs" 2>/dev/null; then
    echo "test-implementer-traversal: SKIP (this host cannot create symlinks)"
    exit 0
fi

# Some hosts (e.g. an MSYS `ln -s` symlink under native Windows Python) create a link
# `os.path.realpath()` does not actually follow, which would make the escape scenario
# below silently not apply — probe it the same way run-implementer.sh's guard resolves
# paths, and skip rather than report a false pass/fail if this host can't demonstrate it.
PROBE="$(python3 - "$TV" "$OUT" <<'PY'
import os, sys
vault, out = sys.argv[1], sys.argv[2]
resolved = os.path.realpath(os.path.join(vault, "Canon", "_stubs", "probe.md"))
out_real = os.path.realpath(out)
print("ESCAPES" if resolved.startswith(out_real) else "CONTAINED")
PY
)"
if [ "$PROBE" != "ESCAPES" ]; then
    echo "test-implementer-traversal: SKIP (python realpath() on this host does not follow the Canon/_stubs symlink — cannot exercise the escape scenario here)"
    exit 0
fi

cat > "$TV/Canon/Notes/n.md" <<'EOF'
---
type: concept
name: Traversal Test
source: ai-extracted
---
# 💡 Traversal Test

A dangling but entity-shaped link: [[Traversal Target]]
EOF

VAULT_DIR="$TV" bash "$IMPL" >"$RUNLOG" 2>&1
OUTPUT="$(cat "$RUNLOG")"

check "no stub leaked into the real (outside-vault) target dir" \
    test ! -e "$OUT/Traversal Target.md"
check "nothing written at the symlinked stub path either" \
    test ! -e "$TV/Canon/_stubs/Traversal Target.md"
check "outside dir has no new files at all" \
    [ -z "$(ls -A "$OUT" 2>/dev/null)" ]
check "refusal logged to implementer-log.md" \
    grep -q "SECURITY" "$TV/Meta/AI-Reflections/implementer-log.md" 2>/dev/null
check "logged refusal names the escaping link" \
    grep -q "Traversal Target" "$TV/Meta/AI-Reflections/implementer-log.md" 2>/dev/null
check "console output reports a refusal" \
    printf '%s' "$OUTPUT" | grep -q "refused"
check "original wikilink left unmodified (not silently resolved)" \
    grep -q '\[\[Traversal Target\]\]' "$TV/Canon/Notes/n.md"

[ "$fail" -eq 0 ] && echo "test-implementer-traversal: PASS" || { echo "test-implementer-traversal: FAIL"; exit 1; }
