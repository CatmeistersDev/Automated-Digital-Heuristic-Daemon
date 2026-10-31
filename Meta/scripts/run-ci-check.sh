#!/bin/bash
# run-ci-check.sh — weekly in-container sanity gate: syntax/compile/shellcheck of the
# baked code (catches environment drift — a broken dependency, a corrupted image layer)
# plus frontmatter validation of the LIVE vault (catches an agent slowly degrading note
# schema over time) plus the behavioral test suite. Wraps ci-check.sh because
# scheduler.py's run_script() only self-alerts on a TIMEOUT, not a plain non-zero exit —
# every other scheduled job that needs failure alerts (run-backup.sh, run-health.sh) does
# its own notify.sh call, so this follows the same pattern.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

if bash "$SCRIPT_DIR/ci-check.sh" > "$OUT" 2>&1; then
    echo "run-ci-check: PASS"
    cat "$OUT"
    exit 0
fi

echo "run-ci-check: FAIL" >&2
cat "$OUT" >&2
SUMMARY="$(grep -E 'FAIL' "$OUT" | head -20)"
/bin/bash "$SCRIPT_DIR/notify.sh" "🛑 Weekly ci-check FAILED" "${SUMMARY:-see Meta/scheduler.log for detail}" high "rotating_light" 2>/dev/null || true
exit 1
