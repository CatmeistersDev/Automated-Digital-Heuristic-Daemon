#!/bin/bash
# review-unblock.sh — clear a rejection-count block on a Meta/review-queue/ item key
# (Phase 2 hardening, 2026-07-18). Usage:
#   Meta/scripts/review-unblock.sh <item-key> ["note"]
# Item keys look like "dedup:funtime corp+funtime corporation" or "stale-action:get
# driving license" — see review-queue-list.sh for the currently-blocked ones.
#
# Does NOT erase rejection history (Meta/.review-rejections.jsonl keeps every past
# rejection forever) — it just resets the counting window: rejections BEFORE this
# unblock stop counting toward REVIEW_REJECTION_CAP, so the item can be proposed
# again. If it's rejected REVIEW_REJECTION_CAP more times, it blocks again.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ $# -ge 1 ] || { echo "Usage: $0 <item-key> [\"note\"]" >&2; exit 1; }
KEY="$1"
NOTE="${2:-}"

python3 "$SCRIPT_DIR/review-rejections.py" unblock --item-key "$KEY" --note "$NOTE"
