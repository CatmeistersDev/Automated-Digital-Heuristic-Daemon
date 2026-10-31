#!/bin/bash
# test-voice-memo-gps-slug.sh — behavioral test for process-voice-memo.sh's GPS-in-title fix.
# The Tasker capture filename embeds raw home/office GPS (loc_<lat>,<lon>_<date>), which used to
# ride straight into the created note's filename (= Obsidian title, = every notification title).
# Asserts: the note's filename/title carries none of the coordinate digits, the gps: frontmatter
# field still captures them correctly (unchanged behavior), audio_file: still preserves the full
# original filename for audit trail, and a filename with no loc_ segment is untouched (no-op).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
PVM="$SCRIPT_DIR/process-voice-memo.sh"
TV="$(mktemp -d)"; STUB="$(mktemp -d)"
trap 'rm -rf "$TV" "$STUB"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
checknot() { local d="$1"; shift; if ! "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Inbox/Voice/_drop" "$TV/Meta"
DROP="$TV/Inbox/Voice/_drop"

cat > "$STUB/whisperx" <<'EOS'
#!/bin/bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "--output_dir" ] && out="$a"; prev="$a"; done
[ -n "$out" ] || exit 1
printf '{"segments":[{"text":"hello world from the stub"}]}' > "$out/stub.json"
printf 'hello world from the stub\n' > "$out/transcript.txt"
EOS
chmod +x "$STUB/whisperx"

run_pvm() { VAULT_DIR="$TV" PATH="$STUB:$PATH" \
    OLLAMA_HOST="http://127.0.0.1:9" OLLAMA_RETRIES=1 OLLAMA_RETRY_DELAY=0 \
    bash "$PVM" "$DROP/$1" >/dev/null 2>&1; }

# --- GPS-bearing filename, matching the real Tasker capture pattern ---
GPS_FILE="loc_12.345678901234567,-98.76543210987654_7-21-26-09.10.3gp"
echo not-really-audio > "$DROP/$GPS_FILE"
run_pvm "$GPS_FILE" || true
NOTE="$(find "$TV/Inbox/Voice" -maxdepth 1 -name '*.md' | head -1)"
check "a note was created"                                  test -n "$NOTE"
checknot "note filename carries no latitude digits"          grep -q "12.345" <<< "$(basename "$NOTE")"
checknot "note filename carries no longitude digits"         grep -q "98.765" <<< "$(basename "$NOTE")"
checknot "note filename carries no 'loc_' marker"            grep -qi "loc_" <<< "$(basename "$NOTE")"
check "gps: frontmatter still captures the coordinates"      grep -q "^gps: \[12.345678901234567, -98.76543210987654\]" "$NOTE"
check "audio_file: frontmatter keeps the full original name" grep -q "^audio_file: ${GPS_FILE%.3gp}\$" "$NOTE"

# --- Filename with no loc_ segment at all -> untouched (no-op) ---
rm -f "$TV"/Inbox/Voice/*.md
PLAIN_FILE="quick-note_7-21-26-10.30.3gp"
echo not-really-audio > "$DROP/$PLAIN_FILE"
run_pvm "$PLAIN_FILE" || true
NOTE2="$(find "$TV/Inbox/Voice" -maxdepth 1 -name '*.md' | head -1)"
check "no-loc_ filename still produces a note"                test -n "$NOTE2"
check "no-loc_ filename's slug is unaffected (no-op)"         grep -q "quick-note" <<< "$(basename "$NOTE2")"
checknot "no-loc_ filename has no gps: line (no GPS in name)" grep -q "^gps:" "$NOTE2"

[ "$fail" -eq 0 ] && echo "test-voice-memo-gps-slug: PASS" || { echo "test-voice-memo-gps-slug: FAIL"; exit 1; }
