#!/bin/bash
# test-reviewer-severity.sh — behavioral test for run-reviewer.sh's severity tiers
# (Phase 2 hardening, 2026-07-18). Asserts every finding line in review-log.md gets
# a [BLOCKER]/[HIGH]/[MEDIUM]/[LOW] tag: deterministic mechanical checks are tagged
# by known severity (a broken wikilink is [HIGH]), and a model verdict line the
# model left untagged is defaulted to [MEDIUM] by the deterministic post-pass, while
# a line the model DID self-tag is passed through unchanged. Runs the real
# run-reviewer.sh (copied into the fixture so SCRIPT_DIR resolves inside it) with a
# stubbed model layer. No network / no real model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
REV="$SCRIPT_DIR/run-reviewer.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Meta/scripts" "$TV/Canon/People" "$TV/Inbox"
# Copy the real script into the fixture so its self-located SCRIPT_DIR (dirname $0)
# resolves to the fixture's Meta/scripts — the only way to make it pick up a stubbed
# invoke-agent.sh instead of the real one (SCRIPT_DIR is derived from $0, not VAULT_DIR).
cp "$REV" "$TV/Meta/scripts/run-reviewer.sh"
printf '#!/bin/bash\necho "Jimmy Pesto - a coworker mentioned once in passing"\n' > "$TV/Meta/scripts/invoke-agent.sh"
chmod +x "$TV/Meta/scripts/invoke-agent.sh" "$TV/Meta/scripts/run-reviewer.sh"

printf -- '---\ntype: person\nname: Teddy\nsource_agent: Extractor\nsource_date: 2026-06-01\n---\n\n# 👤 Teddy\n' > "$TV/Canon/People/Teddy.md"
cat > "$TV/Inbox/test-note.md" <<'EOF'
---
status: extracted
source: voice
---
# Raw
Met Teddy and Jimmy Pesto.

## Extracted
- [[Teddy]]
- [[Zzznobody]]
EOF

VAULT_DIR="$TV" bash "$TV/Meta/scripts/run-reviewer.sh" >/dev/null 2>&1
LOG="$TV/Meta/AI-Reflections/review-log.md"
check "review-log was written" [ -f "$LOG" ]
check "broken wikilink mechanical finding is tagged [HIGH]" \
    bash -c 'grep -q "\[HIGH\] broken wikilink \[\[Zzznobody\]\]" "$1"' _ "$LOG"
check "model verdict line the model left untagged defaults to [MEDIUM]" \
    bash -c 'grep -q "\[MEDIUM\] Jimmy Pesto" "$1"' _ "$LOG"
check "every mechanical bullet line carries a severity tag" \
    bash -c '! grep -E "^- " "$1" | grep -vE "^- \[(BLOCKER|HIGH|MEDIUM|LOW)\]"' _ "$LOG"

# --- a model line that DOES self-tag is passed through, not double-tagged ---
rm -rf "$TV/Meta/AI-Reflections"
printf '#!/bin/bash\necho "[HIGH] Bob Smith - central to the whole conversation"\n' > "$TV/Meta/scripts/invoke-agent.sh"
# Second note so idempotency (unchanged-content skip) doesn't suppress this run.
cat > "$TV/Inbox/test-note-2.md" <<'EOF'
---
status: extracted
source: voice
---
# Raw
Met Teddy and Bob Smith.

## Extracted
- [[Teddy]]
EOF
VAULT_DIR="$TV" bash "$TV/Meta/scripts/run-reviewer.sh" >/dev/null 2>&1
check "model self-tagged [HIGH] line passes through unchanged" \
    bash -c 'grep -q "^\[HIGH\] Bob Smith" "$1"' _ "$LOG"
check "self-tagged line is not double-tagged" \
    bash -c '! grep -q "\[MEDIUM\] \[HIGH\]" "$1"' _ "$LOG"

[ "$fail" -eq 0 ] && echo "test-reviewer-severity: PASS" || { echo "test-reviewer-severity: FAIL"; exit 1; }
