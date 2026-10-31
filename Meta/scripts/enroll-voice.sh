#!/bin/bash
# enroll-voice.sh — register a person's voice so memos/meetings label their turns by name.
#
# Usage:
#   enroll-voice.sh <Name> <audio> [more-audio ...]
#       Enroll from one or more clean solo clips (best: same phone mic as captures).
#   enroll-voice.sh <Name> --from-memo <whisperx.json> <SPEAKER_xx> <audio>
#       Pull one diarized speaker out of a meeting recording and enroll them.
#
# Writes Meta/voiceprints/<slug>.json (re-running a name averages the new sample in).
set -uo pipefail
VAULT_DIR="${VAULT_DIR:-/vault}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT="$VAULT_DIR/Meta/voiceprints"

NAME="${1:-}"; shift || true
[ -n "$NAME" ] || { echo "usage: enroll-voice.sh <Name> <audio...>  |  <Name> --from-memo <json> <SPEAKER_xx> <audio>"; exit 1; }

if [ "${1:-}" = "--from-memo" ]; then
    JSON="${2:?need whisperx json}"; SPK="${3:?need SPEAKER_xx}"; AUDIO="${4:?need audio}"
    python3 "$SCRIPT_DIR/speaker_id.py" enroll --name "$NAME" --out "$OUT" \
        --json "$JSON" --speaker "$SPK" "$AUDIO"
else
    [ "$#" -ge 1 ] || { echo "no audio files given"; exit 1; }
    python3 "$SCRIPT_DIR/speaker_id.py" enroll --name "$NAME" --out "$OUT" "$@"
fi
