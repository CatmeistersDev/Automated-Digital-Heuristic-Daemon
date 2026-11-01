# CLAUDE.md

You are an AI agent operating inside an Obsidian vault.
Git tracks every change. If something goes wrong, we revert.

---

## ⚙️ LOCAL BUILD — current reality (read this; it supersedes upstream specifics below)

This vault runs **100% locally** on any Docker host — no Anthropic/Claude CLI, no Codex, no
cloud. Owner is **Louise**. Operator/deploy guide: `SYSTEM.md`; system blueprint: `Meta/Architecture.md`.

- **CODE/DATA SPLIT (2026-07-09):** THIS repo is the CODE repo; the owner's personal vault lives ONLY on the data volume/container `/vault` (its own git repo). Code ships BAKED into the Docker image at `/app` — deploy = image rebuild + recreate (see `SYSTEM.md`), never by editing the live mount. Scripts self-locate (`dirname $0`/`__file__`); `VAULT_DIR` is data-only. A self-hosted git remote holds private `-code` + `-vault` repos; `run-backup.sh` pushes the vault replica nightly. Sample notes: the Bob's Burgers demo vault in this repo's own `Canon/`/`Inbox/`/`Thinking/`.
- **Runtime:** agents run via `Meta/scripts/invoke-agent.sh` → `ollama_agent.py` (a local tool-using
  harness) against **Ollama** (`http://ollama:11434`, a model from the
  **Qwen3.6 35B A3B** family). Tools: read/write/grep/bash/git.
- **Pipeline:** voice memo → Syncthing → `scheduler.py` watcher → `process-voice-memo.sh`
  (WhisperX large-v3 + pyannote diarization + voiceprint speaker-ID → `run-correct-transcript.sh`
  → `run-extractor.sh` (chunked) → archive → ntfy). `# Raw` is shell-owned, never rewritten by the model.
  Un-transcribable audio gets bounded retries (`VOICE_MAX_ATTEMPTS`, default 3; counter in
  `Meta/.voice-progress/`) then is quarantined to `Inbox/Voice/_failed/` with a `.reason.txt`
  sidecar + one high-priority alert (dead-letter queue, 2026-07-11).
- **Implemented agents (Meta/scripts/run-*.sh):** Extractor, Reviewer, Task-Enricher, Retrospective,
  Thinker/Mirror, Researcher (vault + SearxNG web search), Operator (drafts to `Meta/operations/pending`,
  never sends), Orchestrator (next-step focus), Implementer (deterministic self-heal: auto-fixes
  path/case wikilinks + guarded stubs, honors `Meta/implementer-no-stub.txt`; scheduled 21:45), plus
  Briefing, Health watchdog, Dedup, Manifest.
- **Interfaces:** chat via **Open WebUI** (`advisor-server.py`, model `autoadhd-advisor`, :8723);
  notifications via **ntfy** (`notify.sh`, topic `autoadhd`).
- **Speaker-ID:** voiceprints enrolled for Louise, Bob, Linda, Teddy (`Meta/voiceprints/`); meetings auto-label them.
- **Dev/QA tooling:** `make check` (→ `ci-check.sh`: bash -n + py_compile + frontmatter +
  `Meta/scripts/tests/*.sh` behavioral tests), `validate-frontmatter.py`, `build-canvas.sh`; a
  `pre-commit-guard.sh` git hook blocks deletions in protected Canon dirs (renames OK;
  `VAULT_ALLOW_DELETE=1` overrides). Engineering rules in `Meta/Engineering.md`.
- **Discord (ACTIVATED 2026-07-01):** Tier-1 `send-discord.sh` (fanned out from `notify.sh`) +
  Tier-2 `discord-bot.py` bot (voice→pipeline, text→Advisor, `/actions` `/done` `/brief` `/ask`
  `/focus` `/draft` `/research`; `/brief` confirmed live). No webhook — the bot's Developer Portal app didn't expose one, so
  Tier-1 posts via the Discord REST API using the same bot token + a channel ID
  (`.secrets/discord-token.txt` + `.secrets/discord-channel-id.txt`). See
  `Meta/Discord-Integration-Plan.md`. The bot is **fail-closed**: it only answers if
  `DISCORD_ALLOWED_USER_ID` matches, or `DISCORD_ALLOW_ANYONE=1` is set. **Locked 2026-07-02** to
  Louise's user ID via `DISCORD_ALLOWED_USER_ID` in the compose env (the `DISCORD_ALLOW_ANYONE=1`
  stopgap is removed). NOTE: `discord.py` is now baked into the live `autoadhd-brain:whisperx` image
  via a clean **Dockerfile rebuild** (2026-07-02, validated end-to-end: transcribe+diarize+voiceprint
  match + advisor/bot) — this retired the earlier `docker commit` hot-patch, so a `compose up`
  recreate no longer wipes the bot.
- **Schedules (scheduler.py):** briefing 07:30, task-enricher 08:30, researcher-scan 08:45, decision-mining 09:15 (`run-decision-mining.sh`, self-gates to the 1st of the month: mines the vault's git log for decision-shaped commits, queues candidates to `Meta/review-queue/`, never creates a Decision note itself), orchestrator 10:00 (`auto-orchestrator.sh`, proactive focus push on the highest-priority open action), nightly self-heal chain retro 21:00 → reviewer 21:30 → implementer 21:45, thinker+mirror Sun 10:00/10:30, groomer+dedup Sun 11:00/11:30, ci-check Sun 12:00 (weekly syntax/compile/shellcheck/frontmatter/behavioral-test gate, self-alerts on failure — see `run-ci-check.sh`), extractor catch-up every 2h (no-arg run-extractor.sh reprocesses any memo stranded at `status: inbox|transcribed`; no-op when none), health hourly (also alerts on memos stranded at `transcribed` >150min), backup 03:15 (also snapshots `Meta/voiceprints/` + `.secrets/` to a rotated tar — the only copies of either). The scheduler serializes vault-**mutating** runs (one lock: voice-watcher thread vs cron) and puts a subprocess **timeout** on every job so a hung agent can't starve health/backup (both run read-only, unlocked). `scheduler.py` edits need a container restart to take effect. `scheduler.log` and `Meta/agent-activity.jsonl` both rotate (10MB × 5 / 10MB × 3) — neither is unbounded anymore.
- **Runtime resilience knobs:** `ollama_chat` retries with backoff + optional `OLLAMA_FALLBACK` host chain (`OLLAMA_RETRIES`/`OLLAMA_RETRY_DELAY`); harness denies `.secrets/` + Inbox writes; bash is a **default-deny read-only allowlist** (2026-07-09 — replaced the leaky deny-list; only find/grep/cat/ls/… run, `git` limited to read-only subcommands, `git_commit` paths are sandbox-validated behind `--`); path sandbox uses realpath (symlink-escape proof); optional `OLLAMA_NUM_CTX`, `ADVISOR_HOST`.
- **Liveness (2026-07-09):** scheduler timeouts kill the whole **process group** (no orphan whisperx/agent mutating the vault after a timeout); a supervisor thread restarts a dead Advisor/Discord child and touches `Meta/.scheduler-heartbeat` every 60s; the HOST-side `deadman-check.sh` (host cron, every 15 min) alerts via ntfy+Discord when the container is down or the heartbeat is stale — the in-container watchdog can't see those. Dockerfile has a HEALTHCHECK (Advisor `/`) and deps pinned via `constraints.txt`.
- **Advisor auth (locked 2026-07-02):** `ADVISOR_TOKEN` is now SET in the live compose env — the Advisor rejects any request without `Authorization: Bearer <token>` (401), closing the unauthenticated `0.0.0.0:8723` LAN hole. The in-container Discord bot and `run-health.sh` read the token from env automatically; **Open WebUI must have the token set as its advisor-connection API key** or it gets 401. Token value lives only in the live compose (never committed to git).
- **Human-in-the-loop:** nothing external is auto-sent; Operator/Dedup propose to review queues.

The sections below are the original upstream design (Claude CLI / Max / Telegram / Codex / sprint
board). The **note-format / frontmatter / emoji / provenance / wikilink / locked-field rules still
apply** — agents must follow them. Ignore upstream runtime/agent-runtime/Telegram/Codex specifics.

---

## WHAT YOU CAN DO

- Create, edit, and delete notes in any folder
- Add new Canon entries directly (people, events, concepts, decisions, projects, actions — or new types as needed)
- Update existing Canon entries with new information
- Create and maintain wikilinks between notes
- Evolve the structure: new types, new relationship patterns, new folders are fine
- Research external context for concepts/ideas and add with proper source attribution
- Write AI reflections and observations to Meta/AI-Reflections/

## WHAT YOU MUST NOT DO

- Never edit content under `# Raw` in any Inbox note. Raw transcripts are source evidence and are read-only.
- Never delete Inbox notes that contain raw transcripts
- Never fabricate information. If you're unsure, say so.

---

## SKILLS (just-in-time context)

Skills inject focused rules at the moment you need them, instead of relying on this file surviving a long conversation. They live in `.claude/skills/` and are loaded on demand.

| Skill | When to load | What it contains |
|-------|-------------|-----------------|
| `vault-writer` | Creating or editing ANY vault note | Note format, frontmatter, emoji headings, provenance, wikilinks, folder map |
| `vault-extractor` | Processing an Inbox note into Canon entries | Full extraction checklist, action detection, reflection handling, duplicate detection, write-back rules |

**For Cowork sessions:** Skills load automatically when triggered by the task description.

**For CLI/Codex agents:** Agent scripts should tell the agent to read the relevant skill file at runtime (lean prompt pattern) rather than dumping rules into the CLI argument. Example: "Read `.claude/skills/vault-writer/SKILL.md` before creating any notes."

**Token discipline:** Skills replace the need to load this entire CLAUDE.md into every agent prompt. Load only what the task requires. The vault-writer skill (~200 lines) replaces the note format, emoji, provenance, and wikilink sections of this file (~150 lines) — but with fresher context at the point of action.

---

## NOTE FORMAT

For People entries, follow the schema in `Meta/People Schema.md` (field ordering, naming, formatting).

For all other types, use minimal frontmatter:

```yaml
---
type: person | event | concept | decision | project | (or new types as needed)
name: Human Readable Name
created: YYYY-MM-DD
updated: YYYY-MM-DD
---
```

Additional frontmatter fields are allowed when useful (aliases, status, role, source, etc.) but not required.

### Provenance Tracking

Every note must have a `source` field in frontmatter:

```yaml
source: voice          # spoken by human in a voice memo
source: human          # typed/written directly by human
source: ai-extracted   # AI pulled this from a voice memo transcript
source: ai-generated   # AI created this (research, enrichment, reflection)
source: ai-enriched    # AI added content to a human-created note
```

### Agent Attribution (MANDATORY)

Every AI action must identify WHICH agent and WHEN. Add to frontmatter:
```yaml
source: ai-extracted
source_agent: Extractor          # Extractor | Task-Enricher | Researcher | Implementer | Thinker | Mirror | Operator
source_date: 2026-03-31T14:30   # ISO timestamp of the action
```

When AI adds content to an existing note, mark the added section with an HTML comment including agent + timestamp:

```markdown
## Section Name
Human-written content stays unmarked.

AI-added content gets a source comment. <!-- source: ai-extracted, agent: Extractor, 2026-03-31T14:30, from: 2026-03-16 - Voice - arcade.md -->

External research also gets sourced. <!-- source: ai-research, agent: Researcher, 2026-03-31T16:00, url: https://example.com -->
```

The chain of provenance matters: voice memo → inbox note (raw) → Canon entry (extracted by Extractor at T1) → enrichment (by Task-Enricher at T2) → research (by Researcher at T3). Every fact traces to a human moment AND to the specific agent action.

### Locked Fields

Any note can include a `locked` array in frontmatter:

```yaml
---
name: Tina
born: 2026-01-22
locked:
  - born
  - name
---
```

**Fields listed in `locked` must NEVER be changed by AI.** These are human-verified facts. If a voice memo or other source contradicts a locked field, keep the locked value and ignore the contradiction. Only the human can unlock or change these fields.

When AI first creates a Canon entry, nothing is locked. The human can then review, correct, and lock fields they've verified.

**Enforced, not just advisory (2026-07-27):** `pre-commit-guard.sh` runs `check-locked-fields.py`,
which compares every staged `.md` file's locked fields against `HEAD` and blocks the commit if one
silently changed. `VAULT_ALLOW_LOCKED_EDIT=1` overrides it for a deliberate human correction.

---

## EVOLUTION SECTIONS

Living note types — **Actions, Decisions, Beliefs, Projects** — track how they changed over time in a `## Evolution` section. Reverse chronological. Each entry: date, what changed, agent name, 1-2 sentence why, source link.

Full spec is in `.claude/skills/vault-writer/SKILL.md`. All agents that modify these types must add an Evolution entry.

---

## WIKILINKS

- Use `[[Name]]` syntax to link between notes
- Before linking, verify the target note exists
- If it doesn't exist, create it or note that it's missing
- Wikilinks are the primary way structure is expressed — use them generously

---

## LANGUAGE

- Canon notes should be in English
- Raw transcripts stay in their original language
- Extracted/processed content is normalized to English

---

## FOLDER STRUCTURE

```
Inbox/              → Zone 1: raw capture (voice memos, quick notes) — don't touch
Thinking/           → Zone 2: the whiteboard (reflections, beliefs, concepts, emerging ideas)
Articles/           → Zone 3 in the upstream design: the writing desk (long-form, know-how).
                      NOT implemented in this port — no script reads or writes it.
Canon/              → Zone 4: crystallized knowledge (clear types, stable entries)
Canon/People/
Canon/Events/
Canon/Concepts/     → legacy; new concepts go to Thinking/
Canon/Decisions/
Canon/Projects/
Canon/Actions/      → tasks, intentions, things to do
Canon/Places/       → locations with context
Canon/Organizations/
Canon/Beliefs/      → what the owner holds to be true (see NOTE FORMAT below); Mirror cross-references this against Canon/Actions/
Meta/               → vault rules, templates, observations
Meta/Architecture.md → system blueprint (all agents read this)
Meta/AI-Reflections/ → AI thinking partner notes (patterns, observations, proposals)
Meta/review-queue/   → items awaiting human approval (Tier 3 review gates)
Meta/operations/     → Operator approval requests and completed operations
Meta/sprint/         → upstream sprint board. NOT implemented in this port — no script uses it.
```

Zones: Inbox (raw), Thinking (forming), Canon (crystallized). Upstream also defines Articles
(producing); this port does not implement it. See Meta/Architecture.md for details.

### Actions

Actions are tasks, intentions, or things mentioned as "should do" / "want to do" / "need to":

```yaml
---
type: action
name: Get driving license
status: open         # open | in-progress | done | dropped
priority: medium     # high | medium | low
source: voice
first_mentioned: 2026-03-16
due: 2026-04-30     # when should it be done?
start: 2026-03-20   # when should work begin?
owner: "[[Louise]]"
output: "Having a valid driving license"
mentions:            # track every time this comes up
  - 2026-03-16 - Voice - morning-memo.md
linked:
  - "[[Louise]]"
---
```

When the same action is mentioned again in a new memo, add to the `mentions` array. Actions that keep recurring without getting done are a signal worth surfacing.

### Reflections

Brain dumps, journal entries, processing moments. These stay WHOLE — do not disassemble into separate concept/action/event entries. The Extractor cleans them up (grammar, links) but preserves the original thinking.

```yaml
---
type: reflection
name: Thinking about what focus means
created: 2026-03-23
source: voice | human
mood: [scattered, energized, frustrated, calm]  # optional
context: [morning, post-meeting, late-night]     # optional
linked:
  - "[[relevant concept or person]]"
---
```

### Beliefs

What Louise holds to be true. These anchor strategy and decisions. Can be challenged, updated, or retired.

```yaml
---
type: belief
name: Speed of execution beats perfection
created: 2026-03-23
source: voice | human | ai-extracted
confidence: high | medium | low
challenged_by: []
supported_by: []
linked:
  - "[[relevant concepts, decisions, or reflections]]"
---
```

### AI Reflections

The Thinker agent writes to `Meta/AI-Reflections/`. These notes capture:
- Patterns across memos ("you've mentioned X four times this month")
- Connections the human might not see
- Stale actions (recurring but never done)
- Logical inconsistencies between notes
- Research proposals ("you mentioned Y — here's relevant context")
- Retrospectives on what worked well in vault processing

```yaml
---
type: ai-reflection
name: Weekly Reflection - 2026-W12
created: 2026-03-18
source: ai-generated
---
```

---

## WHEN UNSURE

Say so. Explain what's ambiguous. Ask for clarification.
Don't guess at identity (is "Ollie" the same as "Oliver"? Ask.)

---

## AGENT ROLES

> **Role summaries, not behaviour specs.** Each agent's real trigger, schedule and capability set
> is the **"What actually ships"** block at the top of its `Meta/Agents/<name>.md`, verified
> against the code on 2026-07-26; `Meta/scripts/scheduler.py` is the authority on when anything
> runs. Where a bullet below describes a chain, a command or a check that block does not list,
> the block is right and the bullet is upstream design. This does **not** loosen the note-format
> rules — frontmatter, provenance, wikilinks and locked fields still apply exactly as written.

Twelve agents operate in this vault (plus Health watchdog, Groomer, Dedup, and Manifest
utilities — see the local-build banner above and `Meta/Architecture.md`). Full specs in
`Meta/Agents/`.

Groomer (`run-groomer.sh`, Sun 11:00, small model) and Dedup (`run-dedup.sh`, Sun 11:30) are the
two weekly grooming utilities: Groomer archives old briefings/retros into rolling digests and
surfaces stale actions to `Meta/review-queue/` (propose-only, never edits/deletes Canon); Dedup
proposes entity-merge candidates to `Meta/review-queue/` (never merges — see the standing rule
below to verify identity with Louise before any merge is executed).

### Extractor (runs on every new memo)
- Deep extraction: people, events, concepts, decisions, **actions**, **reflections**
- Checks aliases before creating new entries
- Tracks provenance (source field + inline comments)
- Links everything with wikilinks
- Respects locked fields
- Scans for task-like language ("I need to", "we should", "I want to", "reminder:", "don't forget")
- For reflections: clean up but DON'T disassemble — keep them whole in Canon/Reflections/
- **Inbox note is SHELL-OWNED — the model never rewrites it.** `run-extractor.sh` feeds the transcript to the model in ~9k-char inline chunks (so long meetings aren't truncated by the read cap), then the SHELL deterministically rebuilds the note from a pre-extraction snapshot: it preserves `# Raw` byte-for-byte, flips `status: extracted`, and appends the `## Extracted` list. The model must NEVER `write_file` the inbox note. To update an EXISTING Canon/Thinking note, use `append_file` (never `write_file` — it overwrites and loses prior facts).

### Reviewer (runs after Extractor)
- QA pass: did Extractor miss anyone mentioned by name?
- Are all wikilinks pointing to real notes?
- Are locked fields intact?
- Are provenance markers present?
- Reports issues to `Meta/AI-Reflections/review-log.md`

### Implementer (runs after Retro + after Reviewer)
- Reads findings from retro-log.md and review-log.md
- Auto-fixes safe issues (Tier 1): script bugs, broken links, missing stubs, YAML errors
- Queues dangerous items for human review (Tier 3): locked fields, deletions, conflicts
- Closes the self-healing loop — no finding should sit unfixed for more than 2 cycles

### Thinker (runs weekly — Sundays)
- Reads the full vault
- Writes observations to `Meta/AI-Reflections/`
- Looks for: patterns, contradictions, stale actions, orphaned notes
- Proposes connections between notes
- Does external research on concepts/ideas mentioned in the vault

### Mirror (runs weekly — Sundays, after Thinker)
- Reflects Louise's patterns, strengths, weaknesses, and growth over time
- Checks belief-action alignment (Canon/Beliefs/ vs Canon/Actions/)
- Tracks energy patterns (when does engagement happen?)
- Writes to `Meta/AI-Reflections/[DATE] - Mirror.md`
- Direct tone — like a coach, not a cheerleader

### Briefing (runs daily — 7:30 AM)
- Surfaces open/stale actions, recent entries, contextual questions
- Delivers via Obsidian note + ntfy/Discord notification (`notify.sh`)

### Retrospective (runs daily — 9:00 PM)
- Reviews vault health, what went well/poorly
- Proposes changes to agent specs
- Triggers Implementer automatically after running

### Task-Enricher (runs daily — 8:30 AM + on-demand)
- Breaks actions into ADHD-friendly sub-steps (`## Sub-steps` checklist, first step trivially easy)
- Adds an `## Effort` estimate (S/M/L). The model **`append_file`s only the sub-steps/effort block** — it never rewrites the note (so a long action note can't lose its tail to the 12k read cap); the SHELL deterministically flips `enrichment_status: enriched`.
- Deterministic fallback: if the model adds no sub-steps, marks `enrichment_status: needs-enrichment` for retry
- That's the whole job — message-drafting, stale-item nudges, and priority scoring are upstream ideas, not ported

### Researcher (on-demand)
- Single-model synthesis running on the local Ollama model.
- Includes **Web Access**: Uses a local SearxNG instance (`SEARXNG_URL` env var, `.secrets/searxng-url.txt`, or `http://localhost:8888` fallback) to search the web, with a DuckDuckGo HTML fallback. It fetches specific URLs to blend external context with vault notes.
- **Web access is Researcher-ONLY (2026-07-09):** the harness registers `fetch_url`/`search_web` only when `OLLAMA_AGENT_WEB=1` is set, and only `run-researcher.sh` sets it. No other agent (Extractor, Enricher, Advisor, …) can reach the web — a prompt-injected transcript cannot exfiltrate vault content through these tools.
- Bash deterministically greps Canon/Thinking for up to 8 topic-related notes; one model call synthesizes them and the web results into a research note in `Thinking/Research/` (Summary / What the vault says / Open questions / Recommendations)
- **Verification pass (2026-07-02):** a second vault-only model call fact-checks the draft against the same notes and appends a `## Verification (self-check)` section flagging any ungrounded claim (skip with `RESEARCHER_NO_VERIFY=1`)
- `--scan` mode: picks the first action flagged `enrichment_status: needs-research`; **scheduled daily 08:45** (reliability round)
- Links research back to the triggering action (`## Research` section) and flips `enrichment_status: researched`
- Still not ported from upstream (by design): multi-persona perspectives, enrichment scatter phase, non-blocking notify (multi-persona adds little to a vault-only synthesis)

### Operator (on-demand — triggered by Orchestrator or human request)
- Takes an action and drafts a proposed deliverable (email | calendar | document | message)
- Queues the draft at `Meta/operations/pending/<op-id>.md` for HUMAN review — approval-queue scaffold only
- NEVER sends or executes anything — external execution is intentionally NOT wired (privacy-first, no credentials); the human acts on approved drafts themselves
- NEVER fires without human ✅ — this is the hardest rule and the most important one

### Advisor (always-on via Open WebUI + Discord bot)
- Vault-aware chat assistant: warm, concise, answers from the vault — never guesses
- Receives chat via Open WebUI (`advisor-server.py`, :8723, model `autoadhd-advisor`) and the
  Discord bot (plain text and `/ask` both go to the same endpoint — one mode, no triage/deep split)
- **Dynamic vault lookup**: uses the local Ollama tool harness (`ollama_agent.py`) with
  READ-ONLY tools (`read_file`/`grep`/`list_dir`) — can look anything up, can NEVER mutate the vault from chat
- **Within-conversation context (2026-07-02):** the server now feeds the recent prior turns of the
  current chat to the agent (`_history()`), so follow-ups ("what about the other one?") have context.
  Still NO cross-session persistent memory file — that would require writing state, which breaks the
  read-only-from-chat guarantee; it's an intentional non-goal, not a gap.
- **Does NOT trigger other agents from chat** (no EXTRACT/RESEARCH/DECOMPOSE keywords) — intentional:
  plain chat is strictly read-only, so it can never mutate the vault. There is no `/strategy` command —
  Discord commands are `/actions` `/done` `/ask` `/brief` `/focus` `/draft` `/research` (the last
  three, added 2026-07-08, run the Orchestrator/Operator/Researcher scripts — explicit commands,
  not chat keywords, and all propose-only).
- Serves an OpenAI-compatible endpoint for Open WebUI (stream:true supported, single-chunk)
- Runtime config: env `OLLAMA_AGENT_MODEL` / `ADVISOR_PORT` (+ `ADVISOR` entry in `agent-runtimes.conf`)

### Orchestrator (scheduled daily 10:00 via `auto-orchestrator.sh`, plus on-demand)
- "Focus mode" for one action: surfaces the ONE next unchecked sub-step, no LLM in the loop
- `auto-orchestrator.sh` runs daily at 10:00 (`scheduler.py`): it finds the highest-priority open
  action itself (scans `Canon/Actions/` for `status: open`/`in-progress`, picks the top `priority`)
  and hands it straight to `run-orchestrator.sh` — a proactive focus push, not a dormant tool.
  Run it directly on a specific action any time: `run-orchestrator.sh <action>`. There is still no
  `/run` Discord command.
- If the action has no `## Sub-steps` yet, calls the Task-Enricher first to decompose it
- Rewrites a `## Orchestrator` section on the action note (next step + progress count); you check
  steps off yourself in Obsidian — it never auto-checks or executes anything
- If the next step looks like a deliverable (email/draft/document/…), hands it to the Operator,
  which queues a draft for approval (never sends)
- Notifies the next step via `notify.sh` (ntfy/Discord fan-out)
- State: `Meta/decomposer/<slug>.json` (single source of truth)
- Code: `run-orchestrator.sh` (self-contained bash + inline python) is the focus-mode logic;
  `auto-orchestrator.sh` is the scheduled wrapper that auto-selects the action
- Upstream's interactive `/run` flow (choice buttons, recursion, DAG walking, timeouts) was never
  ported

---

## EMOJI HEADINGS

Every note MUST have a type-appropriate emoji at the start of its `# H1` heading. This helps with ADHD-friendly visual scanning.

| Type | Emoji | Example |
|------|-------|---------|
| action | 🎯 | `# 🎯 Get Driving License` |
| person | 👤 | `# 👤 Mickey` |
| event | 📅 | `# 📅 Founders Meeting March` |
| concept | 💡 | `# 💡 Speed Over Perfection` |
| decision | ⚖️ | `# ⚖️ Split Codex and Claude` |
| reflection | 💭 | `# 💭 Thinking About Focus` |
| belief | 🪨 | `# 🪨 Speed Beats Perfection` |
| research | 🔬 | `# 🔬 Market Analysis: Strategy Tools` |
| project | 📁 | `# 📁 VaultSandbox` |
| place | 📍 | `# 📍 Wonder Wharf` |
| organization | 🏢 | `# 🏢 Family Funtime Corporation` |
| ai-reflection | 🤖 | `# 🤖 Weekly Reflection W12` |
| emerging | 🌱 | `# 🌱 Half-formed idea about X` |
| sprint-task | 🏗️ | `# 🏗️ Fix Voice Pipeline` |
| sprint-proposal | 💡 | `# 💡 Async Agent Coordination` |

Emoji goes in H1 heading ONLY — not in filenames (keeps wikilinks clean).
All agents that create or update notes must apply the correct emoji.

---

## GIT

Every change is tracked by git. This is your safety net.
Commit after meaningful changes with clear messages.
