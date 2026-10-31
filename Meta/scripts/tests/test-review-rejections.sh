#!/bin/bash
# test-review-rejections.sh — behavioral test for Meta/scripts/review-rejections.py
# (Phase 2 hardening, 2026-07-18): the rejection-feedback memory core library.
# Asserts: rejection counting, cap-based blocking, unblock resets the counting
# window without erasing history, dedup item-key normalization is order-independent,
# proposal-file item-key extraction handles both proposal shapes (dedup groups +
# groomer stale-action bullets), and the dedup-specific exact/candidate filters and
# PREVIOUS REJECTIONS context builder. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
LIB="$SCRIPT_DIR/review-rejections.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -q -- "$2"; }
not_contains() { ! printf '%s' "$1" | grep -q -- "$2"; }
is_blank() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }
not_blocked() { ! python3 "$LIB" blocked --item-key "$1" >/dev/null 2>&1; }

export VAULT_DIR="$TV"
mkdir -p "$TV/Meta"

# --- basic record/count ---
c1="$(python3 "$LIB" record --item-key "dedup:a+b" --agent Dedup --proposal-file x.md --feedback "not the same" | tr -d '\r')"
check "first rejection count is 1" [ "$c1" -eq 1 ]
check "not blocked at count 1" not_blocked "dedup:a+b"

# --- cap-based blocking (default cap 5) ---
for i in 2 3 4 5; do
    python3 "$LIB" record --item-key "dedup:a+b" --agent Dedup --proposal-file x.md --feedback "still no" >/dev/null
done
check "blocked at count 5 (default cap)" bash -c 'python3 "$1" blocked --item-key "dedup:a+b" >/dev/null 2>&1' _ "$LIB"
check "count reports 5" [ "$(python3 "$LIB" count --item-key "dedup:a+b" | tr -d '\r')" -eq 5 ]

# --- cap is overridable, both via --cap and REVIEW_REJECTION_CAP ---
check "cap override: not blocked at count 5 vs cap 10" bash -c '! python3 "$1" blocked --item-key "dedup:a+b" --cap 10 >/dev/null 2>&1' _ "$LIB"
check "env REVIEW_REJECTION_CAP=3 -> blocked at count 5" bash -c 'REVIEW_REJECTION_CAP=3 python3 "$1" blocked --item-key "dedup:a+b" >/dev/null 2>&1' _ "$LIB"

# --- unblock resets the counting window without erasing history ---
python3 "$LIB" unblock --item-key "dedup:a+b" --note "reconsidered" >/dev/null
check "unblocked: count resets to 0" [ "$(python3 "$LIB" count --item-key "dedup:a+b" | tr -d '\r')" -eq 0 ]
check "unblocked: no longer blocked" not_blocked "dedup:a+b"
python3 "$LIB" record --item-key "dedup:a+b" --agent Dedup --proposal-file x.md --feedback "again" >/dev/null
check "unblocked: history preserved, new rejection is count 1" [ "$(python3 "$LIB" count --item-key "dedup:a+b" | tr -d '\r')" -eq 1 ]
check "rejections log still has all 6 historical entries" [ "$(grep -c '"item_key"' "$TV/Meta/.review-rejections.jsonl")" -eq 6 ]

# --- dedup_key normalization is order-independent and case/whitespace-insensitive ---
k1="$(python3 "$LIB" normalize-dedup-key --names "Funtime Corp, Funtime Corporation" | tr -d '\r')"
k2="$(python3 "$LIB" normalize-dedup-key --names "funtime corporation ,  FUNTIME CORP" | tr -d '\r')"
check "dedup key is order/case/whitespace independent" [ "$k1" = "$k2" ]

# --- extract-item-keys: dedup proposal shape (multiple groups in one file) ---
DEDUP_FILE="$TV/dedup-proposal.md"
cat > "$DEDUP_FILE" <<'EOF'
---
type: review-item
source_agent: Dedup
---
CANONICAL: Funtime Corp
DUPLICATES: Funtime Corporation
WHY: exact normalized-text match

CANONICAL: Bob Smith
DUPLICATES: Bobby Smith, Robert Smith
WHY: alias variant
EOF
mapfile -t ROWS < <(python3 "$LIB" extract-item-keys --file "$DEDUP_FILE" | tr -d '\r')
ROWS_TEXT="$(printf '%s\n' "${ROWS[@]}")"
check "extract-item-keys found 2 dedup groups" [ "${#ROWS[@]}" -eq 2 ]
check "agent field is Dedup" [ "${ROWS[0]%%$'\t'*}" = "Dedup" ]
check "first group key present" contains "$ROWS_TEXT" "dedup:funtime corp+funtime corporation"
check "second group key present (3 names)" contains "$ROWS_TEXT" "dedup:bob smith+bobby smith+robert smith"

# --- extract-item-keys: groomer stale-action shape ---
STALE_FILE="$TV/stale-proposal.md"
cat > "$STALE_FILE" <<'EOF'
---
type: review-item
source_agent: Groomer
---
- [[Get driving license]] — last activity 2026-05-01 (78d ago)
- [[Fix the roof]] — last activity 2026-04-01 (108d ago)
EOF
mapfile -t SROWS < <(python3 "$LIB" extract-item-keys --file "$STALE_FILE" | tr -d '\r')
SROWS_TEXT="$(printf '%s\n' "${SROWS[@]}")"
check "extract-item-keys found 2 stale actions" [ "${#SROWS[@]}" -eq 2 ]
check "stale key normalized" contains "$SROWS_TEXT" "stale-action:get driving license"

# --- get-frontmatter ---
check "get-frontmatter reads source_agent" \
    [ "$(python3 "$LIB" get-frontmatter --file "$DEDUP_FILE" --key source_agent | tr -d '\r')" = "Dedup" ]
check "get-frontmatter missing key -> empty" \
    is_blank "$(python3 "$LIB" get-frontmatter --file "$DEDUP_FILE" --key nope | tr -d '\r')"

# --- filter-exact-groups: suppress a previously-rejected exact group outright ---
PJ='{"exact_groups":[{"type":"Organizations","canonical":"Widget Co","duplicates":["Widget Company"]}],"candidates":{}}'
FILTERED1="$(printf '%s' "$PJ" | python3 "$LIB" filter-exact-groups 2>/dev/null | tr -d '\r')"
check "exact group survives before any rejection" contains "$FILTERED1" "Widget Co"
python3 "$LIB" record --item-key "dedup:widget co+widget company" --agent Dedup --proposal-file x --feedback "different companies" >/dev/null
FILTERED2="$(printf '%s' "$PJ" | python3 "$LIB" filter-exact-groups 2>/dev/null | tr -d '\r')"
check "exact group suppressed after a SINGLE rejection (no cap wait)" is_blank "$FILTERED2"

# --- filter-candidates: drop only names belonging to a BLOCKED (cap+) group ---
PJ2='{"exact_groups":[],"candidates":{"People":["Bob Smith","Bobby Smith","Robert Smith","Random Guy"]}}'
for i in 1 2 3 4 5; do
    python3 "$LIB" record --item-key "dedup:bob smith+bobby smith" --agent Dedup --proposal-file x --feedback "no $i" >/dev/null
done
FILTERED3="$(printf '%s' "$PJ2" | python3 "$LIB" filter-candidates 2>/dev/null | tr -d '\r')"
check "blocked pair's names removed from candidates" not_contains "$FILTERED3" "Bob Smith"
check "unrelated candidate name kept" contains "$FILTERED3" "Random Guy"
check "third name (not in blocked pair) kept" contains "$FILTERED3" "Robert Smith"

# --- relevant-context: only surfaces context for groups fully present in candidates ---
NAMES_FILE="$TV/names.txt"
printf 'Widget Co\nWidget Company\nSomeone Else\n' > "$NAMES_FILE"
CTX="$(python3 "$LIB" relevant-context --names-file "$NAMES_FILE" 2>/dev/null | tr -d '\r')"
check "relevant-context surfaces the Widget rejection" contains "$CTX" "different companies"
check "relevant-context header present" contains "$CTX" "PREVIOUS REJECTIONS"
NAMES_FILE2="$TV/names2.txt"
printf 'Someone Unrelated\n' > "$NAMES_FILE2"
CTX2="$(python3 "$LIB" relevant-context --names-file "$NAMES_FILE2" 2>/dev/null | tr -d '\r')"
check "relevant-context empty when no group's names are all present" is_blank "$CTX2"

[ "$fail" -eq 0 ] && echo "test-review-rejections: PASS" || { echo "test-review-rejections: FAIL"; exit 1; }
