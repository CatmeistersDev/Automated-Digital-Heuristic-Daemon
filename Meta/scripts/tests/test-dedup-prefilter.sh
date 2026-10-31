#!/bin/bash
# test-dedup-prefilter.sh — behavioral test for Meta/scripts/dedup-prefilter.py
# (Phase 1 hardening, 2026-07-18). Asserts: byte-identical-after-normalization notes
# are flagged as an exact-match group (no LLM needed), near-duplicate notes above the
# Jaccard threshold surface as LLM candidates, unrelated notes are skipped entirely,
# and the threshold is env-overridable. Read-only over Canon/ — asserts nothing is
# written. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
PREFILTER="$SCRIPT_DIR/dedup-prefilter.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Canon/People" "$TV/Canon/Organizations"

# Exact-normalized-hash duplicate pair (People): identical body, cosmetic frontmatter
# difference only (normalization strips frontmatter, so these hash equal).
cat > "$TV/Canon/People/Exact One.md" <<'EOF'
---
type: person
name: Exact One
source: ai-extracted
---
# 👤 Exact One

A quiet collaborator who mostly reviews pull requests on weekends.
EOF
cat > "$TV/Canon/People/Exact Two.md" <<'EOF'
---
type: person
name: Exact Two
created: 2026-01-01
---
# 👤 Exact One

A quiet collaborator who mostly reviews pull requests on weekends.
EOF

# Near-duplicate pair (Organizations): high token overlap, NOT identical -> above
# the default 0.3 Jaccard threshold but not an exact hash match.
cat > "$TV/Canon/Organizations/Funtime Corp.md" <<'EOF'
---
type: organization
name: Funtime Corp
---
# 🏢 Funtime Corp

Funtime Corp is a logistics company based in Denver providing shipping and warehousing services.
EOF
cat > "$TV/Canon/Organizations/Funtime Corporation.md" <<'EOF'
---
type: organization
name: Funtime Corporation
---
# 🏢 Funtime Corporation

Funtime Corporation is a logistics company based in Denver providing shipping and warehousing services.
EOF

# Unrelated organization: near-zero token overlap with the pair above -> must be
# skipped entirely (never sent to the LLM, never an exact match).
cat > "$TV/Canon/Organizations/Random Org.md" <<'EOF'
---
type: organization
name: Random Org
---
# 🏢 Random Org

Completely unrelated text about zebras painting rainbows during quiet thunderstorms.
EOF

OUT="$(VAULT_DIR="$TV" python3 "$PREFILTER" 2>&1)"

PARSE() { printf '%s' "$OUT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
$1
"; }

check "output is valid JSON"                          bash -c 'printf "%s" "$1" | python3 -c "import json,sys; json.load(sys.stdin)"' _ "$OUT"
check "exact-hash group found for People"              [ "$(PARSE 'print(len(data["exact_groups"]))')" -ge 1 ]
check "exact group canonical is Exact One"              [ "$(PARSE 'print(data["exact_groups"][0]["canonical"])')" = "Exact One" ]
check "exact group duplicates include Exact Two"        [ "$(PARSE 'print("Exact Two" in data["exact_groups"][0]["duplicates"])')" = "True" ]
check "near-duplicate Organizations pair sent to LLM"   [ "$(PARSE 'print(sorted(data["candidates"].get("Organizations", [])))')" = "['Funtime Corp', 'Funtime Corporation']" ]
check "unrelated Random Org NOT sent to LLM"            [ "$(PARSE 'print("Random Org" in data["candidates"].get("Organizations", []))')" = "False" ]
check "stats: at least 1 exact duplicate counted"       [ "$(PARSE 'print(data["stats"]["exact"] >= 1)')" = "True" ]
check "stats: at least 2 sent to LLM"                   [ "$(PARSE 'print(data["stats"]["sent_to_llm"] >= 2)')" = "True" ]
check "stats: skipped includes the unrelated org"       [ "$(PARSE 'print(data["stats"]["skipped"] >= 1)')" = "True" ]

# --- read-only: no note under Canon/ was touched ---
check "read-only: Random Org.md still present"    test -f "$TV/Canon/Organizations/Random Org.md"
check "read-only: no review-queue dir created"    test ! -d "$TV/Meta/review-queue"

# --- threshold is env-overridable: an impossibly high threshold sends nothing ---
OUT2="$(VAULT_DIR="$TV" DEDUP_JACCARD_THRESHOLD=0.999 python3 "$PREFILTER" 2>&1)"
CANDS2="$(printf '%s' "$OUT2" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(sum(len(v) for v in d["candidates"].values()))')"
check "threshold=0.999 sends nothing to the LLM"  [ "$CANDS2" -eq 0 ]

[ "$fail" -eq 0 ] && echo "test-dedup-prefilter: PASS" || { echo "test-dedup-prefilter: FAIL"; exit 1; }
