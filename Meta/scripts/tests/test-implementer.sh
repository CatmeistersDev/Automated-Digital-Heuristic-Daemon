#!/bin/bash
# test-implementer.sh — behavioral test for run-implementer.sh.
# Builds a throwaway fixture vault, runs the Implementer, asserts link normalization,
# guarded stub creation, and no-stub honoring. Exit 0 = pass, 1 = fail. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
IMPL="$SCRIPT_DIR/run-implementer.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Canon/People" "$TV/Canon/Notes" "$TV/Meta"
printf -- '---\ntype: person\nname: Hugo\n---\n\n# 👤 Hugo\n' > "$TV/Canon/People/Hugo.md"
printf 'Mort\n' > "$TV/Meta/implementer-no-stub.txt"
cat > "$TV/Canon/Notes/n.md" <<'EOF'
---
type: concept
name: Link Test
source: ai-extracted
---
# 💡 Link Test

[[Canon/People/Hugo.md]] [[hugo]] [[Canon/People/Hugo.md|Hug]] [[Hugo]]
[[Calvin Fischoeder]] [[Mort]] [[Me]] [[Quinn 2.5]]
EOF

VAULT_DIR="$TV" bash "$IMPL" >/dev/null 2>&1

NF="$TV/Canon/Notes/n.md"
grepq()  { grep -q "$1" "$NF"; }
ngrepq() { ! grep -q "$1" "$NF"; }

check "path-style link normalized to [[Hugo]]"        ngrepq 'Canon/People/Hugo.md]]'
check "wrong-case [[hugo]] normalized"                ngrepq '\[\[hugo\]\]'
check "alias preserved as [[Hugo|Hug]]"               grepq  '\[\[Hugo|Hug\]\]'
check "entity dangle stubbed"                         test -f "$TV/Canon/_stubs/Calvin Fischoeder.md"
check "no-stub name Mort NOT stubbed"                 test ! -f "$TV/Canon/_stubs/Mort.md"
check "stoplist [[Me]] NOT stubbed"                   test ! -f "$TV/Canon/_stubs/Me.md"
check "version-junk [[Quinn 2.5]] NOT stubbed"        test ! -f "$TV/Canon/_stubs/Quinn 2.5.md"

[ "$fail" -eq 0 ] && echo "test-implementer: PASS" || { echo "test-implementer: FAIL"; exit 1; }
