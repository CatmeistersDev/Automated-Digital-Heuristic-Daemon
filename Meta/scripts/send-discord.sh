#!/bin/bash
# send-discord.sh "Title" "message" [priority] [tags] [click] - post to a Discord channel as
# a color-coded embed (title, description, severity color, and — if a click target is given —
# a clickable Obsidian deep link) instead of plain text.
# Config (either works; webhook wins if both are set):
#   Webhook: DISCORD_WEBHOOK_URL env, or ${VAULT_DIR}/.secrets/discord-webhook.txt
#   Bot:     DISCORD_BOT_TOKEN env (or .secrets/discord-token.txt, already needed for the Tier 2
#            bot) + DISCORD_NOTIFY_CHANNEL_ID env (or .secrets/discord-channel-id.txt)
# No-op if neither is configured.
#   tags:  same comma-separated ntfy tag vocabulary notify.sh uses (see its header) — read here
#          only to pick an embed color (red=critical, yellow=warning, green=success, else blue).
#   click: a repo-relative note path (see notify.sh's header for the OBSIDIAN_VAULT/SUBPATH/.md
#          details) — turned into an obsidian://open link and added to the description as inline
#          code (copy + paste into a mobile browser's address bar to open it). Discord will NOT
#          linkify a non-http(s) scheme anywhere — confirmed live 2026-07-12: embed.url 400s
#          (URL_TYPE_INVALID_SCHEME) and a markdown link in the description just renders as
#          literal, unclickable text — so this can't be tap-to-open.
set -uo pipefail
TITLE="${1:-AutoADHD}"; BODY="${2:-}"; PRIO="${3:-default}"; TAGS="${4:-}"; CLICK="${5:-}"
VAULT_DIR="${VAULT_DIR:-/vault}"
OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-MyVault}"
OBSIDIAN_SUBPATH="${OBSIDIAN_SUBPATH:-}"

URL="${DISCORD_WEBHOOK_URL:-}"
if [ -z "$URL" ] && [ -f "$VAULT_DIR/.secrets/discord-webhook.txt" ]; then
    URL="$(tr -d '[:space:]' < "$VAULT_DIR/.secrets/discord-webhook.txt")"
fi

TOKEN="${DISCORD_BOT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$VAULT_DIR/.secrets/discord-token.txt" ]; then
    TOKEN="$(tr -d '[:space:]' < "$VAULT_DIR/.secrets/discord-token.txt")"
fi
CHANNEL_ID="${DISCORD_NOTIFY_CHANNEL_ID:-}"
if [ -z "$CHANNEL_ID" ] && [ -f "$VAULT_DIR/.secrets/discord-channel-id.txt" ]; then
    CHANNEL_ID="$(tr -d '[:space:]' < "$VAULT_DIR/.secrets/discord-channel-id.txt")"
fi

if [ -z "$URL" ] && { [ -z "$TOKEN" ] || [ -z "$CHANNEL_ID" ]; }; then
    exit 0
fi

# Build the embed payload once, shared by both send paths below.
PAYLOAD="$(python3 - "$TITLE" "$BODY" "$PRIO" "$TAGS" "$CLICK" "$OBSIDIAN_VAULT" "$OBSIDIAN_SUBPATH" <<'PYEOF' 2>/dev/null
import sys, json, urllib.parse
title, body, prio, tags, click, vault, subpath = sys.argv[1:8]

PREFIX = {"urgent": "[!] ", "high": "[!] ", "5": "[!] ", "low": "[.] ", "1": "[.] "}.get(prio, "")

# Severity color from the ntfy tag vocabulary (see notify.sh header); falls back to priority.
tagset = {t.strip() for t in tags.split(",") if t.strip()}
if tagset & {"rotating_light", "skull", "no_entry"}:
    color = 0xE74C3C   # red — critical/failure
elif tagset & {"warning", "lock"}:
    color = 0xF1C40F   # yellow — warning
elif tagset & {"white_check_mark"}:
    color = 0x2ECC71   # green — success
elif prio in ("urgent", "high", "5"):
    color = 0xE74C3C
elif prio in ("low", "1"):
    color = 0x95A5A6   # grey — low priority
else:
    color = 0x3498DB   # blue — info (default)

embed = {"title": (PREFIX + title)[:256], "description": body[:4000], "color": color}

if click:
    path = click.strip("/")
    if not path.endswith(".md"):
        path = path + ".md"
    full_path = f"{subpath.strip('/')}/{path}" if subpath else path
    link = f"obsidian://open?vault={urllib.parse.quote(vault, safe='')}&file={urllib.parse.quote(full_path, safe='/')}"
    # Discord will not linkify a non-http(s) scheme ANYWHERE — confirmed live 2026-07-12:
    # embed.url gets a hard 400 (URL_TYPE_INVALID_SCHEME), and a markdown [text](obsidian://...)
    # link in the description just renders as literal, unclickable bracket/paren text. There is
    # no way to make this tap-to-open on Discord. Inline-code is the honest fallback: it doesn't
    # pretend to be a link, but tap-and-hold-to-copy + paste into a mobile browser's address bar
    # DOES trigger the app (same copy/paste-over-automation approach this project already uses
    # for the Operator's drafts).
    embed["description"] = (embed["description"] + f"\n\n📄 `{link}`")[:4000]

print(json.dumps({"embeds": [embed], "allowed_mentions": {"parse": []}}))
PYEOF
)"

# NOTE: no `|| true` here — the send's exit code is this script's exit code so callers
# (notify.sh) can tell a real send failure from a no-op. Unconfigured already exited 0 above.
if [ -n "$URL" ]; then
    python3 - "$URL" "$PAYLOAD" <<'PYEOF' 2>/dev/null
import sys, urllib.request
url, payload = sys.argv[1], sys.argv[2]
data = payload.encode()
# Discord/Cloudflare rejects the default Python-urllib User-Agent with HTTP 403 (error 1010) —
# a descriptive UA is REQUIRED by the Discord API. Without this, Tier-1 posts silently fail.
req = urllib.request.Request(url, data=data, headers={
    "Content-Type": "application/json",
    "User-Agent": "DiscordBot (https://github.com/autoadhd, 1.0)",
})
urllib.request.urlopen(req, timeout=8).read()
PYEOF
else
    # TOKEN goes via env, not argv: process argv (unlike env) is visible to any local user
    # via `ps aux` / /proc/*/cmdline, and this token is a live bot credential.
    _SD_TOKEN="$TOKEN" python3 - "$CHANNEL_ID" "$PAYLOAD" <<'PYEOF' 2>/dev/null
import sys, os, urllib.request
token = os.environ["_SD_TOKEN"]
channel_id, payload = sys.argv[1], sys.argv[2]
url = f"https://discord.com/api/v10/channels/{channel_id}/messages"
data = payload.encode()
req = urllib.request.Request(url, data=data, headers={
    "Content-Type": "application/json",
    "Authorization": f"Bot {token}",
    # REQUIRED by the Discord API — the default urllib UA gets a 403 (Cloudflare error 1010).
    "User-Agent": "DiscordBot (https://github.com/autoadhd, 1.0)",
})
urllib.request.urlopen(req, timeout=8).read()
PYEOF
fi
