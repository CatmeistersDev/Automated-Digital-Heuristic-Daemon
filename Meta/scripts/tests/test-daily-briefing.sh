#!/bin/bash
# test-daily-briefing.sh — behavioral test for the field-level change-tracking added to
# daily-briefing.sh 2026-07-23 (replaces the old "repeat today's top-12 open actions"
# behavior, which produced near-identical briefings day after day). Asserts: first run
# establishes a baseline snapshot; a second run correctly reports a resolved action, a
# priority bump, a newly-set due date, and a deleted-note case, while leaving an untouched
# action out of the delta list; a third, change-free run reports "no change". Uses
# BRIEFING_DATE (test-only override) so the test doesn't depend on wall-clock timing.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
BRIEF="$SCRIPT_DIR/daily-briefing.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }
not_contains() { ! printf '%s' "$1" | grep -qF -- "$2"; }

mkdir -p "$TV/Canon/Actions" "$TV/Meta/briefings"
cd "$TV" && git init -q && git config user.email t@t.com && git config user.name t

action() { # name status priority due
cat > "$TV/Canon/Actions/$1.md" <<EOF
---
type: action
name: $1
status: $2
priority: $3
due: $4
---
# 🎯 $1
EOF
}
action "Task A" open medium ""
action "Task B" open medium ""
action "Task C" open medium ""
action "Task D" open medium ""
action "Task E" open medium ""

run_brief() { VAULT_DIR="$TV" BRIEFING_DATE="$1" bash "$BRIEF" >/dev/null 2>&1; }
out() { cat "$TV/Meta/briefings/$1 - Daily Briefing.md" 2>/dev/null; }

# --- Day 1: baseline, no prior snapshot ---
run_brief 2026-01-01
D1="$(out 2026-01-01)"
check "day1: reports baseline"          contains "$D1" "establishing a baseline"
check "day1: snapshot file written"     test -f "$TV/Meta/.briefing-actions-snapshot.json"

# --- Mutate for day 2: resolve A, bump B's priority, set C's due, delete E, leave D alone ---
sed -i 's/^status: open$/status: done/' "$TV/Canon/Actions/Task A.md"
sed -i 's/^priority: medium$/priority: high/' "$TV/Canon/Actions/Task B.md"
sed -i 's/^due: $/due: 2026-01-05/' "$TV/Canon/Actions/Task C.md"
rm -f "$TV/Canon/Actions/Task E.md"

run_brief 2026-01-02
D2="$(out 2026-01-02)"
check "day2: reports 4 changes"         contains "$D2" "4 changes since yesterday"
check "day2: Task A resolved"           contains "$D2" "[[Task A]] — marked done"
check "day2: Task B priority bump"      contains "$D2" "[[Task B]] — priority medium → high"
check "day2: Task C due date set"       contains "$D2" "[[Task C]] — due date set to 2026-01-05"
check "day2: Task E removed"            contains "$D2" "[[Task E]] — was open yesterday, note no longer found"
check "day2: Task D not in delta list"  not_contains "$D2" "[[Task D]] —"
check "day2: 1 unchanged action noted"  contains "$D2" "1 other open action unchanged"

# --- Day 3: no further changes -> quiet-day path ---
run_brief 2026-01-03
D3="$(out 2026-01-03)"
check "day3: reports no change"         contains "$D3" "no change since yesterday"
check "day3: does not repeat old delta" not_contains "$D3" "marked done"

[ "$fail" -eq 0 ] && echo "test-daily-briefing: PASS" || { echo "test-daily-briefing: FAIL"; exit 1; }
