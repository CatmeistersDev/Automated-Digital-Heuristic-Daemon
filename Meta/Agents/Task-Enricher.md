---
type: agent-spec
name: Task Enricher
trigger: on new/updated action in Canon/Actions/ + daily check-in via Discord
script: Meta/scripts/run-task-enricher.sh
integration: discord-bot.py (Discord quick actions)
created: 2026-03-20
source: ai-generated
design_principle: "Lower the activation energy. Every enrichment should make it easier to act, not harder to read."
---

# Task Enricher Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** a daily 08:30 sweep over open, un-enriched actions (`scheduler.py:337`), or one
>   explicit action path (`run-task-enricher.sh:18-30`). There is no on-creation hook from the
>   Extractor.
> - **Does:** one prompt that reads only the action's name and description, then either produces
>   `## Sub-steps` (3-6 concrete steps, the first trivially easy) + `## Effort`, or — if the action
>   needs external info before it can be broken down — `## Needs Research`; the shell sets
>   `enrichment_status` (`enriched` or `needs-research` respectively) and commits (`:39-125`).
>   `needs-research` actions are picked up by the Researcher's daily 08:45 scan.
> - **Does not:** look up contacts, draft messages in your voice, score or rank priority (actions
>   are processed in glob order), set `next_step`/`snooze_until`/`contact`, decompose into
>   sub-action files, or add any Discord command.
