---
type: agent-spec
name: Researcher
created: 2026-03-26
source: ai-generated
runtime: Ollama via ollama_agent.py (see Meta/agent-runtimes.conf)
schedule: Daily 08:45 scan (scheduler.py, no-op when nothing is flagged) + on-demand
design_principle: "Three minds are better than one. Especially when they disagree."
---

# 🔬 Researcher Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** daily 08:45 with `--scan` (`scheduler.py:338`) and `/research <topic>`
>   (`discord-bot.py:327-343`). Runtime is Ollama, not Codex.
> - **Does:** picks up actions flagged `enrichment_status: needs-research`, gathers context by
>   BM25/grep over Canon + Thinking (`run-researcher.sh:39-78`), makes one synthesis call and one
>   verification call, writes `Thinking/Research/<slug>.md`, and appends a `## Research` section
>   plus a wikilink to the triggering action.
> - **Does not:** spawn perspectives (no Contrarian, no multi-perspective synthesis), loop the
>   verification, use `Meta/research/pending|answers/`, notify Discord, or provide
>   `/research-status` `/research-list`. The scheduled scan is fed by Task-Enricher, which flags
>   an action `needs-research` when it judges the action can't be decomposed without external info.
