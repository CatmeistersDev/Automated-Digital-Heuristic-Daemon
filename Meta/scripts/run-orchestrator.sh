#!/bin/bash
# run-orchestrator.sh <action> — "focus mode" for an action.
# Surfaces the ONE next sub-step, tracks progress in Meta/decomposer/<slug>.json, and
# drafts deliverable-type steps via the Operator (queued for approval). Deterministic.
# NEVER executes external actions; NEVER auto-checks steps (you check them in Obsidian).
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
git config --global --add safe.directory '*' 2>/dev/null || true
git config --global user.email "autoadhd@local" 2>/dev/null || true
git config --global user.name "AutoADHD" 2>/dev/null || true

# Single-pipeline lock: serialize against every other mutating agent run,
# manual or scheduled, across processes. Held for the duration of this run, including
# any nested run-operator.sh call below (VAULT_AGENT_LOCK_HELD is exported so the
# child short-circuits instead of deadlocking on its own acquire).
if [ -f "$SCRIPT_DIR/lib-agent.sh" ]; then
    . "$SCRIPT_DIR/lib-agent.sh" 2>/dev/null || true
    if command -v agent_acquire_lock >/dev/null 2>&1; then
        agent_acquire_lock "vault-pipeline" 900 || exit 1
    fi
fi

ARG="${1:-}"
[ -n "$ARG" ] || { echo "usage: run-orchestrator.sh <action note path or name>"; exit 1; }
if [ -f "$ARG" ]; then ACTION="$ARG"; else
    ACTION="$(grep -rilE "^name: .*$ARG" Canon/Actions 2>/dev/null | head -1)"
    [ -z "$ACTION" ] && ACTION="$(ls Canon/Actions/*"$ARG"*.md 2>/dev/null | head -1)"
fi
[ -n "$ACTION" ] && [ -f "$ACTION" ] || { echo "Action not found: $ARG"; exit 1; }

# Ensure the action is decomposed into sub-steps
if ! grep -q '^## Sub-steps' "$ACTION"; then
    echo "No sub-steps yet — enriching first..."
    /bin/bash "$SCRIPT_DIR/run-task-enricher.sh" "$ACTION" >/dev/null 2>&1 || true
fi

RESULT="$(ACTION="$ACTION" VAULT_DIR="$VAULT_DIR" python3 - <<'PY'
import os, re, json, datetime
vault = os.environ["VAULT_DIR"]; path = os.environ["ACTION"]
text = open(path, encoding="utf-8").read()
name = path.rsplit("/", 1)[-1][:-3]
# parse sub-steps section
steps = []
in_ss = False
for line in text.splitlines():
    if re.match(r'^##\s+Sub-steps', line): in_ss = True; continue
    if in_ss and re.match(r'^##\s+', line): break
    if in_ss:
        m = re.match(r'^\s*-\s*\[( |x|X)\]\s*(.+)$', line)
        if m:
            steps.append({"text": m.group(2).strip(), "done": m.group(1).lower() == "x"})
total = len(steps); done = sum(1 for s in steps if s["done"])
nxt = next((s["text"] for s in steps if not s["done"]), "")
slug = re.sub(r'[^a-z0-9._-]', '', name.lower().replace(' ', '-'))[:50] or "action"
status = "complete" if (total and done >= total) else ("in-progress" if done else "ready")

# state file
os.makedirs(os.path.join(vault, "Meta", "decomposer"), exist_ok=True)
json.dump({"action": name, "slug": slug, "total": total, "done": done,
           "next": nxt, "status": status, "steps": steps,
           "updated": datetime.datetime.now().isoformat()[:19]},
          open(os.path.join(vault, "Meta", "decomposer", slug + ".json"), "w"), indent=2)

# rewrite the ## Orchestrator section in the note (remove old, append fresh)
text = re.sub(r'\n## Orchestrator\n.*?(?=\n## |\Z)', '\n', text, flags=re.DOTALL)
if total == 0:
    block = "\n## Orchestrator\n- No sub-steps found. Run the Task-Enricher.\n"
elif done >= total:
    block = f"\n## Orchestrator\n✅ All {total} sub-steps complete — consider closing this action.\n"
else:
    block = f"\n## Orchestrator\n**▶️ Next step:** {nxt}\n\n_Progress: {done}/{total} done. Check steps off in Sub-steps above as you go._\n"
open(path, "w", encoding="utf-8").write(text.rstrip() + "\n" + block)

# is the next step a deliverable?
deliverable = bool(re.search(r'email|draft|proposal|document|message|write[ -]?up|send|letter', nxt, re.I))
# vault-relative path for the notify.sh click target (cwd is VAULT_DIR; $ARG may have been
# passed as either a vault-relative or an absolute path)
rel_path = os.path.relpath(os.path.abspath(path), vault)
print(json.dumps({"name": name, "total": total, "done": done, "next": nxt,
                  "status": status, "slug": slug, "deliverable": deliverable, "path": rel_path}))
PY
)"
echo "$RESULT"

NXT="$(echo "$RESULT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("next",""))' 2>/dev/null)"
NAME="$(echo "$RESULT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("name",""))' 2>/dev/null)"
DELIV="$(echo "$RESULT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("deliverable",False))' 2>/dev/null)"
STATUS="$(echo "$RESULT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("status",""))' 2>/dev/null)"
ACTION_REL="$(echo "$RESULT" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("path",""))' 2>/dev/null)"

# If the next step is a deliverable, have the Operator draft it (queued, never sent)
if [ "$DELIV" = "True" ]; then
    echo "Next step is a deliverable -> drafting via Operator (queued for approval)..."
    /bin/bash "$SCRIPT_DIR/run-operator.sh" "$ACTION" >/dev/null 2>&1 || true
fi

# Notify the next step (ntfy no-op if unconfigured)
if [ "$STATUS" = "complete" ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "✅ $NAME — all steps done" "Consider closing this action." default "white_check_mark" "$ACTION_REL" 2>/dev/null || true
elif [ -n "$NXT" ]; then
    /bin/bash "$SCRIPT_DIR/notify.sh" "▶️ Next: $NAME" "$NXT" default "arrow_forward" "$ACTION_REL" 2>/dev/null || true
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$ACTION" Meta/decomposer/ Meta/operations/ 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(nothing to commit)"
    elif cerr="$(git commit -q -m "[Orchestrator] $NAME -> next step surfaced" 2>&1)"; then
        echo committed
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
