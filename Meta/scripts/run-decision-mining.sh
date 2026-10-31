#!/bin/bash
# run-decision-mining.sh — monthly propose-only decision mining (B2, 2026-07-19).
# Wraps mine-commit-decisions.py --queue: scans git log for decision-shaped commits,
# dedups against Canon/Decisions/ + prior queue items, and queues candidates to
# Meta/review-queue/ for human review. Nothing is auto-created in Canon.
#
# Scheduled DAILY at 09:15 but self-gates to the 1st of the month (the `schedule`
# library has no anchored monthly job). DECISION_MINING_FORCE=1 skips the gate for
# manual runs: DECISION_MINING_FORCE=1 bash run-decision-mining.sh
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-/vault}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "${DECISION_MINING_FORCE:-0}" != "1" ] && [ "$(date +%d)" != "01" ]; then
    echo "(decision mining: not the 1st of the month — no-op)"
    exit 0
fi

cd "$VAULT_DIR" || { echo "FATAL: cannot cd to $VAULT_DIR" >&2; exit 1; }
python3 "$SCRIPT_DIR/mine-commit-decisions.py" --queue
rc=$?

if [ "$rc" -eq 0 ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "⚖️ Monthly decision mining done" \
        "New decision candidates (if any) queued to Meta/review-queue/" default "scales" 2>/dev/null || true
fi
exit "$rc"
