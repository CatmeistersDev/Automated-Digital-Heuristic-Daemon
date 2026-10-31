---
type: agent-spec
name: Mirror
created: 2026-03-23
updated: 2026-03-23
source: ai-generated
runtime: Ollama via ollama_agent.py (see Meta/agent-runtimes.conf)
schedule: Weekly, Sundays 10:30 (scheduler.py), after Thinker at 10:00
---

# Mirror Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** `run-mirror.sh` -> `run-thinker.sh --mirror`, Sundays 10:30, after the Thinker at
>   10:00 (`scheduler.py:341-342`). Runtime is Ollama, not Cowork.
> - **Does:** builds the same snapshot as the Thinker — Canon folder name lists, Belief excerpts,
>   open actions, frontier notes (`run-thinker.sh:30-78`) — makes one model call, and writes one
>   4-7 sentence paragraph to `Meta/AI-Reflections/`.
> - **Does not:** exist in Cowork, read retro-log / review-log / style-guide / git log, or produce
>   the multi-section structure described below.
