#!/usr/bin/env bash
# setup.sh — first-run setup wizard. Asks a few questions, then writes:
#   .env                         settings docker-compose.yml reads (git-ignored, chmod 600)
#   <vault>/.secrets/*.txt       tokens the pipeline reads at runtime (git-ignored, chmod 600)
#   Meta/agent-runtimes.conf     per-agent model picks, copied from the template if missing
# and optionally fetches WhisperX into the build context.
#
# Safe to re-run: every answer you gave last time is offered as the default, so you can
# press Enter through it and change only what you need. Blank answers on optional items
# leave that feature off. Nothing here talks to Docker or starts the stack.
#
# Usage:
#   ./setup.sh          interactive
#   ./setup.sh --yes    accept every default without asking (re-run / scripted use)
#
# Test hooks: SETUP_SKIP_WHISPERX=1 skips the WhisperX download step; SETUP_SKIP_PROBE=1
# skips the Ollama reachability check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT" || { echo "setup: cannot cd to $ROOT" >&2; exit 1; }
ENV_FILE="$ROOT/.env"
YES=0
case "${1:-}" in
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    "") ;;
    *) echo "setup: unknown option $1 (try --help)" >&2; exit 2 ;;
esac

bold() { printf '\n\033[1m%s\033[0m\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# Previous answer for KEY from .env, else the given default.
prev() {   # $1 = key, $2 = default
    local v=""
    [ -f "$ENV_FILE" ] && v="$(grep -E "^$1=" "$ENV_FILE" | tail -1 | cut -d= -f2-)"
    printf '%s' "${v:-$2}"
}

# ask VAR "Question" "default" [secret]
# Secret defaults are shown masked; pressing Enter keeps the existing value.
ask() {
    local var="$1" q="$2" def="$3" secret="${4:-}" shown ans
    if [ "$YES" -eq 1 ]; then printf -v "$var" '%s' "$def"; return; fi
    shown="$def"
    if [ -n "$secret" ] && [ -n "$def" ]; then shown="****${def: -4}"; fi
    if [ -n "$shown" ]; then printf '  %s [%s]: ' "$q" "$shown"; else printf '  %s: ' "$q"; fi
    IFS= read -r ans || ans=""
    ans="${ans#"${ans%%[![:space:]]*}"}"; ans="${ans%"${ans##*[![:space:]]}"}"   # trim
    [ "$ans" = "-" ] && ans="" && def=""     # a single "-" clears a previous value
    printf -v "$var" '%s' "${ans:-$def}"
}

yesno() {   # yesno "Question" default(y|n) -> exit 0 for yes
    local q="$1" def="$2" ans
    if [ "$YES" -eq 1 ]; then [ "$def" = y ]; return; fi
    printf '  %s [%s]: ' "$q" "$([ "$def" = y ] && echo Y/n || echo y/N)"
    IFS= read -r ans || ans=""
    ans="${ans:-$def}"
    case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

secret_file() {   # $1 = dir, $2 = name, $3 = value (blank = leave any existing file alone)
    [ -n "$3" ] || return 0
    mkdir -p "$1" && chmod 700 "$1" 2>/dev/null
    printf '%s\n' "$3" > "$1/$2" && chmod 600 "$1/$2" 2>/dev/null
}

read_secret() { [ -f "$1" ] && tr -d '[:space:]' < "$1" || true; }

gen_token() {
    if command -v openssl >/dev/null 2>&1; then openssl rand -hex 32
    else head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; fi
}

guess_tz() {
    local tz="${TZ:-}"
    [ -z "$tz" ] && command -v timedatectl >/dev/null 2>&1 && tz="$(timedatectl show -p Timezone --value 2>/dev/null)"
    [ -z "$tz" ] && [ -f /etc/timezone ] && tz="$(cat /etc/timezone)"
    [ -z "$tz" ] && [ -L /etc/localtime ] && tz="$(readlink /etc/localtime | sed 's#.*/zoneinfo/##')"
    printf '%s' "${tz:-UTC}"
}

printf '\033[1mA.D.H.D setup\033[0m — a few questions, Enter accepts the [default].\n'
[ -f "$ENV_FILE" ] && note "Found an existing .env — your previous answers are the defaults."

# --- 1. You -----------------------------------------------------------------------------
bold "1/5  You"
ask VAULT_OWNER "Your name (agents address you by it; 'Me' in notes resolves to it)" "$(prev VAULT_OWNER Louise)"
ask TZ "Your timezone (schedules and memo dates use local time)" "$(prev TZ "$(guess_tz)")"
ask VAULT_PATH "Vault folder to mount ('.' = this repo's demo vault)" "$(prev VAULT_PATH .)"
SECRETS_DIR="$VAULT_PATH/.secrets"
case "$VAULT_PATH" in /*) ;; *) SECRETS_DIR="$ROOT/$VAULT_PATH/.secrets" ;; esac
[ -d "$VAULT_PATH" ] || note "Note: '$VAULT_PATH' doesn't exist yet — create it (and 'git init' it) before starting."

# --- 2. The model -----------------------------------------------------------------------
bold "2/5  Local model (Ollama)"
ask OLLAMA_HOST "Ollama address, as the container sees it" "$(prev OLLAMA_HOST http://ollama:11434)"
ask OLLAMA_AGENT_MODEL "Model name" "$(prev OLLAMA_AGENT_MODEL qwen3.6:35b-a3b)"
if [ "${SETUP_SKIP_PROBE:-0}" != 1 ] && command -v curl >/dev/null 2>&1; then
    if tags="$(curl -sf -m 5 "${OLLAMA_HOST%/}/api/tags" 2>/dev/null)"; then
        if printf '%s' "$tags" | grep -qF "\"$OLLAMA_AGENT_MODEL\""; then
            note "OK: Ollama answered and has $OLLAMA_AGENT_MODEL."
        else
            note "Ollama answered, but $OLLAMA_AGENT_MODEL isn't pulled yet: ollama pull $OLLAMA_AGENT_MODEL"
        fi
    else
        note "Couldn't reach $OLLAMA_HOST from here. That's normal for a docker-network name like"
        note "'ollama' — just make sure the container can reach it once it's running."
    fi
fi

# --- 3. Transcription -------------------------------------------------------------------
bold "3/5  Transcription"
ask WHISPER_LANG "Main language you speak in memos (en, de, fr, ...)" "$(prev WHISPER_LANG en)"
ask HF_TOKEN "Hugging Face token for speaker labels (hf_..., blank = no diarization)" "$(read_secret "$SECRETS_DIR/hf-token.txt")" secret
case "$HF_TOKEN" in ""|hf_*) ;; *) note "Warning: Hugging Face tokens normally start with 'hf_'." ;; esac
[ -n "$HF_TOKEN" ] && note "Accept the pyannote model terms on huggingface.co with that account, or diarization fails."

if [ -f whisperX-main/whisperX-main/pyproject.toml ]; then
    note "WhisperX is already in place."
elif [ "${SETUP_SKIP_WHISPERX:-0}" = 1 ]; then
    note "Skipping the WhisperX download (SETUP_SKIP_WHISPERX=1)."
elif yesno "WhisperX isn't in the build folder yet. Download it now (~5 MB)?" y; then
    if command -v curl >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; then
        tmpzip="$(mktemp)"
        if curl -fsSL -o "$tmpzip" https://github.com/m-bain/whisperX/archive/refs/heads/main.zip \
           && mkdir -p whisperX-main && unzip -q -o "$tmpzip" -d whisperX-main \
           && [ -f whisperX-main/whisperX-main/pyproject.toml ]; then
            note "OK: WhisperX downloaded."
        else
            note "Download failed — get the main.zip from github.com/m-bain/whisperX and unzip it into whisperX-main/."
        fi
        rm -f "$tmpzip"
    else
        note "Needs curl + unzip. Manually: unzip WhisperX's main.zip into whisperX-main/"
        note "(so that whisperX-main/whisperX-main/pyproject.toml exists)."
    fi
fi

# --- 4. Chat endpoint -------------------------------------------------------------------
bold "4/5  Chat (Advisor for Open WebUI)"
ADVISOR_TOKEN="$(prev ADVISOR_TOKEN "")"
if [ -z "$ADVISOR_TOKEN" ]; then
    ADVISOR_TOKEN="$(gen_token)"
    note "Generated an Advisor token. Paste it into Open WebUI as the connection's API key:"
    note "  $ADVISOR_TOKEN"
else
    note "Keeping your existing Advisor token (delete ADVISOR_TOKEN from .env to make a new one)."
fi
ADVISOR_HOST="$(prev ADVISOR_HOST 0.0.0.0)"

# --- 5. Notifications -------------------------------------------------------------------
bold "5/5  Notifications (all optional — blank skips; '-' clears a saved value)"
ask NTFY_URL "ntfy server URL (e.g. https://ntfy.sh)" "$(prev NTFY_URL "")"
NTFY_TOPIC="$(prev NTFY_TOPIC autoadhd)"
[ -n "$NTFY_URL" ] && ask NTFY_TOPIC "ntfy topic (pick something hard to guess on a public server)" "$NTFY_TOPIC"
ask DISCORD_TOKEN "Discord bot token" "$(read_secret "$SECRETS_DIR/discord-token.txt")" secret
DISCORD_CHANNEL=""; DISCORD_ALLOWED_USER_ID="$(prev DISCORD_ALLOWED_USER_ID "")"
if [ -n "$DISCORD_TOKEN" ]; then
    ask DISCORD_CHANNEL "Discord channel ID for alerts" "$(read_secret "$SECRETS_DIR/discord-channel-id.txt")"
    ask DISCORD_ALLOWED_USER_ID "YOUR Discord user ID (the only person the bot will answer)" "$DISCORD_ALLOWED_USER_ID"
    [ -z "$DISCORD_ALLOWED_USER_ID" ] && note "Without a user ID the bot ignores everyone — that's deliberate."
fi
ask TELEGRAM_BOT_TOKEN "Telegram bot token" "$(read_secret "$SECRETS_DIR/telegram-token.txt")" secret
TELEGRAM_CHAT_ID=""
[ -n "$TELEGRAM_BOT_TOKEN" ] && ask TELEGRAM_CHAT_ID "Telegram chat ID" "$(read_secret "$SECRETS_DIR/telegram-chat-id.txt")"

# --- Write ------------------------------------------------------------------------------
umask 077
{
    echo "# Written by setup.sh on $(date '+%Y-%m-%d %H:%M'). Re-run ./setup.sh to change; safe to edit."
    echo "# docker compose reads this automatically. Contains your Advisor token — never commit it."
    for k in VAULT_OWNER TZ VAULT_PATH OLLAMA_HOST OLLAMA_AGENT_MODEL WHISPER_LANG \
             ADVISOR_HOST ADVISOR_TOKEN NTFY_URL NTFY_TOPIC DISCORD_ALLOWED_USER_ID; do
        printf '%s=%s\n' "$k" "${!k}"
    done
} > "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null

secret_file "$SECRETS_DIR" hf-token.txt "$HF_TOKEN"
secret_file "$SECRETS_DIR" discord-token.txt "$DISCORD_TOKEN"
secret_file "$SECRETS_DIR" discord-channel-id.txt "$DISCORD_CHANNEL"
secret_file "$SECRETS_DIR" telegram-token.txt "$TELEGRAM_BOT_TOKEN"
secret_file "$SECRETS_DIR" telegram-chat-id.txt "$TELEGRAM_CHAT_ID"

if [ ! -f Meta/agent-runtimes.conf ] && [ -f Meta/agent-runtimes.conf.ollama ]; then
    cp Meta/agent-runtimes.conf.ollama Meta/agent-runtimes.conf
    CONF_NOTE="copied from the template"
else
    CONF_NOTE="kept as-is"
fi

if [ -d .git ] && [ ! -f .git/hooks/pre-commit ] && yesno "Install the git hook that blocks accidental Canon/ deletions?" y; then
    make install-hooks >/dev/null 2>&1 || {
        printf '#!/bin/sh\nexec "$(git rev-parse --show-toplevel)/Meta/scripts/pre-commit-guard.sh" "$@"\n' > .git/hooks/pre-commit
        chmod +x .git/hooks/pre-commit
    }
fi

bold "Done"
note "Wrote .env and $(basename "$SECRETS_DIR")/ (both git-ignored); Meta/agent-runtimes.conf $CONF_NOTE."
note "Next:  docker compose up -d --build"
note "Then:  docker compose exec autoadhd bash /app/Meta/scripts/run-health.sh"
