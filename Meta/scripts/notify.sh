#!/bin/bash
# notify.sh "Title" "message body" [priority] [tags] [click] — fan out a notification to ntfy,
# Discord AND Telegram. Pick one, pick all three, pick none — each channel is a no-op unless ITS
# OWN config is set, so this is safe to call unconditionally:
#   ntfy     -> NTFY_URL + NTFY_TOPIC (+ optional NTFY_TOKEN)
#   Discord  -> send-discord.sh  (webhook OR bot token + channel ID; see that script's header)
#   Telegram -> send-telegram.sh (bot token + chat ID; see that script's header)
# Setup guides for each: docs/notifications/
# Privacy: only sends to servers you configure.
#   tags:  comma-separated ntfy tag names (emoji-mapped by the ntfy client, e.g. "warning").
#          Also used by send-discord.sh to pick an embed color — see its header.
#   click: a path relative to THIS repo's root (with or without .md, e.g. "Canon/Actions/Foo")
#          — turned into an obsidian://open deep link for ntfy's Click header AND Discord.
#          Set OBSIDIAN_VAULT to whatever your vault is actually registered as in Obsidian's
#          vault switcher (get this EXACTLY right, don't guess — a mismatch means the link just
#          reopens Obsidian's last page instead of erroring, which looks like it works until you
#          tap it). If Obsidian sees a PARENT folder as the vault and this repo is a subfolder
#          inside it (a nested-vault layout), also set OBSIDIAN_SUBPATH to that subfolder name
#          so it gets prefixed onto every click path. Keep the .md extension — stripping it (an
#          earlier version of this code did) hits the same silent last-page fallback.
set -uo pipefail
TITLE="${1:-AutoADHD}"
BODY="${2:-}"
PRIO="${3:-default}"
TAGS="${4:-}"
CLICK="${5:-}"
OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-MyVault}"
OBSIDIAN_SUBPATH="${OBSIDIAN_SUBPATH:-}"

# Build the obsidian:// deep link once, if a click target was given.
CLICK_URL=""
if [ -n "$CLICK" ]; then
    CLICK_URL="$(OBSIDIAN_VAULT="$OBSIDIAN_VAULT" OBSIDIAN_SUBPATH="$OBSIDIAN_SUBPATH" CLICK_PATH="$CLICK" python3 -c '
import os, urllib.parse
vault = os.environ["OBSIDIAN_VAULT"]
subpath = os.environ["OBSIDIAN_SUBPATH"].strip("/")
path = os.environ["CLICK_PATH"].strip("/")
if not path.endswith(".md"):
    path = path + ".md"
full_path = f"{subpath}/{path}" if subpath else path
encoded = urllib.parse.quote(full_path, safe="/")
vault_enc = urllib.parse.quote(vault, safe="")
print(f"obsidian://open?vault={vault_enc}&file={encoded}")
' 2>/dev/null)"
fi

# notify.sh IS the alert channel, so it can't alert about its own failures. Instead it records
# a failed send to a bounded log; run-health.sh surfaces recent entries so a dead channel is
# observable in the health note (and via whichever OTHER channel still works).
VAULT_DIR="${VAULT_DIR:-/vault}"
ERRLOG="$VAULT_DIR/Meta/notify-errors.log"
log_fail() {
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${TITLE:0:80}" >> "$ERRLOG" 2>/dev/null || true
    # keep it bounded (last 200 lines)
    if [ -f "$ERRLOG" ] && [ "$(wc -l < "$ERRLOG" 2>/dev/null || echo 0)" -gt 200 ]; then
        tail -n 200 "$ERRLOG" > "$ERRLOG.tmp" 2>/dev/null && mv "$ERRLOG.tmp" "$ERRLOG" 2>/dev/null || true
    fi
}

# --- ntfy push (-f so an HTTP error counts as a failure, not a silent 2xx-only success) ---
if [ -n "${NTFY_URL:-}" ] && [ -n "${NTFY_TOPIC:-}" ]; then
    URL="${NTFY_URL%/}/${NTFY_TOPIC}"
    HEADERS=(-H "Title: $TITLE" -H "Priority: $PRIO")
    [ -n "${NTFY_TOKEN:-}" ] && HEADERS+=(-H "Authorization: Bearer $NTFY_TOKEN")
    [ -n "$TAGS" ] && HEADERS+=(-H "Tags: $TAGS")
    [ -n "$CLICK_URL" ] && HEADERS+=(-H "Click: $CLICK_URL")
    curl -sf -m 8 "${HEADERS[@]}" -d "$BODY" "$URL" >/dev/null 2>&1 || log_fail ntfy
fi

# --- Discord (no-op unless configured; send-discord.sh returns non-zero on a real send failure) ---
# Invoked via `bash`, and tested with -f rather than -x, deliberately: every file in Meta/scripts/
# is mode 100644 in the index, so a fresh clone produces non-executable scripts. An -x guard here
# would silently skip the channel on any new checkout and look exactly like "no alerts configured".
_sd="$(dirname "$0")/send-discord.sh"
if [ -f "$_sd" ]; then
    bash "$_sd" "$TITLE" "$BODY" "$PRIO" "$TAGS" "$CLICK" >/dev/null 2>&1 || log_fail discord
fi

# --- Telegram (same contract as Discord: exits 0 unconfigured, non-zero on a real send failure) ---
_st="$(dirname "$0")/send-telegram.sh"
if [ -f "$_st" ]; then
    bash "$_st" "$TITLE" "$BODY" "$PRIO" "$TAGS" "$CLICK" >/dev/null 2>&1 || log_fail telegram
fi

exit 0
