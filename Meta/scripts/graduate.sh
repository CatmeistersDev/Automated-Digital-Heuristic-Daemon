#!/bin/bash
# graduate.sh — promote a Thinking/ note (idea, concept, emerging, reflection, ...)
# to a crystallized entry, preserving lineage back to the origin note (Phase 4b).
# Human-run CLI — NOT scheduled, NOT model-driven; deterministic, no LLM call.
#
# Usage: graduate.sh <thinking-note> <project|decision|belief>
#   project/decision -> new Canon/Projects/ or Canon/Decisions/ note
#   belief            -> new Thinking/ note (beliefs live in Thinking/ per the vault
#                         folder map — this still "graduates" an idea's TYPE from
#                         tentative to a crystallized belief, just not its folder)
#
# Creates the new note with a graduated_from lineage field, correct folder/emoji/
# frontmatter, and a provenance comment pointing back at the origin. Then APPENDS
# to the origin (status: graduated via lib-agent.sh's agent_note_set_status, plus a
# "Graduated to [[...]]" line) — the origin is NEVER deleted or rewritten.
# Refuses if the target note already exists.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"

# shellcheck source=lib-agent.sh
source "$SCRIPT_DIR/lib-agent.sh"

usage() {
    echo "Usage: $0 <thinking-note> <project|decision|belief>" >&2
    exit 1
}

[ $# -eq 2 ] || usage
ORIGIN="$1"
TARGET_TYPE="$2"

[ -f "$ORIGIN" ] || { echo "Origin note not found: $ORIGIN" >&2; exit 1; }

case "$TARGET_TYPE" in
    project)  TARGET_DIR="Canon/Projects";  EMOJI="📁" ;;
    decision) TARGET_DIR="Canon/Decisions"; EMOJI="⚖️" ;;
    belief)   TARGET_DIR="Thinking";        EMOJI="🪨" ;;
    *) echo "Unknown target-type: $TARGET_TYPE (must be project|decision|belief)" >&2; exit 1 ;;
esac

ORIGIN_BASENAME="$(basename "${ORIGIN%.md}")"

# --- derive the new note's name: origin's frontmatter name: if present, else basename ---
NAME="$(grep -m1 '^name:' "$ORIGIN" 2>/dev/null | sed -e 's/^name: *//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
[ -n "$NAME" ] || NAME="$ORIGIN_BASENAME"

TARGET_PATH="$TARGET_DIR/$NAME.md"

if [ -f "$TARGET_PATH" ]; then
    echo "Refusing: target already exists: $TARGET_PATH" >&2
    exit 1
fi
if [ "$TARGET_PATH" = "$ORIGIN" ]; then
    echo "Refusing: target and origin resolve to the same note: $TARGET_PATH" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"

# --- body of the origin, minus frontmatter and its own leading H1 (the new note
# gets a fresh H1 with the target type's emoji) ---
ORIGIN_BODY="$(python3 - "$ORIGIN" <<'PYEOF'
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    text = fh.read()

body = text
if body.startswith("---"):
    end = body.find("\n---", 3)
    if end != -1:
        body = body[end + 4:]
        if body.startswith("\n"):
            body = body[1:]

lines = body.splitlines()
i = 0
while i < len(lines) and lines[i].strip() == "":
    i += 1
if i < len(lines) and lines[i].lstrip().startswith("#"):
    i += 1
    while i < len(lines) and lines[i].strip() == "":
        i += 1

print("\n".join(lines[i:]))
PYEOF
)"

{
    echo "---"
    echo "type: $TARGET_TYPE"
    echo "name: $NAME"
    echo "created: $TODAY"
    echo "updated: $TODAY"
    echo "source: human"
    echo "graduated_from: \"[[$ORIGIN_BASENAME]]\""
    echo "---"
    echo ""
    echo "# $EMOJI $NAME"
    echo ""
    echo "$ORIGIN_BODY"
    echo ""
    echo "<!-- graduated from [[$ORIGIN_BASENAME]] via graduate.sh, $TODAY -->"
} > "$TARGET_PATH"
echo "Created: $TARGET_PATH (graduated_from [[$ORIGIN_BASENAME]])"

# --- append-only update to the origin: status + a graduation line. Never rewrites
# the origin's existing content. ---
agent_note_set_status "$ORIGIN" "graduated"
printf '\nGraduated to [[%s]] on %s.\n' "$NAME" "$TODAY" >> "$ORIGIN"
echo "Origin updated (append-only, never rewritten): $ORIGIN"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add -- "$TARGET_PATH" "$ORIGIN" 2>/dev/null || true
    if git diff --cached --quiet -- "$TARGET_PATH" "$ORIGIN"; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[Human] graduate: $ORIGIN_BASENAME -> $TARGET_PATH" -- "$TARGET_PATH" "$ORIGIN" 2>&1)"; then
        echo "committed"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
