#!/bin/bash
# agent-undo.sh — list and safely revert agent-authored vault commits.
#
# Every agent commit carries a "[Agent-Name] ..." subject-line prefix — enforced by
# lib-agent.sh's agent_prefixed_message() (for shell call sites) and
# ollama_agent.py's tool_git_commit() (for model-driven commits); see the
# hand-written "[Extractor] extract: ..." / "[Implementer] vault self-heal ..." style
# messages already used by every run-*.sh. Human commits never carry that prefix, so
# this script uses it as the ONLY signal for "safe to touch" — it refuses to revert
# anything without one.
#
# Usage:
#   agent-undo.sh [list] [--agent NAME] [-n N]   # list last N (default 10) agent
#                                                 # commits, optionally filtered to
#                                                 # one agent (bracket name, e.g.
#                                                 # "Extractor" or "Task-Enricher")
#   agent-undo.sh revert <hash>                  # git revert --no-edit one commit
#   agent-undo.sh revert --last [N]              # revert the N most recent commits
#                                                 # (default 1), newest first
#
# NOTE: reverting a commit that CREATED a Canon/Thinking file turns into a deletion
# under that path — pre-commit-guard.sh blocks deletions in protected Canon dirs by
# default (VAULT_ALLOW_DELETE=1 overrides). That guard is intentional and this script
# does not bypass it.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR" || { echo "FATAL: cannot cd to $VAULT_DIR" >&2; exit 1; }

git config --global --add safe.directory '*' 2>/dev/null || true

PREFIX_RE='^\[[^]]+\] '

usage() {
    cat >&2 <<'EOF'
Usage:
  agent-undo.sh [list] [--agent NAME] [-n N]
  agent-undo.sh revert <hash>
  agent-undo.sh revert --last [N]
EOF
    exit 1
}

commit_subject() {
    git -C "$VAULT_DIR" log -1 --format=%s "$1" 2>/dev/null
}

is_agent_commit() {
    local subject
    subject="$(commit_subject "$1")" || return 1
    [ -n "$subject" ] && [[ "$subject" =~ $PREFIX_RE ]]
}

cmd_list() {
    local n=10
    local agent_filter=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --agent) agent_filter="${2:?--agent requires a name}"; shift 2 ;;
            -n) n="${2:?-n requires a count}"; shift 2 ;;
            *) usage ;;
        esac
    done
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "agent-undo.sh: -n requires a positive integer" >&2; exit 1; }

    local agent_filter_lc=""
    [ -n "$agent_filter" ] && agent_filter_lc="$(printf '%s' "$agent_filter" | tr '[:upper:]' '[:lower:]')"

    local shown=0
    while IFS=$'\t' read -r hash subject; do
        [ -n "$hash" ] || continue
        [[ "$subject" =~ $PREFIX_RE ]] || continue
        if [ -n "$agent_filter_lc" ]; then
            local bracket="${subject%%]*}"
            bracket="${bracket#[}"
            bracket_lc="$(printf '%s' "$bracket" | tr '[:upper:]' '[:lower:]')"
            [ "$bracket_lc" = "$agent_filter_lc" ] || continue
        fi
        printf '%s  %s\n' "${hash:0:10}" "$subject"
        shown=$((shown + 1))
        [ "$shown" -ge "$n" ] && break
    done < <(git -C "$VAULT_DIR" log --format='%H%x09%s')

    if [ "$shown" -eq 0 ]; then
        if [ -n "$agent_filter" ]; then
            echo "(no [$agent_filter]-prefixed commits found)"
        else
            echo "(no agent-prefixed commits found)"
        fi
    fi
}

cmd_revert() {
    local hashes=()
    if [ "${1:-}" = "--last" ]; then
        shift
        local n="${1:-1}"
        [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] || { echo "agent-undo.sh: --last requires a positive integer" >&2; exit 1; }
        mapfile -t hashes < <(git -C "$VAULT_DIR" log --format=%H -n "$n")
        [ "${#hashes[@]}" -eq "$n" ] || { echo "agent-undo.sh: fewer than $n commit(s) in history" >&2; exit 1; }
    elif [ -n "${1:-}" ]; then
        local full
        full="$(git -C "$VAULT_DIR" rev-parse --verify "${1}^{commit}" 2>/dev/null)"
        [ -n "$full" ] || { echo "agent-undo.sh: not a valid commit: $1" >&2; exit 1; }
        hashes=("$full")
    else
        usage
    fi

    # Fail closed: verify EVERY targeted commit carries the agent prefix BEFORE
    # touching anything — a batch --last N never partially reverts.
    local bad=()
    local h
    for h in "${hashes[@]}"; do
        is_agent_commit "$h" || bad+=("$h")
    done
    if [ "${#bad[@]}" -gt 0 ]; then
        echo "agent-undo.sh: refusing — commit(s) without an [Agent] prefix (human commits are off-limits):" >&2
        for h in "${bad[@]}"; do
            printf '  %s  %s\n' "${h:0:10}" "$(commit_subject "$h")" >&2
        done
        exit 1
    fi

    for h in "${hashes[@]}"; do
        echo "Reverting $(git -C "$VAULT_DIR" log -1 --format='%h %s' "$h")"
        if ! git -C "$VAULT_DIR" revert --no-edit "$h"; then
            echo "agent-undo.sh: revert failed for $h — resolve conflicts manually (git revert --abort to bail out)" >&2
            exit 1
        fi
    done
}

cmd="${1:-list}"
case "$cmd" in
    list)
        shift || true
        cmd_list "$@"
        ;;
    revert)
        shift || true
        cmd_revert "$@"
        ;;
    -h|--help)
        usage
        ;;
    --agent|-n)
        # Bare filter flags with no explicit "list" subcommand still list.
        cmd_list "$@"
        ;;
    *)
        usage
        ;;
esac
