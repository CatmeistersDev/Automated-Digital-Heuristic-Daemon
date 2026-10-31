---
type: meta
name: Discord Integration Plan
created: 2026-06-24
updated: 2026-07-26
source: ai-generated
status: implemented
---

# Discord Integration Plan

Why Discord exists in this build and how the two tiers fit together. **Setup steps live in
[`docs/notifications/discord.md`](../docs/notifications/discord.md)** — this file is the design,
not the runbook, and it carries template values only: every token, channel ID and user ID below is
a placeholder you replace with your own.

Discord replaces upstream's Telegram. Both tiers run inside the container, kept alive by
`scheduler.py`, and neither one adds a pipeline — Discord is a new front door and back door onto
the pipeline that already exists.

## Tier 1 — outbound alerts

`Meta/scripts/send-discord.sh "Title" "body" [priority] [tags] [click]`, fanned out from
`notify.sh` alongside ntfy and Telegram. Two credential paths, checked in this order:

| Path | Config | Notes |
|---|---|---|
| Webhook | `DISCORD_WEBHOOK_URL` or `.secrets/discord-webhook.txt` | Simplest. Alerts only — a webhook cannot receive anything. |
| REST API | `DISCORD_BOT_TOKEN` + `DISCORD_NOTIFY_CHANNEL_ID` (or `.secrets/discord-token.txt` + `.secrets/discord-channel-id.txt`) | `POST https://discord.com/api/v10/channels/{id}/messages` with `Authorization: Bot {token}`. |

The REST path exists because a bot application does not issue webhooks — webhooks are a per-channel
feature (channel → Integrations → Webhooks), so a setup that starts from the Developer Portal has a
bot token and no webhook. Reusing the bot token means **one credential set covers both tiers**. If
a webhook is configured it wins, since it is the narrower credential.

## Tier 2 — two-way bot

`Meta/scripts/discord-bot.py`, a `discord.py` gateway daemon. `scheduler.py` starts it only when a
token exists, and logs a skip otherwise, so a deployment without Discord is silent rather than
broken.

- **Inbound voice:** an audio attachment is saved to the voice-drop folder
  (`DISCORD_VOICE_DROP`, default `Inbox/Voice/_drop`) and the normal `process-voice-memo.sh`
  pipeline picks it up. The bot acknowledges immediately; the memo lands like any other.
- **Inbound text:** routed to the Advisor and answered inline.
- **Slash commands:** `/actions` `/done <action>` `/ask <q>` `/brief` `/focus` `/draft` `/research`.
  See `docs/notifications/discord.md` for what each one does.

### Access control fails closed — read this part

With `DISCORD_ALLOWED_USER_ID` unset the bot **ignores everyone** and prints a `SECURITY:` warning
at startup (`discord-bot.py:189-196`). Set it to your own Discord user ID; that is the intended
configuration, not a hardening extra. Answering everyone is an explicit opt-in via
`DISCORD_ALLOW_ANYONE=1`, and you should not set it: the bot exposes full vault read through the
Advisor plus `/done` writes. Both variables are env-only, so changing them needs a container
**recreate**, not a restart.

## What is wired

- `discord.py` is a Dockerfile dependency, not a hot-patch — a `compose up` recreate cannot lose it.
- `notify.sh` fans out to Tier 1 (alongside ntfy and Telegram); each channel is a no-op unless its
  own config is set.
- Behavioral test: `Meta/scripts/tests/test-discord-bot.sh`, run by `ci-check.sh`.
- The Operator stays human-in-the-loop regardless of channel: it writes drafts for a person to send
  and has no send path of its own.

## Not built

Proactive posts *by the bot* — briefings currently reach Discord as a Tier-1 fan-out from
`notify.sh`, not as something the bot decides to send. The natural next step if you want it.
