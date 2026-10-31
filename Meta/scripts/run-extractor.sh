#!/bin/bash
# run-extractor.sh (LOCAL / Ollama harness version)
# Turns an inbox/transcribed note into structured Canon entries via the local
# tool-using agent (ollama_agent.py through invoke-agent.sh).
#
# Usage:
#   run-extractor.sh                 # no arg -> sweep all Inbox notes with
#                                     # status: inbox|transcribed (schedulers call this)
#   run-extractor.sh <note>          # process exactly this note (schedulers call this
#                                     # right after transcription; status is always
#                                     # inbox|transcribed at that point)
#   run-extractor.sh --force <note>  # reprocess a note EVEN IF status is already
#                                     # "extracted" (or anything else) — e.g. after a
#                                     # manual transcript correction. Unlike the plain
#                                     # `<note>` form, --force unconditionally resets
#                                     # status to "extracted" afterward regardless of
#                                     # what it was before a successful run.
#   run-extractor.sh --dry-run [note]  # print what WOULD be processed and why.
#                                     # Zero writes, zero LLM calls, zero commits.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"
NOW_ISO="$(date +%Y-%m-%dT%H:%M)"
VAULT_OWNER="${VAULT_OWNER:-Louise}"   # vault owner; actions are owned by this person by default

# --- parse args ---
# Kept deliberately narrow so the two existing call shapes (no-arg sweep, plain
# `<note>`) are byte-compatible: any bare non-flag argument still lands in ARG_NOTE
# exactly like the old `"${1:-}"` check did.
FORCE=0
DRY_RUN=0
ARG_NOTE=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)
            FORCE=1
            ARG_NOTE="${2:?--force requires a note path}"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=1
            if [ -n "${2:-}" ] && [ "${2#--}" = "$2" ]; then
                ARG_NOTE="$2"
                shift 2
            else
                shift 1
            fi
            ;;
        --*)
            echo "Unknown flag: $1" >&2
            echo "Usage: run-extractor.sh [--force <note> | --dry-run [note] | <note>]" >&2
            exit 1
            ;;
        *)
            ARG_NOTE="$1"
            shift 1
            ;;
    esac
done

note_status() {
    grep -m1 '^status:' "$1" 2>/dev/null | sed -e 's/^status: *//' -e 's/[[:space:]]*$//'
}

# --- --dry-run: report only, before any write/LLM/commit machinery below ---
if [ "$DRY_RUN" -eq 1 ]; then
    if [ -n "$ARG_NOTE" ]; then
        if [ ! -f "$ARG_NOTE" ]; then
            echo "NOT FOUND: $ARG_NOTE"
            exit 1
        fi
        st="$(note_status "$ARG_NOTE")"
        if [ "$FORCE" -eq 1 ]; then
            echo "WOULD PROCESS (forced): $ARG_NOTE (status: ${st:-none} -> would be reset to extracted regardless of prior value)"
        else
            case "$st" in
                inbox|transcribed) echo "WOULD PROCESS: $ARG_NOTE (status: $st, matches sweep criteria)" ;;
                *) echo "WOULD PROCESS: $ARG_NOTE (status: ${st:-none} — explicit note arg processes regardless of status; use --force to make that explicit)" ;;
            esac
        fi
    else
        mapfile -t DRY_NOTES < <(grep -rlE "^status: (inbox|transcribed)" Inbox/ 2>/dev/null || true)
        if [ "${#DRY_NOTES[@]}" -eq 0 ]; then
            echo "No unprocessed inbox notes (status: inbox|transcribed) — dry run, nothing would be processed."
        else
            echo "Dry run: ${#DRY_NOTES[@]} memo(s) would be processed (status: inbox|transcribed):"
            for n in "${DRY_NOTES[@]}"; do
                echo "  - $n (status: $(note_status "$n"))"
            done
        fi
    fi
    exit 0
fi

# --- find notes to process ---
if [ -n "$ARG_NOTE" ]; then
    NOTES=("$ARG_NOTE")
else
    mapfile -t NOTES < <(grep -rlE "^status: (inbox|transcribed)" Inbox/ 2>/dev/null || true)
fi
if [ "${#NOTES[@]}" -eq 0 ]; then
    echo "No unprocessed inbox notes (status: inbox|transcribed)."
    exit 0
fi

# Pull the best transcript text from a note for extraction: prefer
# "## Corrected Transcript" (speech-to-text fixes) else "# Raw"; for non-transcript
# (typed) notes fall back to the body after the frontmatter. Stops before an
# existing "## Extracted" tail and drops HTML comment lines (e.g. recovery banners).
get_transcript() {
    local note="$1"
    if grep -q '^## Corrected Transcript' "$note"; then
        awk '/^## Corrected Transcript/{f=1;next} f&&/^## /{exit} f' "$note"
    elif grep -q '^# Raw' "$note"; then
        awk '/^# Raw/{f=1;next} f&&/^## /{exit} f' "$note"
    else
        awk 'd&&/^## Extracted[[:space:]]*$/{exit} d{print} /^---[[:space:]]*$/{c++; if(c==2)d=1}' "$note"
    fi | grep -v '^[[:space:]]*<!--'
}

build_prompt() {
    local note="$1" idx="$2" total="$3" chunk="$4"
    cat <<EOF
You are the EXTRACTOR agent. Between the CHUNK markers below is part $idx of $total of the transcript from $note. CREATE structured Canon notes from THIS chunk using write_file. APPLY these rules — do NOT summarize them, EXECUTE them.

TOOLS: bash, read_file, write_file, append_file, list_dir, grep, final. Reply with ONE JSON object per turn.
- write_file(path, content): CREATE a brand-new note (overwrites if it exists — so only for new notes).
- append_file(path, content): ADD to an EXISTING note without losing its current content. Use this for every update.

ENTITY TYPES & FOLDERS (paths ALWAYS start with Canon/ or Thinking/):
- person       -> Canon/People/<Name>.md         H1 emoji 👤
- event        -> Canon/Events/<Name>.md          H1 emoji 📅
- action       -> Canon/Actions/<Name>.md         H1 emoji 🎯
- project      -> Canon/Projects/<Name>.md        H1 emoji 📁
- place        -> Canon/Places/<Name>.md          H1 emoji 📍
- organization -> Canon/Organizations/<Name>.md   H1 emoji 🏢
- decision     -> Canon/Decisions/<Name>.md       H1 emoji ⚖️
- reflection   -> Thinking/<Name>.md               H1 emoji 💭  (feelings, journal, self-assessment)
- concept      -> Thinking/<Name>.md               H1 emoji 💡  (an idea, principle, mental model)
- belief       -> Thinking/<Name>.md               H1 emoji 🪨  (a conviction held as true — add "confidence: medium" to its frontmatter)

The 'type:' value must be EXACTLY ONE of: person, organization, place, project, event, decision, action, reflection, concept, belief. Never a combined value like "reflection/concept".
$MANIFEST_BLOCK
FRONTMATTER for every Canon note (fill the values):
---
type: <type>
name: <Human Name>
created: $TODAY
updated: $TODAY
source: ai-extracted
source_agent: Extractor
source_date: $NOW_ISO
---

# <emoji> <Name>

<1-3 sentences of content, using [[Wikilinks]] to related entities>

WIKILINK RULE: write links as CLEAN [[Name]] only — never include folder paths, .md, or pipes. Correct: [[Louise]]. Wrong: [[Canon/People/Louise.md|Louise]].

ACTION notes additionally need frontmatter: status: open, priority: medium, first_mentioned: $TODAY, and a body line "Owner: [[$VAULT_OWNER]]".

WRAP-UP BIAS: if this chunk contains end-of-memo wrap-up language ("to wrap up", "to summarize", "goodnight", "that's it for today", "let's stop here", or similar), treat it as the memo's closing rather than mid-stream content — bias toward ONE concise summary/reflection note plus explicit action items, instead of extracting every passing remark as its own entity.

PROCEDURE — do ALL of it before calling final:
1. The transcript chunk is provided INLINE below — do NOT read the inbox note to get it. Identify EVERY entity in the chunk and write_file a note for each (correct folder + frontmatter + emoji H1 + wikilinks). Before creating, check the EXISTING VAULT INDEX above for a name match — it's current as of this run, so trust it first instead of an exploratory bash 'find Canon -type f'/grep; only fall back to find/grep if the index is absent above, looks stale, or the entity might have been created by an EARLIER CHUNK of this same memo (the index predates this whole run and won't have it yet). If the entity already exists — via the index OR an earlier chunk — use append_file to ADD only the new facts to it. NEVER write_file an existing note: write_file overwrites and permanently loses its prior content. write_file is ONLY for creating a brand-new note. Be THOROUGH — extract ALL of these when present:
   - people (named individuals)
   - organizations AND named technologies/tools/products/software (e.g. a named app, platform, or system) -> Canon/Organizations/
   - places, projects, events
   - decisions (a choice made) AND intentions stated as "I need to / I'm about to / we should / transitioning to / going to" -> capture as an action (status: open) or decision
   - BELIEF/DECISION BIAS: "I believe / I'm convinced / my rule is / the way I see it / I always / I never" -> belief note; "I've decided / we're going with / from now on / no more X / we settled on" -> decision note. These are chronically under-extracted vs people/orgs — when one of these phrases carries real conviction or a real choice, give it its own note instead of leaving it in prose.
   - reflections (feelings, self-assessment) -> Thinking/
   Do not leave a clearly-named person, tool, org, or stated intention as mere prose — give it its own note.
   GUARDRAILS (avoid Canon clutter):
   - Do NOT create a Person note for a ROLE with no name (e.g. "CEO", "Manager", "Brother", "the client", "Deployment Team Manager"). Mention the role in prose, or link to the named person if you know who it is.
   - Do NOT create a Person note for an AI agent, model, or tool (e.g. Orchestrator, Quinn, Whisper) — those are systems/organizations, not people.
   - Before creating a Person, check the index's People list for a near-duplicate or mis-heard variant (e.g. transcription garble) and append_file to the existing note instead of creating a new one.
2. Do NOT modify the inbox note ($note). The pipeline flips its status and appends the "## Extracted" list after ALL chunks finish — you never write_file the note. Your ONLY writes are Canon/Thinking entity files.
3. Call final when done: if this chunk is pure small talk with no nameable entity, call final with "nothing in this chunk"; otherwise call final only AFTER creating the files, summarizing the exact paths.

HARD RULES:
- NEVER write_file the inbox note ($note). It is owned by the pipeline.
- To update an EXISTING Canon/Thinking note, ALWAYS use append_file — never write_file (write_file overwrites and loses existing facts).
- Never run git commit. Paths must start with Canon/ or Thinking/.

--- BEGIN TRANSCRIPT CHUNK $idx OF $total ---
$chunk
--- END TRANSCRIPT CHUNK $idx OF $total ---
EOF
}

# git runs as root in the container against a vault owned by another user -> trust it
git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# For agent_ignored_among() below — the silent-loss guard on the commit step. Sourced
# defensively (same pattern as run-thinker.sh) so a missing/broken lib-agent.sh can
# never break extraction itself, only the extra safety check.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    # Single-pipeline lock: serialize against every other mutating agent run,
    # manual or scheduled, across processes. Long timeout — a chunked extraction
    # of a long meeting can legitimately run past an hour.
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 3600 || exit 1
    fi
fi

# Chunk-level checkpointing (Phase 3 hardening, 2026-07-18): a scheduler timeout kills
# the whole process group mid-memo, and the next catch-up sweep used to re-run EVERY
# chunk from scratch. extract-checkpoint.py (Meta/scripts/) records per-note, per-chunk
# completion (keyed by a hash of the exact transcript text) in Meta/.extract-progress/
# so a resumed run skips chunks already done. Feature-detected: if the helper script is
# missing, CHECKPOINT_ENABLED stays 0 and every note follows exactly today's behavior
# (no checkpoint read/write anywhere below).
CHECKPOINT_DIR="Meta/.extract-progress"
CHECKPOINT_ENABLED=0
[ -f "$SCRIPT_DIR/extract-checkpoint.py" ] && CHECKPOINT_ENABLED=1

chunk_is_done() {   # $1 = chunk index; true if present in the (per-note) $COMPLETED_CSV
    case ",$COMPLETED_CSV," in
        *",$1,"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Refresh the vault index once per run so the agent can check for an existing entity by
# name straight from the prompt instead of an exploratory bash find/grep every time (that
# used to cost real turns/tokens per note). build-manifest.sh is deterministic and has no
# LLM cost. Best-effort: if it's missing or fails, MANIFEST_CONTENT stays empty and the
# prompt's own "fall back to find/grep" instruction still covers dedup correctly.
MANIFEST_CONTENT=""
if [ -f "$SCRIPT_DIR/build-manifest.sh" ]; then
    /bin/bash "$SCRIPT_DIR/build-manifest.sh" >/dev/null 2>&1 || true
fi
[ -f "Meta/MANIFEST.md" ] && MANIFEST_CONTENT="$(cat Meta/MANIFEST.md)"
MANIFEST_BLOCK=""
if [ -n "$MANIFEST_CONTENT" ]; then
    MANIFEST_BLOCK="
EXISTING VAULT INDEX (current as of this run — check HERE FIRST for a name match; far cheaper than an exploratory find/grep, and covers everything except an entity created earlier in THIS SAME run):
$MANIFEST_CONTENT
"
fi

EXIT=0
for note in "${NOTES[@]}"; do
    [ -f "$note" ] || { echo "skip (missing): $note"; continue; }
    echo "=== Extracting: $note ==="
    MARKER="$(mktemp)"; sleep 1   # files newer than this = created/updated by this run
    SNAPSHOT="$(mktemp)"; cp "$note" "$SNAPSHOT"   # pre-extraction note: source of truth for "# Raw"

    # CHUNKED EXTRACTION: feed the transcript to the agent in inline pieces so the
    # WHOLE memo is covered. The agent's read/result caps (8-12k chars) used to
    # silently limit extraction to the first ~10 min of long meetings; passing the
    # text inline in the prompt has no such cap. Split on turn (line) boundaries so
    # no sentence/entity is cut; sequential, so later chunks see and update entities
    # the earlier ones created (dedup holds).
    NOTE_FAIL=0   # set if ANY chunk's agent call fails -> do NOT mark the note extracted
    CHUNK_DIR="$(mktemp -d)"
    FILTERED_TRANSCRIPT="$(mktemp)"
    get_transcript "$note" | grep -v '^[[:space:]]*$' > "$FILTERED_TRANSCRIPT"
    TOTAL="$(awk -v B="${EXTRACT_CHUNK_CHARS:-9000}" -v D="$CHUNK_DIR" '
            BEGIN{n=1;c=0}
            { if (c>0 && c+length($0)+1 > B){ n++; c=0 }
              fn = D "/chunk_" sprintf("%03d", n) ".txt"
              print $0 >> fn
              c += length($0)+1 }
            END{ print (NR>0 ? n : 0) }' "$FILTERED_TRANSCRIPT")"
    TOTAL="${TOTAL:-0}"

    # Resolve/consume any checkpoint for THIS transcript's exact content before the
    # chunk loop runs. Keyed by sha256(transcript text) so an edited transcript (manual
    # correction, re-run after fixing a typo) invalidates a stale checkpoint instead of
    # resuming against wrong chunk boundaries. --force always starts clean (the whole
    # point of forcing a reprocess).
    CHECKPOINT_FILE=""
    COMPLETED_CSV=""
    CHECKPOINT_FILES=()
    TRANSCRIPT_HASH=""
    if [ "$CHECKPOINT_ENABLED" -eq 1 ] && [ "$TOTAL" -gt 0 ]; then
        TRANSCRIPT_HASH="$(sha256sum "$FILTERED_TRANSCRIPT" | cut -d' ' -f1)"
        CHECKPOINT_FILE="$CHECKPOINT_DIR/${TRANSCRIPT_HASH}.json"
        if [ "$FORCE" -eq 1 ]; then
            python3 "$SCRIPT_DIR/extract-checkpoint.py" discard --checkpoint "$CHECKPOINT_FILE" \
                >/dev/null 2>&1 || true
        elif [ -f "$CHECKPOINT_FILE" ]; then
            RESUME_OUT="$(python3 "$SCRIPT_DIR/extract-checkpoint.py" load \
                --checkpoint "$CHECKPOINT_FILE" --hash "$TRANSCRIPT_HASH" 2>/dev/null | tr -d '\r')"
            if [ "$RESUME_OUT" = "DISCARDED" ]; then
                echo "  (checkpoint discarded: transcript changed since last attempt)"
            elif [ -n "$RESUME_OUT" ]; then
                COMPLETED_CSV="$(printf '%s\n' "$RESUME_OUT" | head -n1)"
                while IFS= read -r f; do
                    [ -n "$f" ] && CHECKPOINT_FILES+=("$f")
                done < <(printf '%s\n' "$RESUME_OUT" | tail -n +2)
                if [ -n "$COMPLETED_CSV" ]; then
                    N_DONE="$(printf '%s' "$COMPLETED_CSV" | awk -F',' '{print NF}')"
                    echo "  Resume: using $N_DONE/$TOTAL checkpointed chunks"
                fi
            fi
        fi
    fi
    rm -f "$FILTERED_TRANSCRIPT"

    if [ "$TOTAL" -eq 0 ]; then
        echo "  (no transcript text to extract)"
    else
        echo "  transcript -> $TOTAL chunk(s) of ~${EXTRACT_CHUNK_CHARS:-9000} chars"
        declare -A KNOWN_FILE=()
        for f in "${CHECKPOINT_FILES[@]}"; do
            [ -n "$f" ] && KNOWN_FILE["$f"]=1
        done
        idx=0
        for cf in "$CHUNK_DIR"/chunk_*.txt; do
            [ -f "$cf" ] || continue
            idx=$((idx+1))
            if [ -n "$COMPLETED_CSV" ] && chunk_is_done "$idx"; then
                echo "  [chunk $idx/$TOTAL] skipped (checkpointed — already completed)"
                continue
            fi
            echo "  [chunk $idx/$TOTAL] extracting ($(wc -c <"$cf" | tr -d ' ') chars)..."
            PROMPT="$(build_prompt "$note" "$idx" "$TOTAL" "$(cat "$cf")")"
            if OLLAMA_AGENT_MAX_ITERS="${OLLAMA_AGENT_MAX_ITERS:-45}" \
                    /bin/bash "$SCRIPT_DIR/invoke-agent.sh" extractor "$PROMPT"; then
                # Persist this chunk as done, along with the Canon/Thinking files it
                # (uniquely) created — so a later resumed run's "## Extracted" rebuild
                # is complete even though those files were written by THIS (possibly
                # since-killed) process, not the resuming one.
                if [ -n "$CHECKPOINT_FILE" ]; then
                    CHUNK_FILES_TMP="$(mktemp)"
                    while IFS= read -r f; do
                        [ -n "$f" ] || continue
                        if [ -z "${KNOWN_FILE[$f]:-}" ]; then
                            printf '%s\n' "$f" >> "$CHUNK_FILES_TMP"
                            KNOWN_FILE["$f"]=1
                        fi
                    done < <(find Canon Thinking -name '*.md' -newer "$MARKER" 2>/dev/null | sort)
                    python3 "$SCRIPT_DIR/extract-checkpoint.py" mark-chunk \
                        --checkpoint "$CHECKPOINT_FILE" --hash "$TRANSCRIPT_HASH" \
                        --note "$note" --total "$TOTAL" --chunk "$idx" \
                        --files-file "$CHUNK_FILES_TMP" >/dev/null 2>&1 || true
                    rm -f "$CHUNK_FILES_TMP"
                fi
            else
                EXIT=$?; NOTE_FAIL=1; echo "  ⚠ chunk $idx/$TOTAL FAILED (rc=$EXIT)" >&2
            fi
        done
    fi
    rm -rf "$CHUNK_DIR"

    # DETERMINISTIC, AUTHORITATIVE WRITE-BACK — the inbox note is shell-owned.
    # The agent only creates Canon/Thinking files; it must never rewrite the note.
    # We rebuild the note from the pre-extraction snapshot (which preserves the
    # verbatim "# Raw" + any "## Corrected Transcript" EXACTLY), flip status, and
    # append a fresh "## Extracted". This makes it physically impossible for the
    # model to truncate or alter "# Raw" — the bug that silently dropped the tail
    # of long transcripts. Idempotent: an existing "## Extracted" (always last) is
    # stripped from the snapshot before the new one is appended.
    #
    # H1 guard: flip status -> extracted ONLY when every chunk succeeded. If any chunk's
    # agent call failed (e.g. Ollama down), leave the status as-is so the no-arg catch-up
    # run reprocesses the note later — instead of silently marking a memo "extracted" with
    # an empty/partial "## Extracted" and never retrying it.
    if [ "$NOTE_FAIL" -eq 0 ]; then
        if [ "$FORCE" -eq 1 ]; then
            # --force: unconditionally reset status -> extracted regardless of what it
            # was before this run (extracted/archived/anything). The inbox|transcribed
            # -only filter below would silently no-op on a note whose status is
            # anything else, leaving it inconsistent with the fresh "## Extracted"
            # section this run just wrote — that's the "reset the status field sanely"
            # a force-reprocess (e.g. after a manual transcript correction) needs.
            STATUS_FILTER=(sed -E 's/^status: *[A-Za-z0-9_-]*/status: extracted/')
        else
            STATUS_FILTER=(sed -e 's/^status: *transcribed/status: extracted/' \
                               -e 's/^status: *inbox/status: extracted/')
        fi
        # Full memo succeeded end-to-end -> the checkpoint has served its purpose.
        # Delete it so a later re-run of this same transcript (e.g. --force after a
        # manual correction) starts clean instead of "resuming" a finished memo.
        if [ -n "$CHECKPOINT_FILE" ]; then
            python3 "$SCRIPT_DIR/extract-checkpoint.py" discard --checkpoint "$CHECKPOINT_FILE" \
                >/dev/null 2>&1 || true
        fi
    else
        echo "  ⚠ extraction incomplete — leaving status unchanged for retry (NOT marking extracted)" >&2
        STATUS_FILTER=(cat)
    fi
    # Files this run actually created/touched under Canon/Thinking — used both for the
    # "## Extracted" backlinks below and to verify the commit step really captured them.
    # Seeded with any files a checkpointed EARLIER (possibly killed) process already
    # created for this same memo, so a resumed run's list is still complete — those
    # files are older than THIS invocation's $MARKER and would otherwise be missed.
    NEWER_FILES=()
    declare -A NF_SEEN=()
    for f in "${CHECKPOINT_FILES[@]}"; do
        if [ -n "$f" ] && [ -z "${NF_SEEN[$f]:-}" ]; then
            NEWER_FILES+=("$f"); NF_SEEN["$f"]=1
        fi
    done
    while IFS= read -r f; do
        if [ -n "$f" ] && [ -z "${NF_SEEN[$f]:-}" ]; then
            NEWER_FILES+=("$f"); NF_SEEN["$f"]=1
        fi
    done < <(find Canon Thinking -name '*.md' -newer "$MARKER" 2>/dev/null | sort)

    # Idempotent mentions: guard — a retried chunk, the periodic no-arg catch-up
    # sweep re-processing a stranded memo, or a second pass over the same transcript
    # can append the same source filename into an action's `mentions:` array more
    # than once. Deterministic, LLM-free cleanup on every note this run touched;
    # a no-op for notes with no `mentions:` array or no duplicates.
    if [ "${#NEWER_FILES[@]}" -gt 0 ] && [ -f "$SCRIPT_DIR/dedup-mentions.py" ]; then
        python3 "$SCRIPT_DIR/dedup-mentions.py" "${NEWER_FILES[@]}" || true
    fi

    # Write to a same-directory temp file, then mv into place — mv within the same
    # directory is an atomic rename on the container's Linux fs, so a scheduler kill
    # mid-write leaves the ORIGINAL note intact (never a truncated/partial rebuild).
    # A direct `> "$note"` redirect truncates the file before a single byte of the
    # rebuild is written, which is exactly what atomicity here is protecting against.
    TMP_NOTE="$(mktemp "${note}.tmp.XXXXXX")"
    {
        # snapshot up to (not incl.) any existing "## Extracted", trailing blanks trimmed
        awk '
            /^## Extracted[[:space:]]*$/ { stop=1 }
            stop { next }
            { buf[++n]=$0 }
            END { while (n>0 && buf[n] ~ /^[[:space:]]*$/) n--; for (i=1;i<=n;i++) print buf[i] }
        ' "$SNAPSHOT" \
            | "${STATUS_FILTER[@]}"
        echo ""
        echo "## Extracted"
        for f in "${NEWER_FILES[@]}"; do
            echo "- [[${f%.md}]]"
        done
    } > "$TMP_NOTE"
    mv -f "$TMP_NOTE" "$note"
    rm -f "$MARKER" "$SNAPSHOT"

    # Commit extractor-owned paths. Distinguish "nothing staged" from a REAL commit failure
    # (pre-commit-guard rejection, index.lock contention, missing identity) — the old
    # `2>/dev/null || echo "(nothing to commit)"` idiom silently swallowed both.
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git add Canon/ Thinking/ "$note" 2>/dev/null || true

        # Silent-loss guard: `git add` on a directory never errors when a path inside it
        # is gitignored — it just skips it — so a stray .gitignore rule or a wrong
        # VAULT_DIR could drop every entity file this run just wrote while $note itself
        # still stages fine, making the commit below look completely clean. Check the
        # EXACT files this run touched, not just "did something get staged."
        IGNORED_NEW=()
        if [ "${#NEWER_FILES[@]}" -gt 0 ] && command -v agent_ignored_among >/dev/null 2>&1; then
            while IFS= read -r f; do
                [ -n "$f" ] && IGNORED_NEW+=("$f")
            done < <(agent_ignored_among "${NEWER_FILES[@]}")
        fi
        if [ "${#IGNORED_NEW[@]}" -gt 0 ]; then
            echo "  ⚠ SILENT LOSS for $(basename "$note"): extractor wrote file(s) git will not track (gitignored) — not staged, not committed:" >&2
            printf '   - %s\n' "${IGNORED_NEW[@]}" >&2
            if [ -x "$SCRIPT_DIR/notify.sh" ]; then
                "$SCRIPT_DIR/notify.sh" "🛑 Extractor silent-loss guard tripped" "$(basename "$note"): gitignored entity file(s) never reached git: ${IGNORED_NEW[*]}" high "rotating_light" 2>/dev/null || true
            fi
            EXIT=1
        fi

        if git diff --cached --quiet; then
            echo "  (nothing to commit for $(basename "$note"))"
        elif cerr="$(git commit -q -m "[Extractor] extract: $(basename "$note")" 2>&1)"; then
            echo "  committed extraction for $(basename "$note")"
        else
            echo "  ⚠ COMMIT FAILED for $(basename "$note"): $cerr" >&2
            EXIT=1
        fi
    fi
done
exit "$EXIT"
