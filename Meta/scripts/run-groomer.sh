#!/bin/bash
# run-groomer.sh — lightweight vault grooming (small model, default gemma4:e4b).
# Keeps the vault tidy without nagging. TWO jobs:
#
#   A) Ephemera consolidation (auto, reversible): daily briefings + daily retros
#      whose FILENAME DATE is older than GROOM_ARCHIVE_DAYS are summarized into a
#      rolling weekly digest (Meta/Digests/), then git-mv'd into Meta/_archive/.
#      Everything is git-tracked -> fully reversible.
#
#   B) Stale-info check (propose-only): open actions with no activity in
#      GROOM_STALE_DAYS days are surfaced as a proposal in Meta/review-queue/ for
#      human review. The Groomer NEVER closes, edits, or deletes a Canon note itself.
#
# SAFETY: the commit at the end stages ONLY the exact files this run created/moved
# (digest, review-queue item, archived files + their old paths). It must never do a
# broad `git add` of Inbox/ etc. — that would sweep up unrelated working-tree changes.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"
WEEK="$(date +%G-W%V)"
ARCHIVE_DAYS="${GROOM_ARCHIVE_DAYS:-7}"
STALE_DAYS="${GROOM_STALE_DAYS:-30}"
REJLIB="$SCRIPT_DIR/review-rejections.py"
REJECTION_CAP="${REVIEW_REJECTION_CAP:-5}"
NOW_S="$(date +%s)"
CUTOFF_S=$(( NOW_S - ARCHIVE_DAYS * 86400 ))

git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# Engineering Working Agreement: standalone reflection agents run on a clean worktree only
# (don't fold unrelated edits into the reflection commit). Override: VAULT_AGENT_ALLOW_DIRTY=1.
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    if command -v agent_assert_clean_worktree >/dev/null 2>&1; then
        agent_assert_clean_worktree "Groomer" || { echo "Groomer: worktree not clean - skipping run."; exit 0; }
    fi
    # Single-pipeline lock: serialize against every other mutating agent run,
    # manual or scheduled, across processes.
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 900 || exit 1
    fi
fi

ARCHIVE_DIR="$VAULT_DIR/Meta/_archive"
COMMIT_PATHS=()   # exact paths this run touches — the ONLY things we commit

# ───────────────────────────── Part A: ephemera consolidation ─────────────────────────────
# Select by the date embedded in the filename (YYYY-MM-DD), NOT file mtime —
# Syncthing rewrites mtimes, so mtime is meaningless for "how old is this note".
OLD_EPHEMERA=()
while IFS= read -r f; do
    [ -f "$f" ] || continue
    d="$(basename "$f" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
    [ -n "$d" ] || continue
    ds="$(date -d "$d" +%s 2>/dev/null || echo "$NOW_S")"
    [ "$ds" -lt "$CUTOFF_S" ] && OLD_EPHEMERA+=("$f")
done < <(find Inbox "Meta/AI-Reflections" "Meta/briefings" -maxdepth 1 -type f -name '*.md' \
            \( -iname '*Daily Briefing*' -o -iname '*Retro*' \) 2>/dev/null | sort)

if [ "${#OLD_EPHEMERA[@]}" -gt 0 ]; then
    echo "Groomer: ${#OLD_EPHEMERA[@]} ephemeral note(s) dated older than ${ARCHIVE_DAYS}d -> digest + archive"
    DIGEST_INPUT="$(for f in "${OLD_EPHEMERA[@]}"; do echo "### $(basename "$f")"; sed -n '1,40p' "$f"; echo; done | cut -c1-12000)"
    # The model is given every note's content inline below (### filename + body) — it does NOT
    # need to (and must not) fetch anything itself. Confirmed live (2026-07-15) that without this
    # explicit ban, a local model treats the "### filename" headings as a cue to call read_file/
    # list_dir on those names instead of just summarizing the inline text, burning iterations on
    # tool calls that fail ("not a file: <name>", since it's a heading in the prompt, not a real
    # path) until it hits the iteration cap without ever calling final. That's what produced the
    # empty "(agent stopped: reached max iterations without calling final)" digests.
    PROMPT="You are a vault archivist for ${VAULT_OWNER:-Louise}'s knowledge vault. Summarize the following old daily briefings and retrospectives into a SHORT digest: 5-12 markdown bullet points capturing recurring themes, decisions made, and still-unresolved items. Be concise and concrete.

The full content of every note is already included below — do NOT call read_file, list_dir, grep, or any other tool to look anything up; everything you need is right here. Your very first and only response must be exactly one JSON tool call: {\"tool\": \"final\", \"args\": {\"answer\": \"<the digest bullets>\"}}. Do not output anything else.

## NOTES
$DIGEST_INPUT"
    # MAX_ITERS raised 2 -> 6 as a safety margin on top of the prompt fix above (covers a stray
    # malformed-JSON retry or two), not as the primary fix — see the prompt-fix note above for the
    # actual root cause.
    DIGEST="$(OLLAMA_AGENT_MAX_ITERS=6 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" groomer "$PROMPT" 2>/dev/null | tr -d '\r')"
    [ -n "$(echo "$DIGEST" | tr -d '[:space:]')" ] || DIGEST="- (digest model unavailable; ${#OLD_EPHEMERA[@]} notes archived without summary)"

    mkdir -p "$VAULT_DIR/Meta/Digests"
    DIGESTFILE="$VAULT_DIR/Meta/Digests/${WEEK}-digest.md"
    if [ ! -f "$DIGESTFILE" ]; then
        {
            echo "---"; echo "type: digest"; echo "name: Grooming Digest ${WEEK}"; echo "created: ${TODAY}"
            echo "source_agent: Groomer"; echo "---"; echo
            echo "# 🧹 Grooming Digest — ${WEEK}"; echo
        } > "$DIGESTFILE"
    fi
    {
        echo "## Consolidated ${TODAY} (${#OLD_EPHEMERA[@]} notes, dated > ${ARCHIVE_DAYS}d old)"
        echo "<!-- originals moved to Meta/_archive/ — reversible via git -->"
        echo "$DIGEST"; echo
    } >> "$DIGESTFILE"
    COMMIT_PATHS+=("Meta/Digests/${WEEK}-digest.md")

    for f in "${OLD_EPHEMERA[@]}"; do
        dest="$ARCHIVE_DIR/$(dirname "$f")"
        mkdir -p "$dest"
        if git mv "$f" "$dest/" 2>/dev/null; then
            COMMIT_PATHS+=("$f" "$dest/$(basename "$f")")
        else
            # plain mv: $f was untracked, so there is no deletion to stage — adding the
            # vanished old path would make the later batch `git add` fatal and sink the
            # whole commit (observed 2026-07-19)
            mv "$f" "$dest/" 2>/dev/null && COMMIT_PATHS+=("$dest/$(basename "$f")")
        fi
    done
    echo "Groomer: archived ${#OLD_EPHEMERA[@]} note(s); digest -> Meta/Digests/${WEEK}-digest.md"
else
    echo "Groomer: no ephemera dated older than ${ARCHIVE_DAYS}d."
fi

# ───────────────────────────── Part B: stale open actions ─────────────────────────────
STALE=""
N_STALE=0
N_BLOCKED=0
while IFS= read -r af; do
    [ -f "$af" ] || continue
    grep -qiE '^status: *(done|dropped)' "$af" && continue          # only open-ish actions
    last="$(grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$af" | sort | tail -1)"   # latest date referenced
    [ -n "$last" ] || continue
    last_s="$(date -d "$last" +%s 2>/dev/null || echo "$NOW_S")"
    age=$(( (NOW_S - last_s) / 86400 ))
    if [ "$age" -gt "$STALE_DAYS" ]; then
        # Phase 2 hardening (2026-07-18): a stale action rejected REVIEW_REJECTION_CAP
        # times (the human keeps saying "leave it alone") stops being re-surfaced.
        # Feature-detected so a partially-deployed image (missing review-rejections.py)
        # falls back to the original always-list behavior unchanged.
        if [ -f "$REJLIB" ]; then
            name="$(basename "${af%.md}")"
            skey="$(python3 "$REJLIB" normalize-stale-key --name "$name" 2>/dev/null | tr -d '\r')"
            if [ -n "$skey" ] && python3 "$REJLIB" blocked --item-key "$skey" --cap "$REJECTION_CAP" >/dev/null 2>&1; then
                N_BLOCKED=$((N_BLOCKED+1))
                continue
            fi
        fi
        STALE="${STALE}
- [[${af%.md}]] — last activity ${last} (${age}d ago)"
        N_STALE=$((N_STALE+1))
    fi
done < <(find Canon/Actions -maxdepth 1 -name '*.md' 2>/dev/null | sort)

if [ "$N_STALE" -gt 0 ]; then
    mkdir -p Meta/review-queue
    OUT="Meta/review-queue/${TODAY}-groom-stale-actions.md"
    {
        echo "---"; echo "type: review-item"; echo "name: Stale actions ${TODAY}"; echo "status: pending"
        echo "source_agent: Groomer"; echo "created: ${TODAY}"; echo "---"; echo
        echo "# 🧹 Stale open actions (no activity > ${STALE_DAYS}d)"; echo
        echo "These open actions have gone quiet. For each: **close**, **drop**, or **re-commit** (then they fall off this list)."; echo
        echo "Disagree an action is stale? Run \`Meta/scripts/review-reject.sh \"${OUT}\" \"why\"\` (rejects all listed here), or set \`status: rejected\` here + add a \`## Feedback\` section and run \`review-reject.sh --sweep\`. An action rejected ${REJECTION_CAP}+ times stops being surfaced (see \`review-unblock.sh\` to clear it)."; echo
        echo "${STALE}"
    } > "$OUT"
    COMMIT_PATHS+=("$OUT")
    echo "Groomer: ${N_STALE} stale action(s) -> ${OUT}"
else
    echo "Groomer: no stale open actions (> ${STALE_DAYS}d)."
fi
[ "$N_BLOCKED" -gt 0 ] && echo "Groomer: ${N_BLOCKED} stale action(s) suppressed (rejected ${REJECTION_CAP}+ times; see review-unblock.sh)."

# ───────────────────────────── Part C: freshness lint (propose-only) ─────────────────────────────
# Optional sub-check (Phase 4b): flags present-tense volatile claims ("currently",
# "there are N", ...) in Canon/Thinking bodies that lack a "(as of YYYY-MM-DD)"
# stamp. Report-only — Groomer never edits the flagged note itself. Feature-detected:
# a missing freshness-lint.py just skips this block, unchanged behavior otherwise.
FRESHNESS_SCRIPT="$SCRIPT_DIR/freshness-lint.py"
if [ -f "$FRESHNESS_SCRIPT" ]; then
    FRESH_OUT="$(VAULT_DIR="$VAULT_DIR" python3 "$FRESHNESS_SCRIPT" 2>/dev/null | tr -d '\r')"
    FRESH_COUNT="$(printf '%s\n' "$FRESH_OUT" | grep -c '.' || true)"
    if [ -n "$FRESH_OUT" ] && [ "$FRESH_COUNT" -gt 0 ]; then
        FRESH_CAPPED="$(printf '%s\n' "$FRESH_OUT" | head -30)"
        mkdir -p Meta/review-queue
        FOUT="Meta/review-queue/${TODAY}-freshness-findings.md"
        {
            echo "---"; echo "type: review-item"; echo "name: Freshness findings ${TODAY}"; echo "status: pending"
            echo "source_agent: Groomer"; echo "created: ${TODAY}"; echo "---"; echo
            echo "# 🧹 Stale present-tense claims (freshness lint)"; echo
            echo "These lines make a present-tense claim (\"currently\", \"there are N\", ...) with no \`(as of YYYY-MM-DD)\` stamp — they may be stale. Add a stamp, update the claim, or ignore."; echo
            echo "Disagree? Run \`Meta/scripts/review-reject.sh \"${FOUT}\" \"why\"\`."; echo
            echo '```'
            echo "$FRESH_CAPPED"
            echo '```'
        } > "$FOUT"
        COMMIT_PATHS+=("$FOUT")
        echo "Groomer: ${FRESH_COUNT} freshness finding(s) (showing up to 30) -> ${FOUT}"
    else
        echo "Groomer: no freshness findings."
    fi
else
    echo "Groomer: freshness-lint.py not present; skipping."
fi

# ───────────────────────────── commit (ONLY this run's exact paths) ─────────────────────────────
if [ "${#COMMIT_PATHS[@]}" -gt 0 ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # add per-path: one missing/bad path must not abort staging of the rest
    for _p in "${COMMIT_PATHS[@]}"; do
        git add -A -- "$_p" 2>/dev/null || echo "Groomer: could not stage $_p (skipped)" >&2
    done
    # commit the staged index (no pathspec: one unmatched path would abort the whole
    # commit with "did not match any file(s) known to git" — observed 2026-07-19)
    if git diff --cached --quiet; then
        echo "Groomer: nothing to commit."
    elif cerr="$(git commit -q -m "[Groomer] groom: digest+archive ephemera, flag stale actions ($TODAY)" 2>&1)"; then
        echo "Groomer: committed ${#COMMIT_PATHS[@]} path(s)."
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
else
    echo "Groomer: no changes this run."
fi
