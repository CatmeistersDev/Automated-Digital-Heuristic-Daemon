#!/bin/bash
# run-dedup.sh (LOCAL HYBRID, CAUTIOUS) — find likely-duplicate Canon entities.
# bash gathers entity names; model proposes merges (typo/abbrev/alias variants only);
# proposals go to Meta/review-queue for HUMAN approval. NEVER merges or deletes anything.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"
REJLIB="$SCRIPT_DIR/review-rejections.py"
REJECTION_CAP="${REVIEW_REJECTION_CAP:-5}"

git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# Engineering Working Agreement: standalone reflection agents run on a clean worktree only
# (don't fold unrelated edits into the reflection commit). Override: VAULT_AGENT_ALLOW_DIRTY=1.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    if command -v agent_assert_clean_worktree >/dev/null 2>&1; then
        agent_assert_clean_worktree "Dedup" || { echo "Dedup: worktree not clean - skipping run."; exit 0; }
    fi
    # Single-pipeline lock: serialize against every other mutating agent run,
    # manual or scheduled, across processes.
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 900 || exit 1
    fi
fi

# Deterministic pre-filter (Phase 1 hardening, 2026-07-18): exact-normalized-hash
# duplicates are flagged WITHOUT any LLM call; the remaining candidates the LLM sees
# are narrowed to pairs above a token-set Jaccard similarity threshold — everything
# else is skipped entirely. Feature-detected so a partially-deployed image (missing
# dedup-prefilter.py) falls back to the original full-gather behavior unchanged.
LIST=""
EXACT_BLOCK=""
if [ -f "$SCRIPT_DIR/dedup-prefilter.py" ]; then
    PREFILTER_JSON="$(VAULT_DIR="$VAULT_DIR" python3 "$SCRIPT_DIR/dedup-prefilter.py" 2>/dev/null)"
fi
if [ -n "${PREFILTER_JSON:-}" ]; then
    if [ -f "$REJLIB" ]; then
        # Phase 2 hardening (2026-07-18): a deterministic exact-hash group the human
        # already rejected is suppressed OUTRIGHT (no cap wait — a "no" on a CERTAIN
        # match doesn't change on re-run); a Jaccard-candidate name pair that hit the
        # rejection cap is dropped from what the LLM even sees. Feature-detected so a
        # partially-deployed image (missing review-rejections.py) falls back unchanged.
        LIST="$(printf '%s' "$PREFILTER_JSON" | python3 "$REJLIB" filter-candidates --cap "$REJECTION_CAP" | tr -d '\r')"
        EXACT_BLOCK="$(printf '%s' "$PREFILTER_JSON" | python3 "$REJLIB" filter-exact-groups | tr -d '\r')"
    else
        LIST="$(printf '%s' "$PREFILTER_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
out = []
for t, names in data.get("candidates", {}).items():
    if names:
        out.append(f"{t}:")
        out.extend(names)
        out.append("")
print("\n".join(out))
')"
        EXACT_BLOCK="$(printf '%s' "$PREFILTER_JSON" | python3 -c '
import json, sys
data = json.load(sys.stdin)
blocks = []
for g in data.get("exact_groups", []):
    dups = ", ".join(g["duplicates"])
    canonical = g["canonical"]
    gtype = g["type"]
    blocks.append(f"CANONICAL: {canonical}\nDUPLICATES: {dups}\nWHY: exact normalized-text match ({gtype}, pre-filter, no LLM — CERTAIN)")
print("\n\n".join(blocks))
')"
    fi
    STATS="$(printf '%s' "$PREFILTER_JSON" | python3 -c '
import json, sys
s = json.load(sys.stdin).get("stats", {})
total, exact = s.get("pairs_total", 0), s.get("exact", 0)
sent, skipped = s.get("sent_to_llm", 0), s.get("skipped", 0)
print(f"{total} pairs total, {exact} exact, {sent} sent to LLM, {skipped} skipped")
')"
    echo "Dedup prefilter: $STATS"
else
    # Fallback: prefilter missing/failed -> original full gather, unchanged behavior.
    for t in People Organizations Places Projects Events; do
        ns="$(find "Canon/$t" -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sed 's/\.md$//' | sort)"
        [ -n "$ns" ] && LIST="$LIST
$t:
$ns
"
    done
fi

if [ -z "$(echo "$LIST" | tr -d '[:space:]')" ] && [ -z "$(echo "$EXACT_BLOCK" | tr -d '[:space:]')" ]; then
    echo "No Canon entities to check."; exit 0
fi

if [ -n "$(echo "$LIST" | tr -d '[:space:]')" ]; then
    # Phase 2 hardening (2026-07-18): feed the model any PREVIOUS REJECTIONS whose
    # full name-set is still among today's candidates, so it doesn't re-propose a
    # group the human already said no to. Empty when nothing relevant was rejected.
    PREV_CONTEXT=""
    if [ -f "$REJLIB" ]; then
        NAMES_TMP="$(mktemp)"
        printf '%s\n' "$LIST" | grep -vE ':$' | sed '/^$/d' > "$NAMES_TMP"
        PREV_CONTEXT="$(python3 "$REJLIB" relevant-context --names-file "$NAMES_TMP" 2>/dev/null | tr -d '\r')"
        rm -f "$NAMES_TMP"
    fi

    PROMPT="You are a careful data-quality reviewer for ${VAULT_OWNER:-Louise}'s knowledge vault. Below are Canon entity note names grouped by type. Identify ONLY groups of entries that clearly refer to the SAME real-world entity — i.e. typos, mis-transcriptions, abbreviations, or alias variants (e.g. 'WW' vs 'Wonder Wharf'; 'Bucket-Ball' vs 'Bucket Ball').

CRITICAL: Do NOT group entries that are merely related or similar but DISTINCT (e.g. 'Tipsy Tulip Classic' and 'Tipsy Tulip Deluxe' are DIFFERENT products — keep separate). When unsure, do NOT propose a merge.

For each genuine duplicate group output:
- CANONICAL: <the best name to keep>
- DUPLICATES: <other name(s) that should merge into it>
- WHY: <one line>

If there are no clear duplicates, reply exactly: NONE.
Reply by calling final with only that.

## ENTITIES
$LIST"
    if [ -n "$(echo "$PREV_CONTEXT" | tr -d '[:space:]')" ]; then
        PROMPT="$PROMPT

$PREV_CONTEXT"
    fi

    RESULT="$(OLLAMA_AGENT_MAX_ITERS=3 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" dedup "$PROMPT" 2>/dev/null | tr -d '\r')"
    [ -n "$RESULT" ] || RESULT="NONE"
else
    echo "Dedup: no candidate pairs above similarity threshold — skipping LLM call."
    RESULT="NONE"
fi

# Merge pre-filter-certain exact matches with model-proposed (heuristic) matches into
# one combined proposal block, preserving the existing CANONICAL/DUPLICATES/WHY shape.
COMBINED="$EXACT_BLOCK"
if ! echo "$RESULT" | grep -qiE '^\s*NONE\s*$'; then
    if [ -n "$(echo "$COMBINED" | tr -d '[:space:]')" ]; then
        COMBINED="$COMBINED

$RESULT"
    else
        COMBINED="$RESULT"
    fi
fi

if [ -z "$(echo "$COMBINED" | tr -d '[:space:]')" ]; then
    echo "Dedup: no duplicate entities proposed."
    exit 0
fi

mkdir -p Meta/review-queue
OUT="Meta/review-queue/$TODAY-dedup-proposals.md"
{
    echo "---"
    echo "type: review-item"
    echo "name: Entity merge proposals $TODAY"
    echo "status: pending"
    echo "source_agent: Dedup"
    echo "---"
    echo ""
    echo "# 📋 Proposed entity merges — $TODAY"
    echo ""
    echo "> ⚠️ PROPOSALS ONLY — nothing has been merged or deleted. Review, then merge by hand in Obsidian if you agree."
    echo ">"
    echo "> Disagree? Run \`Meta/scripts/review-reject.sh \"$OUT\" \"why\"\` (or reject a single group with its item key from \`review-queue-list.sh\`) — or set \`status: rejected\` here + add a \`## Feedback\` section, then run \`review-reject.sh --sweep\`. Rejected groups won't be re-proposed; repeated rejections auto-block the group (see \`review-unblock.sh\`)."
    echo ""
    echo "$COMBINED"
} > "$OUT"
echo "Dedup proposals queued (no changes made): $OUT"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add Meta/review-queue/ 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[Dedup] entity merge proposals $TODAY (review-queue, no changes)" 2>&1)"; then
        echo "committed"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
