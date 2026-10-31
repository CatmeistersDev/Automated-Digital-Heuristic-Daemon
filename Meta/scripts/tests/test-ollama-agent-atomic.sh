#!/bin/bash
# test-ollama-agent-atomic.sh — behavioral test for atomic write_file/append_file in
# ollama_agent.py. The scheduler kills hung agent process groups; a kill mid-write must
# never truncate a vault note. Asserts: write_file/append_file produce intact content and
# leave no stray temp file, and a simulated write failure leaves a pre-existing file
# byte-for-byte untouched (no partial/truncated content). Loads the module by path
# (mirrors test-discord-bot.sh) — no Ollama/network needed.
# HARNESS_PROTECT_EXISTING=0: this test is about _atomic_write's own mid-write-kill
# safety, not the separate hand-edit-refusal feature (see test-note-write-state.sh) —
# without this, the second write_file call below would be legitimately REFUSED (target
# already exists) before ever reaching _atomic_write, which is not what this test means
# to exercise.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
AGENT_PY="$SCRIPT_DIR/ollama_agent.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
mkdir -p "$TV/Canon/Notes"

VAULT_DIR="$TV" HARNESS_PROTECT_EXISTING=0 python3 - "$AGENT_PY" <<'PY'
import importlib.util, sys, os, glob

spec = importlib.util.spec_from_file_location("oagent", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)   # module-level VAULT_DIR reads env VAULT_DIR at import time

fail = 0
def check(desc, ok):
    global fail
    print(("  ok: " if ok else "  FAIL: ") + desc)
    if not ok:
        fail = 1

vault = os.environ["VAULT_DIR"]
target = "Canon/Notes/atomic.md"
full = os.path.join(vault, target)
no_stray_tmp = lambda: not glob.glob(full + ".tmp.*")

# --- write_file: fresh create, intact content, no stray temp file left behind ---
res = m.tool_write_file({"path": target, "content": "hello world"})
check("write_file returns OK", res.startswith("OK:"))
check("write_file content intact", open(full, encoding="utf-8").read() == "hello world")
check("write_file leaves no stray temp file", no_stray_tmp())

# --- append_file: appends without losing prior content, no stray temp file ---
res = m.tool_append_file({"path": target, "content": " -- appended"})
check("append_file returns OK", res.startswith("OK:"))
check("append_file content intact", open(full, encoding="utf-8").read() == "hello world -- appended")
check("append_file leaves no stray temp file", no_stray_tmp())

# --- simulated failure mid-write: pre-existing content must survive untouched ---
# content=None (key present, so the "" default does not kick in) makes f.write() raise
# TypeError partway through _atomic_write — exactly the "killed mid-write" shape this
# hardening protects against. With the old direct `open(full, "w")` this would have
# truncated the file to empty; with the temp-file+os.replace fix, `full` is untouched.
before = open(full, encoding="utf-8").read()
raised = False
try:
    m.tool_write_file({"path": target, "content": None})
except TypeError:
    raised = True
check("write_file(None) raised (simulated mid-write failure)", raised)
after = open(full, encoding="utf-8").read()
check("failed write left original file byte-for-byte untouched", before == after)
check("failed write leaves no stray temp file", no_stray_tmp())

# Same simulated-failure check for append_file
before = open(full, encoding="utf-8").read()
raised = False
try:
    m.tool_append_file({"path": target, "content": None})
except TypeError:
    raised = True
check("append_file(None) raised (simulated mid-write failure)", raised)
after = open(full, encoding="utf-8").read()
check("failed append left original file byte-for-byte untouched", before == after)
check("failed append leaves no stray temp file", no_stray_tmp())

sys.exit(fail)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "test-ollama-agent-atomic: PASS" || { echo "test-ollama-agent-atomic: FAIL"; exit 1; }
