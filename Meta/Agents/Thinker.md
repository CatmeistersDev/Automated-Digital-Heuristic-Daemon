---
type: agent-spec
name: Thinker
trigger: weekly (Sunday 10 AM) or on-demand
script: Meta/scripts/run-thinker.sh
created: 2026-03-18
source: ai-generated
---

# Thinker Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** Sundays at 10:00 (`scheduler.py:341`), and on demand.
> - **Does:** builds a snapshot of Canon folder name lists, Belief excerpts, open actions and
>   frontier notes (`run-thinker.sh:30-78`), makes one call for 4-7 concrete sentences, writes
>   `Meta/AI-Reflections/<date> - Thinker.md`, extracts conflict stubs, and commits.
> - **Does not:** read Inbox memos or prior reflections, and it changes no other note — no
>   wikilink edits, no status updates, no research side effects.
