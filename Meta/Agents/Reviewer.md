---
type: agent-spec
name: Reviewer
trigger: after Extractor (automatic) + weekly
script: Meta/scripts/run-reviewer.sh
created: 2026-03-18
source: ai-generated
---

# Reviewer Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** its own daily 21:30 cron (`scheduler.py:347`) — not chained to the Extractor and not
>   weekly.
> - **Does:** four narrow checks over recently extracted notes — missed
>   PERSON/ORGANIZATION/PLACE/PROJECT mentions (`:120-129`), H1-emoji presence (`:108-114`), a
>   `## Extracted` heading whose wikilinks resolve (`:95-105`), and `source_agent`/`source_date`
>   presence (`:106-107`). Findings are appended to `Meta/AI-Reflections/review-log.md` and, for
>   real misses, to `Meta/review-queue/` (`:134-175`).
> - **Does not:** fix anything — repairs are the Implementer's job; verify locked fields;
>   auto-link the whole vault; detect orphans; check tags; or handle stale actions and duplicate
>   entities (the Groomer and Dedup own those).
