#!/bin/bash
# run-task-enricher.sh (LOCAL / Ollama harness) — break an action into ADHD-friendly sub-steps.
# Concrete single-file task: the model edits ONE action note (adds ## Sub-steps + enrichment_status).
#
# Usage: run-task-enricher.sh [path/to/action.md]
#   no arg -> all open actions lacking enrichment_status
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"

git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# Single-pipeline lock: serialize against every other mutating agent run,
# manual or scheduled, across processes.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 900 || exit 1
    fi
fi

if [ -n "${1:-}" ]; then
    NOTES=("$1")
else
    NOTES=()
    for f in Canon/Actions/*.md; do
        [ -f "$f" ] || continue
        st="$(grep -m1 '^status:' "$f" | sed 's/^status: *//')"
        [ "$st" = "open" ] || [ "$st" = "in-progress" ] || continue
        grep -q '^enrichment_status:' "$f" && continue   # already enriched
        NOTES+=("$f")
    done
fi
[ "${#NOTES[@]}" -gt 0 ] || { echo "No open un-enriched actions."; exit 0; }

build_prompt() {
    local note="$1"
    cat <<EOF
You are the TASK-ENRICHER agent. Break ONE action into small, ADHD-friendly sub-steps. Work via tools (read_file, write_file, final). Reply with ONE JSON object per turn. APPLY — do not describe.

TARGET ACTION NOTE: $note

PROCEDURE:
1. read_file $note — just to understand what the action is (its name / any description near the top).
2. Decide: can this be broken into concrete steps from what you already know, or does it need
   external information first (comparing options, prices, vendors, current facts, "figure out
   which X is best" style actions)? If it needs research first, append_file EXACTLY this block and
   nothing else, then call final — do NOT invent sub-steps for something you'd have to guess at:

## Needs Research
<one sentence: what needs to be looked up before this can be decomposed>

   Otherwise, append_file to $note EXACTLY this block and nothing else:

## Sub-steps
- [ ] <step 1 — a tiny 2-minute starter that removes friction>
- [ ] <step 2>
- [ ] <step 3>
## Effort
<one of: S (<30min) | M (a few hours) | L (multi-day)>

   (3 to 6 concrete, sequential, small steps; first step must be trivially easy to start.)
   If the note ALREADY contains a "## Sub-steps" or "## Needs Research" heading, do NOT append
   again — just call final.
3. call final with a one-line summary.

HARD RULES: use append_file, NEVER write_file — write_file overwrites the whole note, and on a long
note the read cap would truncate its tail and permanently lose content. Edit ONLY $note. Do NOT create
other files. Do NOT run git commit. Do NOT touch the frontmatter (the shell sets enrichment_status) or
the action's name/status/owner, and do NOT alter any existing text.
EOF
}

EXIT=0
for note in "${NOTES[@]}"; do
    [ -f "$note" ] || { echo "skip (missing): $note"; continue; }
    echo "=== Enriching: $note ==="
    # Deterministic guard: if the note is already sub-stepped, don't invoke the agent at all — just
    # ensure the frontmatter flag is set. (Avoids the OLLAMA_AGENT_REQUIRE_WRITE=1 forcing a
    # duplicate append when the model is told "don't append if ## Sub-steps already exists".)
    if grep -q '^## Sub-steps' "$note" 2>/dev/null; then
        echo "  already has ## Sub-steps — skipping agent"
        grep -q '^enrichment_status:' "$note" || \
            sed -i '0,/^---/!{0,/^---/ s/^---/enrichment_status: enriched\n---/}' "$note" 2>/dev/null || true
        git add "$note" 2>/dev/null || true
        git diff --cached --quiet || git commit -q -m "[Task-Enricher] flag enriched: $(basename "$note")" 2>/dev/null || true
        continue
    fi
    if grep -q '^## Needs Research' "$note" 2>/dev/null; then
        echo "  already has ## Needs Research — skipping agent"
        grep -q '^enrichment_status:' "$note" || \
            sed -i '0,/^---/!{0,/^---/ s/^---/enrichment_status: needs-research\n---/}' "$note" 2>/dev/null || true
        git add "$note" 2>/dev/null || true
        git diff --cached --quiet || git commit -q -m "[Task-Enricher] flag needs-research: $(basename "$note")" 2>/dev/null || true
        continue
    fi
    PROMPT="$(build_prompt "$note")"
    OLLAMA_AGENT_REQUIRE_WRITE=1 OLLAMA_AGENT_MAX_ITERS="${OLLAMA_AGENT_MAX_ITERS:-10}" \
        /bin/bash "$SCRIPT_DIR/invoke-agent.sh" task-enricher "$PROMPT" || EXIT=$?

    # Deterministic frontmatter flag — the model appends only the body block; the shell owns the
    # enrichment_status field. Sub-steps -> enriched; Needs Research -> needs-research (picked up
    # by run-researcher.sh --scan); neither -> needs-enrichment (retry).
    if grep -q '^## Sub-steps' "$note" 2>/dev/null; then
        grep -q '^enrichment_status:' "$note" || \
            sed -i '0,/^---/!{0,/^---/ s/^---/enrichment_status: enriched\n---/}' "$note" 2>/dev/null || true
    elif grep -q '^## Needs Research' "$note" 2>/dev/null; then
        echo "  research needed -> marking enrichment_status: needs-research"
        grep -q '^enrichment_status:' "$note" || \
            sed -i '0,/^---/!{0,/^---/ s/^---/enrichment_status: needs-research\n---/}' "$note" 2>/dev/null || true
    else
        echo "  no sub-steps added -> marking enrichment_status: needs-enrichment"
        grep -q '^enrichment_status:' "$note" || \
            sed -i '0,/^---/!{0,/^---/ s/^---/enrichment_status: needs-enrichment\n---/}' "$note" 2>/dev/null || true
    fi

    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add "$note" 2>/dev/null || true
        if git diff --cached --quiet; then
            echo "  (nothing to commit)"
        elif cerr="$(git commit -q -m "[Task-Enricher] enrich: $(basename "$note")" 2>&1)"; then
            echo "  committed"
        else
            echo "  ⚠ COMMIT FAILED for $(basename "$note"): $cerr" >&2
            EXIT=1
        fi
    fi
done
exit "$EXIT"
