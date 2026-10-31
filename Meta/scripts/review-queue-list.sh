#!/bin/bash
# review-queue-list.sh — list Meta/review-queue/ contents sorted by rejection-count
# descending (Phase 2 hardening, 2026-07-18): repeatedly-bounced items surface
# first, and any file containing an item at/over REVIEW_REJECTION_CAP is tagged
# [BLOCKED]. Read-only — makes no changes to the vault.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="$SCRIPT_DIR/review-rejections.py"
CAP="${REVIEW_REJECTION_CAP:-5}"

shopt -s nullglob
FILES=(Meta/review-queue/*.md)
shopt -u nullglob
if [ "${#FILES[@]}" -eq 0 ]; then
    echo "Review queue is empty."
    exit 0
fi

ROWS=""
for f in "${FILES[@]}"; do
    MAXCNT=0
    BLOCKED=0
    if [ -f "$LIB" ]; then
        while IFS=$'\t' read -r agent key; do
            [ -n "$key" ] || continue
            c="$(python3 "$LIB" count --item-key "$key" | tr -d '\r')"
            [ "$c" -gt "$MAXCNT" ] && MAXCNT="$c"
            [ "$c" -ge "$CAP" ] && BLOCKED=1
        done < <(python3 "$LIB" extract-item-keys --file "$f" | tr -d '\r')
    fi
    TAG=""
    [ "$BLOCKED" -eq 1 ] && TAG=" [BLOCKED]"
    printf -v ROWLINE '%s\t%s\t%s' "$MAXCNT" "$f" "$TAG"
    ROWS="${ROWS}${ROWLINE}"$'\n'
done

printf '%s' "$ROWS" | sort -t"$(printf '\t')" -k1,1 -rn | while IFS=$'\t' read -r cnt path tag; do
    [ -n "$path" ] || continue
    if [ "$cnt" -gt 0 ]; then
        echo "[$cnt rejection(s)]$tag $path"
    else
        echo "$path"
    fi
done
