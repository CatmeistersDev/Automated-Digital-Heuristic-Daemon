#!/bin/bash
# test-agent-undo.sh — behavioral test for Meta/scripts/agent-undo.sh (Phase 1
# hardening, 2026-07-18). Asserts: `list` shows only [Agent]-prefixed commits (never
# human ones), `--agent` filters correctly, `revert <hash>` works on an agent commit,
# a human commit is refused (fail closed, HEAD unchanged), and a `--last N` batch
# refuses ENTIRELY (no partial revert) if any commit in the range lacks a prefix.
# Builds its own throwaway git repo. No network / no model.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
UNDO="$SCRIPT_DIR/agent-undo.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

git -C "$TV" init -q
git -C "$TV" config user.email "test@local"
git -C "$TV" config user.name "Test"

mk_commit() {
    local file="$1" content="$2" msg="$3"
    printf '%s\n' "$content" > "$TV/$file"
    git -C "$TV" add -- "$file"
    git -C "$TV" commit -q -m "$msg"
}

mk_commit "seed.md" "seed content"              "chore: seed vault"                       # human, no prefix
mk_commit "a.md"    "extractor output A"        "[Extractor] extract: memo-a.md"          # agent
mk_commit "b.md"    "implementer fix B"          "[Implementer] vault self-heal 2026-07-18" # agent
mk_commit "c.md"    "human edit"                 "fix typo in b.md"                        # human, no prefix
mk_commit "d.md"    "dedup proposal D"            "[Dedup] entity merge proposals 2026-07-18" # agent

# --- list: only [Agent]-prefixed commits, human commits excluded ---
LIST_OUT="$(VAULT_DIR="$TV" bash "$UNDO" list 2>&1)"
check "list shows Extractor commit"           bash -c 'printf "%s" "$1" | grep -q "\[Extractor\]"' _ "$LIST_OUT"
check "list shows Implementer commit"         bash -c 'printf "%s" "$1" | grep -q "\[Implementer\]"' _ "$LIST_OUT"
check "list shows Dedup commit"               bash -c 'printf "%s" "$1" | grep -q "\[Dedup\]"' _ "$LIST_OUT"
check "list excludes the human seed commit"   bash -c '! printf "%s" "$1" | grep -q "seed vault"' _ "$LIST_OUT"
check "list excludes the human typo-fix commit" bash -c '! printf "%s" "$1" | grep -q "fix typo"' _ "$LIST_OUT"

# --- list --agent filters to one bracket name (case-insensitive) ---
FILT_OUT="$(VAULT_DIR="$TV" bash "$UNDO" list --agent extractor 2>&1)"
check "list --agent extractor shows only Extractor"  bash -c 'printf "%s" "$1" | grep -q "\[Extractor\]"' _ "$FILT_OUT"
check "list --agent extractor excludes Implementer"  bash -c '! printf "%s" "$1" | grep -q "\[Implementer\]"' _ "$FILT_OUT"

# --- list -n limits count ---
LIMIT_OUT="$(VAULT_DIR="$TV" bash "$UNDO" list -n 1 2>&1)"
check "list -n 1 returns exactly one line"    [ "$(printf '%s\n' "$LIMIT_OUT" | grep -c '\[')" -eq 1 ]

# --- revert <hash> on a real agent commit succeeds ---
D_HASH="$(git -C "$TV" log --format=%H --grep='^\[Dedup\]' -n 1)"
HEAD_BEFORE="$(git -C "$TV" rev-parse HEAD)"
VAULT_DIR="$TV" bash "$UNDO" revert "$D_HASH" >/dev/null 2>&1
HEAD_AFTER="$(git -C "$TV" rev-parse HEAD)"
check "revert of agent commit creates a new commit"  [ "$HEAD_BEFORE" != "$HEAD_AFTER" ]
check "revert of agent commit removes d.md"          test ! -f "$TV/d.md"

# --- revert refuses a human commit (fail closed), HEAD unchanged ---
SEED_HASH="$(git -C "$TV" log --format=%H --grep='^chore: seed' -n 1)"
HEAD_BEFORE2="$(git -C "$TV" rev-parse HEAD)"
set +e
VAULT_DIR="$TV" bash "$UNDO" revert "$SEED_HASH" >/tmp/agent-undo-refuse.$$ 2>&1
RC=$?
set -e
REFUSE_OUT="$(cat /tmp/agent-undo-refuse.$$)"; rm -f /tmp/agent-undo-refuse.$$
HEAD_AFTER2="$(git -C "$TV" rev-parse HEAD)"
check "revert of human commit exits nonzero"          [ "$RC" -ne 0 ]
check "revert of human commit leaves HEAD unchanged"  [ "$HEAD_BEFORE2" = "$HEAD_AFTER2" ]
check "revert of human commit prints a refusal"       bash -c 'printf "%s" "$1" | grep -qi "refus"' _ "$REFUSE_OUT"

# --- revert --last N refuses ENTIRELY if any commit in range lacks a prefix
#     (fail closed: no partial revert). Current top of history at this point:
#     [Dedup]-revert(agent-prefixed by ollama_agent? no - agent-undo doesn't prefix
#     its own revert commits) -> "fix typo in b.md" (human) -> [Implementer] -> ...
#     so --last 2 spans the revert commit (unprefixed, since git revert --no-edit
#     names it "Revert \"[Dedup] ...\"") and must be refused. ---
HEAD_BEFORE3="$(git -C "$TV" rev-parse HEAD)"
set +e
VAULT_DIR="$TV" bash "$UNDO" revert --last 2 >/tmp/agent-undo-last.$$ 2>&1
RC2=$?
set -e
LAST_OUT="$(cat /tmp/agent-undo-last.$$)"; rm -f /tmp/agent-undo-last.$$
HEAD_AFTER3="$(git -C "$TV" rev-parse HEAD)"
check "revert --last with a non-agent commit in range refuses" [ "$RC2" -ne 0 ]
check "revert --last refusal leaves HEAD completely unchanged" [ "$HEAD_BEFORE3" = "$HEAD_AFTER3" ]

# --- revert --last 1 on a clean agent-only top succeeds ---
# (top commit right now is the "Revert [Dedup]..." commit from above, itself
# unprefixed, so add one more clean agent commit on top first)
mk_commit "e.md" "another agent write" "[Groomer] groom: digest+archive ephemera 2026-07-18"
HEAD_BEFORE4="$(git -C "$TV" rev-parse HEAD)"
VAULT_DIR="$TV" bash "$UNDO" revert --last >/dev/null 2>&1
HEAD_AFTER4="$(git -C "$TV" rev-parse HEAD)"
check "revert --last (default 1) reverts the top agent commit" [ "$HEAD_BEFORE4" != "$HEAD_AFTER4" ]
check "revert --last removes e.md"                              test ! -f "$TV/e.md"

[ "$fail" -eq 0 ] && echo "test-agent-undo: PASS" || { echo "test-agent-undo: FAIL"; exit 1; }
