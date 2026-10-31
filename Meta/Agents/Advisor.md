---
type: agent-spec
name: Advisor
trigger: /ask, /strategy via Discord; direct use in Claude Code
script: Meta/scripts/advisor-server.py
integration: advisor-server.py HTTP endpoint (Open WebUI) + discord-bot.py /ask
created: 2026-04-01
source: ai-generated
design_principle: "Be the strategist who knows the whole board. Never give generic advice — ground every answer in what this vault already knows."
personality: "A sharp strategist meets a therapist who actually listens. Strategic rigor with genuine empathy."
---

# Advisor Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-27):
> - **Runs:** `advisor-server.py` — an OpenAI-compatible endpoint on :8723 for Open WebUI — and
>   `/ask` in `discord-bot.py`. There is no `run-advisor.sh` in this tree.
> - **Does:** one model call per request with three read-only tools
>   (`READONLY = {"read_file","grep","list_dir"}`). Reads `Meta/advisor-knowledge.md` on the vault
>   data volume (not the code-baked `Meta/Agents/` copy) into the system prompt every call, and can
>   append a new bullet to it via a trailing `UPDATE_KNOWLEDGE: <section> | <learning>` line, parsed
>   and applied deterministically by the shell/Python — the model never writes the file directly.
> - **Does not:** write anything else to the vault, keep within-session state beyond the last few
>   turns, log decisions, cap answer length, run a triage/cost tier, or parse
>   `RESEARCH:`/`DECOMPOSE:` trigger protocols.
