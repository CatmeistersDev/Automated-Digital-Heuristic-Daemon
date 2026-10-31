#!/bin/bash
# test-health-syncthing-conflicts.sh — behavioral test for run-health.sh's Syncthing
# conflict-file watchdog. The vault storage cutover to local ZFS + Syncthing (2026-07-23) made
# phone-vs-agent edit races on the same note possible for the first time; Syncthing drops
# "name.sync-conflict-<timestamp>-<device>.ext" files when that happens, and nothing was
# watching for them. Asserts: a standing [WARN] line (not a FAIL -- nothing is down) lists the
# conflict count and a sample when one or more exist, and a clean "no conflicts" [OK] line
# otherwise, regardless of unrelated network checks failing in this sandboxed environment.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
HEALTH="$SCRIPT_DIR/run-health.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
mkdir -p "$TV/Inbox/Voice/_drop" "$TV/Meta" "$TV/Canon/Actions"
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
checknot() { local d="$1"; shift; if ! "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

# Unreachable network deps by design -- this test only cares about the conflict-file line, and
# run-health.sh keeps running (adding [FAIL] lines) rather than aborting when those are down.
run_health() {
    VAULT_DIR="$TV" OLLAMA_HOST="http://127.0.0.1:9" NTFY_URL="" \
        bash "$HEALTH" 2>/dev/null
}

# --- Clean vault: no conflict files ---
OUT="$(run_health)"
check "clean vault: reports no conflict files" \
    grep -q "no Syncthing conflict files" <<< "$OUT"
checknot "clean vault: does not report a conflict WARN" \
    grep -q "conflict file(s) awaiting" <<< "$OUT"

# --- One conflict file, dropped by Syncthing under a real note ---
CONFLICT1="$TV/Canon/Actions/X5 Maintenance.sync-conflict-20260723-051500-NLQEN4F.md"
echo "conflicting content from the phone" > "$CONFLICT1"
OUT="$(run_health)"
check "one conflict: WARN line present"        grep -q "1 Syncthing conflict file(s)" <<< "$OUT"
check "one conflict: sample names the file"    grep -q "X5 Maintenance.sync-conflict" <<< "$OUT"
checknot "one conflict: not a FAIL"             grep -q "\[FAIL\].*conflict" <<< "$OUT"
check "one conflict: health.md also records it" grep -q "1 Syncthing conflict file(s)" "$TV/Meta/health.md"

# --- A second conflict elsewhere, plus one inside .git (must be pruned, not counted) ---
mkdir -p "$TV/.git/objects"
echo ignored > "$TV/.git/objects/should-not-count.sync-conflict-20260723-051500-XXXXXXX.md"
CONFLICT2="$TV/Inbox/Text/_drop/note.sync-conflict-20260723-060000-E4IMIM4.md"
mkdir -p "$(dirname "$CONFLICT2")"
echo "another conflict" > "$CONFLICT2"
OUT="$(run_health)"
check "two conflicts: count is exactly 2 (not 3 -- .git excluded)" \
    grep -q "2 Syncthing conflict file(s)" <<< "$OUT"
checknot "two conflicts: .git-internal match never surfaces" \
    grep -q "should-not-count" <<< "$OUT"

[ "$fail" -eq 0 ] && echo "test-health-syncthing-conflicts: PASS" || { echo "test-health-syncthing-conflicts: FAIL"; exit 1; }
