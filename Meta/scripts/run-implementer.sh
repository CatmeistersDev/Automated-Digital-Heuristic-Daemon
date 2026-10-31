#!/bin/bash
# run-implementer.sh — deterministic vault self-healing (no LLM).
# Auto-FIXES provably-safe, reversible issues:
#   - missing source_date on AI notes; missing type-emoji in H1
#   - wikilinks that DO resolve to an existing note but are written path-style
#     ([[Canon/People/X.md]]) or in the wrong case -> rewritten to canonical [[X]]
#   - dangling links to plausible entity names -> a corralled stub in Canon/_stubs/
#     (additive, reversible; never touches a typed Canon folder)
# FLAGS risky/ambiguous issues to Meta/review-queue/ — dangling NON-entity links
#   ([[Me]], [[CEO]]), version-junk ([[Quinn 2.5]]). Never edits existing content,
#   merges entries, or deletes notes.
# Logs to Meta/AI-Reflections/implementer-log.md.
#
# B1 (2026-07-19): ALSO parses NEW review-log.md findings (severity tags emitted by
# run-reviewer.sh since 2026-07-18) from a byte-offset cursor (Meta/.implementer-review-cursor):
#   [BLOCKER]/[HIGH]  -> escalated to Meta/review-queue/<date>-review-escalations.md
#   [MEDIUM]/[LOW]    -> logged only; the mechanical classes behind them (missing
#                        source_date/emoji/wikilinks) are exactly what the deterministic
#                        pass above auto-fixes on the same run, and missed-entity judgment
#                        lines already get their own review-queue file from the Reviewer.
# This closes the "Implementer reads review-log.md" gap that CLAUDE.md called aspirational.
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$VAULT_DIR"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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

VAULT_DIR="$VAULT_DIR" python3 - <<'PY'
import os, re, json, datetime, tempfile, hashlib
from pathlib import Path

def atomic_write(path, content):
    # temp file in the same dir + os.replace: a scheduler kill mid-write must
    # never leave a Canon/Thinking note truncated
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=os.path.dirname(path) or ".")
    try:
        # mkstemp defaults to 0600 -- unreadable to the vault's own later reads once the
        # write and read identities differ (NFS+unprivileged-LXC split, 2026-07-20).
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise

# Note write-state (hand-edit detection, Phase 3 hardening 2026-07-18) — same state
# file/schema as Meta/scripts/note-write-state.py and ollama_agent.py's harness hooks
# (duplicated here, not imported: same self-contained-script convention as atomic_write
# above). The Implementer's edits are always additive/non-destructive (wikilink fixes
# only, never touches prose) so a hand-edit is never a reason to skip a fix — just log
# it and refresh the hash after.
NOTE_STATE_PATH = os.path.join(os.environ["VAULT_DIR"], "Meta", ".note-write-state.json")

def _note_state_load():
    if not os.path.isfile(NOTE_STATE_PATH):
        return {}
    try:
        with open(NOTE_STATE_PATH, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}

def _note_state_save(state):
    try:
        vd = os.environ["VAULT_DIR"]
        pruned = {rp: e for rp, e in state.items() if os.path.isfile(os.path.join(vd, rp))}
        dirpath = os.path.dirname(NOTE_STATE_PATH)
        os.makedirs(dirpath, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(NOTE_STATE_PATH) + ".tmp.", dir=dirpath)
        try:
            os.chmod(tmp, 0o644)  # mkstemp's 0600 default is unreadable cross-identity under NFS+LXC
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump(pruned, fh, ensure_ascii=False)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, NOTE_STATE_PATH)
        except Exception:
            try:
                os.remove(tmp)
            except OSError:
                pass
    except Exception:
        pass

hand_edited = []   # relpaths detected as hand-edited since their last recorded agent write

vault = os.environ["VAULT_DIR"]
# realpath (not the raw env value) is the containment boundary for the stub-path guard
# below: a symlink INSIDE the vault pointing outside it must not slip past a naive
# string-prefix check, so both sides of that check need to be resolved the same way.
vault_root = os.path.realpath(vault)
today = datetime.date.today().isoformat()
EMOJI = {"person":"👤","action":"🎯","event":"📅","reflection":"💭","belief":"🪨",
         "decision":"⚖️","concept":"💡","project":"📁","place":"📍","organization":"🏢",
         "research":"🔬","ai-reflection":"🤖"}

def parse_fm(text):
    fm = {}
    if text.startswith("---"):
        end = text.find("\n---", 3)
        if end != -1:
            for line in text[3:end].splitlines():
                if ":" in line and not line.strip().startswith("-"):
                    k, v = line.split(":", 1)
                    fm[k.strip()] = v.strip().strip('"').strip("'")
            return fm, end
    return fm, -1

# Build map of all note basenames -> canonical casing (for wikilink resolution).
# Obsidian resolves [[Name]] to a note named Name.md ANYWHERE in the vault, case-
# insensitively. notemap lets us both resolve and normalize a link to the real filename.
notemap = {}  # lowercase basename -> canonical basename
for sub in ("Canon", "Thinking", "Inbox"):
    for root, _, files in os.walk(os.path.join(vault, sub)):
        for f in files:
            if f.endswith(".md"):
                base = f[:-3]
                notemap.setdefault(base.lower(), base)
notes = set(notemap)  # set of lowercase basenames

fixes, broken, stubs, security = [], [], [], []
# capture group 1 = link target (before '|'); group 2 = optional '|alias'
wl = re.compile(r'\[\[([^\]|]+)(\|[^\]]+)?\]\]')

# Dangling links we should NOT auto-stub (flag for a human instead): pronouns/roles,
# agent names, and version-junk like "Quinn 2.5" (a dedup artifact, not a real entity).
STUB_STOP = {"me", "i", "you", "us", "we", "ceo", "cto", "cfo", "coo", "ciso", "cmo",
             "cro", "chro", "advisor", "orchestrator", "extractor", "reviewer",
             "implementer", "thinker", "mirror", "operator", "researcher", "briefing",
             "retrospective", "task-enricher", "groomer", "dedup", "health", "manifest"}
ENTITY_RE = re.compile(r"^[A-Z][A-Za-z0-9 .&'\-]{1,49}$")
VERSION_RE = re.compile(r"\d+\.\d+")

# Names a human has marked ambiguous / do-not-create (one per line). Dangling links to
# these are flagged for human disambiguation, never auto-stubbed (e.g. "Mort" -> which Mort?).
NO_STUB = set()
_ns = os.path.join(vault, "Meta", "implementer-no-stub.txt")
if os.path.exists(_ns):
    for _line in open(_ns, encoding="utf-8"):
        _s = _line.strip()
        if _s and not _s.startswith("#"):
            NO_STUB.add(_s.lower())

STUB_TMPL = """---
type: stub
name: {name}
created: {today}
updated: {today}
source: ai-generated
source_agent: Implementer
source_date: {today}
status: stub
---

# \U0001F331 {name}

<!-- source: ai-generated, agent: Implementer, {today}, auto-stub for a dangling [[{name}]] wikilink. Human: set the real type + move to the right Canon folder and flesh out, or delete. -->
Stub created by the Implementer to resolve a dangling [[{name}]] link. Needs human typing/placement.
"""

def stub_basename(name):
    """Canonical basename to stub for a dangling link, or None -> flag for human."""
    n = name.strip()
    if not n or n.lower() in STUB_STOP or n.lower() in NO_STUB:
        return None
    if not ENTITY_RE.match(n):
        return None
    if VERSION_RE.search(n):
        return None
    return n

for sub in ("Canon", "Thinking"):
    base = os.path.join(vault, sub)
    if not os.path.isdir(base):
        continue
    for root, _, files in os.walk(base):
        for f in files:
            if not f.endswith(".md"):
                continue
            p = os.path.join(root, f)
            rel = os.path.relpath(p, vault)
            try:
                text = open(p, encoding="utf-8").read()
            except Exception:
                continue
            fm, end = parse_fm(text)
            new = text
            # FIX 1: AI note missing source_date -> add (use created or today)
            if fm.get("source", "").startswith("ai") and "source_date" not in fm and end != -1:
                sd = fm.get("created", today)
                new = new[:end] + f"\nsource_date: {sd}" + new[end:]
                fixes.append(f"{rel}: added source_date")
                fm["source_date"] = sd
            # FIX 2: H1 missing type emoji
            t = fm.get("type", "")
            emj = EMOJI.get(t)
            if emj:
                m = re.search(r'^#\s+(.*)$', new, re.MULTILINE)
                if m and re.match(r'^[A-Za-z0-9"\'(]', m.group(1).strip()):
                    new = new.replace(m.group(0), f"# {emj} {m.group(1).strip()}", 1)
                    fixes.append(f"{rel}: added {emj} to H1")
            # FIX 3: resolve / normalize wikilinks. Rewrite links that DO resolve but are
            # path-style or wrong-case; create corralled stubs for plausible dangles; flag
            # the rest. Operates on the in-progress `new` text.
            def _resolve_link(m):
                target = m.group(1).strip()
                alias = m.group(2) or ""
                base = target.split("/")[-1]
                if base.endswith(".md"):
                    base = base[:-3]
                key = base.lower()
                if key in notemap:
                    canon = notemap[key]
                    if canon != target:          # path-style or wrong-case -> normalize
                        fixes.append(f"{rel}: link [[{target}]] -> [[{canon}]]")
                        return f"[[{canon}{alias}]]"
                    return m.group(0)
                sb = stub_basename(base)         # genuine dangle
                if sb is not None:
                    stub_path = os.path.join(vault, "Canon", "_stubs", sb + ".md")
                    # Path-traversal guard: sb is derived from a wikilink target, which
                    # is model/vault-derived (untrusted) input. stub_basename() already
                    # rejects most shapes via ENTITY_RE + the earlier '/'-split, but a
                    # string-prefix check on the raw path is not the real guarantee — it
                    # can be fooled by a symlink (e.g. Canon/_stubs itself redirected
                    # outside the vault). Resolve the candidate path for real and verify
                    # containment; refuse and log instead of writing on any escape.
                    resolved = os.path.realpath(stub_path)
                    try:
                        Path(resolved).relative_to(vault_root)
                    except ValueError:
                        security.append(
                            f"{rel}: refused to create stub for [[{target}]] — "
                            f"resolved path {resolved} escapes the vault ({vault_root})"
                        )
                        return m.group(0)
                    if not os.path.exists(stub_path):
                        os.makedirs(os.path.dirname(stub_path), exist_ok=True)
                        with open(stub_path, "w", encoding="utf-8") as sfh:
                            sfh.write(STUB_TMPL.format(name=sb, today=today))
                        stubs.append(f"Canon/_stubs/{sb}.md (for [[{sb}]])")
                    notemap[sb.lower()] = sb      # so later links in this run resolve
                    notes.add(sb.lower())
                    return f"[[{sb}{alias}]]"
                broken.append(f"{rel}: dangling [[{target}]] (flagged for human)")
                return m.group(0)

            new = wl.sub(_resolve_link, new)
            if new != text:
                note_state = _note_state_load()
                entry = note_state.get(rel)
                if entry and entry.get("hash") != hashlib.sha256(text.encode("utf-8")).hexdigest():
                    hand_edited.append(rel)
                atomic_write(p, new)
                note_state[rel] = {
                    "hash": hashlib.sha256(new.encode("utf-8")).hexdigest(),
                    "updated": today,
                    "agent": "Implementer",
                }
                _note_state_save(note_state)

# Log fixes + stubs + refused (security) attempts
if fixes or stubs or security:
    os.makedirs(os.path.join(vault, "Meta", "AI-Reflections"), exist_ok=True)
    with open(os.path.join(vault, "Meta", "AI-Reflections", "implementer-log.md"), "a", encoding="utf-8") as fh:
        fh.write(f"\n## Implementer: {today}\n")
        for x in fixes:
            fh.write(f"- {x}\n")
        for x in stubs:
            fh.write(f"- created stub {x}\n")
        for x in security:
            fh.write(f"- 🛑 SECURITY: {x}\n")
        for x in hand_edited:
            fh.write(f"- ⚠️ note was hand-edited since last agent write — fixed anyway: {x}\n")

# Queue genuinely-dangling, non-stubbable links for human review (no auto-create/delete)
if broken:
    rq = os.path.join(vault, "Meta", "review-queue")
    os.makedirs(rq, exist_ok=True)
    with open(os.path.join(rq, f"{today}-broken-links.md"), "w", encoding="utf-8") as fh:
        fh.write(f"---\ntype: review-item\nname: Dangling wikilinks {today}\nstatus: pending\n---\n\n")
        fh.write(f"# 📋 Dangling wikilinks — {today}\n\nThese links point to notes that don't exist and were not auto-stubbed (pronoun/role/version-junk or non-entity). Fix the link, create the right note, or ignore:\n\n")
        fh.write("\n".join(f"- {x}" for x in broken) + "\n")

print(f"Implementer: {len(fixes)} fix(es), {len(stubs)} stub(s), {len(broken)} dangling link(s) flagged, {len(security)} refused (path escape), {len(hand_edited)} hand-edited note(s) fixed anyway")
for x in fixes[:10]:
    print("  FIX", x)
for x in stubs[:10]:
    print("  STUB", x)
for x in broken[:10]:
    print("  FLAG", x)
for x in security[:10]:
    print("  REFUSE", x)
for x in hand_edited[:10]:
    print("  HAND-EDITED (fixed anyway)", x)
PY

# ── B1: review-log severity parsing (deterministic, cursor-tracked) ──────────────
VAULT_DIR="$VAULT_DIR" python3 - <<'PY'
import os, re, datetime

vault = os.environ["VAULT_DIR"]
today = datetime.date.today().isoformat()
log_path = os.path.join(vault, "Meta", "AI-Reflections", "review-log.md")
cursor_path = os.path.join(vault, "Meta", ".implementer-review-cursor")

if not os.path.isfile(log_path):
    print("Implementer/B1: no review-log.md — nothing to parse")
    raise SystemExit(0)

size = os.path.getsize(log_path)
try:
    offset = int(open(cursor_path, encoding="utf-8").read().strip())
except (OSError, ValueError):
    offset = 0
if offset > size:   # log rotated/truncated -> start over
    offset = 0

with open(log_path, encoding="utf-8", errors="replace") as fh:
    fh.seek(offset)
    chunk = fh.read()

# Parse finding lines under their "## Review: <ts> — <note>" headers.
TAG_RE = re.compile(r'^-?\s*\[(BLOCKER|HIGH|MEDIUM|LOW)\]\s*(.+)$')
header = "(no header)"
escalate, minor = [], 0
for line in chunk.splitlines():
    if line.startswith("## Review:"):
        header = line[len("## Review:"):].strip()
        continue
    m = TAG_RE.match(line.strip())
    if not m:
        continue
    sev, msg = m.group(1), m.group(2).strip()
    if sev in ("BLOCKER", "HIGH"):
        escalate.append((sev, msg, header))
    else:
        minor += 1

if escalate:
    rq = os.path.join(vault, "Meta", "review-queue")
    os.makedirs(rq, exist_ok=True)
    out = os.path.join(rq, f"{today}-review-escalations.md")
    is_new = not os.path.exists(out)
    with open(out, "a", encoding="utf-8") as fh:
        if is_new:
            fh.write(f"---\ntype: review-item\nname: Reviewer escalations {today}\n"
                     f"status: pending\nsource_agent: Implementer\n---\n\n"
                     f"# 📋 Reviewer [BLOCKER]/[HIGH] findings — {today}\n\n"
                     "Escalated automatically from review-log.md (Implementer B1 wiring). "
                     "Fix the underlying note/pipeline issue, then delete or close this item.\n\n")
        for sev, msg, hdr in escalate:
            fh.write(f"- **[{sev}]** {msg}  \n  _from review:_ {hdr}\n")

# Log a summary line
os.makedirs(os.path.join(vault, "Meta", "AI-Reflections"), exist_ok=True)
if escalate or minor:
    with open(os.path.join(vault, "Meta", "AI-Reflections", "implementer-log.md"), "a", encoding="utf-8") as fh:
        fh.write(f"\n## Implementer/B1 review-log parse: {today}\n")
        fh.write(f"- {len(escalate)} BLOCKER/HIGH escalated to review-queue, "
                 f"{minor} MEDIUM/LOW left to the auto-fix pass\n")

# Advance the cursor only after successful processing
with open(cursor_path, "w", encoding="utf-8") as fh:
    fh.write(str(size))

print(f"Implementer/B1: {len(escalate)} escalated, {minor} minor (auto-fix classes), cursor -> {size}")
PY

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add Canon/ Thinking/ Meta/AI-Reflections/ Meta/review-queue/ 2>/dev/null || true
    if git diff --cached --quiet; then
        echo "(nothing to fix/commit)"
    elif cerr="$(git commit -q -m "[Implementer] vault self-heal $(date +%Y-%m-%d)" 2>&1)"; then
        echo "committed"
    else
        echo "⚠ COMMIT FAILED: $cerr" >&2
        exit 1
    fi
fi
