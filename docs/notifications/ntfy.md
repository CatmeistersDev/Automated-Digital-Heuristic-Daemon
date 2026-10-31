# ntfy setup

Push alerts to your phone or desktop. Simplest of the three channels — no bot, no account, no
app store account linking. **Push only:** ntfy cannot send commands back, so `/ask`, `/brief` and
friends are not available on this channel. If you want two-way, see
[discord.md](discord.md).

## 1. Pick a server

**Option A — the public server.** Nothing to install. Use `https://ntfy.sh`.

> **Read this before using the public server.** Topics are not secret and not access-controlled.
> Anyone who knows or guesses your topic name can read every alert you send and publish alerts
> into it. Your alerts contain note titles, action names and briefing summaries. Use a long random
> topic name (`openssl rand -hex 12`), not `autoadhd`, and treat it as a password. If any of that
> is uncomfortable, self-host.

**Option B — self-host.** One container, and your alerts never leave your network:

```bash
docker run -d --name ntfy -p 8090:80 -v ntfy-cache:/var/cache/ntfy \
  binwiederhier/ntfy serve
```

Then use `http://<your-host>:8090` as the URL. For anything reachable from outside your LAN, turn
on auth (`auth-file` + `auth-default-access: deny-all` in `server.yml`) and set `NTFY_TOKEN` below.

## 2. Configure

In [`docker-compose.yml`](../../docker-compose.yml):

```yaml
- NTFY_URL=https://ntfy.sh          # or http://your-host:8090
- NTFY_TOPIC=<your-long-random-topic>
```

Optional, for a server with auth enabled — set it in your shell environment or a compose
`env_file`, not committed:

```
NTFY_TOKEN=tk_xxxxxxxxxxxx
```

Leaving `NTFY_URL` empty disables the channel entirely. That is the default.

## 3. Subscribe

Install the ntfy app (Android/iOS) or open the web app, add your server, subscribe to your topic.

## 4. Test

```bash
docker compose exec autoadhd bash /vault/Meta/scripts/notify.sh \
  "Test" "hello from AutoADHD" default "white_check_mark"
```

A green-check notification should arrive. Nothing arriving is usually a topic typo or a firewall
between the container and your server.

## What you get

- **Priority** maps to ntfy's `Priority` header, so urgent alerts can override your phone's
  do-not-disturb.
- **Tags** map to ntfy's emoji vocabulary — `warning`, `rotating_light`, `white_check_mark`.
- **Click** becomes an `obsidian://open` deep link in the notification, so tapping an alert opens
  the note that caused it. Set `OBSIDIAN_VAULT` to your vault's exact name in Obsidian's vault
  switcher — a mismatch silently reopens Obsidian's last page instead of erroring, which looks
  like it worked. If your vault is a parent folder and this repo sits inside it, also set
  `OBSIDIAN_SUBPATH`.

## When it breaks

`notify.sh` is the alert channel, so it cannot alert you that alerting is broken. Failed sends
append to `Meta/notify-errors.log` instead, and `make health` surfaces recent entries. If you run
more than one channel, a dead ntfy shows up in the others.
