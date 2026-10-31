#!/bin/bash
# auto-orchestrator.sh — Automatically runs run-orchestrator.sh on the highest priority open action.

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

echo "No action provided; finding the highest-priority open action..."
ACTION="$(VAULT_DIR="$VAULT_DIR" python3 -c '
import os, glob
prio = {"high": 0, "medium": 1, "low": 2}
best, best_val = None, (99, "")
for f in glob.glob(os.environ["VAULT_DIR"] + "/Canon/Actions/*.md"):
    try:
        text = open(f, encoding="utf-8", errors="replace").read()
        if "status: open" in text or "status: in-progress" in text:
            p = "medium"
            for line in text.splitlines():
                if line.startswith("priority:"):
                    p = line.split(":", 1)[1].strip()
            val = (prio.get(p, 1), f)
            if val < best_val:
                best_val = val
                best = f
    except Exception:
        pass
print(best or "")
' 2>/dev/null)"

if [ -z "$ACTION" ]; then
    echo "No open actions found."
    exit 0
fi

# Run the actual orchestrator
/bin/bash "$(dirname "$0")/run-orchestrator.sh" "$ACTION"
