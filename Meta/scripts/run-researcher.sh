#!/bin/bash
# run-researcher-v2.sh (LOCAL, VAULT-ONLY context + optional fetch_url for web).
# Synthesizes existing vault notes on a topic into Thinking/Research/<slug>.md.
# bash gathers related notes (deterministic); model writes the synthesis.
#
# Usage: run-researcher.sh "topic"        (explicit topic)
#        run-researcher.sh --scan          (find an action flagged enrichment_status: needs-research)
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"
OWNER="${VAULT_OWNER:-Louise}"

# The harness registers fetch_url/search_web ONLY when this is set (see ollama_agent.py).
# The Researcher is the one agent allowed on the web: it runs on a human-chosen topic, not
# on untrusted transcript text, so it can't be prompt-injected into exfiltrating the vault.
export OLLAMA_AGENT_WEB=1

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

ARG="${1:-}"
ACTION_NOTE=""
TOPIC=""
if [ "$ARG" = "--scan" ] || [ -z "$ARG" ]; then
    ACTION_NOTE="$(grep -rlE '^enrichment_status: needs-research' Canon/Actions 2>/dev/null | head -1)"
    if [ -n "$ACTION_NOTE" ]; then
        TOPIC="$(grep -m1 '^name:' "$ACTION_NOTE" | sed 's/^name: *//; s/"//g')"
    fi
else
    TOPIC="$ARG"
fi
[ -n "$TOPIC" ] || { echo "No topic. Pass a topic string, or flag an action with 'enrichment_status: needs-research' and run --scan."; exit 0; }
echo "=== Researching (vault-only + fetch_url): $TOPIC ==="

# --- Gather related vault context (bash, deterministic) ---
# Try the BM25 lexical index first (ranked, not readdir-order luck). Feature-detected —
# a missing script, a missing/corrupt index (exit 10), or zero hits all fall through to
# the ORIGINAL grep pass below, unchanged.
BM25_SCRIPT="$SCRIPT_DIR/bm25-index.py"
RELATED=()
USED_BM25=0
if [ -f "$BM25_SCRIPT" ]; then
    # Incremental refresh (cheap — unchanged notes aren't re-touched). Best-effort:
    # a build failure just means the query below will also fail/exit 10 and we
    # fall back, so nothing extra to handle here.
    VAULT_DIR="$VAULT_DIR" python3 "$BM25_SCRIPT" build >/dev/null 2>&1 || true
    BM25_OUT="$(VAULT_DIR="$VAULT_DIR" python3 "$BM25_SCRIPT" query "$TOPIC" --top 8 2>/dev/null | tr -d '\r')"
    BM25_RC=$?
    if [ "$BM25_RC" -eq 0 ] && [ -n "$BM25_OUT" ]; then
        while IFS=$'\t' read -r _score relpath _snippet; do
            [ -n "$relpath" ] || continue
            dup=0
            for r in "${RELATED[@]:-}"; do [ "$r" = "$relpath" ] && dup=1 && break; done
            [ "$dup" -eq 1 ] || RELATED+=("$relpath")
        done <<< "$BM25_OUT"
        [ "${#RELATED[@]}" -gt 0 ] && USED_BM25=1
    fi
fi

if [ "$USED_BM25" -ne 1 ]; then
    # --- fallback: legacy unranked grep pass (unchanged) ---
    PAT="$(echo "$TOPIC" | tr ' ' '\n' | awk 'length>3' | paste -sd'|' -)"
    [ -n "$PAT" ] || PAT="$TOPIC"
    mapfile -t RELATED < <(grep -rilE "$PAT" Canon Thinking 2>/dev/null | head -8)
fi
CONTEXT=""
for f in "${RELATED[@]}"; do
    [ -f "$f" ] || continue
    CONTEXT="$CONTEXT

=== $f ===
$(sed -n '1,45p' "$f")"
done
[ -n "$CONTEXT" ] || CONTEXT="(no related notes found in the vault for this topic)"

PROMPT="You are the RESEARCHER for ${OWNER}'s personal vault. You may use the search_web tool to search the internet for topics that require external context, and the fetch_url tool to read specific webpages. Prioritize connecting external research back to the vault context below. Topic: \"$TOPIC\".

Write a concise analysis note with these markdown sections:
## Summary
(2-3 sentences)
## What the vault says
(bullets grounded in the notes below — cite note names)
## Open questions
(what's unknown or missing from the vault)
## Recommendations
(concrete next steps for ${OWNER})

Base everything strictly on the provided notes and fetched URLs; if the vault lacks information, say so explicitly. Reply by calling final with ONLY the markdown body (the sections above).

## VAULT CONTEXT
$CONTEXT"

BODY="$(OLLAMA_AGENT_MAX_ITERS=3 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$PROMPT" 2>/dev/null | tr -d '\r')"
[ -n "$BODY" ] || BODY="(no synthesis produced this run)
Related notes: ${RELATED[*]:-none}"

# Verification pass (hallucination guard): a second model call checks the draft's claims against
# the SAME vault context and flags anything not grounded. Still vault-only, no web. Set
# RESEARCHER_NO_VERIFY=1 to skip. Best-effort: any failure just omits the self-check section.
VERIFY=""
if [ "${RESEARCHER_NO_VERIFY:-0}" != "1" ] && [ "$BODY" != "(no synthesis produced this run)
Related notes: ${RELATED[*]:-none}" ]; then
    VERIFY_PROMPT="You are the fact-checker for ${OWNER}'s vault researcher. Your ONLY job: flag any claim in the DRAFT below that is NOT supported by the VAULT CONTEXT or fetched URLs. Do not add new analysis. Reply by calling final with a SHORT markdown bullet list of unsupported/uncertain claims; if every claim is grounded in the context, reply with exactly: All claims grounded in the vault context.

## DRAFT
$BODY

## VAULT CONTEXT
$CONTEXT"
    VERIFY="$(OLLAMA_AGENT_MAX_ITERS=3 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" researcher "$VERIFY_PROMPT" 2>/dev/null | tr -d '\r')"
fi

SLUG="$(echo "$TOPIC" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]//g' | cut -c1-50)"
[ -n "$SLUG" ] || SLUG="research-$(date +%H%M%S)"
mkdir -p Thinking/Research
OUT="Thinking/Research/$SLUG.md"
{
    echo "---"
    echo "type: research"
    echo "name: $TOPIC"
    echo "created: $TODAY"
    echo "source: ai-generated"
    echo "source_agent: Researcher"
    # Lineage convention (see lineage.py): a research note derived from a triggering
    # action records it in derived_from — only when --scan actually found one; an
    # explicit-topic run (no ACTION_NOTE) has no lineage to record.
    if [ -n "$ACTION_NOTE" ]; then
        echo "derived_from:"
        echo "  - \"[[$(basename "${ACTION_NOTE%.md}")]]\""
    fi
    echo "---"
    echo ""
    echo "# 🔬 $TOPIC"
    echo ""
    echo "$BODY"
    if [ -n "$VERIFY" ]; then
        echo ""
        echo "## Verification (self-check)"
        echo "<!-- source: ai-generated, agent: Researcher (verification pass), $TODAY -->"
        echo "$VERIFY"
    fi
} > "$OUT"
echo "Research written: $OUT"

# If triggered by an action, link it back + flip status
if [ -n "$ACTION_NOTE" ] && [ -f "$ACTION_NOTE" ]; then
    sed -i 's/^enrichment_status: needs-research/enrichment_status: researched/' "$ACTION_NOTE" 2>/dev/null || true
    if ! grep -q '^## Research' "$ACTION_NOTE" 2>/dev/null; then
        printf '\n## Research\n- [[%s]]\n' "$SLUG" >> "$ACTION_NOTE"
    fi
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add Thinking/Research/ ${ACTION_NOTE:+"$ACTION_NOTE"} 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[Researcher] $TOPIC" 2>&1)"; then
        echo "committed"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
