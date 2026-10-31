#!/bin/bash
# run-retro.sh (LOCAL HYBRID) — nightly retrospective.
# bash gathers the day's stats (deterministic); model writes a short reflection.
# Output: Meta/AI-Reflections/<date> - Retro.md
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"
OWNER="${VAULT_OWNER:-Louise}"

git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# Engineering Working Agreement: standalone reflection agents run on a clean worktree only
# (don't fold unrelated edits into the reflection commit). Override: VAULT_AGENT_ALLOW_DIRTY=1.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    if command -v agent_assert_clean_worktree >/dev/null 2>&1; then
        agent_assert_clean_worktree "Retro" || { echo "Retro: worktree not clean - skipping run."; exit 0; }
    fi
    # Single-pipeline lock: serialize against every other mutating agent run,
    # manual or scheduled, across processes.
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 900 || exit 1
    fi
fi

# --- Deterministic stats (bash) ---
COMMITS_TODAY="$(git log --since="$TODAY 00:00:00" --oneline 2>/dev/null | wc -l | tr -d ' ')"
MEMOS="$(grep -rlE "^recorded: $TODAY" Inbox/Voice 2>/dev/null | wc -l | tr -d ' ')"
CANON_NEW="$(grep -rlE "^created: $TODAY" Canon Thinking 2>/dev/null | wc -l | tr -d ' ')"
OPEN_ACTIONS="$(grep -rlE "^status: (open|in-progress)" Canon/Actions 2>/dev/null | wc -l | tr -d ' ')"
ENRICHED="$(grep -rl "^enrichment_status: enriched" Canon/Actions 2>/dev/null | wc -l | tr -d ' ')"
COMMIT_LIST="$(git log --since="$TODAY 00:00:00" --pretty='- %s' 2>/dev/null | grep -vE '\[Briefing\]|\[Reviewer\]' | head -15)"

# --- One focused model call for the narrative ---
RP="You are writing a brief nightly RETROSPECTIVE for ${OWNER}'s personal 'AutoADHD' vault (voice memos -> structured notes). Today's stats:
- Voice memos processed: $MEMOS
- New notes created: $CANON_NEW
- Open actions: $OPEN_ACTIONS (enriched with sub-steps: $ENRICHED)
- Vault commits today: $COMMITS_TODAY

Notable activity today:
$COMMIT_LIST

Write 3-5 warm, direct sentences for ${OWNER}: what happened today, ONE pattern or observation worth noting, and ONE concrete suggestion for tomorrow. ADHD-aware (concise, no fluff). Reply by calling final with ONLY the retrospective text."
NARRATIVE="$(OLLAMA_AGENT_MAX_ITERS=3 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" retrospective "$RP" 2>/dev/null | tr -d '\r')"
[ -n "$NARRATIVE" ] || NARRATIVE="Processed $MEMOS memo(s) and created $CANON_NEW note(s) today; $OPEN_ACTIONS open actions remain. (model narrative unavailable this run)"

# --- Write the retro note ---
mkdir -p Meta/AI-Reflections
OUT="Meta/AI-Reflections/$TODAY - Retro.md"
{
    echo "---"
    echo "type: ai-reflection"
    echo "name: Retro $TODAY"
    echo "created: $TODAY"
    echo "source: ai-generated"
    echo "source_agent: Retrospective"
    echo "---"
    echo ""
    echo "# 🤖 Retrospective — $TODAY"
    echo ""
    echo "## 📊 Today"
    echo "- Voice memos processed: $MEMOS"
    echo "- New notes: $CANON_NEW"
    echo "- Open actions: $OPEN_ACTIONS (enriched: $ENRICHED)"
    echo "- Commits: $COMMITS_TODAY"
    echo ""
    echo "## 💭 Reflection"
    echo "$NARRATIVE"
} > "$OUT"
echo "Retro written: $OUT"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$OUT" 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[Retrospective] $TODAY" 2>&1)"; then
        echo "committed"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
