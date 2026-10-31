#!/bin/bash
# run-operator.sh (LOCAL — APPROVAL-QUEUE SCAFFOLD ONLY).
# Drafts a proposed deliverable (email/calendar/document/message) for an action and
# queues it at Meta/operations/pending/<id>.md for HUMAN approval.
# It NEVER sends, executes, or calls any external service. Execution is intentionally
# NOT wired (privacy-first + no credentials). A human reviews/acts in Obsidian.
#
# Usage: run-operator.sh "path/to/action.md"  | run-operator.sh "Action Name"
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TODAY="$(date +%Y-%m-%d)"; NOW_ISO="$(date +%Y-%m-%dT%H:%M)"; STAMP="$(date +%Y%m%d-%H%M%S)"
OWNER="${VAULT_OWNER:-Louise}"

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

ARG="${1:-}"
[ -n "$ARG" ] || { echo "Usage: run-operator.sh <action note path or name>"; exit 1; }
if [ -f "$ARG" ]; then
    ACTION="$ARG"
else
    ACTION="$(grep -rilE "^name: .*$ARG" Canon/Actions 2>/dev/null | head -1)"
    [ -z "$ACTION" ] && ACTION="$(ls Canon/Actions/*"$ARG"*.md 2>/dev/null | head -1)"
fi
[ -n "$ACTION" ] && [ -f "$ACTION" ] || { echo "Action not found: $ARG"; exit 1; }
ANAME="$(grep -m1 '^name:' "$ACTION" | sed 's/^name: *//; s/"//g')"
echo "=== Operator drafting for: $ANAME ==="

CONTEXT="$(sed -n '1,60p' "$ACTION")"
PROMPT="You are the OPERATOR. Draft a proposed DELIVERABLE that would help ${OWNER} accomplish this action. This is a DRAFT for ${OWNER}'s approval — it will NOT be sent or executed automatically; a human reviews it first.

Choose the most useful deliverable type: email | calendar | document | message.
Format your reply EXACTLY as:
TYPE: <one of email|calendar|document|message>
SUBJECT: <short subject/title>
BODY:
<the full draft content, ready for ${OWNER} to review/edit>

Reply by calling final with ONLY that block.

## ACTION NOTE
$CONTEXT"

DRAFT="$(OLLAMA_AGENT_MAX_ITERS=3 /bin/bash "$SCRIPT_DIR/invoke-agent.sh" operator "$PROMPT" 2>/dev/null | tr -d '\r')"
[ -n "$DRAFT" ] || DRAFT="TYPE: document
SUBJECT: $ANAME
BODY:
(model draft unavailable this run)"

OP_TYPE="$(printf '%s\n' "$DRAFT" | grep -m1 -iE '^TYPE:' | sed 's/^[^:]*: *//' | tr -d ' ' | tr '[:upper:]' '[:lower:]')"
OP_SUBJECT="$(printf '%s\n' "$DRAFT" | grep -m1 -iE '^SUBJECT:' | sed 's/^[^:]*: *//')"
[ -n "$OP_TYPE" ] || OP_TYPE="document"
[ -n "$OP_SUBJECT" ] || OP_SUBJECT="$ANAME"
OP_BODY="$(printf '%s\n' "$DRAFT" | sed -n '/^[Bb][Oo][Dd][Yy]:/,$p' | sed '1s/^[Bb][Oo][Dd][Yy]: *//')"
[ -n "$OP_BODY" ] || OP_BODY="$DRAFT"

mkdir -p Meta/operations/pending
OPID="op-$STAMP"
OUT="Meta/operations/pending/$OPID.md"
{
    echo "---"
    echo "type: operation"
    echo "op_id: $OPID"
    echo "operation_type: $OP_TYPE"
    echo "subject: \"$OP_SUBJECT\""
    echo "status: pending"
    echo "for_action: \"[[$ANAME]]\""
    echo "created: $NOW_ISO"
    echo "source_agent: Operator"
    echo "executed: false"
    echo "---"
    echo ""
    echo "# 🔧 Proposed $OP_TYPE — $OP_SUBJECT"
    echo ""
    echo "> ⚠️ DRAFT for your approval. AutoADHD does NOT send or execute anything automatically."
    echo "> To act: review/edit below, then do it yourself. (External execution is intentionally not wired.)"
    echo ""
    echo "**For action:** [[$ANAME]]"
    echo ""
    echo "## Draft"
    echo "$OP_BODY"
} > "$OUT"
echo "Proposed operation queued (NOT sent): $OUT"

# Notify — a draft existing must never be silent (see Notification UX 13e, Goal 1's gap: this
# script previously never called notify.sh at all; the only signal was orchestrator's generic
# "Next: {NAME}" push when it auto-handed a deliverable step here).
/bin/bash "$SCRIPT_DIR/notify.sh" "📝 Draft ready: $ANAME" "$OP_TYPE draft queued for approval — $OP_SUBJECT" default "memo" "$OUT" 2>/dev/null || true

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add Meta/operations/ 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[Operator] draft ($OP_TYPE) for $ANAME -> pending approval" 2>&1)"; then
        echo "committed"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
