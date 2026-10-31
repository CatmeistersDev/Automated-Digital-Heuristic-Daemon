---
type: agent-spec
name: Retrospective
trigger: daily 9:00 PM (end of day)
script: Meta/scripts/run-retro.sh
created: 2026-03-18
source: ai-generated
---

# Agent Retrospective

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** `run-retro.sh` daily at 21:00 (`scheduler.py:340`); callable manually.
> - **Does:** deterministic counts — memos, new notes, open actions, commits (`:18-23`) — plus one
>   narrative call asking three things: what happened, one pattern, one suggestion (`:26-35`).
>   Writes `Meta/AI-Reflections/<date> - Retro.md`.
> - **Does not:** convene the agents for a meeting, sample per-note evidence, keep a
>   `retro-log.md`, or modify agent specs, `CLAUDE.md` or any script.
