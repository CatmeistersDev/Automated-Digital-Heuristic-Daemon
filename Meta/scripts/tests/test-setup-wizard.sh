#!/bin/bash
# test-setup-wizard.sh — behavioral test for the repo-root setup.sh wizard. Runs it in a
# throwaway copy of the repo root with answers piped on stdin (no network, no Docker) and
# checks what it writes: .env, the .secrets/ files, the runtime config, and that a re-run
# keeps every previous answer (including the generated Advisor token) as the default.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/Meta"
cp "$REPO/setup.sh" "$REPO/docker-compose.yml" "$T/"
cp "$REPO/Meta/agent-runtimes.conf.ollama" "$T/Meta/"
export SETUP_SKIP_WHISPERX=1 SETUP_SKIP_PROBE=1

fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
envval() { grep -E "^$1=" "$T/.env" | tail -1 | cut -d= -f2-; }

# --- A. first run, interactive ---------------------------------------------------------
# Order: name, tz, vault path, ollama host, model, language, HF token, ntfy url (blank ->
# no topic question), discord token, channel, user id, telegram token (blank -> no chat id).
printf '%s\n' "Gene" "Europe/Berlin" "." "http://gpu-box:11434" "gemma4:26b" "de" \
    "hf_testtoken123" "" "discord-tok" "12345" "67890" "" | bash "$T/setup.sh" > "$T/run1.log" 2>&1
RC="${PIPESTATUS[1]}"
check "A: exits 0"                                 [ "$RC" -eq 0 ]
check "A: .env written"                            [ -f "$T/.env" ]
check "A: owner saved"                             [ "$(envval VAULT_OWNER)" = "Gene" ]
check "A: timezone saved"                          [ "$(envval TZ)" = "Europe/Berlin" ]
check "A: ollama host saved"                       [ "$(envval OLLAMA_HOST)" = "http://gpu-box:11434" ]
check "A: model saved"                             [ "$(envval OLLAMA_AGENT_MODEL)" = "gemma4:26b" ]
check "A: language saved"                          [ "$(envval WHISPER_LANG)" = "de" ]
check "A: discord user id saved"                   [ "$(envval DISCORD_ALLOWED_USER_ID)" = "67890" ]
check "A: ntfy left off"                           [ -z "$(envval NTFY_URL)" ]
TOKEN1="$(envval ADVISOR_TOKEN)"
check "A: advisor token generated (64 hex)"        grep -qE '^[0-9a-f]{64}$' <<< "$TOKEN1"
check "A: advisor token shown to the user"         grep -qF "$TOKEN1" "$T/run1.log"
check "A: hf token file"                           [ "$(cat "$T/.secrets/hf-token.txt")" = "hf_testtoken123" ]
check "A: discord token file"                      [ "$(cat "$T/.secrets/discord-token.txt")" = "discord-tok" ]
check "A: discord channel file"                    [ "$(cat "$T/.secrets/discord-channel-id.txt")" = "12345" ]
check "A: no telegram file when skipped"           [ ! -e "$T/.secrets/telegram-token.txt" ]
check "A: tokens are NOT in .env"                  bash -c '! grep -qE "hf_testtoken123|discord-tok" "$1"' _ "$T/.env"
check "A: runtime config copied from template"     cmp -s "$T/Meta/agent-runtimes.conf" "$T/Meta/agent-runtimes.conf.ollama"

# --- B. re-run with --yes keeps everything ---------------------------------------------
bash "$T/setup.sh" --yes > "$T/run2.log" 2>&1; RC=$?
check "B: --yes exits 0"                           [ "$RC" -eq 0 ]
check "B: owner kept"                              [ "$(envval VAULT_OWNER)" = "Gene" ]
check "B: model kept"                              [ "$(envval OLLAMA_AGENT_MODEL)" = "gemma4:26b" ]
check "B: advisor token NOT regenerated"           [ "$(envval ADVISOR_TOKEN)" = "$TOKEN1" ]
check "B: hf token kept"                           [ "$(cat "$T/.secrets/hf-token.txt")" = "hf_testtoken123" ]
check "B: secret values never echoed in full"      bash -c '! grep -qF "hf_testtoken123" "$1"' _ "$T/run2.log"

# --- C. Enter keeps defaults; '-' clears one --------------------------------------------
# name kept, tz kept, path kept, host kept, model kept, lang kept, hf kept, ntfy set,
# topic set, discord token kept, channel kept, user id cleared with '-', telegram blank.
printf '%s\n' "" "" "" "" "" "" "" "https://ntfy.example" "my-topic" "" "" "-" "" \
    | bash "$T/setup.sh" > "$T/run3.log" 2>&1
check "C: Enter kept the owner"                    [ "$(envval VAULT_OWNER)" = "Gene" ]
check "C: ntfy url set"                            [ "$(envval NTFY_URL)" = "https://ntfy.example" ]
check "C: ntfy topic set"                          [ "$(envval NTFY_TOPIC)" = "my-topic" ]
check "C: '-' cleared the discord user id"         [ -z "$(envval DISCORD_ALLOWED_USER_ID)" ]
check "C: and the wizard warns about it"           grep -q "ignores everyone" "$T/run3.log"
check "C: hf token still kept"                     [ "$(cat "$T/.secrets/hf-token.txt")" = "hf_testtoken123" ]

# --- D. compose reads every key the wizard writes ----------------------------------------
for k in $(grep -oE '^[A-Z_]+=' "$T/.env" | tr -d '='); do
    check "D: docker-compose.yml uses \${$k}"     grep -qF "\${$k:-" "$T/docker-compose.yml"
done

[ "$fail" -eq 0 ] && echo "test-setup-wizard: PASS" || { echo "test-setup-wizard: FAIL"; exit 1; }
