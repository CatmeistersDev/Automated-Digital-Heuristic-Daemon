#!/bin/bash
# test-bm25-index.sh — behavioral test for Meta/scripts/bm25-index.py (Phase 4a,
# ranked lexical retrieval for the Researcher, 2026-07-18). Asserts: build indexes
# Canon/+Thinking/ but skips Canon/_stubs/; query ranks best-first and caps a single
# note at 2 result lines; wikilink syntax indexes as its target word; the hermetic
# title/type/first-sentence prefix lets a query match a chunk that never repeats the
# note's own subject; incremental build skips unchanged notes and drops entries for
# deleted notes; a missing/corrupt index makes query print nothing and exit 10 (the
# "fall back to grep" signal). No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
BM25="$SCRIPT_DIR/bm25-index.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Canon/People" "$TV/Canon/_stubs" "$TV/Thinking"

cat > "$TV/Canon/People/Tina.md" <<'EOF'
---
type: person
name: Tina
---
# Tina

Tina is a backend engineer who loves distributed systems and rock climbing.

She recently started mentoring junior engineers on system design topics.
EOF

cat > "$TV/Canon/People/Bob.md" <<'EOF'
---
type: person
name: Bob
---
# Bob

Bob works in marketing and enjoys hiking on weekends with his dog.
EOF

# Stub note — must be excluded from the index entirely, even though its content
# would otherwise be a strong match.
cat > "$TV/Canon/_stubs/Ghost.md" <<'EOF'
---
type: person
name: Ghost
---
# Ghost

distributed systems distributed systems distributed systems
EOF

# Wikilink note: [[Tina]] must tokenize as "tina" (brackets/pipe stripped), not
# be invisible to a query for "tina".
cat > "$TV/Thinking/Distributed Systems.md" <<'EOF'
---
type: concept
name: Distributed Systems
---
# Distributed Systems

Distributed systems research is a topic [[Tina]] cares deeply about, especially consensus algorithms.
EOF

# --- Task 1: build + query ---
BUILD1="$(VAULT_DIR="$TV" python3 "$BM25" build 2>&1)"
check "build: index file created" test -f "$TV/Meta/.bm25-index.json"
check "build: indexed 3 notes (stub excluded)" bash -c 'printf "%s" "$1" | grep -q "^bm25-index: 3 notes"' _ "$BUILD1"

Q1="$(VAULT_DIR="$TV" python3 "$BM25" query "distributed systems" --top 5)"
RC1=$?
check "query: exit 0 on a real index"          [ "$RC1" -eq 0 ]
check "query: at least one hit"                [ -n "$Q1" ]
check "query: stub note never appears"         bash -c '! printf "%s" "$1" | grep -q "_stubs"' _ "$Q1"
TOP_NOTE="$(printf '%s\n' "$Q1" | head -1 | cut -f2)"
check "query: best-first (Distributed Systems note ranks #1)" [ "$TOP_NOTE" = "Thinking/Distributed Systems.md" ]

# --- wikilink tokenization: [[Tina]] must match a plain query for "tina" ---
QA="$(VAULT_DIR="$TV" python3 "$BM25" query "tina" --top 5)"
check "wikilink: [[Tina]] note matches a query for 'tina'" bash -c 'printf "%s" "$1" | grep -q "Distributed Systems.md"' _ "$QA"

# --- no-match query: valid index, zero hits -> exit 0, prints nothing ---
QN="$(VAULT_DIR="$TV" python3 "$BM25" query "zzznonexistentztermz" --top 5)"
RCN=$?
check "query: unmatched terms -> exit 0"   [ "$RCN" -eq 0 ]
check "query: unmatched terms -> no output" [ -z "$QN" ]

# --- dedup cap: a note contributing 3+ matching chunks shows at most 2 lines ---
mkdir -p "$TV/Canon/Projects"
{
  echo "---"
  echo "type: project"
  echo "name: Widget Project"
  echo "---"
  echo "# Widget Project"
  echo ""
  for i in 1 2 3; do
    echo "Widget project paragraph $i talks about widgets and widget manufacturing at length."
    echo ""
  done
} > "$TV/Canon/Projects/Widget Project.md"
VAULT_DIR="$TV" python3 "$BM25" build >/dev/null
QW="$(VAULT_DIR="$TV" python3 "$BM25" query "widget" --top 10)"
WIDGET_LINES="$(printf '%s\n' "$QW" | grep -c 'Widget Project.md')"
check "dedup: Widget Project.md appears at most twice" [ "$WIDGET_LINES" -le 2 ]
check "dedup: Widget Project.md appears at least once" [ "$WIDGET_LINES" -ge 1 ]

# --- Task 2: hermetic contextual prefixing — a chunk far into a note that never
# repeats the note's own title/subject still matches a query for that subject,
# because indexing prefixes every chunk with title + type + first sentence. ---
mkdir -p "$TV/Canon/Projects"
FILLER="$(python3 -c "print(('Meanwhile the team discussed unrelated logistics and scheduling minutiae at length. ' * 30))")"
{
  echo "---"
  echo "type: project"
  echo "name: Quokka Rollout"
  echo "---"
  echo "# Quokka Rollout"
  echo ""
  echo "Short intro paragraph mentioning the Quokka Rollout kickoff."
  echo ""
  echo "$FILLER"
} > "$TV/Canon/Projects/Quokka Rollout.md"
VAULT_DIR="$TV" python3 "$BM25" build >/dev/null
QQ="$(VAULT_DIR="$TV" python3 "$BM25" query "quokka" --top 10)"
QQ_LINES="$(printf '%s\n' "$QQ" | grep -c 'Quokka Rollout.md' || true)"
check "hermetic prefix: query for the note's own title matches a filler-only chunk too" [ "$QQ_LINES" -ge 2 ]

# --- Incremental build: unchanged notes are not re-touched, deleted notes drop out ---
BUILD2="$(VAULT_DIR="$TV" python3 "$BM25" build 2>&1)"
check "incremental: second build reindexes nothing" bash -c 'printf "%s" "$1" | grep -qE "\(0 \(re\)indexed"' _ "$BUILD2"

rm -f "$TV/Canon/People/Bob.md"
BUILD3="$(VAULT_DIR="$TV" python3 "$BM25" build 2>&1)"
QB="$(VAULT_DIR="$TV" python3 "$BM25" query "hiking marketing dog" --top 10)"
check "incremental: deleted note no longer indexed" bash -c 'echo "$1" | grep -q "notes ("' _ "$BUILD3"
check "incremental: deleted Bob note never returned by query" bash -c '! printf "%s" "$1" | grep -q "Bob.md"' _ "$QB"

# --- missing/corrupt index: query prints nothing, exits 10 ---
rm -f "$TV/Meta/.bm25-index.json"
QM="$(VAULT_DIR="$TV" python3 "$BM25" query "anything" 2>&1)"
RCM=$?
check "missing index: exit code 10"  [ "$RCM" -eq 10 ]
check "missing index: no output"     [ -z "$QM" ]

echo "garbage not json" > "$TV/Meta/.bm25-index.json"
QC="$(VAULT_DIR="$TV" python3 "$BM25" query "anything" 2>&1)"
RCC=$?
check "corrupt index: exit code 10"  [ "$RCC" -eq 10 ]
check "corrupt index: no output"     [ -z "$QC" ]

[ "$fail" -eq 0 ] && echo "test-bm25-index: PASS" || { echo "test-bm25-index: FAIL"; exit 1; }
