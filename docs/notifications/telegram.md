# Telegram setup

Alerts to Telegram via the Bot API. No server to run and no public topic to guard — messages go to
one chat that only you (or your group) can see.

**Scope, stated plainly:** this port sends alerts *out* to Telegram. It does **not** implement
Telegram slash commands or voice-memo upload. Those exist only on Discord here — see
[discord.md](discord.md). The upstream project this port is derived from
([uetzel/AutoADHD](https://github.com/uetzel/AutoADHD)) does ship a full Telegram bot, so if you
want two-way Telegram, that is the place to start rather than from scratch.

## 1. Create the bot

1. Open Telegram, message [@BotFather](https://t.me/BotFather).
2. Send `/newbot`, pick a display name and a username ending in `bot`.
3. BotFather replies with a token like `123456789:AAH...`. That token is a live credential — treat
   it like a password.

## 2. Find your chat ID

Send your new bot any message first (a bot cannot start a conversation with you), then:

```bash
curl -s "https://api.telegram.org/bot<token>/getUpdates" | grep -o '"chat":{"id":[-0-9]*'
```

- A **direct message** gives a positive ID — that is your user ID.
- A **group** gives a negative ID (often starting `-100`). Add the bot to the group first, and if
  the group has privacy mode on, either turn it off via BotFather (`/setprivacy`) or make the bot
  an admin, otherwise it will not see the message and `getUpdates` stays empty.

## 3. Configure

In [`docker-compose.yml`](../../docker-compose.yml):

```yaml
- TELEGRAM_BOT_TOKEN=123456789:AAH...
- TELEGRAM_CHAT_ID=<the id from step 2>
```

Or keep them out of the compose file entirely:

```bash
mkdir -p .secrets
echo "123456789:AAH..." > .secrets/telegram-token.txt
echo "<chat-id>"        > .secrets/telegram-chat-id.txt
```

`.secrets/` is git-ignored. **Both** values must be present or the channel stays off — that is the
default, and an unconfigured channel is a silent no-op, not an error.

## 4. Test

```bash
docker compose exec autoadhd bash /vault/Meta/scripts/notify.sh \
  "Test" "hello from AutoADHD" default "white_check_mark"
```

A message with a green circle and a bold title should arrive. If nothing does, run the `curl` from
step 2 again — an empty `result` array means the bot has never received a message from that chat,
which is the usual cause.

## What you get

- **Priority and tags** become a colored circle before the title: red for critical, yellow for
  warning, green for success, blue for info, white for low priority. Telegram has no embed color,
  so the marker is the signal.
- **Click targets** are sent as `<code>`, not as a link. Telegram will not linkify a custom URL
  scheme, so an `obsidian://` deep link cannot be tapped directly — tap and hold to copy, then
  paste into a mobile browser's address bar to open the note.
- Messages are capped at Telegram's 4096-character limit.

## When it breaks

Failed sends append to `Meta/notify-errors.log` and `make health` surfaces recent entries —
`notify.sh` cannot alert you about its own failure. If you run more than one channel, a dead
Telegram shows up in the others.
