---
type: meta
name: Engineering Working Agreement
created: 2026-06-24
updated: 2026-06-24
source: ai-generated
status: active
---

# Engineering Working Agreement (LOCAL)

How code and automation changes are made in this vault. Adapted from upstream for our
**local Ollama / Docker** build. Goal: good changes in small steps, verified fast, no lost work.

## Principles
1. **Small batches.** Focused commits over broad mixed changes.
2. **Scoped staging only.** NEVER `git add -A` / `git add .`. Stage explicit paths
   (`git add Canon/ Thinking/ "$note"`). All runners already follow this — keep it that way.
3. **One pipeline writes at a time.** `scheduler.py` serializes mutating jobs behind a vault lock
   (`scheduler.py:146-148`). For runs started by hand outside the scheduler, `lib-agent.sh` provides
   `agent_acquire_lock`, wired into all 12 mutating runners (see Status below), so manual and
   scheduled runs also serialize against each other across processes.
4. **Clean tree for standalone agents.** Thinker/Mirror/Retro/Dedup/Groomer should run on a
   clean worktree (`agent_assert_clean_worktree`); skip otherwise. Override: `VAULT_AGENT_ALLOW_DIRTY=1`.
   **Exempt:** the inline voice pipeline (`process-voice-memo.sh` → `run-extractor.sh`) runs
   dirty by design (it just created the note).
5. **Provenance is mandatory.** Every fact traces to an inbox note / quote / URL.
6. **`# Raw` is sacred and shell-owned.** Agents never rewrite it (see run-extractor.sh write-back).
7. **CI before done.** Run `make check` (= `ci-check.sh`: bash -n, py_compile, shellcheck,
   frontmatter) before considering script work complete. A pre-commit hook
   (`pre-commit-guard.sh`) blocks deletions in protected dirs unless `VAULT_ALLOW_DELETE=1`.

## Token / source discipline
- Prefer passing file paths + read instructions over pasting full content...
- **...EXCEPTION (intentional):** the Extractor pastes transcript **chunks** inline because the
  agent's read tool caps at ~12k chars and silently dropped long meetings. Chunked inline paste
  is the fix — do not "optimize" it back to path-passing for transcripts.
- Save intermediate results to files and re-read them; don't nest prior full transcripts into prompts.
- Update an existing note with `append_file`, never `write_file` (write_file overwrites/loses facts).

## Shared library
`lib-agent.sh` provides the glue — `agent_git`, `agent_assert_clean_worktree`,
`agent_acquire_lock`/`release`, `agent_stage_and_commit` (scoped), `agent_filtered_worktree_status`
(ignores `.obsidian/workspace.json`, `_drop/`, locks), forbidden-path asserts.

## Status of compliance
- Scoped staging: ✅ all shell runners. Pre-commit guard: ✅ available (`make install-hooks`).
  Frontmatter validator: ✅.
  **Exception:** the LLM harness's own `git_commit` tool falls back to `git add -A` when called
  without explicit paths (`ollama_agent.py:486`). Pass `paths` to keep it scoped.
- Clean-tree guard wired: ✅ Thinker/Mirror (`run-thinker.sh`), Retro, Dedup, Groomer.
- Single-pipeline lock: ✅ `agent_acquire_lock("vault-pipeline", ...)` wired into all 12 mutating
  runners (correct-transcript, extractor, reviewer, implementer, task-enricher, researcher,
  operator, orchestrator, thinker, retro, dedup, groomer) — serializes manual and scheduled
  runs against each other across processes, not just the scheduler's in-process lock.
