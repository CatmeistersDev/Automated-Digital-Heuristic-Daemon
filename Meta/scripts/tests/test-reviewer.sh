#!/bin/bash
# test-reviewer.sh — behavioral test for run-reviewer.sh.
# Asserts vault-wide wikilink resolution (subfolder + path-style links are NOT false-flagged) and
# per-note idempotency (unchanged notes are skipped on re-run). Stubs the model layer. Exit 0 = pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
REV="$SCRIPT_DIR/run-reviewer.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Meta/scripts" "$TV/Canon/People" "$TV/Inbox"
# stub the model layer so the reviewer's one judgment call returns 'none' instantly
printf '#!/bin/bash\necho none\n' > "$TV/Meta/scripts/invoke-agent.sh"
chmod +x "$TV/Meta/scripts/invoke-agent.sh"
printf -- '---\ntype: person\nname: Teddy\nsource_agent: Extractor\nsource_date: 2026-06-01\n---\n\n# 👤 Teddy\n' > "$TV/Canon/People/Teddy.md"
cat > "$TV/Inbox/test-note.md" <<'EOF'
---
status: extracted
source: voice
---
# Raw
Met Teddy.

## Extracted
- [[Teddy]]
- [[Canon/People/Teddy.md]]
- [[Zzznobody]]
EOF

VAULT_DIR="$TV" bash "$REV" >/dev/null 2>&1     # run 1 (writes review-log + seen-hash)
LOG="$TV/Meta/AI-Reflections/review-log.md"
no_false()   { ! grep -q 'broken wikilink \[\[Teddy\]\]' "$LOG"; }
flags_miss() { grep -q 'broken wikilink \[\[Zzznobody\]\]' "$LOG"; }
check "resolves [[Teddy]] (subfolder) — no false broken"      no_false
check "resolves path-style [[Canon/People/Teddy.md]]"         no_false
check "flags the genuine missing [[Zzznobody]]"               flags_miss

RUN2="$(VAULT_DIR="$TV" bash "$REV" 2>&1)"       # run 2 (unchanged -> should skip)
idem() { printf '%s' "$RUN2" | grep -q 'Unchanged since last review'; }
check "idempotent: 2nd run skips unchanged note"              idem

[ "$fail" -eq 0 ] && echo "test-reviewer: PASS" || { echo "test-reviewer: FAIL"; exit 1; }
