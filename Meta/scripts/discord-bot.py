#!/usr/bin/env python3
"""
discord-bot.py - Two-way Discord interface to the AutoADHD vault (Tier 2).

Replaces upstream's Telegram vault-bot.py; wires into our LOCAL stack:
  - voice attachment -> dropped into the voice-drop folder -> existing pipeline
  - text / slash commands -> Advisor (advisor-server on :8723) or quick vault actions

Setup (see Meta/Discord-Integration-Plan.md):
  pip install discord.py                 (in the container; also in the Dockerfile)
  .secrets/discord-token.txt             (or env DISCORD_BOT_TOKEN)
  env: DISCORD_ALLOWED_USER_ID, DISCORD_GUILD_ID, DISCORD_VOICE_DROP (default Inbox/Voice/_drop)
  Run: scheduler.py starts it automatically once a token is present (else it's a no-op).

Design note: `import discord` happens INSIDE main() on purpose, so this module's vault-facing
helpers (list_open_actions / mark_action_done / today_briefing) are importable + testable without
discord.py installed. See Meta/scripts/tests/test-discord-bot.sh.
"""
import os, sys, asyncio, subprocess, datetime, pathlib, re, glob

VAULT_DIR = os.environ.get("VAULT_DIR", "/vault")
# Scripts are CODE, baked into the image at /app (2026-07-09 split) — independent of
# VAULT_DIR, which is DATA-only. Self-locate like every other baked script (dirname
# $0/__file__) instead of assuming co-location with the vault; the old
# os.path.join(VAULT_DIR, "Meta", "scripts") resolved to /vault/Meta/scripts, which
# hasn't existed since the split — silently broke /brief, /focus, /draft, /research.
SCRIPTS = os.path.dirname(os.path.abspath(__file__))
VOICE_DROP = os.environ.get("DISCORD_VOICE_DROP", os.path.join(VAULT_DIR, "Inbox", "Voice", "_drop"))
ALLOWED_USER = os.environ.get("DISCORD_ALLOWED_USER_ID", "")
# Fail CLOSED: with no allowlist configured the bot must NOT answer to everyone (it exposes
# full vault read via the Advisor plus /done writes). Responding to all is now an explicit
# opt-in, not the silent default. Set DISCORD_ALLOWED_USER_ID (recommended) or, to keep the
# old open behaviour deliberately, DISCORD_ALLOW_ANYONE=1.
ALLOW_ANYONE = os.environ.get("DISCORD_ALLOW_ANYONE", "") == "1"
GUILD_ID = os.environ.get("DISCORD_GUILD_ID", "")
AUDIO_EXT = (".ogg", ".m4a", ".mp3", ".wav", ".3gp", ".amr", ".opus", ".aac")
DISCORD_LIMIT = 1900  # Discord hard limit is 2000; leave headroom


def _load_token():
    tok = os.environ.get("DISCORD_BOT_TOKEN", "")
    if not tok:
        p = os.path.join(VAULT_DIR, ".secrets", "discord-token.txt")
        if os.path.isfile(p):
            tok = open(p).read().strip()
    return tok


def _chunks(text, n=DISCORD_LIMIT):
    """Split a reply into Discord-sized pieces (Discord rejects messages > 2000 chars)."""
    text = (text or "").strip() or "(no response)"
    return [text[i:i + n] for i in range(0, len(text), n)]


# Set these to match your own Obsidian setup. If Obsidian sees a PARENT folder as the vault and
# this repo is a subfolder inside it (a nested-vault layout), set OBSIDIAN_SUBPATH to that
# subfolder name too. Get OBSIDIAN_VAULT exactly right (case/spacing) — a mismatch doesn't error,
# it just silently reopens Obsidian's last page instead of the intended note.
OBSIDIAN_VAULT = os.environ.get("OBSIDIAN_VAULT", "MyVault")
OBSIDIAN_SUBPATH = os.environ.get("OBSIDIAN_SUBPATH", "")


def obsidian_link(rel_path: str) -> str:
    """Inline-code obsidian://open URI for a note relative to this repo (same scheme/vault/subpath
    as notify.sh/send-discord.sh). NOT a markdown [text](url) link: Discord doesn't linkify
    non-http(s) schemes anywhere, so this is copy-paste-into-a-browser, not tap-to-open."""
    import urllib.parse
    path = rel_path.strip("/")
    if not path.endswith(".md"):
        path += ".md"
    full_path = f"{OBSIDIAN_SUBPATH.strip('/')}/{path}" if OBSIDIAN_SUBPATH else path
    encoded = urllib.parse.quote(full_path, safe="/")
    vault_enc = urllib.parse.quote(OBSIDIAN_VAULT, safe="")
    return f"`obsidian://open?vault={vault_enc}&file={encoded}`"


def run_advisor(query: str) -> str:
    """Query the local Advisor via advisor-server.py's OpenAI-compatible endpoint
    (POST /v1/chat/completions, model 'autoadhd-advisor')."""
    import json, urllib.request
    url = os.environ.get("ADVISOR_URL", "http://localhost:8723/v1/chat/completions")
    payload = json.dumps({
        "model": "autoadhd-advisor",
        "messages": [{"role": "user", "content": query}],
        "stream": False,
    }).encode()
    headers = {"Content-Type": "application/json"}
    # Send the bearer token when the advisor is locked down (ADVISOR_TOKEN set). The bot runs in
    # the same container as advisor-server.py, so it shares the env and needs no separate config.
    _atok = os.environ.get("ADVISOR_TOKEN", "")
    if _atok:
        headers["Authorization"] = f"Bearer {_atok}"
    try:
        req = urllib.request.Request(url, data=payload, headers=headers)
        resp = json.loads(urllib.request.urlopen(req, timeout=180).read())
        return (resp["choices"][0]["message"]["content"] or "").strip() or "(no response)"
    except Exception as e:
        return f"advisor unavailable ({e}). Is advisor-server.py running on port 8723?"


def list_open_actions(limit: int = 15) -> str:
    d = pathlib.Path(VAULT_DIR, "Canon", "Actions")
    rows = []
    for f in sorted(d.glob("*.md")):
        txt = f.read_text(encoding="utf-8", errors="replace")
        if "status: open" in txt or "status: in-progress" in txt:
            rows.append("- " + f.stem)
    return "\n".join(rows[:limit]) or "No open actions."


def today_briefing() -> str:
    """Return the newest Daily Briefing note; generate one if none exists yet."""
    def newest():
        # Meta/briefings/ is the home since 2026-07-19 (Track A3); Inbox kept as
        # fallback for any pre-move stragglers.
        c = sorted(glob.glob(os.path.join(VAULT_DIR, "Meta", "briefings", "*Daily Briefing*.md"))
                   or glob.glob(os.path.join(VAULT_DIR, "Inbox", "*Daily Briefing*.md")))
        return c[-1] if c else None
    p = newest()
    if not p:
        try:
            subprocess.run(["/bin/bash", os.path.join(SCRIPTS, "daily-briefing.sh")],
                           cwd=VAULT_DIR, timeout=120,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            p = newest()
        except Exception:
            pass
    if not p:
        return "No briefing available."
    return pathlib.Path(p).read_text(encoding="utf-8", errors="replace")


def mark_action_done(name: str) -> str:
    """Flip an action to status:done, bump `updated`, and add an ## Evolution entry
    (Actions are a living type — see .claude/skills/vault-writer). Commits best-effort."""
    # Sanitize: the name comes straight from a Discord user. Reject path separators / ".."
    # so "/done ../../Thinking/X" can't traverse out of Canon/Actions and rewrite an
    # arbitrary vault note (it flips status + auto-commits).
    if "/" in name or "\\" in name or ".." in name or name.strip() in ("", "."):
        return "Invalid action name (no path separators)."
    f = pathlib.Path(VAULT_DIR, "Canon", "Actions", f"{name}.md")
    actions_dir = pathlib.Path(VAULT_DIR, "Canon", "Actions").resolve()
    try:
        f.resolve().relative_to(actions_dir)   # defense-in-depth: must stay inside Actions/
    except ValueError:
        return "Invalid action name."
    if not f.exists():
        return f"No action named '{name}'. Try /actions for the list."
    t = f.read_text(encoding="utf-8")
    today = datetime.date.today().isoformat()
    if re.search(r"^status:", t, flags=re.M):
        t = re.sub(r"^status: .*$", "status: done", t, count=1, flags=re.M)
    if re.search(r"^updated:", t, flags=re.M):
        t = re.sub(r"^updated: .*$", f"updated: {today}", t, count=1, flags=re.M)
    entry = f"**{today}** — Marked done · human (via Discord)\nCompleted and closed from the Discord /done command.\n"
    if "## Evolution" in t:
        t = t.replace("## Evolution\n", f"## Evolution\n\n{entry}\n", 1)
    else:
        t = t.rstrip() + f"\n\n## Evolution\n\n{entry}\n"
    f.write_text(t, encoding="utf-8")
    try:
        subprocess.run(["git", "-C", VAULT_DIR, "add", str(f)], timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["git", "-C", VAULT_DIR, "commit", "-q", "-m", f"[Discord] mark done: {name}"],
                       timeout=15, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass
    return f"✅ Marked '{name}' done (status:done + Evolution entry)."


def main():
    token = _load_token()
    if not token:
        print("No Discord token (.secrets/discord-token.txt or DISCORD_BOT_TOKEN). Exiting.", file=sys.stderr)
        return 0
    try:
        import discord
        from discord import app_commands
    except ImportError:
        print("discord.py not installed: pip install discord.py", file=sys.stderr)
        return 1

    intents = discord.Intents.default()
    intents.message_content = True
    client = discord.Client(intents=intents)
    tree = app_commands.CommandTree(client)

    def allowed(user_id) -> bool:
        if ALLOWED_USER:
            return str(user_id) == str(ALLOWED_USER)
        return ALLOW_ANYONE   # no allowlist -> respond only if explicitly opted in

    if not ALLOWED_USER and not ALLOW_ANYONE:
        print("SECURITY: DISCORD_ALLOWED_USER_ID is unset — the bot will IGNORE all users "
              "until you set it (recommended), or set DISCORD_ALLOW_ANYONE=1 to deliberately "
              "allow everyone. See Meta/Discord-Integration-Plan.md.", file=sys.stderr)

    async def _reply(target, text):
        for c in _chunks(text):
            await target(c)

    @client.event
    async def on_ready():
        try:
            await tree.sync()
        except Exception:
            pass
        print(f"discord-bot online as {client.user}")

    @client.event
    async def on_message(msg):
        if msg.author == client.user or not allowed(msg.author.id):
            return
        for att in msg.attachments:
            if att.filename.lower().endswith(AUDIO_EXT):
                os.makedirs(VOICE_DROP, exist_ok=True)
                stamp = datetime.datetime.now().strftime("%m-%d-%y-%H.%M")
                safe_name = os.path.basename(att.filename)   # strip any path from the upload name
                dest = os.path.join(VOICE_DROP, f"discord_{stamp}_{safe_name}")
                await att.save(dest)
                await msg.channel.send(f"Got it — processing `{att.filename}`. I'll post when it's extracted.")
                return
        if msg.content.strip():
            # asyncio.to_thread: run_advisor blocks up to 180s (local model latency is
            # 1-2 min) — run synchronously it stalls the ENTIRE gateway event loop
            # (heartbeat-blocked warnings, unresponsive commands, missed voice uploads)
            # for the whole reply. Same for every helper below that does I/O.
            await _reply(msg.channel.send, await asyncio.to_thread(run_advisor, msg.content.strip()))

    @tree.command(name="actions", description="List open actions")
    async def _actions(interaction):
        if not allowed(interaction.user.id):
            return
        await interaction.response.defer()
        await interaction.followup.send(await asyncio.to_thread(list_open_actions))

    @tree.command(name="done", description="Mark an action completed")
    async def _done(interaction, action: str):
        if not allowed(interaction.user.id):
            return
        # defer: mark_action_done runs two git subprocesses (up to 30s) — over the 3s
        # initial-response window on a slow array, and it must not block the loop.
        await interaction.response.defer()
        await interaction.followup.send(await asyncio.to_thread(mark_action_done, action))

    @tree.command(name="ask", description="Ask the advisor")
    async def _ask(interaction, question: str):
        if not allowed(interaction.user.id):
            return
        await interaction.response.defer()
        await _reply(interaction.followup.send, await asyncio.to_thread(run_advisor, question))

    @tree.command(name="brief", description="Post today's briefing")
    async def _brief(interaction):
        if not allowed(interaction.user.id):
            return
        await interaction.response.defer()
        await _reply(interaction.followup.send, await asyncio.to_thread(today_briefing))

    # /focus /draft /research were added on the live vault 2026-07-08 and merged back here
    # 2026-07-09; their subprocess calls run via asyncio.to_thread like everything above
    # (a 2-5 min agent run must not stall the gateway event loop).
    @tree.command(name="focus", description="Get your next step for an action (runs Orchestrator)")
    async def _focus(interaction, action: str):
        if not allowed(interaction.user.id):
            return
        await interaction.response.defer()
        try:
            r = await asyncio.to_thread(
                subprocess.run, ["/bin/bash", os.path.join(SCRIPTS, "run-orchestrator.sh"), action],
                cwd=VAULT_DIR, capture_output=True, text=True, timeout=120)
            if r.returncode != 0:
                await _reply(interaction.followup.send, f"❌ Failed to run Orchestrator: {r.stderr.strip() or r.stdout.strip()}")
                return

            import json
            for line in r.stdout.splitlines():
                if line.strip().startswith("{") and '"next"' in line:
                    try:
                        data = json.loads(line.strip())
                        nxt = data.get("next")
                        status = data.get("status")
                        total = data.get("total", 0)
                        done = data.get("done", 0)
                        path = data.get("path", "")

                        if status == "complete":
                            reply = f"✅ **{data.get('name')}** is complete ({done}/{total} steps)."
                        elif nxt:
                            reply = f"▶️ **Next step for {data.get('name')}:**\n{nxt}\n\n_Progress: {done}/{total} done._"
                        else:
                            reply = f"No sub-steps found for **{data.get('name')}**. Run the Task-Enricher!"
                        if path:
                            reply += f"\n📄 {obsidian_link(path)}"

                        await _reply(interaction.followup.send, reply)
                        return
                    except Exception:
                        pass
            await _reply(interaction.followup.send, "Orchestrator ran, but couldn't parse the next step.")
        except Exception as e:
            await _reply(interaction.followup.send, f"Error: {e}")

    @tree.command(name="draft", description="Draft a deliverable for an action using the Operator")
    async def _draft(interaction, action: str):
        if not allowed(interaction.user.id):
            return
        await interaction.response.defer()
        try:
            r = await asyncio.to_thread(
                subprocess.run, ["/bin/bash", os.path.join(SCRIPTS, "run-operator.sh"), action],
                cwd=VAULT_DIR, capture_output=True, text=True, timeout=240)
            if r.returncode != 0:
                await _reply(interaction.followup.send, f"❌ Failed to run Operator: {r.stderr.strip() or r.stdout.strip()}")
            else:
                out_line = next((line for line in r.stdout.splitlines() if "Proposed operation queued" in line), "")
                op_path = out_line.rsplit("): ", 1)[-1].strip() if "): " in out_line else ""
                if out_line:
                    reply = f"✅ Draft complete! {out_line}"
                    reply += f"\n📄 {obsidian_link(op_path)}" if op_path else "\nOpen Obsidian (Meta/operations/pending/) to review and act on it."
                else:
                    reply = "✅ Operator finished."
                await _reply(interaction.followup.send, reply)
        except Exception as e:
            await _reply(interaction.followup.send, f"Error: {e}")

    @tree.command(name="research", description="Run the Researcher agent on a specific topic")
    async def _research(interaction, topic: str):
        if not allowed(interaction.user.id):
            return
        await interaction.response.defer()
        try:
            r = await asyncio.to_thread(
                subprocess.run, ["/bin/bash", os.path.join(SCRIPTS, "run-researcher.sh"), topic],
                cwd=VAULT_DIR, capture_output=True, text=True, timeout=300)
            if r.returncode != 0:
                await _reply(interaction.followup.send, f"❌ Failed to run Researcher: {r.stderr.strip() or r.stdout.strip()}")
            else:
                out_line = next((line for line in r.stdout.splitlines() if "Research written" in line), "")
                reply = f"✅ Synthesis complete! {out_line}" if out_line else "✅ Researcher finished."
                await _reply(interaction.followup.send, reply)
        except Exception as e:
            await _reply(interaction.followup.send, f"Error: {e}")

    client.run(token)
    return 0


if __name__ == "__main__":
    sys.exit(main())
