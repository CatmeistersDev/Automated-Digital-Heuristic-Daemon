#!/bin/bash
# process-voice-memo.sh (LOCAL / lean version)
# Audio file -> transcript (WhisperX w/ speaker diarization, or plain Whisper) ->
# Inbox note -> run-extractor.sh -> archive audio.
# Fully local. No Telegram/progress/lib-agent dependencies, no GPS reverse-geocode
# (privacy: coordinates from filename are stored but NOT sent to any web service).
#
# Transcription engine selection (auto):
#   * If `whisperx` is on PATH  -> WhisperX (faster-whisper backend). When a real
#     Hugging Face token is present in .secrets/hf-token.txt, speaker diarization is
#     enabled and the transcript is written with "SPEAKER_xx:" turn labels; notes
#     with 2+ speakers are tagged as meetings (type: meeting).
#   * Otherwise                 -> legacy openai-whisper (plain transcript, no labels).
# This makes the script safe to deploy before/after the whisperx container swap.
#
# Usage: process-voice-memo.sh /path/to/audio.(3gp|m4a|ogg|wav|amr|mp3)
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-/vault}"
cd "$VAULT_DIR" || { echo "FATAL: cannot cd to $VAULT_DIR" >&2; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

AUDIO="${1:-}"
[ -n "$AUDIO" ] || { echo "usage: $0 <audiofile>"; exit 1; }
BASE="$(basename "$AUDIO")"

# Skip Syncthing temp/partial/hidden files (the watcher may fire on these)
case "$BASE" in
    .*|*.tmp|*.part|*~|*.syncthing.*) echo "skip (temp/hidden): $BASE"; exit 0 ;;
esac
# Only handle known audio extensions
case "${BASE,,}" in
    *.3gp|*.m4a|*.ogg|*.wav|*.amr|*.mp3|*.aac|*.opus) : ;;
    *) echo "skip (not audio): $BASE"; exit 0 ;;
esac
[ -f "$AUDIO" ] || { echo "skip (not found, likely renamed): $AUDIO"; exit 0; }

# Wait for the file to stop growing (Syncthing still writing)
prev=-1; for _ in 1 2 3 4 5; do
    cur=$(stat -c %s "$AUDIO" 2>/dev/null || echo 0)
    [ "$cur" = "$prev" ] && [ "$cur" -gt 0 ] && break
    prev="$cur"; sleep 2
done

# --- Dead-letter queue: bounded retries for un-transcribable audio ---------------
# Every attempt is counted at START (so a run killed by the scheduler's job timeout
# still consumes one). After VOICE_MAX_ATTEMPTS the audio is quarantined to
# Inbox/Voice/_failed/ with a .reason.txt sidecar and ONE high-priority alert —
# instead of sitting in _drop re-alerting hourly and re-burning the mutating lock
# on every container-restart drain. Counter clears on success or quarantine.
# Manual retry after fixing the cause: move the file back into _drop.
PROGRESS_DIR="$VAULT_DIR/Meta/.voice-progress"
FAILED_DIR="$VAULT_DIR/Inbox/Voice/_failed"
MAX_ATTEMPTS="${VOICE_MAX_ATTEMPTS:-3}"
ATTEMPT_FILE="$PROGRESS_DIR/${BASE}.attempts"
mkdir -p "$PROGRESS_DIR"
ATTEMPTS=$(( $(cat "$ATTEMPT_FILE" 2>/dev/null || echo 0) + 1 ))
echo "$ATTEMPTS" > "$ATTEMPT_FILE"

quarantine() {   # $1 = one-line reason. Parks audio + sidecar in _failed; alerts once.
    mkdir -p "$FAILED_DIR"
    {
        echo "file: $BASE"
        echo "quarantined: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "attempts: $ATTEMPTS"
        echo "engine: ${ENGINE:-unknown}"
        echo "reason: $1"
        if [ -n "${TMP:-}" ] && [ -f "$TMP/whisperx.log" ]; then
            echo "--- last 20 whisperx.log lines ---"
            tail -n 20 "$TMP/whisperx.log"
        fi
    } > "$FAILED_DIR/${BASE}.reason.txt" 2>/dev/null
    mv "$AUDIO" "$FAILED_DIR/" 2>/dev/null || true
    rm -f "$ATTEMPT_FILE"
    /bin/bash "$SCRIPT_DIR/notify.sh" "🚫 Voice memo quarantined: $BASE" \
        "$1 — gave up after $ATTEMPTS attempt(s); moved to Inbox/Voice/_failed/ (see ${BASE}.reason.txt). Move back to _drop to retry." high "no_entry,rotating_light" 2>/dev/null || true
}

if [ "$ATTEMPTS" -gt "$MAX_ATTEMPTS" ]; then
    quarantine "exceeded $MAX_ATTEMPTS attempts without completing (previous runs crashed or hit the job timeout)"
    exit 0
fi

WHISPER_MODEL="${WHISPER_MODEL:-medium}"
WHISPER_LANG="${WHISPER_LANG:-en}"
WHISPER_DEVICE="${WHISPER_DEVICE:-cpu}"
WHISPER_COMPUTE_TYPE="${WHISPER_COMPUTE_TYPE:-int8}"   # int8 = fast on CPU
WHISPER_MAX_SPEAKERS="${WHISPER_MAX_SPEAKERS:-8}"
FILENAME="$(basename "$AUDIO" | sed 's/\.[^.]*$//')"
# Recording timestamp: prefer the one embedded in the memo filename (trailing M-D-YY-HH.MM after
# the last '_', e.g. ..._7-2-26-00.26) so a memo transcribed late — or reprocessed days later — is
# dated when it was RECORDED, not when the pipeline happened to run. Fall back to now if unparsable.
DATE="$(date +%Y-%m-%d)"; TIME="$(date +%H:%M)"
_stamp="${FILENAME##*_}"
if [[ "$_stamp" =~ ^([0-9]{1,2})-([0-9]{1,2})-([0-9]{2})-([0-9]{2})\.([0-9]{2})$ ]]; then
    _mo=$((10#${BASH_REMATCH[1]})); _dy=$((10#${BASH_REMATCH[2]})); _yr=$((10#${BASH_REMATCH[3]}))
    _hh=$((10#${BASH_REMATCH[4]})); _mm=$((10#${BASH_REMATCH[5]}))
    if [ "$_mo" -ge 1 ] && [ "$_mo" -le 12 ] && [ "$_dy" -ge 1 ] && [ "$_dy" -le 31 ] \
       && [ "$_hh" -le 23 ] && [ "$_mm" -le 59 ]; then
        DATE="$(printf '20%02d-%02d-%02d' "$_yr" "$_mo" "$_dy")"
        TIME="$(printf '%02d:%02d' "$_hh" "$_mm")"
    fi
fi

# --- Hugging Face token (for diarization). Only a real hf_ token enables it. ---
HF_TOKEN=""
HF_TOKEN_FILE="$VAULT_DIR/.secrets/hf-token.txt"
if [ -f "$HF_TOKEN_FILE" ]; then
    _t="$(tr -d '[:space:]' < "$HF_TOKEN_FILE" 2>/dev/null)"
    case "$_t" in hf_*) HF_TOKEN="$_t" ;; esac   # ignore PASTE_... placeholder
fi

TMP="$(mktemp -d)"
TRANSCRIPT=""
N_SPEAKERS=0
ENGINE="whisper"

transcribe_whisperx() {
    # Returns transcript on stdout via $TMP/transcript.txt; sets N_SPEAKERS via stdout int.
    local diarize=()
    if [ -n "$HF_TOKEN" ]; then
        diarize=(--diarize --hf_token "$HF_TOKEN" --min_speakers 1 --max_speakers "$WHISPER_MAX_SPEAKERS")
    fi
    whisperx "$AUDIO" --model "$WHISPER_MODEL" --language "$WHISPER_LANG" \
        --device "$WHISPER_DEVICE" --compute_type "$WHISPER_COMPUTE_TYPE" \
        --output_format json --output_dir "$TMP" "${diarize[@]}" \
        >"$TMP/whisperx.log" 2>&1
    local json
    json="$(ls "$TMP"/*.json 2>/dev/null | head -1)"
    [ -n "$json" ] || return 1
    # Format segments into a speaker-labeled transcript (merges consecutive turns).
    # Prints the distinct-speaker count to stdout; writes text to $TMP/transcript.txt.
    python3 - "$json" "$TMP/transcript.txt" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
segs = data.get("segments", [])
has_spk = any(s.get("speaker") for s in segs)
lines, cur, buf = [], None, []
for s in segs:
    txt = (s.get("text") or "").strip()
    if not txt:
        continue
    if has_spk:
        spk = s.get("speaker") or "SPEAKER_?"
        if spk != cur:
            if buf:
                lines.append(f"{cur}: " + " ".join(buf))
            cur, buf = spk, [txt]
        else:
            buf.append(txt)
    else:
        # No diarization: emit ONE LINE PER SEGMENT so run-extractor.sh's line-based
        # chunker can split a long memo. Buffering everything into a single line made one
        # unsplittable oversized chunk that could silently truncate long transcripts.
        lines.append(txt)
if has_spk and buf:
    lines.append(f"{cur}: " + " ".join(buf))
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines) + "\n")
print(len({s.get("speaker") for s in segs if s.get("speaker")}))
PY
}

echo "[$(date +%H:%M:%S)] Transcribing $BASE (model=$WHISPER_MODEL lang=$WHISPER_LANG)..."
if command -v whisperx >/dev/null 2>&1; then
    ENGINE="whisperx"
    [ -n "$HF_TOKEN" ] && echo "  diarization: ON (hf token present)" || echo "  diarization: off (no hf token)"
    N_SPEAKERS="$(transcribe_whisperx 2>/dev/null || echo 0)"
    N_SPEAKERS="${N_SPEAKERS:-0}"
    TRANSCRIPT="$(cat "$TMP/transcript.txt" 2>/dev/null || true)"
    # If diarized run produced nothing (e.g. pyannote license not accepted), retry plain.
    if [ -z "$TRANSCRIPT" ] && [ -n "$HF_TOKEN" ]; then
        echo "  diarized run empty; retrying WhisperX without diarization..." >&2
        HF_TOKEN=""; rm -f "$TMP"/*.json 2>/dev/null
        N_SPEAKERS="$(transcribe_whisperx 2>/dev/null || echo 0)"
        TRANSCRIPT="$(cat "$TMP/transcript.txt" 2>/dev/null || true)"
        N_SPEAKERS=0
    fi
else
    # Legacy openai-whisper fallback (no diarization).
    whisper "$AUDIO" --model "$WHISPER_MODEL" --language "$WHISPER_LANG" \
        --device "$WHISPER_DEVICE" --output_format txt --output_dir "$TMP" >/dev/null 2>&1 || true
    TRANSCRIPT="$(cat "$TMP"/*.txt 2>/dev/null || true)"
fi

if [ -z "$TRANSCRIPT" ]; then
    echo "ERROR: transcription empty/failed for $BASE (engine=$ENGINE, attempt $ATTEMPTS/$MAX_ATTEMPTS)" >&2
    [ -f "$TMP/whisperx.log" ] && tail -n 20 "$TMP/whisperx.log" >&2
    if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
        quarantine "transcription empty/failed (engine=$ENGINE)"
        rm -rf "$TMP"
        exit 0
    fi
    rm -rf "$TMP"
    exit 1
fi
WORDS="$(echo "$TRANSCRIPT" | wc -w | tr -d ' ')"
IS_MEETING=false
[ "${N_SPEAKERS:-0}" -ge 2 ] 2>/dev/null && IS_MEETING=true
echo "  transcript: $WORDS words, speakers: ${N_SPEAKERS:-?}, meeting: $IS_MEETING"

# --- Speaker identification: relabel SPEAKER_xx -> known names ------------------
# Solo memos: the lone speaker is the vault owner (fast path, no model load).
# Meetings (2+ speakers): embed each cluster and match enrolled voiceprints in
# Meta/voiceprints/ — the owner and any enrolled people get named; the rest stay
# SPEAKER_xx. Whole block is best-effort: any failure leaves labels untouched.
if [ "$ENGINE" = "whisperx" ] && printf '%s' "$TRANSCRIPT" | grep -q 'SPEAKER_'; then
    VAULT_OWNER="${VAULT_OWNER:-}"
    VOICEPRINTS_DIR="$VAULT_DIR/Meta/voiceprints"
    SPK_JSON="$(ls "$TMP"/*.json 2>/dev/null | head -1)"
    SPK_MAP=""
    if [ -n "$SPK_JSON" ] && ls "$VOICEPRINTS_DIR"/*.json >/dev/null 2>&1; then
        # Verify identity against enrolled voiceprints BEFORE labeling — for solo memos too.
        # --single-owner keeps the "lone speaker who matches nobody -> owner" default, but an
        # enrolled OTHER person (Bob/Linda/Teddy/…) is now correctly named instead of being
        # blindly attributed to the owner (the wrong-attribution bug). For meetings (2+ clusters)
        # --single-owner is a no-op, so behaviour there is unchanged.
        echo "  identifying speakers (voiceprint match)..."
        SPK_MAP="$(python3 "$SCRIPT_DIR/speaker_id.py" match --json "$SPK_JSON" \
            --audio "$AUDIO" --voiceprints "$VOICEPRINTS_DIR" --owner "$VAULT_OWNER" \
            --single-owner 2>>"$TMP/whisperx.log" || true)"
    elif [ "${N_SPEAKERS:-0}" -le 1 ] && [ -n "$VAULT_OWNER" ]; then
        # No voiceprints enrolled -> nothing to verify against; a solo memo defaults to the owner.
        lone="$(printf '%s' "$TRANSCRIPT" | grep -oE 'SPEAKER_[0-9]+' | head -1)"
        [ -n "$lone" ] && SPK_MAP="$(printf '%s\t%s' "$lone" "$VAULT_OWNER")"
    fi
    if [ -n "$SPK_MAP" ]; then
        while IFS="$(printf '\t')" read -r _spk _name _score; do
            [ -n "$_spk" ] && [ -n "$_name" ] || continue
            TRANSCRIPT="$(printf '%s' "$TRANSCRIPT" | sed "s/^${_spk}:/${_name}:/")"
            echo "    ${_spk} -> ${_name}${_score:+ (${_score})}"
        done <<EOF
$SPK_MAP
EOF
    fi
fi

rm -rf "$TMP"

# GPS from filename (loc_LAT,LON...) — stored only, NOT reverse-geocoded (privacy)
LAT=""; LON=""
if echo "$FILENAME" | grep -q "loc_"; then
    LAT="$(echo "$FILENAME" | sed -n 's/.*loc_\(-\?[0-9.]*\),\(-\?[0-9.]*\).*/\1/p')"
    LON="$(echo "$FILENAME" | sed -n 's/.*loc_\(-\?[0-9.]*\),\(-\?[0-9.]*\).*/\2/p')"
fi

# The note's filename IS its Obsidian title and rides into every notification title
# (basename "$NOTE" below) -- GPS coordinates belong in the gps: frontmatter field above, already
# captured, never in anything human/notification-facing. Strip the loc_<lat>,<lon> segment before
# slugifying (harmless no-op on filenames without it); audio_file: below intentionally keeps the
# untouched original for audit trail.
SLUG_SRC="$(echo "$FILENAME" | sed -E 's/loc_-?[0-9.]*,-?[0-9.]*_?//')"
SLUG="$(echo "$SLUG_SRC" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]//g' | cut -c1-60)"
[ -n "$SLUG" ] || SLUG="memo-$(date +%H%M%S)"
mkdir -p "$VAULT_DIR/Inbox/Voice"
PREFIX="Voice"; $IS_MEETING && PREFIX="Meeting"
NOTE="$VAULT_DIR/Inbox/Voice/${DATE} - ${PREFIX} - ${SLUG}.md"
n=1; while [ -f "$NOTE" ]; do NOTE="$VAULT_DIR/Inbox/Voice/${DATE} - ${PREFIX} - ${SLUG}-${n}.md"; n=$((n+1)); done

{
    echo "---"
    echo "status: transcribed"
    if $IS_MEETING; then
        echo "type: meeting"
        echo "source: meeting"
    else
        echo "source: voice"
    fi
    echo "recorded: ${DATE} ${TIME}"
    [ "${N_SPEAKERS:-0}" -ge 1 ] && echo "speakers: ${N_SPEAKERS}"
    echo "transcriber: ${ENGINE}"
    [ -n "$LAT" ] && echo "gps: [${LAT}, ${LON}]"
    echo "audio_file: ${FILENAME}"
    echo "---"
    echo ""
    echo "# Raw"
    echo "${TRANSCRIPT}"
} > "$NOTE"
echo "  created: $(basename "$NOTE")"

# Archive the audio so the watcher won't reprocess it
mkdir -p "$VAULT_DIR/Inbox/Voice/_processed"
mv "$AUDIO" "$VAULT_DIR/Inbox/Voice/_processed/" 2>/dev/null || true
rm -f "$ATTEMPT_FILE"   # transcription succeeded — retire the DLQ attempt counter

# Correct obvious transcription errors (proper nouns) before extraction (no-op if model unavailable)
echo "[$(date +%H:%M:%S)] Correcting transcript..."
/bin/bash "$SCRIPT_DIR/run-correct-transcript.sh" "$NOTE" 2>/dev/null || true

# Extract structured Canon entries
echo "[$(date +%H:%M:%S)] Extracting..."
EXTRACT_RC=0
/bin/bash "$SCRIPT_DIR/run-extractor.sh" "Inbox/Voice/$(basename "$NOTE")" || EXTRACT_RC=$?
echo "[$(date +%H:%M:%S)] Done: $(basename "$NOTE") (extract rc=$EXTRACT_RC)"

# Notify (ntfy, no-op if unconfigured). Report the TRUE outcome: if extraction failed,
# run-extractor left the note as status: transcribed for a later retry — don't cry success.
EXTRACTED_LIST="$(sed -n '/^## Extracted/,$p' "$NOTE" 2>/dev/null | grep -oE '\[\[[^]]+\]\]' | tr -d '[]' | paste -sd',' - | sed 's/,/, /g' | cut -c1-180)"
LABEL="Memo"; $IS_MEETING && LABEL="Meeting (${N_SPEAKERS} speakers)"
REL_NOTE="${NOTE#$VAULT_DIR/}"
if [ "$EXTRACT_RC" -ne 0 ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "⚠️ ${LABEL} transcribed but extraction FAILED: $(basename "$NOTE" .md)" "left as 'transcribed' for retry (rc=$EXTRACT_RC)" high "warning" "$REL_NOTE" 2>/dev/null || true
else
    /bin/bash "$SCRIPT_DIR/notify.sh" "✅ ${LABEL} processed: $(basename "$NOTE" .md)" "${EXTRACTED_LIST:-transcribed}" default "white_check_mark,microphone" "$REL_NOTE" 2>/dev/null || true
fi
