#!/bin/bash
# deadman-check.sh — HOST-side (Unraid) dead-man's switch for the autoadhd-brain container.
#
# WHY: every in-container alert (run-health.sh, notify fan-out) is scheduled by the very
# scheduler it watches — a dead container or wedged scheduler means TOTAL SILENCE, which is
# the one failure mode the stack couldn't see. This script runs OUTSIDE the container on the
# Unraid host and alerts when:
#   1) the container isn't running, or
#   2) the scheduler heartbeat (Meta/.scheduler-heartbeat, touched every 60s by a dedicated
#      supervisor thread in scheduler.py — NOT the job-running main loop, so a legitimate
#      2h extraction can't false-alarm) is stale beyond MAX_AGE_MIN.
#
# Alerts go to ntfy AND Discord directly with curl (no python needed on the host), throttled
# to one alert per THROTTLE_MIN so a dead container doesn't ping every 15 minutes all night.
#
# INSTALL (one-time, on the Unraid host — this cannot run inside the container it watches):
#   User Scripts plugin -> Add Script -> paste this file -> schedule: Custom "*/15 * * * *"
#   (or root crontab:  */15 * * * * bash "/path/to/your/vault/Meta/scripts/deadman-check.sh")
# NOTE: deploy the updated scheduler.py (which writes the heartbeat) BEFORE installing this,
# or it will alert immediately on the missing heartbeat file.
set -u

CONTAINER="${DEADMAN_CONTAINER:-autoadhd-brain}"
VAULT="${DEADMAN_VAULT:-/vault}"
NTFY_URL="${DEADMAN_NTFY_URL:-http://127.0.0.1:2586}"
NTFY_TOPIC="${DEADMAN_NTFY_TOPIC:-autoadhd}"
MAX_AGE_MIN="${DEADMAN_MAX_AGE_MIN:-10}"      # heartbeat is written every 60s; 10min = clearly dead
THROTTLE_MIN="${DEADMAN_THROTTLE_MIN:-60}"    # at most one alert per hour while down
STATE="/tmp/autoadhd-deadman.alerted"

fail=""
status="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo missing)"
if [ "$status" != "running" ]; then
    fail="container $CONTAINER is '$status' (not running) — the whole pipeline is down"
else
    hb="$VAULT/Meta/.scheduler-heartbeat"
    if [ ! -f "$hb" ]; then
        fail="no scheduler heartbeat file at $hb (scheduler never started, or pre-heartbeat scheduler.py is deployed)"
    elif [ -z "$(find "$hb" -mmin -"$MAX_AGE_MIN" 2>/dev/null)" ]; then
        fail="scheduler heartbeat stale >${MAX_AGE_MIN}min — container is up but the scheduler is dead/wedged"
    fi
fi

if [ -z "$fail" ]; then
    rm -f "$STATE" 2>/dev/null   # recovered: re-arm so the NEXT outage alerts immediately
    exit 0
fi

logger -t autoadhd-deadman "$fail" 2>/dev/null || true

# Throttle: skip if we already alerted within the window
if [ -f "$STATE" ] && [ -n "$(find "$STATE" -mmin -"$THROTTLE_MIN" 2>/dev/null)" ]; then
    exit 0
fi
touch "$STATE"

TITLE="🛑 AutoADHD DEAD-MAN ALERT"
BODY="$fail (checked from the Unraid host at $(date '+%Y-%m-%d %H:%M'))"

# ntfy (host-reachable; may share fate with the box but not with the container)
curl -sf -m 8 -H "Title: $TITLE" -H "Priority: urgent" -H "Tags: skull,rotating_light" -d "$BODY" \
    "${NTFY_URL%/}/${NTFY_TOPIC}" >/dev/null 2>&1 || true

# Discord via the bot REST API (same token/channel files Tier-1 uses; UA header is REQUIRED
# — the default curl UA gets Cloudflare error 1010, the same 403 that hid Tier-1 for a week)
TOKEN_FILE="$VAULT/.secrets/discord-token.txt"
CHAN_FILE="$VAULT/.secrets/discord-channel-id.txt"
if [ -f "$TOKEN_FILE" ] && [ -f "$CHAN_FILE" ]; then
    TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
    CHAN="$(tr -d '[:space:]' < "$CHAN_FILE")"
    curl -sf -m 8 -X POST "https://discord.com/api/v10/channels/${CHAN}/messages" \
        -H "Authorization: Bot ${TOKEN}" \
        -H "Content-Type: application/json" \
        -H "User-Agent: DiscordBot (https://github.com/autoadhd, 1.0)" \
        -d "{\"content\": \"[!] **${TITLE}**\\n${BODY}\", \"allowed_mentions\": {\"parse\": []}}" \
        >/dev/null 2>&1 || true
fi
exit 1
