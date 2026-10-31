#!/bin/bash
# run-thinker.sh (LOCAL HYBRID) — weekly whole-vault pattern analysis.
# bash assembles a compact vault snapshot (deterministic); model surfaces patterns,
# tensions, stale actions, and one proposal. Output: Meta/AI-Reflections/<date> - Thinker.md
#
# Usage: run-thinker.sh [--mirror]   (--mirror = coach-tone reflection on the person)
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"
OWNER="${VAULT_OWNER:-Louise}"
MODE="${1:-}"

git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# Engineering Working Agreement: standalone reflection agents run on a clean worktree only
# (don't fold unrelated edits into the reflection commit). Override: VAULT_AGENT_ALLOW_DIRTY=1.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    if command -v agent_assert_clean_worktree >/dev/null 2>&1; then
        agent_assert_clean_worktree "Thinker" || { echo "Thinker/Mirror: worktree not clean - skipping run."; exit 0; }
    fi
    # Single-pipeline lock: serialize against every other mutating agent run,
    # manual or scheduled, across processes.
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 900 || exit 1
    fi
fi

# --- Deterministic vault snapshot (bash) ---
snapshot() {
    local d cnt names
    # NOTE (2026-07-23, ported from a 2026-07-12 fix that had only ever landed in the public
    # mirror, never here): Beliefs was missing from this list entirely, even though Mirror's own
    # spec (Meta/Agents/Mirror.md) calls cross-referencing Canon/Beliefs/ with Canon/Actions/ its
    # MOST IMPORTANT section — the model was being asked to check belief-action alignment with
    # zero belief data ever in its context. Added.
    for d in People Organizations Places Projects Events Decisions Actions Beliefs; do
        cnt=$(find Canon/"$d" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
        [ "$cnt" -eq 0 ] && continue
        if [ "$d" = "Beliefs" ]; then
            # Beliefs need actual substance, not just a name, for alignment-checking to mean
            # anything — a bare filename list gives the model nothing to compare against.
            echo "- Beliefs ($cnt):"
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                local bname bline
                bname="$(basename "$f" .md)"
                # First non-blank, non-heading content line AFTER the frontmatter block (skip
                # to the second '---', same convention as run-extractor.sh's get_transcript()).
                bline="$(awk '
                    /^---[[:space:]]*$/ { c++; next }
                    c<2 { next }
                    /^#/ { next }
                    /^[[:space:]]*$/ { next }
                    { print; exit }
                ' "$f" 2>/dev/null | cut -c1-100)"
                echo "  - $bname: ${bline:-(no content)}"
            done < <(find Canon/"$d" -maxdepth 1 -name '*.md' 2>/dev/null)
            continue
        fi
        names=$(find Canon/"$d" -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sed 's/\.md$//' | paste -sd';' - | sed 's/;/; /g')
        echo "- $d ($cnt): $names"
    done
    local tc
    tc=$(find Thinking -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
    [ "$tc" -gt 0 ] && echo "- Thinking ($tc): $(find Thinking -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sed 's/\.md$//' | paste -sd';' - | sed 's/;/; /g')"
}
SNAP="$(snapshot)"
OPEN_ACTIONS="$(grep -rlE '^status: (open|in-progress)' Canon/Actions 2>/dev/null | sed 's#.*/##; s/\.md$//' | paste -sd';' - | sed 's/;/; /g')"

# Frontier notes (Phase 4b): recently-touched-but-poorly-backlinked notes worth the
# Thinker's attention. Feature-detected — a missing boundary-score.py just leaves
# FRONTIER empty and the prompt is unchanged from before this wiring.
BOUNDARY_SCRIPT="$SCRIPT_DIR/boundary-score.py"
FRONTIER=""
if [ -f "$BOUNDARY_SCRIPT" ]; then
    FRONTIER="$(VAULT_DIR="$VAULT_DIR" python3 "$BOUNDARY_SCRIPT" --top 10 2>/dev/null | tr -d '\r')"
fi

if [ "$MODE" = "--mirror" ]; then
    AGENT="mirror"; TITLE="Mirror"; EMOJI="🪞"
    TASK="You are the MIRROR — a direct, caring coach (not a cheerleader) reflecting ${OWNER} back to himself. From the vault snapshot, note: ${OWNER}'s apparent strengths and working style, any tension between stated beliefs/decisions and open actions, and ONE honest, specific nudge. 4-7 sentences, warm but direct, second person ('you')."
else
    AGENT="thinker"; TITLE="Thinker"; EMOJI="🤖"
    TASK="You are the THINKER analyzing ${OWNER}'s knowledge vault. From the snapshot, surface: 1-2 PATTERNS across the notes, any CONTRADICTION or tension, STALE/recurring open actions, and ONE concrete connection or proposal worth ${OWNER}'s attention. Reference notes by name. 4-7 sentences, concrete, no fluff. If you spot a genuine CONTRADICTION between two notes (not just a tension), ALSO add one extra line of its own, exactly formatted as: CONFLICT: <short topic> — <one-line description, naming the notes as [[Wikilinks]] if you know them>. Only do this for a real contradiction; most runs will have none."
fi

PROMPT="$TASK

## VAULT SNAPSHOT
$SNAP

## OPEN ACTIONS
${OPEN_ACTIONS:-（none)}"
if [ -n "$FRONTIER" ]; then
    PROMPT="$PROMPT

FRONTIER NOTES (recently active, poorly integrated — consider connections):
$FRONTIER"
fi
PROMPT="$PROMPT

Reply by calling final with ONLY your reflection text."
NARRATIVE="$(OLLAMA_AGENT_MAX_ITERS=3 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" "$AGENT" "$PROMPT" 2>/dev/null | tr -d '\r')"
[ -n "$NARRATIVE" ] || NARRATIVE="(model narrative unavailable this run; snapshot recorded above)"

mkdir -p Meta/AI-Reflections
OUT="Meta/AI-Reflections/$TODAY - $TITLE.md"
{
    echo "---"
    echo "type: ai-reflection"
    echo "name: $TITLE $TODAY"
    echo "created: $TODAY"
    echo "source: ai-generated"
    echo "source_agent: $TITLE"
    echo "---"
    echo ""
    echo "# $EMOJI $TITLE — $TODAY"
    echo ""
    echo "$NARRATIVE"
    echo ""
    echo "## 🗂️ Vault snapshot"
    echo "$SNAP"
} > "$OUT"
echo "$TITLE written: $OUT"

# Deterministic post-pass (Phase 4b): turn any "CONFLICT: ..." line the model
# emitted (see the CONTRADICTION instruction in TASK above) into a propose-only
# review-queue stub. Factored into its own script so it's unit-testable without a
# live model. Feature-detected: a missing thinker-conflict-stubs.py just skips
# this, unchanged behavior otherwise.
CONFLICT_SCRIPT="$SCRIPT_DIR/thinker-conflict-stubs.py"
CONFLICT_FILES=()
if [ -f "$CONFLICT_SCRIPT" ]; then
    NARR_TMP="$(mktemp)"
    printf '%s\n' "$NARRATIVE" > "$NARR_TMP"
    while IFS= read -r cf; do
        [ -n "$cf" ] && CONFLICT_FILES+=("$cf")
    done < <(VAULT_DIR="$VAULT_DIR" python3 "$CONFLICT_SCRIPT" --narrative-file "$NARR_TMP" --agent "$TITLE" --date "$TODAY" 2>/dev/null | tr -d '\r')
    rm -f "$NARR_TMP"
    [ "${#CONFLICT_FILES[@]}" -gt 0 ] && echo "$TITLE: ${#CONFLICT_FILES[@]} conflict stub(s) queued."
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # add separately: an empty CONFLICT_FILES used to expand to a "" pathspec, which made
    # the whole git add fatal (silently) and the run end "(nothing to commit)" — 2026-07-19
    git add -- "$OUT" 2>/dev/null || true
    if [ "${#CONFLICT_FILES[@]}" -gt 0 ]; then
        git add -- "${CONFLICT_FILES[@]}" 2>/dev/null || true
    fi
    if git diff --cached --quiet; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[$TITLE] $TODAY" 2>&1)"; then
        echo "committed"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
