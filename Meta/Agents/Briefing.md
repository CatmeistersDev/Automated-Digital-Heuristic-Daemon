---
type: agent-spec
name: Daily Briefing
trigger: daily 7:30 AM
script: Meta/scripts/daily-briefing.sh
created: 2026-03-18
source: ai-generated
---

# Daily Briefing Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** `daily-briefing.sh` at 07:30 (`scheduler.py:336`); callable manually any time.
> - **Does:** a deterministic digest with exactly three sections — Open Actions, What's New,
>   Recent Voice Memos (`daily-briefing.sh:144-193`) — written to
>   `Meta/briefings/<date> - Daily Briefing.md`. Open Actions filters `type: action` with
>   status open/in-progress, regardless of folder.
> - **Does not:** include pending operations, the review queue, sprint proposals or heartbeat
>   status; tier items into "no-brainers"; or special-case any particular person.
