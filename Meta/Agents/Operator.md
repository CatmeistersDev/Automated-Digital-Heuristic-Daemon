---
type: agent-spec
name: Operator
created: 2026-03-23
source: ai-generated
runtime: Ollama via ollama_agent.py (see Meta/agent-runtimes.conf)
schedule: On-demand — triggered by Task-Enricher output or direct human request
design_principle: "You think it, I ship it. But you always press the button."
---

# Operator Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** on human command only — `/draft` in `discord-bot.py:304-325`. It has no scheduler
>   entry and no auto-trigger from the Task-Enricher. Runtime is Ollama, not Cowork.
> - **Does:** write ONE draft per invocation to `Meta/operations/pending/` with
>   `op_id`/`status`/`executed: false` (`run-operator.sh:33-86`). It never sends, executes, or
>   calls any external service (`run-operator.sh:1-6`) — one blanket approval gate, no tiers.
> - **Does not:** touch Gmail / Calendar / Drive / Notion (no MCP wiring exists anywhere), rank or
>   queue multiple actions, edit the source action note, use a `completed/` folder or a
>   `TEMPLATE.md`, or provide `/operate` `/approve` `/reject` `/ops` `/undo`.
