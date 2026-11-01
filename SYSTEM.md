# AutoADHD — System Guide (current state)

**Status: COMPLETE & running.** Local, private, free (no Anthropic/cloud). Last updated 2026-07-15
(Groomer fix: 14d→7d archive threshold + fixed the silent digest failure — see changelog below).
Prior: 2026-07-15 backlog hardening round (log rotation, weekly ci-check, backup gap, notify/authn
fixes). 2026-06-24: chunked extraction + shell-owned `# Raw`; 4 voiceprints enrolled; upstream QA
tools ported. 2026-06-23: WhisperX + diarization + voiceprint speaker-ID. History in LOOP_LOG.
This is the canonical "what exists / how it works / how to operate" doc. The blow-by-blow build
history is in `LOOP_LOG.md`; this file is the summary to read first.

## What it is
Voice memos → structured Obsidian notes, plus a vault-aware chat and daily/weekly agents — all
running on the user's own box via a local LLM. In this repo's demo data the vault owner is
**Louise**; set `VAULT_OWNER` to your own name.

## The engine (the core idea)
Upstream AutoADHD's agents relied on Claude Code's tool-use. We replaced that with
`Meta/scripts/ollama_agent.py` — a model-agnostic **prompt-based JSON tool harness** that gives a
local Ollama model file tools (read/write/grep/bash/git). Every agent flows through
`invoke-agent.sh` → `ollama_agent.py`.
- **Model:** a **Qwen3.6 35B A3B** build served by Ollama (set `OLLAMA_AGENT_MODEL` to whichever build
  your GPU forgives).
- **Design rule:** concrete tasks = directive self-contained prompt; analytical tasks = HYBRID
  (bash does deterministic work, model makes ONE focused judgment). Deterministic safety nets +
  a "last-prose fallback" in the harness make agents robust to off-protocol replies.

## Topology (reference deployment)

This is the shape the system was built and verified against. Hostnames, addresses and paths below
are **placeholders** — substitute your own. Everything is env vars in `docker-compose.yml`.

- **One always-on host** (a NAS or small server) runs Ollama (`:11434`) and all containers.
- **Container `autoadhd-brain`**: runs `scheduler.py` (voice watcher + cron jobs) and the Advisor
  server. Compose env: `VAULT_DIR=/vault`, `OLLAMA_HOST=http://ollama:11434`,
  `VAULT_OWNER=<your name>`, `NTFY_URL`/`NTFY_TOPIC`, **`WHISPER_MODEL=large-v3`**,
  `WHISPER_DEVICE=cpu`, `WHISPER_LANG=en`. Ports: 8723 (Advisor).
  - **Pin the image tag.** A bare `image: autoadhd-brain` resolves to whatever `:latest` happens to
    be and can silently downgrade the transcription engine on a recreate — the WhisperX image bakes
    in WhisperX + CPU torch 2.8, while an older `:latest` may still carry openai-whisper.
  - **Give the model cache a persistent volume** mounted at `/root/.cache`. It holds ~3.3 GB of
    Whisper/pyannote/wespeaker weights; without it every recreate re-downloads them.
- **Vaults (2):**
  - A dev checkout of this code repo, wherever you work on it.
  - **The LIVE vault = container `/vault`**, bind-mounted from the host directory that holds your
    Obsidian vault. git-tracked.
- **ntfy** server: its own container, reachable at `NTFY_URL`, topic `autoadhd`.
- **Open WebUI** (host network): connect to the Advisor at `http://localhost:8723/v1` (model
  `autoadhd-advisor`).
- **Capture:** Android (Fossify Voice Recorder; the older Tasker profile, which puts GPS in the filename, still works) → Syncthing → `Inbox/Voice/_drop`.

## Agents / scripts (Meta/scripts/)
- `ollama_agent.py` — the tool harness (engine). `invoke-agent.sh` — chokepoint router (default runtime=ollama).
- `process-voice-memo.sh` — WhisperX (diarized) → speaker-ID relabel → note → correct → extract →
  archive → notify. (called by watcher) Auto-detects `whisperx` on PATH; falls back to legacy whisper.
- `process-text-note.sh` — text/markdown/PDF-drop counterpart to the voice pipeline: wraps a file
  dropped in `Inbox/Text/_drop/` into a standard Inbox note (frontmatter auto-filled, original
  content preserved byte-exact under `# Raw`) → chains `run-extractor.sh` (skip with
  `TEXTNOTE_NO_EXTRACT=1`) → archives to `Inbox/Text/_processed/` → notifies. PDFs (and anything
  dropped in `Inbox/Text/_drop-noextract/`) are filed to `Clippings/` instead — reference material,
  `type: clipping`, never extracted, agent-read-only. PDF text comes from pymupdf; unreadable/empty/
  non-UTF-8/unparseable-PDF drops are quarantined to `Inbox/Text/_failed/` with a `.reason.txt`
  sidecar. Test: `Meta/scripts/tests/test-text-note.sh`.
- `speaker_id.py` — speaker enrollment + identification (pyannote wespeaker 256-d embeddings, cosine
  match). `enroll-voice.sh <Name> <audio…>` (or `<Name> --from-memo <json> <SPEAKER_xx> <audio>`) →
  `Meta/voiceprints/<slug>.json`. Solo memos label the lone speaker as VAULT_OWNER (no model load);
  meetings embed each cluster and name enrolled people, rest stay SPEAKER_xx.
- `run-extractor.sh` — memo → Canon notes. **Chunked** (feeds the transcript inline in ~9k-char
  pieces so long meetings aren't truncated by the read cap); the SHELL owns the inbox note (preserves
  `# Raw`, flips status, appends `## Extracted`); model updates existing notes with `append_file`,
  never `write_file`. Chunk progress is checkpointed by `extract-checkpoint.py`
  (`Meta/.extract-progress/<transcript-sha256>.json`, keyed to the transcript text so an edit
  invalidates it automatically) so a scheduler-timeout kill mid-memo resumes from the next chunk on
  the next catch-up pass instead of re-running chunks that already wrote real files. `run-reviewer.sh`
  — QA (hybrid); resolves [[wikilinks]] vault-wide (Obsidian
  semantics — a basename match anywhere, NOT the old root-only check that false-flagged every
  subfolder link) and is idempotent per note content-hash so it won't re-flag unchanged notes.
- `run-correct-transcript.sh` — fix proper-noun mis-hears pre-extraction (preserves # Raw). Known
  names are fed one-per-line (NOT `paste -sd', '`, which fused adjacent names — see Open items).
- `dedup-mentions.py` — deterministic post-extraction pass: collapses exact-duplicate entries in an
  action note's `mentions:` array (can happen on a retried chunk or a re-processed memo), byte-for-byte,
  never inventing or dropping a real mention. `note-write-state.py` — records each agent-authored
  Canon/Thinking write's SHA256 (`Meta/.note-write-state.json`) so the next agent write can detect a
  human hand-edited the note in between (technical backstop for the append-only rule; `ollama_agent.py`'s
  own write tools use the same state file).
- **Nightly self-heal chain:** `run-retro.sh` (21:00) → `run-reviewer.sh` (21:30) → `run-implementer.sh`
  (21:45). Also scheduled in `scheduler.py`: `daily-briefing.sh` (07:30) · `run-task-enricher.sh` (08:30)
  · `run-thinker.sh`/`run-mirror.sh` (Sun 10:00/10:30) · `run-groomer.sh`/`run-dedup.sh` (Sun 11:00/11:30)
  · `run-health.sh` (hourly) · `run-backup.sh` (03:15).
- `thinker-conflict-stubs.py` — shell-side companion to `run-thinker.sh`/`run-mirror.sh`: turns a
  `CONFLICT: <topic> — <description>` line from their model output into a propose-only
  `Meta/review-queue/` stub (deduped by topic slug); the model never writes review-queue files itself.
- `run-researcher.sh` — synthesis with optional web-search via SearxNG (`.secrets/searxng-url.txt`;
  see "Researcher Web Access" below); context-gathering is now ranked by `bm25-index.py` (pure-stdlib
  Okapi BM25 over Canon/+Thinking, `Meta/.bm25-index.json`, incremental by per-note hash) instead of a
  naive first-match grep — a missing/corrupt index just falls back to grep. `run-operator.sh` — drafts
  deliverables → `Meta/operations/pending` for a human to read and **copy-paste**; it has no send
  path in the code at all (no mail/calendar/Drive/Notion client, wired or unwired). `run-orchestrator.sh` — focus-mode
  next-step tracker (also auto-triggered daily 10:00 via `auto-orchestrator.sh`, which picks the
  highest-priority open action itself — see the Orchestrator section of CLAUDE.md).
- `run-implementer.sh` — deterministic self-heal, **scheduled 21:45** after the Reviewer. Auto-fixes
  provenance/emoji + path-style/wrong-case [[wikilinks]] → canonical; creates guarded stubs in
  `Canon/_stubs/` (skips pronouns/roles/version-junk + any name in `Meta/implementer-no-stub.txt`);
  flags the rest to `Meta/review-queue/`. Never edits content, merges, or deletes.
- `run-health.sh` — watchdog (stuck memos/dead services) + ntfy alert. `build-manifest.sh` — Meta/MANIFEST.md index.
- `deadman-check.sh` — **HOST-side** dead-man's switch (2026-07-09): runs on the Docker host
  (cron / your NAS's task scheduler, every 15 min — NOT inside the container it watches), alerts via
  ntfy+Discord when the container is down or `Meta/.scheduler-heartbeat` (touched every 60s
  by scheduler.py's supervisor thread) goes stale >10 min. Covers the one failure mode the
  in-container health watchdog can't: total silence. Install AFTER deploying the new scheduler.py.
- `run-dedup.sh` — proposes entity merges to review-queue (never merges); `dedup-prefilter.py` runs
  first (exact-hash + within-type Jaccard similarity, stdlib-only) so the LLM only ever sees
  plausible duplicate candidates, never the whole vault's entity list. `normalize-wikilinks.py` —
  clean [[Name]].
- **Review-queue tooling:** `review-queue-list.sh` lists `Meta/review-queue/` sorted by rejection
  count, tagging anything at/over the cap `[BLOCKED]`. `review-reject.sh <file|item-key> ["feedback"]`
  records a human rejection (or `--sweep` picks up hand-edited `status: rejected` notes);
  `review-unblock.sh <item-key>` resets the counting window without erasing history.
  `review-rejections.py` is the shared state library (`Meta/.review-rejections.jsonl` /
  `.review-unblocks.jsonl`) that Dedup and Groomer both consult so a human's rejection isn't
  re-proposed (default cap 5, `REVIEW_REJECTION_CAP`).
- `run-decision-mining.sh` — scheduled daily 09:15 but self-gates to the 1st of the month
  (`DECISION_MINING_FORCE=1` to force a manual run); wraps `mine-commit-decisions.py --queue`, which
  regex-mines the vault's own git log for decision-shaped commit subjects ("switched to", "adopted",
  "replaced X with Y", ...), dedups against existing `Canon/Decisions/` notes and previously-queued
  commits, and queues candidates to `Meta/review-queue/` — propose-only, never creates a Decision
  note itself.
- `notify.sh` — fans out to ntfy, Discord (`send-discord.sh`) and Telegram (`send-telegram.sh`);
  each channel no-op unless its own config is set, so any combination (including none) is valid.
  Per-channel setup guides live in `docs/notifications/`. Outbound alerts only on all three;
  interactive commands are Discord-only in this port. `lib-agent.sh` — shared bash agent lib
  (lock-contention alerts go via `notify.sh`).
- `advisor-server.py` — OpenAI-compatible endpoint (read-only tools) for Open WebUI on :8723.
- `validate-frontmatter.py` — frontmatter schema check (`make validate`). `ci-check.sh` — bash -n +
  py_compile + shellcheck + frontmatter + `Meta/scripts/tests/*.sh` behavioral tests (`make check`).
  `build-canvas.sh` — Obsidian Canvas from wikilinks.
- `normalize-properties.py` — deterministic frontmatter normalization for Bases-ready properties:
  fills a missing action `priority`/`owner`/`first_mentioned`, maps known status synonyms
  (`closed`→`done`, `cancelled`→`dropped`, ...) to the real enum, and rewrites non-ISO dates to
  `YYYY-MM-DD`. Report-only by default; `--fix` applies, `--json` for machine output. Never invents
  a fact — no fabricated due dates or guessed statuses.
- **Report-only vault-graph/lint tools (human-run, no LLM, never edit anything):**
  `boundary-score.py` ranks "frontier" notes (recently touched, weakly backlinked) from the
  wikilink graph; `lineage.py` walks a note's `derived_from:` ancestry up or down; `freshness-lint.py`
  flags present-tense claims ("currently", "there are N") with no `(as of YYYY-MM-DD)` stamp;
  `mechanical-checks.py` (shared by `run-health.sh` and `ci-check.sh`) flags near-empty stub notes
  and `Meta/MANIFEST.md` drift in either direction.
- **Human-run CLI utilities (not scheduled, no LLM in the loop):** `graduate.sh <thinking-note>
  <project|decision|belief>` promotes a Thinking/ note to a crystallized Canon entry, preserving a
  `graduated_from` lineage link and leaving the origin note in place (append-only). `agent-undo.sh`
  lists and safely reverts agent-authored commits — it only ever touches a commit whose subject
  carries the enforced `[Agent-Name] ...` prefix, refusing anything that looks human-authored.
  `bench-models.sh` (+ `bench-models-score.py`) benchmarks a candidate `OLLAMA_AGENT_MODEL`
  replacement against the real Extractor tool-call protocol and fixture transcripts — not a generic
  leaderboard — scoring entity recall, frontmatter correctness, and resistance to an instruction
  injected inside transcript text.
- `pre-commit-guard.sh` — git hook: blocks deletions in protected Canon dirs unless `VAULT_ALLOW_DELETE=1`
  (renames allowed). (Removed 2026-06-30: dead upstream `vault-lib.py` + `vault-mcp-server.py` — Anthropic
  SDK / Telegram MCP, unused in the local build.)
- `send-discord.sh` + `discord-bot.py` — Discord control plane, **ACTIVATED 2026-07-01** (voice→pipeline,
  text→Advisor, `/actions` `/done` `/brief` `/ask`; `/brief` confirmed live). `scheduler.py` starts
  the bot since `.secrets/discord-token.txt` exists; `discord.py` is installed in the live image.
  Tier 1 (`notify.sh` fan-out) posts via the bot token + `.secrets/discord-channel-id.txt` — no
  webhook was available from the Developer Portal, so `send-discord.sh` calls the Discord REST API
  directly instead (`Meta/Discord-Integration-Plan.md`). `Meta/Engineering.md` — engineering working agreement.

## How to operate (the owner)
- **Capture:** speak a memo → it auto-processes → notes appear in Obsidian + ntfy ping.
- **Chat:** Open WebUI → `autoadhd-advisor` ("what are my open actions?"). First reply ~1–2 min (local model).
- **Review (human-in-the-loop):** check off Orchestrator sub-steps; approve items in `Meta/review-queue/`
  (dedup proposals) and `Meta/operations/pending/` (Operator drafts) by hand. Nothing external auto-sends.
- **If it stalls:** `run-health.sh` catches it and pings you.
- **Voice recognition:** solo memos auto-labeled with the vault owner's name; meetings auto-label
  enrolled voices. Enrolled: **Louise, Bob, Linda, Teddy** (`Meta/voiceprints/`). Add more with
  `enroll-voice.sh <Name> <clean-clip>` or `enroll-voice.sh <Name> --from-memo <whisperx.json> <SPEAKER_xx> <audio>`.
  Threshold 0.50 / margin 0.10 (observed self-match 0.89–0.95). NOTE: the matcher can still mis-assign
  (it put the owner's cluster on another enrolled speaker at 0.65 before that print was
  re-enrolled) — verify meeting labels
  against transcript content.

## How to develop/deploy

> **SUPERSEDED 2026-07-09 (code/data split):** code is now BAKED into the image at `/app`; the live vault (`/vault`)
> is data-only (no `Meta/scripts`). Deploy = commit in the code repo → `docker build -t autoadhd-brain:<tag> .`
> → set that tag in the compose file → stop/rm + `compose up -d`.
> Rollback = retag. The "edit the live tree" flow below is HISTORICAL.
- **Live vault = the container's `/vault` mount, bind-mounted from your Obsidian vault directory**
  — the SAME tree the desktop client sees as the Obsidian vault. Edit files there
  directly; they are live immediately (volume-mounted). Per-run scripts (`run-*.sh`, `*.py` invoked
  each run) take effect on the **next invocation**; a change to `scheduler.py` itself needs a
  **container restart** to reload the cron table.
- **Commit in-container** — the `.git` dir is owned by container root and is read-only from an SMB
  client, so commit from inside: `docker exec autoadhd-brain sh -lc 'cd /vault && git -c
  user.name=AutoADHD -c user.email=autoadhd@local commit ...'`. Deletions under `Canon/` are blocked
  by the pre-commit guard unless you prefix `VAULT_ALLOW_DELETE=1`. Stage only your files (the live
  vault always has agent-generated drift: `Meta/health.md`, `MANIFEST.md`, briefings, etc.).
- **Restart to reload `scheduler.py`:** `docker restart autoadhd-brain` (main process is
  `python /vault/Meta/scripts/scheduler.py`, so a plain restart reloads cleanly and avoids the
  compose recreate name-conflict below).
- **Remote access to the host** is however you normally reach it — ssh key, your NAS's web terminal,
  whatever. Keep any credentials in `.secrets/` (gitignored); never in the vault or in `.git/config`.
- Env/compose changes only: edit `docker-compose.yml` and recreate. **Gotcha:** if you manage the
  stack through a container-manager UI, a plain `docker compose up -d --force-recreate` issued from
  inside that manager can hit a name conflict, because the existing container's labels do not match
  the manager's compose project. Reliable recipe:
  `docker stop autoadhd-brain && docker rm autoadhd-brain && docker compose up -d`.
  Host-mounted vault + persistent cache volume → no data loss and no re-download on recreate.
- Test 35B runs in background (~10 min); inspect on completion. Backups in `Meta/operations/_backups/` & compose `.bak`s.

## Key decisions / gotchas
- All scripts must be LF (not CRLF) — `.gitattributes` enforces. CRLF was the original crash.
- Model GGUFs reject Ollama's native tools API → we use the prompt-based protocol.
- Owner is set by `VAULT_OWNER` (**Louise** in the demo data); earlier name variants all fixed.
- **Proper nouns get mis-heard.** WhisperX consistently mangles product names — the demo world's
  **Bucket-Ball** arrives as "Bucket Ball", "Bucket-Bull" and worse. Canon keeps the correct
  spelling; `# Raw` transcripts keep the verbatim mishear (source evidence — corrections live in
  Canon, never in the raw block).
- **Extractor truncation bug (fixed 2026-06-24):** the model used to rewrite the whole inbox note from
  a read-capped copy, silently dropping the tail of long meetings and clobbering `# Raw`. Now the shell
  owns the note and the transcript is fed inline in chunks; existing notes are updated via `append_file`.
- **Transcription = WhisperX large-v3 on CPU + pyannote diarization** (supersedes the 2026-06-06
  "stay on plain CPU whisper" note). GPU still declined — large-v3 on CPU is slower than medium but
  accuracy + speaker labels are worth it; runs in background via the watcher. HF token in
  `.secrets/hf-token.txt` (must start with `hf_`) gates diarization. WhisperX uses a *nested* vendored
  path `whisperX-main/whisperX-main/` and CPU torch 2.8 (the cu128 default would drag in CUDA).
- **Speaker-ID embeddings** use `pyannote/wespeaker-voxceleb-resnet34-LM` (loadable with the existing
  HF token; `pyannote/embedding` is gated/denied). Audio is ffmpeg→in-memory PCM since the slim image
  has no torchaudio file backend (soundfile/sox absent) — don't switch to `torchaudio.load`.
- ntfy topic is open on LAN; add NTFY_TOKEN for off-LAN/auth later.

## Open items

What is unfinished, only partly wired, or worth knowing before you trust it. Verified against the
code in this repo on 2026-07-26.

**Wired less than the docs imply**
- The specs in `Meta/Agents/` describe the upstream cloud design, not this port. Each one opens
  with a **What actually ships** block — that block is the accurate part; the body below it is
  design reference.
- The Researcher's daily 08:45 `--scan` looks for actions flagged
  `enrichment_status: needs-research`, and nothing except the Researcher itself ever writes that
  flag. The scheduled run is a no-op until you flag an action by hand or use `/research <topic>`.
- `Meta/Agents/advisor-knowledge.md` is read by no script. Load it into `ADVISOR_SYS` in
  `advisor-server.py` if you want the Advisor to carry persistent memory.
- ~~`locked:` frontmatter is a convention... not an enforced guarantee~~ — **fixed 2026-07-27**:
  `pre-commit-guard.sh` now runs `check-locked-fields.py`, which blocks a commit that silently
  changes a locked field's value (`VAULT_ALLOW_LOCKED_EDIT=1` to override deliberately).

**Tuning you will probably want**
- Speaker ID ships with **zero** enrolled voices and a conservative matcher (`speaker_id.py`:
  `--threshold 0.50`, `--margin 0.10`). Until you enroll someone with `enroll-voice.sh`, diarized
  memos label speakers `SPEAKER_00`/`SPEAKER_01`. Expect to revisit the threshold once you have
  several voices that sound alike.
- The transcript corrector can only fix a name it can already see as a real Canon note. A product
  or model name that has only ever arrived mangled has nothing to be corrected *to* — create the
  canonical note first, and later mishears get caught.
- `VOICE_MAX_ATTEMPTS` (default 3) bounds retries on un-transcribable audio; after that the file is
  quarantined to `Inbox/Voice/_failed/` with a `.reason.txt` sidecar and one high-priority alert.
  Manual retry is moving the file back into the drop folder.
- `GROOM_ARCHIVE_DAYS` (default 7) sets how quickly daily/retro notes fold into digests.
- Small models given inline content will try to "look it up" with tools unless told not to — the
  Groomer prompt carries an explicit no-tool instruction for exactly that reason
  (`run-groomer.sh:63`). Copy that pattern into any new small-model prompt.

**Security posture to check on your own deployment**
- The Discord bot fails **closed**: with neither `DISCORD_ALLOWED_USER_ID` nor
  `DISCORD_ALLOW_ANYONE=1` it ignores everyone. Set the user ID; do not ship `ALLOW_ANYONE`.
- `ADVISOR_TOKEN` is required — the Advisor refuses to start bound to a non-loopback address
  without one (`advisor-server.py:164-171`).
- The web tools (`fetch_url`/`search_web`) are opt-in per run behind `OLLAMA_AGENT_WEB=1`, which
  only `run-researcher.sh` exports (`:19`). Never export it for the Extractor — that agent reads
  untrusted transcript text.
- `deadman-check.sh` runs on the **host**, not in the container it watches, and its alert path is
  only exercised by a real outage. Test it deliberately instead of assuming it works.

**Ideas, not commitments**
- GPU Whisper for transcription speed, off-LAN ntfy through a reverse proxy, automated off-site
  git backups.
