---
type: meta
name: Advisor Persistent Memory (template)
created: 2026-01-01
source: ai-generated
purpose: Template only. The live, read/written copy is $VAULT_DIR/Meta/advisor-knowledge.md.
---

# Advisor Knowledge (template)

> **Not the live file (2026-07-27).** This copy lives in the code repo (`Meta/Agents/`), which is
> baked into the Docker image and wiped on every rebuild+recreate — so it can't be where persistent
> state actually lives. `advisor-server.py` reads/writes `$VAULT_DIR/Meta/advisor-knowledge.md` on
> the vault data volume instead (see `_knowledge_skeleton()`, `_system_prompt()`,
> `_apply_knowledge_updates()`). This file is kept only as a reference for the section headings and
> intent; edit the one on the vault volume if you want to seed it by hand.

This file is the Advisor agent's persistent memory. It learns about you over time.

## Patterns Noticed

<!-- The Advisor will fill this in as it learns your patterns -->

## What Works

<!-- Coaching approaches that landed well -->

## What Doesn't Work

<!-- Approaches that backfired or felt off -->

## Key Context

<!-- Important life context the Advisor should always remember -->
