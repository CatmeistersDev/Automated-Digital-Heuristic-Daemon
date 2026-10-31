---
type: agent-spec
name: Extractor
trigger: per new voice memo (automatic)
script: Meta/scripts/run-extractor.sh
created: 2026-03-18
source: ai-generated
---

# Extractor Agent

> **This agent's spec has been trimmed to just what actually ships** — see git history for the
> original upstream design this was ported from.
>
> **What actually ships** (verified against the code, 2026-07-26):
> - **Runs:** `run-extractor.sh`, automatically after each memo is transcribed
>   (`process-voice-memo.sh:292`), plus a 2-hourly catch-up sweep for memos stranded at
>   `inbox`/`transcribed` (`scheduler.py:345`). Also takes an explicit note path.
> - **Does:** one self-contained prompt (`run-extractor.sh:124-192`) that creates Canon notes
>   stamped `source`/`source_agent`/`source_date` and wikilinked, and may only `append_file` to
>   existing notes. The shell then rebuilds the inbox note from a pre-extraction snapshot:
>   `# Raw` byte-exact, `status: extracted`, `## Extracted` list appended.
> - **Does not:** read any `.claude/skills/*` SKILL.md (the prompt is standalone), ask for the
>   inline `<!-- source: ... -->` comments described below, or reconcile `updated:`/`status:`.
