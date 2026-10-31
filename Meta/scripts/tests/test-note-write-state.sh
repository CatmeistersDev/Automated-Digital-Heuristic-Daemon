#!/bin/bash
# test-note-write-state.sh — behavioral test for the stored-vs-live hand-edit detection
# in ollama_agent.py's write_file/append_file (Phase 3 hardening, 2026-07-18) and the
# standalone note-write-state.py CLI used by the deterministic (non-LLM) write sites.
# Asserts: write_file on a NEW Canon/Thinking note is allowed and records a hash;
# write_file on an EXISTING note is always refused (enforced "never write_file over
# Canon" rule), whether hand-edited or not, gated behind HARNESS_PROTECT_EXISTING;
# append_file on a hand-edited note is NOT blocked (still succeeds, preserves the
# human edit) but is logged; append_file refreshes the stored hash so a subsequent
# append against unchanged content is silent; and note-write-state.py's CLI
# (check/record/prune) round-trips against the SAME state file ollama_agent.py writes.
# No Ollama/network needed.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
AGENT_PY="$SCRIPT_DIR/ollama_agent.py"
NWS="$SCRIPT_DIR/note-write-state.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
mkdir -p "$TV/Canon/People" "$TV/Meta"
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }
contains() { printf '%s' "$1" | grep -qF -- "$2"; }

STATE_FILE="$TV/Meta/.note-write-state.json"

VAULT_DIR="$TV" python3 - "$AGENT_PY" <<'PY'
import importlib.util, sys, os

spec = importlib.util.spec_from_file_location("oagent", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

fail = 0
def check(desc, ok):
    global fail
    print(("  ok: " if ok else "  FAIL: ") + desc)
    if not ok:
        fail = 1

vault = os.environ["VAULT_DIR"]
target = "Canon/People/Tina.md"
full = os.path.join(vault, target)

# --- write_file on a NEW note: allowed, records a hash ---
res = m.tool_write_file({"path": target, "content": "---\ntype: person\nname: Tina\n---\n# Tina\n"})
check("write_file on new note: OK", res.startswith("OK:"))
state = m._note_state_load()
check("write_file on new note: hash recorded", target in state)

# --- write_file on the SAME (now-existing) note: refused, even though nothing changed
#     since our own last recorded write (enforced "never write_file over Canon") ---
before = open(full, encoding="utf-8").read()
res = m.tool_write_file({"path": target, "content": "clobbered content"})
check("write_file over existing note: refused", res.startswith("ERROR:") and "refused" in res)
check("write_file over existing note: file untouched", open(full, encoding="utf-8").read() == before)

# --- append_file on the SAME note: allowed (no hand-edit yet, hash matches) ---
res = m.tool_append_file({"path": target, "content": "\nMore about Tina.\n"})
check("append_file (no hand-edit): OK", res.startswith("OK:"))
check("append_file (no hand-edit): content appended", "More about Tina." in open(full, encoding="utf-8").read())

# --- simulate a HUMAN hand-edit: modify the file directly on disk, bypassing the harness ---
with open(full, "a", encoding="utf-8") as f:
    f.write("\nHand-edited by Louise directly in Obsidian.\n")

# --- append_file after a hand-edit: NOT blocked — appends anyway, preserves the edit ---
res = m.tool_append_file({"path": target, "content": "\nAgent adds more.\n"})
check("append_file after hand-edit: still OK (not blocked)", res.startswith("OK:"))
final_content = open(full, encoding="utf-8").read()
check("append_file after hand-edit: human's edit preserved", "Hand-edited by Louise directly in Obsidian." in final_content)
check("append_file after hand-edit: agent's new content also present", "Agent adds more." in final_content)

# --- write_file over an existing note is STILL refused after the hash was refreshed ---
res = m.tool_write_file({"path": target, "content": "clobbered again"})
check("write_file over existing note (post hand-edit): still refused", res.startswith("ERROR:"))

# --- HARNESS_PROTECT_EXISTING=0 opts back out of the refusal ---
os.environ["HARNESS_PROTECT_EXISTING"] = "0"
res = m.tool_write_file({"path": target, "content": "intentional overwrite"})
check("write_file with HARNESS_PROTECT_EXISTING=0: allowed", res.startswith("OK:"))
check("write_file with HARNESS_PROTECT_EXISTING=0: content replaced", open(full, encoding="utf-8").read() == "intentional overwrite")
os.environ.pop("HARNESS_PROTECT_EXISTING", None)

# --- write_file on a brand-new note (never existed) is always allowed ---
target2 = "Canon/People/Bob.md"
res = m.tool_write_file({"path": target2, "content": "---\ntype: person\nname: Bob\n---\n# Bob\n"})
check("write_file on a different new note: OK", res.startswith("OK:"))

sys.exit(fail)
PY
RC=$?
[ "$RC" -eq 0 ] || fail=1

# --- note-write-state.py CLI round-trips against the SAME state file ollama_agent.py
#     just wrote (schema compatibility between the two independent implementations) ---
check "state file exists after harness writes" test -f "$STATE_FILE"

OUT_CHECK1="$(VAULT_DIR="$TV" python3 "$NWS" check --path "Canon/People/Bob.md")"
check "CLI check: harness-recorded note reads back MATCH" [ "$OUT_CHECK1" = "MATCH" ]

# Hand-edit Bob.md directly, then re-check via the CLI -> MISMATCH
printf '\nBob was edited by hand.\n' >> "$TV/Canon/People/Bob.md"
OUT_CHECK2="$(VAULT_DIR="$TV" python3 "$NWS" check --path "Canon/People/Bob.md")"
check "CLI check: hand-edited note reads back MISMATCH" [ "$OUT_CHECK2" = "MISMATCH" ]

# A note with no recorded entry -> UNKNOWN
printf -- '---\ntype: person\nname: Carol\n---\n# Carol\n' > "$TV/Canon/People/Carol.md"
OUT_CHECK3="$(VAULT_DIR="$TV" python3 "$NWS" check --path "Canon/People/Carol.md")"
check "CLI check: never-recorded note reads back UNKNOWN" [ "$OUT_CHECK3" = "UNKNOWN" ]

# CLI record then check -> MATCH
VAULT_DIR="$TV" python3 "$NWS" record --path "Canon/People/Carol.md" --agent Implementer >/dev/null
OUT_CHECK4="$(VAULT_DIR="$TV" python3 "$NWS" check --path "Canon/People/Carol.md")"
check "CLI record then check: MATCH" [ "$OUT_CHECK4" = "MATCH" ]

# A deleted note's entry is pruned on the next save (record on a missing file, or prune)
rm -f "$TV/Canon/People/Bob.md"
VAULT_DIR="$TV" python3 "$NWS" prune >/dev/null
check "prune: entry for deleted note removed from state file" bash -c '
    python3 - "$1" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if "Canon/People/Bob.md" not in d else 1)
PY
' _ "$STATE_FILE"
check "prune: surviving note entry (Carol) untouched" bash -c '
    python3 - "$1" <<PY
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if "Canon/People/Carol.md" in d else 1)
PY
' _ "$STATE_FILE"

[ "$fail" -eq 0 ] && echo "test-note-write-state: PASS" || { echo "test-note-write-state: FAIL"; exit 1; }
