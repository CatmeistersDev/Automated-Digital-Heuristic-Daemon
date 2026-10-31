---
type: agent-spec
name: Implementer
created: 2026-03-23
updated: 2026-03-23
source: ai-generated
runtime: Ollama via ollama_agent.py (see Meta/agent-runtimes.conf)
schedule: Daily 21:45 (scheduler.py), independent of Retro and Reviewer
---

# Implementer Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** its own daily 21:45 cron (`scheduler.py:348`) — independent, not a child of the
>   Retrospective or the Reviewer.
> - **Does:** a deterministic pass with **no LLM at all** (`run-implementer.sh:2`). Reads
>   `review-log.md` through a byte-offset cursor and auto-fixes a narrow set: missing
>   `source_date`, missing H1 emoji, wikilink case/path normalization, guarded stub creation
>   (`:102-269`). Queues dangling non-entity wikilinks and BLOCKER/HIGH findings to
>   `Meta/review-queue/`. Logs a flat `## Implementer: <date>` bullet list.
> - **Does not:** run a Reflexion loop, read retro-log/specs/`Architecture.md`, notify Discord,
>   rebuild the manifest, or take the `lib-agent.sh` worktree lock.
