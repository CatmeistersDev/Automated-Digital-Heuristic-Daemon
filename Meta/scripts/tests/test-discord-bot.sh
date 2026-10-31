#!/bin/bash
# test-discord-bot.sh — tests discord-bot.py's vault-facing helpers (no discord.py / token needed).
# Loads the module by path (its `import discord` is inside main(), so the module imports clean) and
# exercises list_open_actions / mark_action_done / today_briefing against a fixture vault.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
BOT="$SCRIPT_DIR/discord-bot.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT

mkdir -p "$TV/Canon/Actions" "$TV/Inbox"
cat > "$TV/Canon/Actions/Test Task.md" <<'EOF'
---
type: action
name: Test Task
status: open
updated: 2026-01-01
---
# 🎯 Test Task
Do the thing.
EOF
printf -- '---\ntype: reflection\nname: Daily Briefing\n---\n# 🤖 Daily Briefing\nyour day\n' \
  > "$TV/Inbox/2026-07-01 - Daily Briefing.md"

VAULT_DIR="$TV" python3 - "$BOT" <<'PY'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("dbot", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)   # must NOT require discord.py (import is inside main())

fail = 0
def check(desc, ok):
    global fail
    print(("  ok: " if ok else "  FAIL: ") + desc)
    if not ok: fail = 1

check("list_open_actions finds the open task", "Test Task" in m.list_open_actions())
check("today_briefing returns the briefing note", "Daily Briefing" in m.today_briefing())
check("mark_action_done missing -> helpful message", m.mark_action_done("Nope").startswith("No action"))

res = m.mark_action_done("Test Task")
check("mark_action_done succeeds", res.startswith("✅"))
t = open(os.path.join(os.environ["VAULT_DIR"], "Canon", "Actions", "Test Task.md"), encoding="utf-8").read()
check("status flipped to done", "status: done" in t)
check("Evolution entry added", "## Evolution" in t and "Marked done" in t)
check("updated bumped off 2026-01-01", "updated: 2026-01-01" not in t)
sys.exit(fail)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "test-discord-bot: PASS" || { echo "test-discord-bot: FAIL"; exit 1; }
