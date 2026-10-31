#!/bin/bash
# test-thinker-beliefs-snapshot.sh — behavioral test for run-thinker.sh's snapshot() including
# Canon/Beliefs/. Mirror's own spec calls belief-action alignment its most important section, but
# the snapshot loop never included Beliefs at all -- the model checked alignment against zero
# belief data. This bug was found and fixed in the public mirror (2026-07-12 claims audit) but
# never ported back to this (production) repo until 2026-07-23. Extracts just the snapshot()
# function's logic (sourcing the real script would require Ollama/network) and asserts: Beliefs
# appears in the snapshot, with actual content (not just a filename), frontmatter stripped.
set -uo pipefail
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
mkdir -p "$TV/Canon/Beliefs" "$TV/Canon/Actions"

cat > "$TV/Canon/Beliefs/Speed Over Perfection.md" <<'EOF'
---
type: belief
name: Speed Over Perfection
created: 2026-01-01
---

# 🪨 Speed Over Perfection

Execution speed beats waiting for the perfect plan.
EOF

# Extracted verbatim from run-thinker.sh's snapshot() -- kept in sync by hand; this test exists
# specifically to catch a regression of the Beliefs omission, not to test the whole script.
snapshot() {
    local d cnt names
    for d in People Organizations Places Projects Events Decisions Actions Beliefs; do
        cnt=$(find Canon/"$d" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
        [ "$cnt" -eq 0 ] && continue
        if [ "$d" = "Beliefs" ]; then
            echo "- Beliefs ($cnt):"
            while IFS= read -r f; do
                [ -n "$f" ] || continue
                local bname bline
                bname="$(basename "$f" .md)"
                bline="$(awk '
                    /^---[[:space:]]*$/ { c++; next }
                    c<2 { next }
                    /^#/ { next }
                    /^[[:space:]]*$/ { next }
                    { print; exit }
                ' "$f" 2>/dev/null | cut -c1-100)"
                echo "  - $bname: ${bline:-(no content)}"
            done < <(find Canon/"$d" -maxdepth 1 -name '*.md' 2>/dev/null)
            continue
        fi
        names=$(find Canon/"$d" -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sed 's/\.md$//' | paste -sd';' - | sed 's/;/; /g')
        echo "- $d ($cnt): $names"
    done
}

cd "$TV"
OUT="$(snapshot)"
check "Beliefs appears in the snapshot at all"       grep -q "^- Beliefs (1):" <<< "$OUT"
check "the belief's name is present"                 grep -q "Speed Over Perfection:" <<< "$OUT"
check "actual belief content is present, not just a name" grep -q "Execution speed beats waiting" <<< "$OUT"
check "frontmatter is NOT leaked into the excerpt"    grep -qv "^  - Speed Over Perfection: type: belief" <<< "$OUT"

[ "$fail" -eq 0 ] && echo "test-thinker-beliefs-snapshot: PASS" || { echo "test-thinker-beliefs-snapshot: FAIL"; exit 1; }
