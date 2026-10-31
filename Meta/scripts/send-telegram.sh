#!/bin/bash
# send-telegram.sh "Title" "message" [priority] [tags] [click] - post to a Telegram chat via the
# Bot API as a formatted message (bold title, severity marker, and — if a click target is given —
# an Obsidian deep link as tap-to-copy code).
# Config:
#   TELEGRAM_BOT_TOKEN env, or ${VAULT_DIR}/.secrets/telegram-token.txt   (from @BotFather)
#   TELEGRAM_CHAT_ID   env, or ${VAULT_DIR}/.secrets/telegram-chat-id.txt (your user or group id)
# No-op if either is missing.
#   tags:  same comma-separated ntfy tag vocabulary notify.sh uses (see its header) — read here
#          only to pick a severity marker, since Telegram has no embed color.
#   click: a repo-relative note path (see notify.sh's header for the OBSIDIAN_VAULT/SUBPATH/.md
#          details) — turned into an obsidian://open link. Telegram, like Discord, will not
#          linkify a non-http(s) scheme, so it is sent as <code> for tap-and-hold-to-copy rather
#          than pretending to be a tappable link.
set -uo pipefail
TITLE="${1:-AutoADHD}"; BODY="${2:-}"; PRIO="${3:-default}"; TAGS="${4:-}"; CLICK="${5:-}"
VAULT_DIR="${VAULT_DIR:-/vault}"
OBSIDIAN_VAULT="${OBSIDIAN_VAULT:-MyVault}"
OBSIDIAN_SUBPATH="${OBSIDIAN_SUBPATH:-}"

TOKEN="${TELEGRAM_BOT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$VAULT_DIR/.secrets/telegram-token.txt" ]; then
    TOKEN="$(tr -d '[:space:]' < "$VAULT_DIR/.secrets/telegram-token.txt")"
fi
CHAT_ID="${TELEGRAM_CHAT_ID:-}"
if [ -z "$CHAT_ID" ] && [ -f "$VAULT_DIR/.secrets/telegram-chat-id.txt" ]; then
    CHAT_ID="$(tr -d '[:space:]' < "$VAULT_DIR/.secrets/telegram-chat-id.txt")"
fi

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
    exit 0
fi

# NOTE: no `|| true` here — the send's exit code is this script's exit code so callers
# (notify.sh) can tell a real send failure from a no-op. Unconfigured already exited 0 above.
# TOKEN goes via env, not argv: process argv (unlike env) is visible to any local user via
# `ps aux` / /proc/*/cmdline, and this token is a live bot credential.
_ST_TOKEN="$TOKEN" python3 - "$CHAT_ID" "$TITLE" "$BODY" "$PRIO" "$TAGS" "$CLICK" \
    "$OBSIDIAN_VAULT" "$OBSIDIAN_SUBPATH" <<'PYEOF' 2>/dev/null
import sys, os, json, html, urllib.parse, urllib.request

token = os.environ["_ST_TOKEN"]
chat_id, title, body, prio, tags, click, vault, subpath = sys.argv[1:9]

PREFIX = {"urgent": "[!] ", "high": "[!] ", "5": "[!] ", "low": "[.] ", "1": "[.] "}.get(prio, "")

# Severity marker from the ntfy tag vocabulary (see notify.sh header); falls back to priority.
tagset = {t.strip() for t in tags.split(",") if t.strip()}
if tagset & {"rotating_light", "skull", "no_entry"}:
    marker = "\U0001F534"       # red circle - critical/failure
elif tagset & {"warning", "lock"}:
    marker = "\U0001F7E1"       # yellow circle - warning
elif tagset & {"white_check_mark"}:
    marker = "\U0001F7E2"       # green circle - success
elif prio in ("urgent", "high", "5"):
    marker = "\U0001F534"
elif prio in ("low", "1"):
    marker = "\U000026AA"       # white circle - low priority
else:
    marker = "\U0001F535"       # blue circle - info (default)

# parse_mode=HTML, so every interpolated value must be escaped.
lines = [f"{marker} <b>{html.escape(PREFIX + title)}</b>"]
if body:
    lines.append(html.escape(body))

if click:
    path = click.strip("/")
    if not path.endswith(".md"):
        path = path + ".md"
    full_path = f"{subpath.strip('/')}/{path}" if subpath else path
    link = ("obsidian://open?vault=" + urllib.parse.quote(vault, safe="")
            + "&file=" + urllib.parse.quote(full_path, safe="/"))
    # Telegram will not linkify a custom scheme, same limitation Discord has. <code> is the
    # honest fallback: tap-and-hold copies it, paste into a mobile browser opens the note.
    lines.append(f"\U0001F4C4 <code>{html.escape(link)}</code>")

# Telegram hard-caps a message at 4096 characters.
text = "\n\n".join(lines)[:4096]

payload = json.dumps({
    "chat_id": chat_id,
    "text": text,
    "parse_mode": "HTML",
    "disable_web_page_preview": True,
}).encode()

req = urllib.request.Request(
    f"https://api.telegram.org/bot{token}/sendMessage",
    data=payload,
    headers={"Content-Type": "application/json"},
)
urllib.request.urlopen(req, timeout=8).read()
PYEOF
