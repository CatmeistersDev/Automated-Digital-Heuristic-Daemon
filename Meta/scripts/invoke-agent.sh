#!/bin/bash
# invoke-agent.sh — local LLM invocation layer (Ollama via ollama_agent.py)
#
# Usage: invoke-agent.sh AGENT_NAME PROMPT [MODE]
#
# Reads agent-runtimes.conf to resolve an agent (+optional mode) to a runtime:
#   AGENT=ollama            -> ollama_agent.py DEFAULT_MODEL
#   AGENT=ollama:<tag>      -> that Ollama model tag (tag may contain ':' and '/')
#   AGENT_MODE=ollama:<tag> -> per-mode override (e.g. ADVISOR_TRIAGE=ollama:gemma4:e4b)
#   AGENT=ollama:a,ollama:b -> fallback chain (try first, then next)
#
# ponytail: ollama-only. The old claude (Max/OAuth + --bare API), codex, and
# kimi/gemini branches were removed — inert (config is ollama-only, no cloud CLI
# installed). Re-add a case in run_provider() if a cloud CLI ever returns.

set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

VAULT_DIR="${VAULT_DIR:-$HOME/VaultSandbox}"
unset PWD OLDPWD 2>/dev/null || true
cd "$VAULT_DIR" || { echo "FATAL: cannot cd to $VAULT_DIR" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${AGENT_RUNTIME_CONFIG:-$SCRIPT_DIR/../agent-runtimes.conf}"

if [ "$#" -lt 2 ]; then
    echo "Usage: $0 AGENT_NAME PROMPT [MODE]" >&2
    exit 1
fi

AGENT_NAME="$1"
PROMPT="$2"
AGENT_MODE="${3:-}"

# ── Load config ──────────────────────────────────────────────────────
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
fi

# ── Resolve runtime (mode-specific > agent-level > default) ──────────
agent_key="$(printf '%s' "$AGENT_NAME" | tr '[:lower:]-' '[:upper:]_')"
runtime_chain="${AGENT_RUNTIME:-}"

# Check mode-specific override first (e.g., ADVISOR_TRIAGE=ollama:gemma4:e4b)
if [ -z "$runtime_chain" ] && [ -n "$AGENT_MODE" ]; then
    mode_key="${agent_key}_$(printf '%s' "$AGENT_MODE" | tr '[:lower:]-' '[:upper:]_')"
    runtime_chain="$(eval "printf '%s' \"\${$mode_key:-}\"")"
fi

# Fall back to agent-level config (e.g., ADVISOR=ollama)
if [ -z "$runtime_chain" ]; then
    runtime_chain="$(eval "printf '%s' \"\${$agent_key:-}\"")"
fi

# Default to local ollama if nothing configured. Any agent name works.
if [ -z "$runtime_chain" ]; then
    runtime_chain="ollama"
fi

# ── Provider driver: run a single provider, return exit code ─────────
# Provider format: "ollama" or "ollama:<tag>"
run_provider() {
    local provider_spec="$1"
    local prompt="$2"

    local provider="${provider_spec%%:*}"
    local model=""
    if [[ "$provider_spec" == *:* ]]; then
        model="${provider_spec#*:}"
    fi

    case "$provider" in
        ollama)
            # Route through the local tool-using harness (ollama_agent.py), NOT plain
            # /api/generate. The harness gives the model file tools (read/write/grep/
            # git_commit) so upstream agent prompts ("read SKILL.md, then use your tools…")
            # work locally. Model: "ollama" (no tag) -> harness DEFAULT_MODEL;
            # "ollama:<tag>" -> that tag (tag may contain '/' and ':' e.g. ...:latest).
            local agent_model_arg=()
            if [ -n "$model" ]; then
                agent_model_arg=(--model "$model")
            fi
            # Resolve a python that actually RUNS (Windows' python3 may be a Store
            # alias stub that exits non-zero). Override with OLLAMA_AGENT_PYTHON.
            local py_bin="${OLLAMA_AGENT_PYTHON:-}"
            if [ -z "$py_bin" ]; then
                local _cand
                for _cand in python3 python; do
                    if command -v "$_cand" >/dev/null 2>&1 && "$_cand" -c 'import sys' >/dev/null 2>&1; then
                        py_bin="$_cand"; break
                    fi
                done
            fi
            if [ -z "$py_bin" ]; then
                echo "ERROR: no working python found for ollama_agent.py" >&2
                return 1
            fi
            OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}" \
            VAULT_DIR="$VAULT_DIR" \
            AGENT_NAME="$AGENT_NAME" \
            "$py_bin" "$SCRIPT_DIR/ollama_agent.py" \
                "${agent_model_arg[@]}" \
                --vault "$VAULT_DIR" \
                --prompt "$prompt"
            return $?
            ;;

        *)
            echo "WARN: Unknown runtime '$provider' for $AGENT_NAME — skipping" >&2
            return 1
            ;;
    esac
}

# ── Execute fallback chain ───────────────────────────────────────────
# Split runtime_chain on commas and try each provider in order. First wins.
IFS=',' read -ra PROVIDERS <<< "$runtime_chain"

for provider in "${PROVIDERS[@]}"; do
    provider=$(echo "$provider" | xargs)  # trim whitespace
    [ -z "$provider" ] && continue

    if run_provider "$provider" "$PROMPT"; then
        exit 0
    fi

    echo "WARN: $provider failed for $AGENT_NAME — trying next in chain" >&2
done

echo "ERROR: All runtimes failed for $AGENT_NAME (chain: $runtime_chain)" >&2
exit 1
