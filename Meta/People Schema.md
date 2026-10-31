---
type: reference
name: People Schema
created: 2026-07-01
updated: 2026-07-01
source: ai-generated
source_agent: Claude
source_date: 2026-07-01T18:00
---

# 👤 People Schema

The schema for `Canon/People/` entries. Referenced by `CLAUDE.md` ("For People entries, follow
the schema in `Meta/README/People Schema.md`") and `.claude/skills/vault-writer/SKILL.md`.
People notes are **reference data, not narratives** — no `## Evolution` section (that's for
Actions/Decisions/Beliefs/Projects only).

## Frontmatter — field ordering

Fields appear in this order. `type`, `name`, `source` and `created` are **required** (enforced by
`Meta/scripts/validate-frontmatter.py`); `updated` is strongly recommended. Include optional fields
only when the fact is actually known (never fabricate a value to fill a slot).

```yaml
---
type: person                 # required
name: Jimmy Pesto             # required — human-readable, matches the filename (no emoji)
aliases: [Jimmy, J. Pesto]    # optional — nicknames / spellings; check BEFORE creating a new person
born: 1984-07-23             # optional — YYYY-MM-DD (or YYYY if only the year is known)
phone: "+1 555 0142"         # optional — quote it (leading + breaks YAML)
email: jimmy@example.com     # optional
city: Seymour's Bay          # optional
employer: "[[Family Funtime Corporation]]"    # optional — wikilink if the org has a Canon/Organizations/ note
relationship: colleague      # optional — e.g. wife | brother | colleague | client | friend
relationship_to: "[[Louise]]"  # optional — who the relationship is anchored to
tags: [work, the-wheelie-mammoth-job]      # optional
linked:                      # optional — related people / projects / events
  - "[[The Wheelie Mammoth Job]]"
created: 2026-06-03          # required
updated: 2026-07-01          # recommended — bump on every edit
source: ai-extracted         # required — voice | human | ai-extracted | ai-generated | ai-enriched
source_agent: Extractor      # required when source is ai-* (+ source_date: ISO timestamp)
source_date: 2026-06-03T06:20
locked:                      # optional — human-verified fields AI must NEVER change
  - born
---
```

## Naming

- **Filename = `name` field**, no emoji, no type prefix: `Canon/People/Jimmy Pesto.md` → `[[Jimmy Pesto]]`.
- Use the fullest confirmed form of the name. First-name-only is fine until a surname is confirmed
  (`Tina.md`); rename the file (don't duplicate) when the full name is learned, and keep the
  old short form in `aliases`.
- **Never guess identity.** Is "Teddy" the same as "Theodore"? Ask Louise — don't merge, don't assume.
  Dedup only *proposes* merges to `Meta/review-queue/`.

## Body formatting

```markdown
# 👤 Jimmy Pesto

One short prose paragraph: who this person is and why they're in the vault.
Wikilink every known entity: works on [[The Wheelie Mammoth Job]] with [[Louise]].

AI-added facts carry a provenance comment. <!-- source: ai-extracted, agent: Extractor, 2026-06-03T06:20, from: 2026-06-03 - Voice - call-notes.md -->
```

- H1 heading MUST be `# 👤 Name` — the `# ` prefix and the 👤 emoji are both mandatory
  (emoji in H1 only, never in the filename).
- Keep the body compact prose; add `##` sections only when a person accumulates enough
  material to need them (e.g. `## Context`, `## Open threads`).
- Every AI-added fact traces to a memo via an inline `<!-- source: ... -->` comment.

## Rules that bite

1. **Locked fields win.** If a new memo contradicts a field listed in `locked:`, keep the locked
   value and ignore the contradiction. Only the human unlocks.
2. **Check `aliases` across all of `Canon/People/` before creating a new person** — duplicates are
   worse than a missed link.
3. **Uncertain facts get flagged, not asserted**: birth dates, ages, relationship labels, spellings
   → append the item to `Meta/review-queue/<date>-uncertain-facts.md`, or state the uncertainty in the note.
4. Update existing notes with `append_file` (never `write_file` — it overwrites prior facts) and
   bump `updated:`.
