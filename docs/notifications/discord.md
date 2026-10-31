# Discord setup

The only channel in this port that works in both directions: alerts out, **and** slash commands
back. Two ways to configure it — pick based on whether you want commands.

| You want | Use | Effort |
|---|---|---|
| Alerts only | **Webhook** | one URL, two minutes |
| Alerts + slash commands + voice-memo upload | **Bot** | a Discord application, five minutes |

A webhook and a bot can both be configured; the webhook wins for outbound alerts.

---

## Option A — webhook (alerts only)

1. In Discord: **Server Settings → Integrations → Webhooks → New Webhook**. Pick the channel,
   **Copy Webhook URL**.
2. Give it to the container either way:

```bash
mkdir -p .secrets
echo "https://discord.com/api/webhooks/..." > .secrets/discord-webhook.txt
```

or set `DISCORD_WEBHOOK_URL` in your environment. `.secrets/` is git-ignored.

That is the whole setup. Skip to [Test](#test).

---

## Option B — bot (alerts + commands)

1. <https://discord.com/developers/applications> → **New Application** → **Bot** → **Reset Token**,
   copy it.
2. Still on the Bot page, enable **Message Content Intent** under *Privileged Gateway Intents*.
   The bot requests it at startup (`discord-bot.py:184`) and will not connect without it.
3. **OAuth2 → URL Generator**: scopes `bot` + `applications.commands`; permissions *Send Messages*,
   *Read Message History*, *Attach Files*. Open the generated URL, invite the bot to your server.
4. Get the channel ID: enable **Settings → Advanced → Developer Mode**, then right-click your
   channel → **Copy Channel ID**.
5. Get your own user ID the same way — right-click your name → **Copy User ID**.
6. Write the secrets and set the allowlist:

```bash
mkdir -p .secrets
echo "<bot-token>"   > .secrets/discord-token.txt
echo "<channel-id>"  > .secrets/discord-channel-id.txt
```

In [`docker-compose.yml`](../../docker-compose.yml):

```yaml
- DISCORD_ALLOWED_USER_ID=<your-user-id>
```

### Read this before you skip step 6

**Access fails closed.** Leave `DISCORD_ALLOWED_USER_ID` empty and the bot ignores everyone,
including you, and says so on startup. That is deliberate — an empty allowlist is not an open door.

There is one deliberate opt-out, `DISCORD_ALLOW_ANYONE=1`, which lets **any** Discord user in the
channel drive the bot. That means full vault read through the Advisor plus `/done` writes, by
anyone who can see the channel. Leave it unset unless you have thought about who is in that server.

## Commands

`/actions` · `/done` · `/ask` · `/brief` · `/focus` · `/draft` · `/research`

Dropping a voice memo into the channel as an attachment sends it through the same transcription
and extraction pipeline as the watcher folder.

---

## Test

```bash
docker compose exec autoadhd bash /vault/Meta/scripts/notify.sh \
  "Test" "hello from AutoADHD" default "white_check_mark"
```

A green-bordered embed should appear. If the bot path is configured but nothing arrives, check the
container log for a 403 — that is usually the missing Message Content Intent or a bot that was
never invited to the server.

## What you get

- **Tags and priority** pick the embed's color: red for critical, yellow for warning, green for
  success, blue for info.
- **Click targets** are included as inline code rather than a link. Discord refuses to linkify
  non-`http(s)` schemes anywhere — `embed.url` returns a hard 400 and a markdown link renders as
  literal text — so an `obsidian://` deep link cannot be tap-to-open here. Tap-and-hold to copy it
  and paste into a mobile browser's address bar; that does open the note.

## When it breaks

Failed sends append to `Meta/notify-errors.log` and `make health` surfaces recent entries —
`notify.sh` cannot alert you about its own failure.
