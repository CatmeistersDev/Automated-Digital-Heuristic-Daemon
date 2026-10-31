#!/bin/bash
# test-dlq.sh — behavioral test for the failed-audio dead-letter queue in process-voice-memo.sh.
# Asserts: bounded retries (attempt counter in Meta/.voice-progress/), quarantine to
# Inbox/Voice/_failed/ with a .reason.txt sidecar after VOICE_MAX_ATTEMPTS, and counter
# cleanup on a successful transcription. Stubs the whisperx engine. Exit 0 = pass.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
PVM="$SCRIPT_DIR/process-voice-memo.sh"
TV="$(mktemp -d)"; STUB="$(mktemp -d)"
trap 'rm -rf "$TV" "$STUB"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Inbox/Voice/_drop" "$TV/Meta"
DROP="$TV/Inbox/Voice/_drop"

# The Ollama env vars make the post-transcription correct/extract steps fail FAST
# (connection refused) instead of retrying against the real model host.
run_pvm() { VAULT_DIR="$TV" VOICE_MAX_ATTEMPTS=3 PATH="$STUB:$PATH" \
    OLLAMA_HOST="http://127.0.0.1:9" OLLAMA_RETRIES=1 OLLAMA_RETRY_DELAY=0 \
    bash "$PVM" "$DROP/$1" >/dev/null 2>&1; }

# --- Failure path: whisperx stub produces nothing -> transcription empty every time ---
printf '#!/bin/bash\nexit 1\n' > "$STUB/whisperx"; chmod +x "$STUB/whisperx"
BAD="memo_7-1-26-10.00.3gp"
echo not-really-audio > "$DROP/$BAD"
AF="$TV/Meta/.voice-progress/${BAD}.attempts"

run_pvm "$BAD" || true   # attempt 1
check "attempt 1: audio stays in _drop for retry"  test -f "$DROP/$BAD"
check "attempt 1: counter = 1"                     grep -qx 1 "$AF"
run_pvm "$BAD" || true   # attempt 2
check "attempt 2: counter = 2"                     grep -qx 2 "$AF"
run_pvm "$BAD" || true   # attempt 3 -> quarantine
check "attempt 3: audio quarantined to _failed"    test -f "$TV/Inbox/Voice/_failed/$BAD"
check "attempt 3: reason sidecar written"          grep -q "transcription empty/failed" "$TV/Inbox/Voice/_failed/${BAD}.reason.txt"
check "attempt 3: counter retired"                 test ! -f "$AF"
check "attempt 3: _drop is clear"                  test ! -e "$DROP/$BAD"

# --- Success path: stub emits a transcript -> archive + counter cleanup -------------
# The stub writes BOTH the segments json (formatted by python3 when available) and the
# final transcript.txt (used directly when python3 is absent) so the test passes in the
# container and on a dev box alike.
cat > "$STUB/whisperx" <<'EOS'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output_dir" ] && out="$a"; prev="$a"; done
[ -n "$out" ] || exit 1
printf '{"segments":[{"text":"hello world from the stub"}]}' > "$out/stub.json"
printf 'hello world from the stub\n' > "$out/transcript.txt"
EOS
chmod +x "$STUB/whisperx"
GOOD="good_7-1-26-11.00.3gp"
echo not-really-audio > "$DROP/$GOOD"
run_pvm "$GOOD" || true
check "success: audio archived to _processed"      test -f "$TV/Inbox/Voice/_processed/$GOOD"
check "success: counter retired"                   test ! -f "$TV/Meta/.voice-progress/${GOOD}.attempts"
check "success: not quarantined"                   test ! -e "$TV/Inbox/Voice/_failed/$GOOD"

[ "$fail" -eq 0 ] && echo "test-dlq: PASS" || { echo "test-dlq: FAIL"; exit 1; }
