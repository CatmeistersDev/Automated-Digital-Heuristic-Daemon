#!/bin/bash
# daily-briefing.sh (LOCAL lean) — deterministic daily digest. No LLM, no Telegram/email.
# Writes Meta/briefings/<date> - Daily Briefing.md from open actions + recent notes.
# (Moved out of Inbox 2026-07-19, Track A3: briefings are derived views, not capture.)
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

VAULT_DIR="$VAULT_DIR" python3 - <<'PY'
import os, datetime, json
vault = os.environ["VAULT_DIR"]
_override = os.environ.get("BRIEFING_DATE")  # test hook only; unset in production
today = datetime.date.fromisoformat(_override) if _override else datetime.date.today()
date = today.isoformat()
dayname = today.strftime("%A")
cutoff = (today - datetime.timedelta(days=1)).isoformat()

def fm(path):
    d = {}
    try:
        t = open(path, encoding="utf-8", errors="replace").read()
    except Exception:
        return d
    if t.startswith("---"):
        end = t.find("\n---", 3)
        seg = t[3:end] if end != -1 else ""
        for line in seg.splitlines():
            if ":" in line and not line.strip().startswith("-"):
                k, v = line.split(":", 1)
                d[k.strip()] = v.strip().strip('"').strip("'")
    return d

EMOJI = {"person":"👤","action":"🎯","event":"📅","reflection":"💭","belief":"🪨",
         "decision":"⚖️","concept":"💡","project":"📁","place":"📍","organization":"🏢"}

# --- Build today's action snapshot (ALL actions, any status -- needed to detect
# --- transitions like open->done, not just today's open list) ---
ACTIVE = ("open", "in-progress")
snapshot = {}  # name -> {status, priority, due}
adir = os.path.join(vault, "Canon", "Actions")
if os.path.isdir(adir):
    for f in sorted(os.listdir(adir)):
        if not f.endswith(".md"):
            continue
        d = fm(os.path.join(adir, f))
        if d.get("type") != "action":
            continue
        snapshot[f[:-3]] = {
            "status": d.get("status", "open"),
            "priority": d.get("priority", "medium"),
            "due": d.get("due", ""),
        }
actions = [(v["priority"], v["due"], n) for n, v in snapshot.items() if v["status"] in ACTIVE]
prio = {"high": 0, "medium": 1, "low": 2}
actions.sort(key=lambda a: (prio.get(a[0], 1), a[1] or "zzzz"))

# --- Diff against yesterday's snapshot (field-level: status/priority/due per action) ---
# 2026-07-23: replaces the old "repeat today's top 12" behavior, which produced
# near-identical briefings day after day since the sorted top-12 rarely reshuffles.
snap_path = os.path.join(vault, "Meta", ".briefing-actions-snapshot.json")
prev, prev_date = {}, None
try:
    with open(snap_path, encoding="utf-8") as fh:
        saved = json.load(fh)
    prev, prev_date = saved.get("actions", {}), saved.get("date")
except Exception:
    pass

resolved, changed, removed = [], [], []
unchanged_count = 0
for name, cur in snapshot.items():
    if name not in prev:
        continue  # brand new action -- covered by "What's New" below, not a "change"
    old = prev[name]
    was_active = old.get("status", "open") in ACTIVE
    is_active = cur["status"] in ACTIVE
    if was_active and not is_active:
        resolved.append((name, cur["status"]))
        continue
    if not is_active:
        continue  # already inactive yesterday, still inactive -- nothing to report
    deltas = []
    if cur["priority"] != old.get("priority", "medium"):
        deltas.append(f'priority {old.get("priority", "medium")} → {cur["priority"]}')
    if cur["due"] != old.get("due", ""):
        if not old.get("due"):
            deltas.append(f'due date set to {cur["due"]}')
        elif not cur["due"]:
            deltas.append("due date cleared")
        else:
            deltas.append(f'due date {old["due"]} → {cur["due"]}')
    else:
        was_overdue = bool(old.get("due")) and prev_date and old["due"] < prev_date
        is_overdue = bool(cur["due"]) and cur["due"] < date
        if is_overdue and not was_overdue:
            deltas.append(f'now overdue (due {cur["due"]})')
    if deltas:
        changed.append((name, deltas))
    else:
        unchanged_count += 1
for name in prev:
    if name not in snapshot and prev[name].get("status", "open") in ACTIVE:
        removed.append(name)  # was open yesterday, its note is just gone today

# Persist today's snapshot for tomorrow's diff (after computing deltas above, not before).
os.makedirs(os.path.dirname(snap_path), exist_ok=True)
tmp_path = snap_path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as fh:
    json.dump({"date": date, "actions": snapshot}, fh)
os.replace(tmp_path, snap_path)

# --- What's new (created/extracted in last 24h) ---
new = []
for sub in ("Canon", "Thinking"):
    base = os.path.join(vault, sub)
    if not os.path.isdir(base):
        continue
    for root, _, files in os.walk(base):
        for f in files:
            if not f.endswith(".md"):
                continue
            d = fm(os.path.join(root, f))
            created = d.get("created") or d.get("source_date", "")[:10]
            if created and created >= cutoff:
                new.append((created, EMOJI.get(d.get("type", ""), "📝"), f[:-3]))
new.sort(reverse=True)

# --- Recent voice memos processed (last 24h) ---
voices = []
vdir = os.path.join(vault, "Inbox", "Voice")
if os.path.isdir(vdir):
    for f in sorted(os.listdir(vdir)):
        if not f.endswith(".md"):
            continue
        d = fm(os.path.join(vdir, f))
        sd = d.get("source_date", "")[:10] or d.get("recorded", "")[:10]
        if sd and sd >= cutoff:
            voices.append(f[:-3])

L = ["---", "type: briefing", f"date: {date}", "source: ai-generated", "---", "",
     f"# ☀️ Daily Briefing — {dayname}, {date}", ""]

n_changes = len(resolved) + len(changed) + len(removed)
if not prev:
    L.append(f"## \U0001F3AF Open Actions — establishing a baseline")
    L.append("")
    L.append("First run with change-tracking — no prior snapshot to diff against, so "
              "today's top 12 by priority/due are shown in full. Tomorrow's briefing will "
              "only report what actually changed.")
    L.append("")
    if actions:
        ic = {"high": "\U0001F534", "medium": "\U0001F7E1", "low": "⚪"}
        for p, due, n in actions[:12]:
            ico = ic.get(p, "\U0001F7E1")
            due_str = f" — due {due}" if due else ""
            L.append(f"- {ico} [[{n}]]{due_str}")
    else:
        L.append("Nothing open. Enjoy the calm.")
elif n_changes == 0:
    L.append(f"## \U0001F3AF Open Actions — no change since yesterday")
    L.append("")
    L.append(f"{unchanged_count} open action{'s' if unchanged_count != 1 else ''} unchanged "
              f"({len(actions)} total open — see `Meta/bases/Actions.base` for the full list).")
else:
    L.append(f"## \U0001F3AF Open Actions — {n_changes} change{'s' if n_changes != 1 else ''} since yesterday")
    L.append("")
    for name, new_status in resolved:
        mark = "✅" if new_status == "done" else "\U0001F5D1️"
        L.append(f"- {mark} [[{name}]] — marked {new_status}")
    for name, deltas in changed:
        L.append(f"- \U0001F53A [[{name}]] — {', '.join(deltas)}")
    for name in removed:
        L.append(f"- ❓ [[{name}]] — was open yesterday, note no longer found "
                  f"(deleted, renamed, or merged?)")
    if unchanged_count:
        L.append(f"- {unchanged_count} other open action{'s' if unchanged_count != 1 else ''} unchanged.")
    L.append("")
    L.append(f"{len(actions)} total open — see `Meta/bases/Actions.base` for the full list.")
L.append("")
if new:
    L += ["## ✨ What's New (last 24h)", ""]
    for _, e, n in new[:12]:
        L.append(f"- {e} [[{n}]]")
    L.append("")
if voices:
    L += ["## \U0001F3A4 Recent Voice Memos", ""]
    for n in voices[:8]:
        L.append(f"- [[{n}]]")
    L.append("")
L += ["---", "*Generated locally by AutoADHD.*"]

out = os.path.join(vault, "Meta", "briefings", f"{date} - Daily Briefing.md")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(L))
print(f"Briefing written: {os.path.basename(out)} — {len(actions)} open actions, {len(new)} new, {len(voices)} memos")
PY

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add Meta/briefings/ 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(briefing unchanged)"
    elif cerr="$(git commit -q -m "[Briefing] daily digest $(date +%Y-%m-%d)" 2>&1)"; then
        echo "committed briefing"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        BRIEF_RC=1
    fi
fi

# Notify (ntfy, no-op if unconfigured)
BRIEF_REL="Meta/briefings/$(date +%Y-%m-%d) - Daily Briefing.md"
/bin/bash "$(cd "$(dirname "$0")" && pwd)/notify.sh" "☀️ Daily Briefing ready" "Open it in Obsidian: $(date +%Y-%m-%d) - Daily Briefing" default "sunny" "$BRIEF_REL" 2>/dev/null || true

# Proactive Discord Embed
# Extract content starting from the H1, skipping frontmatter, and cap it at 1800 chars for Discord.
# (Bug fixed 2026-07-19: previously used "$out" — a python-heredoc variable that is empty in
# shell scope — so the embed body was always blank. Use the real path.)
BRIEFING_BODY="$(sed -n '/^# ☀️ /,$p' "$VAULT_DIR/$BRIEF_REL" | grep -v 'Generated locally by AutoADHD' | head -c 1800)"
/bin/bash "$(cd "$(dirname "$0")" && pwd)/send-discord.sh" "☀️ Daily Briefing" "$BRIEFING_BODY" default "sunny" "$BRIEF_REL" 2>/dev/null || true

exit "${BRIEF_RC:-0}"
