#!/bin/bash
# run-reviewer.sh (LOCAL HYBRID) — QA an extracted note.
# Design: bash does the MECHANICAL checks deterministically (reliable); the model
# is used ONLY for one focused judgment call ("did extraction miss any named entity?").
# Findings -> Meta/AI-Reflections/review-log.md.
#
# Usage: run-reviewer.sh [path/to/inbox-note.md]   (no arg -> last 10 extracted notes)
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
LOG="Meta/AI-Reflections/review-log.md"

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
    NOTES=("$1"); BATCH=0          # explicit note -> always review
else
    mapfile -t NOTES < <(grep -rl "^status: extracted" Inbox/ 2>/dev/null | sort -r | head -10); BATCH=1
fi
[ "${#NOTES[@]}" -gt 0 ] || { echo "No extracted notes to review."; exit 0; }
mkdir -p Meta/AI-Reflections

# Resolve [[wikilinks]] the Obsidian way: [[Name]] matches a note named Name.md
# ANYWHERE in the vault, case-insensitively — NOT just at the vault root. The old
# root-only check ([ -f "$l.md" ]) flagged every Canon/People link (e.g. [[Teddy]],
# [[Rudy]]) as "broken" every night even though the note existed in a subfolder.
declare -A NOTE_PATHS
while IFS= read -r _p; do
    _bn="$(basename "$_p" .md)"; _k="${_bn,,}"
    [ -n "${NOTE_PATHS[$_k]:-}" ] || NOTE_PATHS[$_k]="$_p"
done < <(find Canon Thinking Inbox -name '*.md' 2>/dev/null)
resolve_link() { local l="$1" b; b="${l##*/}"; b="${b%.md}"; printf '%s' "${NOTE_PATHS[${b,,}]:-}"; }

# Severity tiers (Phase 2 hardening, 2026-07-18): every finding line in review-log.md
# gets a [BLOCKER]/[HIGH]/[MEDIUM]/[LOW] tag. Mechanical checks are tagged
# deterministically here (known issue shapes -> known severity); the model is asked
# to self-tag its "missed entities" judgment, but since compliance isn't guaranteed,
# tag_verdict() below defaults any line the model left untagged to [MEDIUM].
tag_issue() {
    local msg="$1"
    case "$msg" in
        *"missing ## Extracted section"*)   printf '[BLOCKER] %s' "$msg" ;;
        *"status is not 'extracted'"*)      printf '[HIGH] %s' "$msg" ;;
        *"broken wikilink"*)                printf '[HIGH] %s' "$msg" ;;
        *"no wikilinks found in"*)          printf '[HIGH] %s' "$msg" ;;
        *"missing source_agent"*)           printf '[MEDIUM] %s' "$msg" ;;
        *"missing source_date"*)            printf '[MEDIUM] %s' "$msg" ;;
        *"missing type emoji"*)             printf '[LOW] %s' "$msg" ;;
        *"no '# ' H1 heading"*)             printf '[MEDIUM] %s' "$msg" ;;
        *)                                  printf '[MEDIUM] %s' "$msg" ;;   # deterministic default (spec)
    esac
}

# Deterministic post-pass over free-text model output: any line that doesn't already
# start with a recognized severity tag defaults to [MEDIUM]; "none" / the no-response
# sentinel pass through untouched so the existing "nothing missed" checks still work.
tag_verdict() {
    local text="$1" line
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            printf '\n'
        elif printf '%s' "$line" | grep -qiE '^\[(blocker|high|medium|low)\]'; then
            printf '%s\n' "$line"
        elif printf '%s' "$line" | grep -qiE '^(none|\(no model response\))$'; then
            printf '%s\n' "$line"
        else
            printf '[MEDIUM] %s\n' "$line"
        fi
    done <<< "$text"
}

# Idempotency: skip a note whose content is unchanged since its last review, so the
# scheduled batch stops re-logging identical findings on a static note set every night.
SEEN="Meta/AI-Reflections/.reviewer-seen.tsv"
[ -f "$SEEN" ] || : > "$SEEN" 2>/dev/null || true
note_hash() { md5sum "$1" 2>/dev/null | awk '{print $1}'; }
seen_hash() { awk -F'\t' -v n="$1" '$2==n{h=$1} END{print h}' "$SEEN" 2>/dev/null; }
record_seen() { awk -F'\t' -v n="$2" '$2!=n' "$SEEN" > "$SEEN.tmp" 2>/dev/null || true; printf '%s\t%s\n' "$1" "$2" >> "$SEEN.tmp"; mv -f "$SEEN.tmp" "$SEEN" 2>/dev/null || true; }

for note in "${NOTES[@]}"; do
    [ -f "$note" ] || { echo "skip (missing): $note"; continue; }
    nh="$(note_hash "$note")"
    if [ "$BATCH" -eq 1 ] && [ -n "$nh" ] && [ "$nh" = "$(seen_hash "$note")" ]; then
        echo "=== Unchanged since last review, skip: $note ==="; continue
    fi
    echo "=== Reviewing: $note ==="
    issues=()

    # (e) inbox note completeness
    grep -q "^## Extracted" "$note" || issues+=("$note: missing ## Extracted section")
    grep -q "^status: extracted" "$note" || issues+=("$note: status is not 'extracted'")

    # collect [[wikilink]] targets from the ## Extracted section
    mapfile -t links < <(sed -n '/^## Extracted/,$p' "$note" | grep -oE '\[\[[^]]+\]\]' | sed 's/\[\[//; s/\]\]//' | sed 's/|.*$//')

    if [ "${#links[@]}" -gt 0 ]; then
        for l in "${links[@]}"; do
            [ -n "$l" ] || continue
            f="$(resolve_link "$l")"
            if [ -z "$f" ]; then issues+=("broken wikilink [[$l]] -> not found in vault"); continue; fi
            grep -q "^source_agent:" "$f" || issues+=("$f: missing source_agent")
            grep -q "^source_date:" "$f"  || issues+=("$f: missing source_date")
            h1="$(grep -m1 '^# ' "$f" || true)"
            if [ -n "$h1" ]; then
                after="${h1#\# }"; first="${after:0:1}"
                case "$first" in [A-Za-z0-9]) issues+=("$f: H1 may be missing type emoji -> $h1");; esac
            else
                issues+=("$f: no '# ' H1 heading")
            fi
        done
    else
        issues+=("$note: no wikilinks found in ## Extracted")
    fi

    # ONE focused model judgment: did extraction miss any named entity?
    RAW="$(sed -n '/^# Raw/,$ p' "$note" | sed '1d' | sed '/^## /,$d')"
    NAMES="$(printf '%s\n' "${links[@]:-}")"
    JP="You are a QA reviewer. Below is a voice-memo transcript and the list of vault notes an extractor created from it. Name any clearly-identified PERSON, ORGANIZATION, PLACE, or PROJECT mentioned in the transcript that is NOT represented in the created notes. For EACH one you report, prefix its line with a severity tag: [HIGH] for a clearly important named person/organization (mentioned by name multiple times, or central to what was discussed), [MEDIUM] for a minor/passing mention. Reply by calling final immediately with a short list (one per line, each tagged), or the single word: none. Do not use other tools.

TRANSCRIPT:
$RAW

CREATED NOTES:
$NAMES"
    VERDICT="$(OLLAMA_AGENT_MAX_ITERS=3 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" reviewer "$JP" 2>/dev/null | tr -d '\r' | head -c 800)"
    [ -n "$VERDICT" ] || VERDICT="(no model response)"
    VERDICT_TAGGED="$(tag_verdict "$VERDICT")"

    {
        echo "## Review: $TS — $(basename "$note")"
        echo "### Mechanical checks"
        if [ "${#issues[@]}" -eq 0 ]; then
            echo "- none — links resolve, provenance + emoji present, write-back complete"
        else
            for i in "${issues[@]}"; do echo "- $(tag_issue "$i")"; done
        fi
        echo "### Missed entities (model judgment)"
        echo "$VERDICT_TAGGED"
        echo ""
    } >> "$LOG"
    echo "  logged ${#issues[@]} mechanical issue(s); verdict captured"

    # Surface real missed-entity findings to an actionable review-queue file (not just review-log).
    # The model replies "none" when nothing is missed; anything else is a concrete to-capture list.
    vnorm="$(printf '%s' "$VERDICT" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:].')"
    if [ -n "$vnorm" ] && [ "$vnorm" != "none" ] && [ "$VERDICT" != "(no model response)" ]; then
        mkdir -p Meta/review-queue
        MQ="Meta/review-queue/$(date +%Y-%m-%d)-missed-entities.md"
        if [ ! -f "$MQ" ]; then
            {
                echo "---"; echo "type: review-item"; echo "name: Missed entities $(date +%Y-%m-%d)"
                echo "status: pending"; echo "source_agent: Reviewer"; echo "---"; echo
                echo "# 📋 Possibly-missed entities — $(date +%Y-%m-%d)"; echo
                echo "People/orgs/places/projects the Reviewer's model judged were mentioned but NOT"
                echo "captured as notes. Create the note (or confirm it's noise), then remove the entry."; echo
            } > "$MQ"
        fi
        { echo "## $(basename "$note")"; echo "$VERDICT_TAGGED"; echo; } >> "$MQ"
        echo "  surfaced possibly-missed entities -> $MQ"
    fi

    git add "$LOG" "$note" Canon/ Thinking/ Meta/review-queue/ 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "  (nothing to commit)"
    elif cerr="$(git commit -q -m "[Reviewer] QA: $(basename "$note")" 2>&1)"; then
        echo "  committed review"
    else
        echo "  ⚠ COMMIT FAILED for $(basename "$note"): $cerr" >&2
        EXIT=1
    fi

    record_seen "$nh" "$note"   # mark this content hash reviewed (idempotency)
done
exit "${EXIT:-0}"
