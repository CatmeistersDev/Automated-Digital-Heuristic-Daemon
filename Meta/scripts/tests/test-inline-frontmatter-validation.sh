#!/bin/bash
# test-inline-frontmatter-validation.sh — behavioral test for inline frontmatter
# validation on write_file/append_file (Phase 3 hardening, 2026-07-18). Previously
# validate-frontmatter.py only ran in the weekly ci-check / Reviewer pass, so bad
# frontmatter from a model write could sit for days. Asserts: a clean note's tool
# result carries no WARNING suffix; a note with invalid frontmatter DOES get a
# WARNING appended to the (still-successful) tool result, both for write_file and
# append_file; the check is scoped to Canon/Thinking .md notes only; a missing
# validator degrades silently (no crash, no warning); and a validator that raises
# mid-check is swallowed defensively (never breaks the write). No Ollama/network.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
AGENT_PY="$SCRIPT_DIR/ollama_agent.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
mkdir -p "$TV/Canon/People" "$TV/Meta/operations"
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

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

# --- clean, fully-valid frontmatter: no WARNING suffix ---
valid = "---\ntype: person\nname: Tina\nsource: ai-extracted\ncreated: 2026-07-18\n---\n# \U0001F464 Tina\n"
res = m.tool_write_file({"path": "Canon/People/Tina.md", "content": valid})
check("valid note write_file: OK", res.startswith("OK:"))
check("valid note write_file: no WARNING suffix", "WARNING" not in res)

# --- invalid frontmatter (missing required 'source' + 'created') on a NEW note:
#     write still succeeds (never blocks a write), but the result carries a WARNING ---
invalid = "---\ntype: person\nname: Bob\n---\n# \U0001F464 Bob\n"
res = m.tool_write_file({"path": "Canon/People/Bob.md", "content": invalid})
check("invalid note write_file: still OK (not blocked)", res.startswith("OK:"))
check("invalid note write_file: WARNING present", "WARNING: written, but frontmatter invalid" in res)
check("invalid note write_file: file still has the content", "name: Bob" in open(os.path.join(os.environ["VAULT_DIR"], "Canon/People/Bob.md"), encoding="utf-8").read())

# --- append_file to an existing note that's still invalid after the append: WARNING too ---
res = m.tool_append_file({"path": "Canon/People/Bob.md", "content": "\nMore about Bob.\n"})
check("append to still-invalid note: OK", res.startswith("OK:"))
check("append to still-invalid note: WARNING present", "WARNING: written, but frontmatter invalid" in res)

# --- append_file that FIXES the frontmatter is out of scope here (append only adds at
#     the end, can't retroactively fix frontmatter) — but a note that BECOMES valid via
#     write_file should have no WARNING ---
res = m.tool_write_file({"path": "Canon/People/Carol.md", "content": "---\ntype: person\nname: Carol\nsource: human\ncreated: 2026-07-18\n---\n# \U0001F464 Carol\n"})
check("valid new note (Carol): no WARNING suffix", "WARNING" not in res)

# --- scope: a .md file outside Canon/Thinking (e.g. Meta/operations/) is never validated ---
res = m.tool_write_file({"path": "Meta/operations/draft.md", "content": "not even frontmatter"})
check("out-of-scope Meta/ note: OK", res.startswith("OK:"))
check("out-of-scope Meta/ note: no WARNING (not in Canon/Thinking scope)", "WARNING" not in res)

# --- defensive wrap: a validator that raises mid-check must never break the write ---
def _boom(_path):
    raise RuntimeError("simulated validator bug")
m._load_validator()  # force lazy-load so _VALIDATOR_MODULE is populated
assert m._VALIDATOR_MODULE is not None, "validator should have loaded from the real repo"
m._VALIDATOR_MODULE.validate_file = _boom
res = m.tool_write_file({"path": "Canon/People/Dave.md", "content": invalid})
check("validator raising: write still OK (swallowed)", res.startswith("OK:"))
check("validator raising: no WARNING (check failed silently)", "WARNING" not in res)

sys.exit(fail)
PY
RC=$?
[ "$RC" -eq 0 ] || fail=1

# --- feature-degrade: validator script missing entirely -> no warning, no crash.
# Copy ollama_agent.py WITHOUT validate-frontmatter.py alongside it, so _load_validator's
# os.path.dirname(__file__)-relative lookup finds nothing. ---
mkdir -p "$TV/scripts-novalidator"
cp "$AGENT_PY" "$TV/scripts-novalidator/ollama_agent.py"
mkdir -p "$TV/vault2/Canon/People"

OUT2="$(VAULT_DIR="$TV/vault2" python3 - "$TV/scripts-novalidator/ollama_agent.py" <<'PY'
import importlib.util, sys, os
spec = importlib.util.spec_from_file_location("oagent2", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
res = m.tool_write_file({"path": "Canon/People/Eve.md", "content": "---\ntype: person\nname: Eve\n---\n# Eve\n"})
print(res)
sys.exit(0 if (res.startswith("OK:") and "WARNING" not in res) else 1)
PY
)"
RC2=$?
check "missing validator: write still OK, no WARNING, no crash" [ "$RC2" -eq 0 ]

[ "$fail" -eq 0 ] && echo "test-inline-frontmatter-validation: PASS" || { echo "test-inline-frontmatter-validation: FAIL"; exit 1; }
