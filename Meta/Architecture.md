---
type: reference
name: AutoADHD System Architecture
created: 2026-06-30
updated: 2026-07-01
source: ai-generated
source_agent: Claude
---

# 🏗️ AutoADHD — System Architecture

> The blueprint CLAUDE.md points agents at. For operator/deploy detail see [`SYSTEM.md`](../SYSTEM.md);
> for note-format rules see `.claude/skills/vault-writer/SKILL.md`. This file describes the LOCAL build
> (Ollama + ntfy + Open WebUI) — the upstream Claude-CLI / Telegram / Codex design is retired.

## 1. One-line model

Voice memo → transcript → structured Obsidian knowledge (Canon), maintained by a fleet of scheduled
local-LLM + deterministic agents, all git-tracked, 100% on-box (a single Docker host: NAS, mini PC, server).

## 2. The four zones (data model)

```
Inbox/     Zone 1 — raw capture (voice memos, text drops). # Raw blocks are read-only source evidence.
Clippings/ others' content filed verbatim (noextract/PDF drops) — agent-write-denied in the harness
Thinking/  Zone 2 — forming (reflections, beliefs, concepts, emerging ideas, research)
Articles/  Zone 3 — producing (long-form)
Canon/     Zone 4 — crystallized (People, Events, Actions, Decisions, Projects, Places, Organizations)
Meta/      rules, agent specs, scripts, logs, queues, voiceprints, this file
```

Every note: typed frontmatter + `source:` provenance + type emoji in H1 + `[[wikilinks]]`. Living types
(Actions/Decisions/Beliefs/Projects) carry an `## Evolution` log. `locked:` fields are a convention the agent prompts are told to respect — **not an enforced
guarantee**; nothing in the code checks a staged `locked:` value against `HEAD` (see SYSTEM.md's
Open items).

## 3. Runtime harness (the LLM layer)

- **`invoke-agent.sh AGENT PROMPT [MODE]`** → resolves a runtime from `Meta/agent-runtimes.conf`
  (Ollama-only; cloud CLI branches removed) → **`ollama_agent.py`**.
- **`ollama_agent.py`** — a tool-using loop against Ollama (`OLLAMA_HOST`, default model
  a **Qwen3.6 35B A3B** build; small/fast paths use a **Gemma4** build (`gemma4:e4b`)). The GGUF rejects
  Ollama's native tools API, so it uses a **prompt-based JSON tool protocol** over `/api/chat`.
  Tools: `read_file/write_file/append_file/list_dir/grep/move_file/git_commit` + a **hardened read-only
  `bash`** — **default-deny allowlist since 2026-07-09** (retired the earlier denylist approach
  described in older versions of this doc; a denylist could never fully enumerate every dangerous
  command, an allowlist only permits known-safe read-only ones like find/grep/cat/ls). `git_commit`
  paths are sandbox-validated behind `--` (closes flag-smuggling); vault-path resolution uses
  realpath (symlink-escape proof). All mutation goes through the file tools, not bash. Every tool
  call is appended to `Meta/agent-activity.jsonl` (audit trail).
- **`lib-agent.sh`** — shared bash safety: per-agent lock dirs (stale-PID/age breaking), clean-worktree
  assertions, frontmatter status get/set, commit guards. Lock-contention alerts go via `notify.sh` (ntfy).

## 4. The pipeline (event-driven)

```
phone voice memo (GPS in filename) → Syncthing → Inbox/Voice/_drop/
  → scheduler.py watcher (watchdog; handles on_moved for Syncthing renames; drains _drop on boot)
  → process-voice-memo.sh:
       WhisperX large-v3 (CPU, faster-whisper) transcribe
       + pyannote diarization (gated on .secrets/hf-token.txt)
       → speaker-ID (speaker_id.py vs Meta/voiceprints/*.json; solo → VAULT_OWNER, meeting → match)
       → run-correct-transcript.sh (fix misheard proper nouns; preserves # Raw)
       → run-extractor.sh (chunked → Canon/Thinking entries; shell owns the note + ## Extracted)
       → archive audio to _processed/ → notify.sh (ntfy)
```

## 5. Agents — real vs dormant (as of 2026-07-01; SCHEDULE TABLE IS STALE — see note below)

> **The schedule table right below predates a lot of real scheduling that's shipped since.**
> Current schedule, read straight off `scheduler.py`'s own startup log line: briefing 07:30,
> task-enricher 08:30, researcher-scan 08:45, decision-mining 09:15 (1st of month),
> orchestrator 10:00, retro 21:00 → reviewer 21:30 → implementer 21:45, thinker+mirror Sun
> 10:00/10:30, groomer Sun 11:00, dedup Sun 11:30, ci-check Sun 12:00, extractor catch-up every 2h,
> health hourly, backup 03:15. `SYSTEM.md`'s "Agents / scripts" section is the accurate,
> kept-current version of this list — treat the table below as the 07-01 baseline it was, not
> current state.

**Scheduled & running (`scheduler.py`):**
| Agent | Trigger | LLM? |
|---|---|---|
| Extractor (`run-extractor.sh`) | per memo (via pipeline) | yes |
| Task-Enricher (`run-task-enricher.sh`) | 08:30 | yes |
| Briefing (`daily-briefing.sh`) | 07:30 | no (deterministic) |
| **Nightly self-heal chain:** Retro (`run-retro.sh`) 21:00 → Reviewer (`run-reviewer.sh`) 21:30 → **Implementer (`run-implementer.sh`) 21:45** | daily | Retro/Reviewer yes; Implementer no |
| Thinker/Mirror (`run-thinker.sh`/`run-mirror.sh`) | Sun 10:00/10:30 | yes |
| Groomer/Dedup (`run-groomer.sh`/`run-dedup.sh`) | Sun 11:00/11:30 | yes |
| Health (`run-health.sh`) | hourly | no |
| Backup (`run-backup.sh`) | 03:15 | no |
| Advisor (`advisor-server.py`) | always (Open WebUI :8723) | yes (read-only tools) |

The **self-heal chain** is the maintenance loop: Reviewer QAs recent extractions (resolves wikilinks
vault-wide, idempotent per note-hash) → Implementer auto-fixes provably-safe issues (provenance/emoji,
path-style/wrong-case links, guarded stubs in `Canon/_stubs/` honoring `Meta/implementer-no-stub.txt`)
and flags the rest to `Meta/review-queue/`. Human-in-the-loop: Dedup/Operator only *propose*.

**Built but dormant / on-demand:** Manifest (`build-manifest.sh`), Researcher (`run-researcher.sh`,
vault-only, no web), Operator (`run-operator.sh`, drafts to `Meta/operations/pending`, never sends),
Orchestrator (`run-orchestrator.sh`, deterministic next-step focus tool).

**ACTIVATED (2026-07-01):** Discord control plane — Tier 1 `send-discord.sh` (fanned out from
`notify.sh`) + Tier 2 `discord-bot.py` (voice→pipeline, text→Advisor, `/actions` `/done` `/brief`
`/ask`). The bot app had no webhook available from the Developer Portal (webhooks are
per-channel, created inside Discord itself, not per-bot), so Tier 1 posts via the Discord REST API
using the same bot token + a target channel ID instead of a webhook URL — one credential set for
both tiers. Create `.secrets/discord-token.txt` and `.secrets/discord-channel-id.txt` to enable it;
`scheduler.py` starts the bot when a token is present. See
`Meta/Discord-Integration-Plan.md`.

## 6. Interfaces

- **ntfy** (`notify.sh`) — outbound push (no-op unless `NTFY_URL`+`NTFY_TOPIC` set).
- **Discord** (`notify.sh` → `send-discord.sh` + `discord-bot.py`) — outbound fan-out (bot-token
  REST post, or webhook if configured) and two-way bot (voice memos, `/actions` `/done` `/brief`
  `/ask`). Active since 2026-07-01.
- **Open WebUI** (`advisor-server.py`) — OpenAI-compatible chat on `:8723`, model `autoadhd-advisor`,
  **read-only** vault tools (can look up, never mutate).

## 7. Deploy topology

Container **`autoadhd-brain`** mounts the host directory holding your Obsidian vault at `/vault`.
Edit the vault live from any Obsidian client, but **commit in-container** — `.git` is typically
read-only from SMB/network clients — and `docker restart autoadhd-brain` to reload `scheduler.py`.
Full recipe + gotchas in `SYSTEM.md`.

## 8. Safety invariants

- Never edit `# Raw`; never delete Inbox raw transcripts; never fabricate.
- `locked:` fields are immutable to AI; identity is confirmed with the human, not guessed.
- Nothing external auto-sends (Operator/Dedup propose to review queues).
- Every change is git-committed → revertible. `pre-commit-guard.sh` blocks Canon deletions unless
  `VAULT_ALLOW_DELETE=1`.
