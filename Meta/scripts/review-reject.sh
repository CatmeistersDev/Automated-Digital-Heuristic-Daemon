#!/bin/bash
# review-reject.sh — record a human rejection of a Meta/review-queue/ proposal
# (Phase 2 hardening, 2026-07-18). Rejections feed back into proposal generation:
# run-dedup.sh injects up to the last 3 into the model prompt as "PREVIOUS
# REJECTIONS" context (and outright suppresses re-proposing an exact-hash group
# that was ever rejected); run-groomer.sh skips a stale action once its item key
# hits the cap. An item key rejected REVIEW_REJECTION_CAP times (default 5) is
# auto-blocked from future proposals until Meta/scripts/review-unblock.sh clears it.
#
# TWO ways to reject a proposal (this is the PRIMARY one; the note-frontmatter
# convention below is the Obsidian-native secondary path):
#
#   1. PRIMARY — run this script:
#        Meta/scripts/review-reject.sh <proposal-file> ["feedback text"]
#        Meta/scripts/review-reject.sh <item-key>       ["feedback text"]
#      Pass a proposal FILE to reject every item it contains (flips its frontmatter
#      `status:` to `rejected`), or a specific item KEY (as printed by
#      review-queue-list.sh, e.g. "dedup:funtime corp+funtime corporation") to reject
#      just one item without touching the file.
#
#   2. SECONDARY (Obsidian-native) — hand-edit the proposal note: set
#      `status: rejected` in its frontmatter and optionally add a `## Feedback`
#      section with your reasoning, save, then run:
#        Meta/scripts/review-reject.sh --sweep
#      which scans Meta/review-queue/ for notes marked that way and records them.
#      Idempotent: each note is swept once (a `<!-- rejection-recorded -->` marker
#      comment is appended so re-sweeps skip it).
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/review-rejections.py"
CAP="${REVIEW_REJECTION_CAP:-5}"
# shellcheck source=lib-agent.sh
source "$SCRIPT_DIR/lib-agent.sh"

MARKER="<!-- rejection-recorded -->"

record_one() {
    local key="$1" agent="$2" file="$3" feedback="$4"
    local cnt
    cnt="$(python3 "$LIB" record --item-key "$key" --agent "$agent" --proposal-file "$file" --feedback "$feedback" | tr -d '\r')"
    if [ "$cnt" -ge "$CAP" ]; then
        echo "  BLOCKED: $key (${cnt}/${CAP} rejections) — future proposals skip this item until review-unblock.sh"
    else
        echo "  recorded: $key (${cnt}/${CAP} rejections)"
    fi
}

commit_file() {
    local f="$1" msg="$2"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    git add -- "$f" 2>/dev/null || true
    if ! git diff --cached --quiet -- "$f" 2>/dev/null; then
        git commit -q -m "$msg" -- "$f" 2>/dev/null || true
    fi
}

sweep() {
    local found=0 f feedback
    shopt -s nullglob
    for f in Meta/review-queue/*.md; do
        [ -f "$f" ] || continue
        grep -qF "$MARKER" "$f" && continue
        grep -qiE '^status:[[:space:]]*rejected[[:space:]]*$' "$f" || continue
        found=1
        echo "Sweeping rejected note: $f"
        feedback="$(sed -n '/^## Feedback/,$p' "$f" | sed '1d' | sed '/^## /,$d' | sed '/^[[:space:]]*$/d' | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
        while IFS=$'\t' read -r agent key; do
            [ -n "$key" ] || continue
            record_one "$key" "$agent" "$f" "$feedback"
        done < <(python3 "$LIB" extract-item-keys --file "$f" | tr -d '\r')
        printf '\n%s\n' "$MARKER" >> "$f"
        commit_file "$f" "[Human] reject review-queue item: $(basename "$f")"
    done
    shopt -u nullglob
    [ "$found" -eq 1 ] || echo "Sweep: no newly-rejected notes found."
}

if [ "${1:-}" = "--sweep" ]; then
    sweep
    exit 0
fi

[ $# -ge 1 ] || {
    echo "Usage: $0 <proposal-file-or-item-key> [\"feedback text\"]" >&2
    echo "       $0 --sweep" >&2
    exit 1
}
TARGET="$1"
FEEDBACK="${2:-}"

if [ -f "$TARGET" ]; then
    mapfile -t ROWS < <(python3 "$LIB" extract-item-keys --file "$TARGET" | tr -d '\r')
    if [ "${#ROWS[@]}" -eq 0 ]; then
        echo "No structured items recognized in $TARGET — recording a whole-file rejection."
        AGENT="$(python3 "$LIB" get-frontmatter --file "$TARGET" --key source_agent | tr -d '\r')"
        [ -n "$AGENT" ] || AGENT="unknown"
        record_one "file:$TARGET" "$AGENT" "$TARGET" "$FEEDBACK"
    else
        for row in "${ROWS[@]}"; do
            agent="${row%%$'\t'*}"
            key="${row#*$'\t'}"
            record_one "$key" "$agent" "$TARGET" "$FEEDBACK"
        done
    fi
    if [ "$(head -1 "$TARGET")" = "---" ]; then
        agent_note_set_status "$TARGET" "rejected"
        echo "Marked $TARGET as status: rejected"
        commit_file "$TARGET" "[Human] reject review-queue item: $(basename "$TARGET")"
    fi
else
    # Treat as a literal item key (single-item rejection, no proposal file to flip)
    record_one "$TARGET" "manual" "" "$FEEDBACK"
fi
