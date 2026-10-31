#!/bin/bash
# pre-commit-guard.sh — git pre-commit hook for the vault
# Blocks dangerous operations: deletions in protected dirs, forbidden path edits by agents
#
# Install (Linux/container): ln -sf ../../Meta/scripts/pre-commit-guard.sh .git/hooks/pre-commit
# Install (portable wrapper — required on Windows checkouts, where ln -sf copies):
#   printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/Meta/scripts/pre-commit-guard.sh" "$@"\n' \
#     > .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

set -euo pipefail

# Resolve a working Python interpreter. On some Windows checkouts `python3` on PATH is the
# Microsoft Store's execution-alias stub, not a real interpreter -- it exists (so `command -v`
# finds it) but errors out when actually invoked. Probe each candidate with a no-op before
# trusting it, and fall through to whichever one actually runs.
PYBIN=""
for cand in python3 python py; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c "" >/dev/null 2>&1; then
        PYBIN="$cand"
        break
    fi
done

# Protected directories — deletions here require VAULT_ALLOW_DELETE=1
PROTECTED_DIRS=(
    "Thinking/Research"
    "Canon/People"
    "Canon/Actions"
    "Canon/Events"
    "Canon/Decisions"
    "Canon/Beliefs"
    "Canon/Reflections"
    "Canon/Projects"
    "Meta/AI-Reflections"
)

# Control files — only editable when VAULT_ALLOW_CONTROL_EDIT=1
CONTROL_PATHS=(
    "CLAUDE.md"
    "HOME.md"
    "Meta/Architecture.md"
    "Meta/agent-runtimes.conf.ollama"
    "Meta/Agents/"
    "Meta/scripts/"
)

ERRORS=()

# --- Check 1: Blocked deletions in protected dirs ---
# -M enables rename detection: without it (and with diff.renames off, the repo default), a
# `git mv` shows up as a raw delete-of-old-path + add-of-new-path, so a legitimate archival move
# (e.g. Groomer relocating old notes from a protected dir into Meta/_archive/) gets misidentified
# as a deletion and blocked here. -M lets a moved-with-content-intact file be recognized as a
# rename (status R) instead of a delete (status D), while genuine deletions are still caught.
DELETED_FILES=$(git diff --cached -M --diff-filter=D --name-only 2>/dev/null || true)
if [ -n "$DELETED_FILES" ]; then
    while IFS= read -r file; do
        [ -n "$file" ] || continue
        for dir in "${PROTECTED_DIRS[@]}"; do
            case "$file" in
                "$dir"/*)
                    if [ "${VAULT_ALLOW_DELETE:-0}" != "1" ]; then
                        ERRORS+=("BLOCKED DELETE: $file (set VAULT_ALLOW_DELETE=1 to override)")
                    fi
                    ;;
            esac
        done
    done <<< "$DELETED_FILES"
fi

# --- Check 2: Control file edits by agents (not humans) ---
# Only enforced when running inside an agent context.
#
# GATING (by design, but currently INERT): this check is env-gated so that
# humans committing from a shell are never blocked from editing control files
# — only automated agents should be. It only fires when VAULT_AGENT_CONTEXT
# is set to the agent's name. As of 2026-07-01 NOTHING in the codebase sets
# it, so this protection does nothing. To activate it, the agent runner
# (Meta/scripts/invoke-agent.sh, which already exports AGENT_NAME into the
# runtime env) should also export VAULT_AGENT_CONTEXT="$AGENT_NAME" so that
# git commits made by agent tools (ollama_agent.py git_commit, lib-agent.sh
# agent_git) inherit it. Deliberately NOT wired here; see Meta/AUDIT-2026-07-01.md F1.
if [ "${VAULT_AGENT_CONTEXT:-}" != "" ]; then
    CHANGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)
    if [ -n "$CHANGED_FILES" ]; then
        while IFS= read -r file; do
            [ -n "$file" ] || continue
            for ctrl in "${CONTROL_PATHS[@]}"; do
                case "$file" in
                    "$ctrl"|"$ctrl"*)
                        if [ "${VAULT_ALLOW_CONTROL_EDIT:-0}" != "1" ]; then
                            ERRORS+=("AGENT BLOCKED: $file (control file, agent=$VAULT_AGENT_CONTEXT)")
                        fi
                        ;;
                esac
            done
        done <<< "$CHANGED_FILES"
    fi
fi

# --- Check 3: Locked frontmatter fields must not silently change ---
# `locked:` was documented as a strong convention but never actually enforced — nothing
# compared a staged value against HEAD before this. check-locked-fields.py does that
# comparison; VAULT_ALLOW_LOCKED_EDIT=1 overrides for a deliberate human correction.
if [ "${VAULT_ALLOW_LOCKED_EDIT:-0}" != "1" ]; then
    # This hook runs both as the CODE repo's own pre-commit (Meta/scripts/ at $(git
    # rev-parse --show-toplevel), same repo) and as a plain copy in the VAULT data repo's
    # .git/hooks/ (no Meta/scripts/ there — it's a different repo; code ships baked at
    # /app in the container). Prefer the baked path, fall back to the repo-relative one.
    if [ -f /app/Meta/scripts/check-locked-fields.py ]; then
        CHECKER=/app/Meta/scripts/check-locked-fields.py
    else
        CHECKER="$(git rev-parse --show-toplevel)/Meta/scripts/check-locked-fields.py"
    fi
    if [ ! -f "$CHECKER" ] || [ -z "$PYBIN" ]; then
        : # checker or interpreter not found — skip rather than hard-fail the commit
    elif LOCKED_OUT=$("$PYBIN" "$CHECKER" 2>&1); then
        :
    else
        ERRORS+=("LOCKED FIELD(S) CHANGED (set VAULT_ALLOW_LOCKED_EDIT=1 to override):")
        while IFS= read -r line; do
            [ -n "$line" ] && ERRORS+=("  $line")
        done <<< "$LOCKED_OUT"
    fi
fi

# --- Check 4: Warn on large commits (> 50 files) ---
FILE_COUNT=$(git diff --cached --name-only 2>/dev/null | wc -l | tr -d ' ')
if [ "$FILE_COUNT" -gt 50 ] && [ "${VAULT_ALLOW_BULK:-0}" != "1" ]; then
    echo "⚠️  Large commit: $FILE_COUNT files staged. Set VAULT_ALLOW_BULK=1 to proceed." >&2
    # Warning only, don't block
fi

# --- Report ---
if [ "${#ERRORS[@]}" -gt 0 ]; then
    echo "" >&2
    echo "🛑 PRE-COMMIT GUARD — blocked this commit:" >&2
    echo "" >&2
    for err in "${ERRORS[@]}"; do
        echo "  $err" >&2
    done
    echo "" >&2
    echo "If this is intentional, set the appropriate env var and retry." >&2
    echo "" >&2
    exit 1
fi

exit 0
