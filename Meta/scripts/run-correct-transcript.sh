#!/bin/bash
# run-correct-transcript.sh <note> — fix obvious speech-to-text errors (esp. proper nouns)
# using vault context. Preserves the verbatim "# Raw"; appends a "## Corrected Transcript".
# NO GPU. ONE model call. Idempotent (skips if already corrected).
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTE="${1:-}"
[ -n "$NOTE" ] && [ -f "$NOTE" ] || { echo "usage: run-correct-transcript.sh <note.md>"; exit 0; }

git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# Single-pipeline lock: serialize against every other mutating agent run,
# manual or scheduled, across processes.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 900 || exit 1
    fi
fi

grep -q '^## Corrected Transcript' "$NOTE" && { echo "already corrected: $(basename "$NOTE")"; exit 0; }

# Verbatim transcript = text under "# Raw" (up to the next "## " heading)
RAW="$(awk '/^# Raw/{f=1;next} /^## /{f=0} f' "$NOTE")"
[ -n "$(echo "$RAW" | tr -d '[:space:]')" ] || { echo "no # Raw text"; exit 0; }

# Known vault proper nouns -> help the model fix mis-heard names.
# One name per line, de-duplicated. (Do NOT join with `paste -sd', '` — that flag
# treats ',' and ' ' as TWO alternating delimiters and fuses adjacent names, e.g.
# "Bob Linda Teddy" / "Tina Gene Louise", which made the model substitute
# spoken first names with bogus full names. Newline-per-name keeps each name intact.)
KNOWN="$(find Canon/People Canon/Organizations Canon/Projects Canon/Places -maxdepth 1 -name '*.md' -printf '%f\n' 2>/dev/null | sed 's/\.md$//' | sort -u | sed 's/^/- /')"

# Shared instruction preamble; the transcript chunk is appended per-call.
INSTR="Fix obvious speech-to-text transcription errors in the voice memo below. ONLY correct clear mis-hears — especially proper nouns (people, companies, products, places) and garbled words. Do NOT paraphrase, summarize, reword, reorder, add, or remove content — preserve the speaker's exact wording and meaning. If a spelled-out term appears (e.g. 'F-U-N-T-I-M-E'), use the correct spelling (Funtime).

Below is a reference list of names already in this vault, one per line. Use it ONLY to fix a clear phonetic mis-hear of a name. Each list entry is a complete, separate name — never combine two entries into one, and never replace a correctly-spelled shorter name (such as a first name) with a longer or different name. When in doubt, leave the spoken word exactly as transcribed.

KNOWN NAMES (one per line):
${KNOWN:-(none)}

Reply by calling final with ONLY the corrected transcript text — nothing else.

MEMO:
"

# Chunk the raw transcript so a long memo is never fed in ONE oversized prompt. Ollama
# silently truncates an over-context prompt to the model's window, which mangles the
# correction — and because run-extractor PREFERS "## Corrected Transcript" over "# Raw",
# that truncated text would then drive extraction, re-opening the long-meeting tail-loss
# the extractor's own chunking was built to close. Correct each piece in order; on any
# chunk failure keep that chunk's RAW text verbatim so nothing is dropped. num_ctx is
# pinned generously (chunks are small) so a single chunk is never itself truncated.
CHUNK_DIR="$(mktemp -d)"
printf '%s\n' "$RAW" | grep -v '^[[:space:]]*$' \
    | awk -v B="${CORRECT_CHUNK_CHARS:-6000}" -v D="$CHUNK_DIR" '
        BEGIN{n=1;c=0}
        { if (c>0 && c+length($0)+1 > B){ n++; c=0 }
          fn = D "/c_" sprintf("%03d", n) ".txt"
          print $0 >> fn; c += length($0)+1 }'

CORRECTED=""; OK_ANY=0
for cf in "$CHUNK_DIR"/c_*.txt; do
    [ -f "$cf" ] || continue
    CHUNK="$(cat "$cf")"
    OUT="$(OLLAMA_AGENT_MAX_ITERS=5 OLLAMA_NUM_CTX="${OLLAMA_NUM_CTX:-8192}" \
        /bin/bash "$SCRIPT_DIR/invoke-agent.sh" corrector "${INSTR}${CHUNK}" 2>/dev/null | tr -d '\r')"
    # strip a leading "Here is/Corrected transcript:" preamble line if present
    OUT="$(printf '%s' "$OUT" | sed '1{/^[Hh]ere.*:$/d; /^[Cc]orrected.*:$/d}')"
    if [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ] || printf '%s' "$OUT" | head -1 | grep -q "agent stopped"; then
        OUT="$CHUNK"   # correction unavailable for this chunk — keep raw, lose nothing
    else
        OK_ANY=1
    fi
    if [ -n "$CORRECTED" ]; then CORRECTED="$CORRECTED
$OUT"; else CORRECTED="$OUT"; fi
done
rm -rf "$CHUNK_DIR"

if [ "$OK_ANY" -eq 0 ]; then
    echo "correction unavailable — leaving note unchanged"; exit 0
fi

printf '\n## Corrected Transcript\n<!-- auto-corrected speech-to-text; the "# Raw" section above is the verbatim original (source of truth) -->\n%s\n' "$CORRECTED" >> "$NOTE"
echo "corrected: $(basename "$NOTE")"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$NOTE" 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[Corrector] transcript fix: $(basename "$NOTE")" 2>&1)"; then
        echo committed
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
