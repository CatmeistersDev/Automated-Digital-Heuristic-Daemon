#!/bin/bash
# run-health.sh — vault/pipeline health watchdog. Deterministic, no LLM.
# Catches SILENT failures (the original problem): stuck memos, dead services,
# unreachable model. Writes Meta/health.md and pushes an ntfy alert on failure.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OLLAMA_HOST="${OLLAMA_HOST:-http://ollama:11434}"
NOW="$(date '+%Y-%m-%d %H:%M')"

LINES=(); FAILS=0
ok()   { LINES+=("- [OK] $1"); }
fail() { LINES+=("- [FAIL] $1"); FAILS=$((FAILS+1)); }

# Scheduler/voice watcher alive
# NOTE: the slim container has no pgrep/ps — scan /proc directly (cmdline is NUL-separated; -a treats it as text)
if grep -aslq "scheduler.py" /proc/*/cmdline 2>/dev/null; then ok "scheduler + voice watcher running"; else fail "scheduler.py NOT running"; fi
# Advisor endpoint (send bearer token when locked down so the check isn't a false 401)
ADV_AUTH=(); [ -n "${ADVISOR_TOKEN:-}" ] && ADV_AUTH=(-H "Authorization: Bearer ${ADVISOR_TOKEN}")
if curl -sf -m 5 "${ADV_AUTH[@]}" "http://localhost:8723/v1/models" >/dev/null 2>&1; then ok "advisor server responding (8723)"; else fail "advisor server not responding"; fi
# Ollama reachable
if curl -sf -m 8 "$OLLAMA_HOST/api/tags" >/dev/null 2>&1; then ok "Ollama reachable"; else fail "Ollama unreachable at $OLLAMA_HOST"; fi
# ntfy reachable — the alert channel itself. If it's down, pushed alerts silently vanish, so
# surface it here (this health note is written to disk regardless, and Discord fan-out still fires).
if [ -n "${NTFY_URL:-}" ]; then
    if curl -sf -m 5 "${NTFY_URL%/}/v1/health" >/dev/null 2>&1 || curl -sf -m 5 "${NTFY_URL%/}" >/dev/null 2>&1; then
        ok "ntfy reachable"
    else
        fail "ntfy unreachable at $NTFY_URL (pushed alerts may not be delivered)"
    fi
fi
# Recent notification-send failures. notify.sh can't alert about its own failures, so it logs
# them to Meta/notify-errors.log; surface any written in the last ~65min (health runs hourly).
NERR="$VAULT_DIR/Meta/notify-errors.log"
if [ -f "$NERR" ] && [ -n "$(find "$NERR" -mmin -65 2>/dev/null)" ]; then
    fail "recent notification-send failure: $(tail -1 "$NERR" 2>/dev/null)"
fi
# Stuck voice memos (real audio sitting in _drop >10 min = pipeline stalled)
STUCK=$(find Inbox/Voice/_drop -maxdepth 1 -type f ! -name '.*' ! -name '*.tmp' ! -name '*.part' -mmin +10 2>/dev/null | wc -l | tr -d ' ')
if [ "$STUCK" -eq 0 ]; then ok "no stuck memos in _drop"; else fail "$STUCK memo(s) stuck in _drop >10min"; fi
# Quarantined memos (dead-letter queue). process-voice-memo.sh already alerted ONCE at
# quarantine time, so this is a standing line item — NOT a [FAIL] — to avoid the old
# "same broken file re-alerts hourly forever" behavior the DLQ exists to end.
NQUAR=$(find Inbox/Voice/_failed -maxdepth 1 -type f ! -name '.*' ! -name '*.reason.txt' 2>/dev/null | wc -l | tr -d ' ')
[ "$NQUAR" -gt 0 ] && LINES+=("- [WARN] $NQUAR memo(s) quarantined in Inbox/Voice/_failed awaiting manual triage (see .reason.txt sidecars)")
# Syncthing conflict files (if the vault is synced to another device, a note edited on the phone
# and by an agent within the same sync window can race). Standing WARN, not a FAIL: nothing is
# down, a human just needs to pick a side and delete the loser. Syncthing's own naming is
# "name.sync-conflict-YYYYMMDD-HHMMSS-XXXXXXX.ext" -- matched loosely so a naming-scheme tweak
# on Syncthing's side doesn't silently stop tripping this.
CONFLICTS=$(find . -path ./.git -prune -o -iname '*sync-conflict-*' -type f -print 2>/dev/null)
NCONFLICT=$(printf '%s\n' "$CONFLICTS" | grep -c . || true)
if [ "$NCONFLICT" -gt 0 ]; then
    SAMPLE=$(printf '%s\n' "$CONFLICTS" | head -3 | tr '\n' ' ')
    LINES+=("- [WARN] $NCONFLICT Syncthing conflict file(s) awaiting manual resolution: $SAMPLE$([ "$NCONFLICT" -gt 3 ] && echo '...')")
else
    ok "no Syncthing conflict files"
fi
# Stranded memos: transcribed but extraction never completed. The scheduler's 2-hourly
# no-arg run-extractor.sh catch-up should clear these; alert only past 150min (> the catch-up
# interval) so this fires only when catch-up itself isn't recovering them — never during normal
# processing or the recovery window. mtime-based so a note actively mid-extraction isn't flagged.
# End-anchored ($) so a future status value that merely starts with "inbox"/"transcribed"
# (e.g. a typo'd or new status) can't false-match an exact-value regex.
STRANDED=0
while IFS= read -r sn; do
    [ -n "$sn" ] && [ -n "$(find "$sn" -mmin +150 2>/dev/null)" ] && STRANDED=$((STRANDED+1))
done < <(grep -rlE "^status: (inbox|transcribed)[[:space:]]*$" Inbox/ 2>/dev/null)
if [ "$STRANDED" -eq 0 ]; then ok "no stranded transcribed memos"; else fail "$STRANDED memo(s) stranded at inbox/transcribed >150min (extraction not completing — check Ollama/run-extractor)"; fi
# Mechanical checks (Phase 1 hardening, 2026-07-18): near-empty Canon/Thinking stubs +
# Manifest/vault drift. Deterministic, no LLM. Report-only — surfaced as WARN lines
# (like the DLQ line above), never bumps FAILS: these are content-quality nudges, not
# service-down signals. Feature-detected so a partially-deployed image degrades cleanly.
if [ -f "$SCRIPT_DIR/mechanical-checks.py" ]; then
    MECH_OUT="$(VAULT_DIR="$VAULT_DIR" python3 "$SCRIPT_DIR/mechanical-checks.py" 2>/dev/null)"
    MECH_WARNS=0
    while IFS=$'\t' read -r sev msg; do
        [ "$sev" = "WARN" ] || continue
        LINES+=("- [WARN] $msg")
        MECH_WARNS=$((MECH_WARNS+1))
    done <<< "$MECH_OUT"
    [ "$MECH_WARNS" -eq 0 ] && ok "no near-empty stubs or manifest drift"
fi
# Recent pipeline activity (last git commit age, if repo)
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    LAST=$(git log -1 --format=%ct 2>/dev/null || echo 0)
    AGE_H=$(( ( $(date +%s) - LAST ) / 3600 ))
    ok "last vault commit ${AGE_H}h ago"
fi

STATUS="OK"; [ "$FAILS" -gt 0 ] && STATUS="$FAILS ISSUE(S)"
{
    echo "---"; echo "type: health"; echo "checked: $NOW"; echo "status: $STATUS"; echo "---"; echo ""
    echo "# 🏥 Vault Health — $NOW"; echo ""
    printf '%s\n' "${LINES[@]}"
} > "$VAULT_DIR/Meta/health.md"
echo "Health: $STATUS"
printf '%s\n' "${LINES[@]}"

# Alert on failure (ntfy no-ops if unconfigured)
if [ "$FAILS" -gt 0 ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "⚠️ AutoADHD health: $FAILS issue(s)" "$(printf '%s\n' "${LINES[@]}" | grep FAIL)" "high" "warning" "Meta/health.md" 2>/dev/null || true
fi
exit "$FAILS"
