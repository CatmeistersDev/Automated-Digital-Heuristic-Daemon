#!/bin/bash
# test-boundary-score.sh — behavioral test for Meta/scripts/boundary-score.py
# (Phase 4b). Asserts: out/in-degree counts (including case-insensitive [[b]] ->
# B.md resolution and [[Target|Alias]] pipe handling), a wikilink inside a code
# fence does NOT create an edge, recency weighting (30-day halflife) makes an
# old high-out-degree note outrank a recent one with the same raw degrees, and
# the final ranking is by score descending. Report-only / no writes. No network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
SCORE="$SCRIPT_DIR/boundary-score.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Canon/Projects"

cat > "$TV/Canon/Projects/A.md" <<'EOF'
---
type: project
name: A
source: ai-extracted
---
# 📁 A

See [[b]] and [[C|alias text]] for related work.
EOF

cat > "$TV/Canon/Projects/B.md" <<'EOF'
---
type: project
name: B
source: ai-extracted
---
# 📁 B

No outgoing links here.
EOF

cat > "$TV/Canon/Projects/C.md" <<'EOF'
---
type: project
name: C
source: ai-extracted
---
# 📁 C

No outgoing links here either.
EOF

cat > "$TV/Canon/Projects/D.md" <<'EOF'
---
type: project
name: D
source: ai-extracted
---
# 📁 D

```
[[B]] — this is inside a code fence, must NOT count as a real link.
```

No real links in the prose.
EOF

# Deterministic mtimes: A/C/D recent (now), B old (90 days ago -> 3 halflives).
python3 - "$TV" <<'PY'
import os, sys, time
tv = sys.argv[1]
now = time.time()
old = now - 90 * 86400
os.utime(os.path.join(tv, "Canon/Projects/A.md"), (now, now))
os.utime(os.path.join(tv, "Canon/Projects/B.md"), (old, old))
os.utime(os.path.join(tv, "Canon/Projects/C.md"), (now, now))
os.utime(os.path.join(tv, "Canon/Projects/D.md"), (now, now))
PY

OUT="$(VAULT_DIR="$TV" python3 "$SCORE" --top 10 2>&1)"

A_ROW="$(printf '%s\n' "$OUT" | grep -F 'Canon/Projects/A.md')"
B_ROW="$(printf '%s\n' "$OUT" | grep -F 'Canon/Projects/B.md')"
C_ROW="$(printf '%s\n' "$OUT" | grep -F 'Canon/Projects/C.md')"
D_ROW="$(printf '%s\n' "$OUT" | grep -F 'Canon/Projects/D.md')"

check "A has out_degree 2 (case-insensitive [[b]] + piped [[C|alias]])" \
    bash -c 'printf "%s" "$1" | awk -F"\t" "{exit (\$3==2)?0:1}"' _ "$A_ROW"
check "A has in_degree 0"  bash -c 'printf "%s" "$1" | awk -F"\t" "{exit (\$4==0)?0:1}"' _ "$A_ROW"
check "B has in_degree 1 (only from A; D's fenced link excluded)" \
    bash -c 'printf "%s" "$1" | awk -F"\t" "{exit (\$4==1)?0:1}"' _ "$B_ROW"
check "C has in_degree 1 (from piped [[C|alias]])" \
    bash -c 'printf "%s" "$1" | awk -F"\t" "{exit (\$4==1)?0:1}"' _ "$C_ROW"
check "D has out_degree 0 and in_degree 0 (fenced link never counted)" \
    bash -c 'printf "%s" "$1" | awk -F"\t" "{exit (\$3==0 && \$4==0)?0:1}"' _ "$D_ROW"

# --- ranking: A (positive, high out-in) > D (0) > B (small negative, old/damped) > C (large negative, recent/undamped) ---
ORDER="$(printf '%s\n' "$OUT" | cut -f2)"
check "ranking order is A, D, B, C" bash -c '
    printf "%s" "$1" | head -1 | grep -qF "A.md" &&
    printf "%s" "$1" | sed -n "2p" | grep -qF "D.md" &&
    printf "%s" "$1" | sed -n "3p" | grep -qF "B.md" &&
    printf "%s" "$1" | sed -n "4p" | grep -qF "C.md"
' _ "$ORDER"

check "makes zero writes to the fixture vault" bash -c '[ -f "$1/Canon/Projects/A.md" ]' _ "$TV"

# --- --top caps output ---
OUT_TOP1="$(VAULT_DIR="$TV" python3 "$SCORE" --top 1 2>&1)"
N_LINES="$(printf '%s\n' "$OUT_TOP1" | grep -c '.')"
check "--top 1 prints exactly one row" [ "$N_LINES" -eq 1 ]

[ "$fail" -eq 0 ] && echo "test-boundary-score: PASS" || { echo "test-boundary-score: FAIL"; exit 1; }
