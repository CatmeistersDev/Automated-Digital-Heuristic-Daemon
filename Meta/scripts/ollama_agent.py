#!/usr/bin/env python3
"""
ollama_agent.py — Local tool-using agent harness (Claude-CLI replacement).

== WHY THIS EXISTS ==
The upstream AutoADHD agents are Claude Code agents: a prompt tells them to read
skill files and then use file tools (read/write/grep/git) to mutate the vault.
Ollama's plain /api/generate only returns text — no tools. And the user's GGUF
(Qwen3.6-A3B-MTP) reports "does not support tools" via Ollama's native tools API.

So this harness gives ANY local Ollama model the same powers, using a
**prompt-based JSON tool protocol** (validated working on gemma4:e4b):
the model replies with one JSON object per turn — {"tool": <name>, "args": {...}} —
this harness executes it (path-scoped to the vault), feeds the result back, and
loops until the model calls {"tool": "final", "args": {"answer": ...}}.

Model-agnostic by design: no dependency on Ollama tool templates or a specific tag.

== USAGE ==
  python ollama_agent.py --prompt "task..." [--system-file f] [--model gemma4:e4b]
  python ollama_agent.py --prompt-file p.txt --vault /vault --verbose

Stdlib only (urllib) so it runs unchanged in the Linux container.
"""

import os
import re
import sys
import json
import time
import shutil
import hashlib
import tempfile
import argparse
import subprocess
import urllib.request
from datetime import datetime

# ---------------- Config ----------------
OLLAMA_HOST = os.environ.get("OLLAMA_HOST", "http://ollama:11434")
VAULT_DIR = os.path.abspath(os.environ.get("VAULT_DIR", os.getcwd()))
DEFAULT_MODEL = os.environ.get(
    "OLLAMA_AGENT_MODEL",
    "qwen3.6:35b-a3b",
)
MAX_FILE_CHARS = 12000   # truncate huge file reads fed back to the model
MAX_RESULT_CHARS = 8000  # cap any single tool result


def log(msg):
    print(f"[ollama_agent {datetime.now().strftime('%H:%M:%S')}] {msg}", file=sys.stderr, flush=True)


ACTIVITY_LOG_MAX_BYTES = int(os.environ.get("AGENT_ACTIVITY_MAX_BYTES", 10 * 1024 * 1024))  # 10MB
ACTIVITY_LOG_BACKUPS = int(os.environ.get("AGENT_ACTIVITY_BACKUPS", 3))


def _rotate_activity_log(path):
    """Rotate agent-activity.jsonl .2 -> .3, .1 -> .2, current -> .1 once it crosses the
    size threshold. Every agent run appends here forever otherwise — this file has no
    natural bound the way scheduler.log's per-run entries do."""
    try:
        if os.path.getsize(path) < ACTIVITY_LOG_MAX_BYTES:
            return
    except OSError:
        return
    for i in range(ACTIVITY_LOG_BACKUPS - 1, 0, -1):
        src, dst = f"{path}.{i}", f"{path}.{i + 1}"
        if os.path.exists(src):
            os.replace(src, dst)
    try:
        os.replace(path, f"{path}.1")
    except OSError:
        pass


def log_activity(record):
    """Append a structured tool-call record to Meta/agent-activity.jsonl (best-effort).

    Unlike log() — which only writes to stderr and is discarded by the scheduler on a
    successful run — this is PERSISTED, so every tool call (especially destructive bash)
    leaves a durable trace. Never raises; logging must not break an agent run.
    """
    try:
        path = os.path.join(VAULT_DIR, "Meta", "agent-activity.jsonl")
        _rotate_activity_log(path)
        with open(path, "a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
    except Exception:
        pass


# ---------------- Path safety ----------------
def _resolve(path):
    """Resolve a vault-relative (or absolute-inside-vault) path; reject escapes.
    Uses realpath (not abspath) so a symlink inside the vault pointing outside
    cannot slip past the prefix check."""
    if path is None:
        raise ValueError("missing 'path'")
    vault_real = os.path.realpath(VAULT_DIR)
    if os.path.isabs(path):
        full = os.path.realpath(path)
    else:
        full = os.path.realpath(os.path.join(VAULT_DIR, path))
    if not (full == vault_real or full.startswith(vault_real + os.sep)):
        raise ValueError(f"path escapes vault: {path}")
    # `.secrets/` lives INSIDE the vault, so the escape check above doesn't cover it.
    # Deny every tool (read/write/list/grep) access to it: a prompt-injected transcript
    # or a read-only Advisor call must never be able to read the Discord/HF tokens or the
    # plaintext Unraid ssh credentials, nor write into that directory.
    secrets_dir = os.path.join(vault_real, ".secrets")
    if full == secrets_dir or full.startswith(secrets_dir + os.sep):
        raise ValueError("path is in the protected .secrets/ directory")
    return full


def _assert_writable(full):
    """Reject writes to pipeline-owned areas. The Inbox is shell-owned: the pipeline
    rebuilds inbox notes deterministically from a pre-extraction snapshot to protect the
    verbatim '# Raw'. The model must NEVER write there (the prompt says so; this enforces
    it technically, for every inbox note — not just the one being processed)."""
    inbox_dir = os.path.join(os.path.realpath(VAULT_DIR), "Inbox")
    if full == inbox_dir or full.startswith(inbox_dir + os.sep):
        raise ValueError("Inbox/ is pipeline-owned; the model must not write there. "
                         "Create entities under Canon/ or Thinking/ instead.")
    # Clippings/ holds others' content filed verbatim — reference material,
    # agent-read-only for the same reason as Inbox: it is source evidence.
    clippings_dir = os.path.join(os.path.realpath(VAULT_DIR), "Clippings")
    if full == clippings_dir or full.startswith(clippings_dir + os.sep):
        raise ValueError("Clippings/ is filed reference material; the model must not "
                         "write there. Create entities under Canon/ or Thinking/ instead.")


# ---------------- Note write-state (hand-edit detection) ----------------
# Stored-vs-live SHA256 per Canon/Thinking note, so the "always append_file, never
# write_file over an existing note" convention becomes an ENFORCED check instead of just
# a prompt instruction, and a human hand-edit racing an agent write is at least logged
# instead of silently disappearing under the next append. State file schema/location is
# shared with the standalone CLI (note-write-state.py), used by the deterministic (non-
# LLM) write sites — see that file's docstring. Duplicated here rather than imported:
# same convention as every other small state-file helper in this codebase (atomic_write,
# review-rejections' _atomic_append, ...) — self-contained scripts, no cross-imports.
def _note_state_path():
    return os.path.join(VAULT_DIR, "Meta", ".note-write-state.json")


def _note_state_load():
    path = _note_state_path()
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _note_state_save(state):
    # Never let this bookkeeping break a real note write — best-effort, swallow errors.
    try:
        vd = VAULT_DIR
        pruned = {rp: entry for rp, entry in state.items()
                  if os.path.isfile(os.path.join(vd, rp))}
        path = _note_state_path()
        dirpath = os.path.dirname(path)
        os.makedirs(dirpath, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=dirpath)
        try:
            # mkstemp defaults to mode 0600 — harmless on a single-host mount (owner ==
            # every future reader) but a split write/read identity (e.g. a network-mount
            # + unprivileged-container setup) means a 600 file can silently become
            # unreadable to the vault's own agents. Widen it before anything else can see it.
            os.chmod(tmp, 0o644)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(pruned, f, ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except Exception:
            try:
                os.remove(tmp)
            except OSError:
                pass
    except Exception:
        pass


def _is_tracked_note(relpath):
    """Only Canon/ and Thinking/ notes are in scope — the "human might hand-edit a
    Canon entry" scenario this exists to catch. Inbox is a different, already-enforced
    protection (_assert_writable); Meta/ proposal/digest files are agent-owned, never
    hand-edited by convention."""
    return relpath.endswith(".md") and (relpath.startswith("Canon/") or relpath.startswith("Thinking/"))


def _note_state_relpath(full):
    return os.path.relpath(full, os.path.realpath(VAULT_DIR)).replace(os.sep, "/")


def _note_state_record(relpath, content):
    try:
        state = _note_state_load()
        state[relpath] = {
            "hash": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            "updated": datetime.now().isoformat(timespec="seconds"),
            "agent": os.environ.get("AGENT_NAME", ""),
        }
        _note_state_save(state)
    except Exception:
        pass


def _note_state_hand_edited(relpath, live_content):
    """True iff a stored hash exists for relpath AND it no longer matches live_content
    — i.e. something other than the last recorded agent write touched the file since
    (a human hand-edit, or an untracked writer). False for both "never recorded" and
    "matches" — this only ever flags a CONFIRMED divergence, never a guess."""
    try:
        entry = _note_state_load().get(relpath)
        if not entry:
            return False
        return entry.get("hash") != hashlib.sha256(live_content.encode("utf-8")).hexdigest()
    except Exception:
        return False


# ---------------- Inline frontmatter validation ----------------
# validate-frontmatter.py previously only ran in the weekly ci-check and the Reviewer
# pass — bad frontmatter from a model write could sit undetected for days. This reuses
# its EXACT validate_file() logic synchronously, right after a successful write to a
# Canon/Thinking note, and folds any error into the tool result so the model sees it on
# the very next turn. Loaded once (lazily, on first use) via importlib rather than a
# `import validate_frontmatter` (the filename is hyphenated, not a valid module name)
# and rather than a subprocess per call (python startup cost on every write_file/
# append_file would be real latency across a chunked extraction run writing dozens of
# notes). Feature-detected — a missing/broken validator degrades to a silent no-op,
# never a crash or a blocked write.
_VALIDATOR_MODULE = None
_VALIDATOR_LOAD_ATTEMPTED = False


def _load_validator():
    global _VALIDATOR_MODULE, _VALIDATOR_LOAD_ATTEMPTED
    if _VALIDATOR_LOAD_ATTEMPTED:
        return _VALIDATOR_MODULE
    _VALIDATOR_LOAD_ATTEMPTED = True
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "validate-frontmatter.py")
        if not os.path.isfile(path):
            return None
        import importlib.util
        spec = importlib.util.spec_from_file_location("_vault_frontmatter_validator", path)
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        _VALIDATOR_MODULE = mod
    except Exception:
        _VALIDATOR_MODULE = None
    return _VALIDATOR_MODULE


def _validate_note_inline(full, relpath):
    """Best-effort, synchronous, non-blocking frontmatter check on a just-written
    Canon/Thinking note. Returns a short suffix string to append to the tool result
    on the FIRST error found (empty string if clean, validator unavailable, or
    anything about the check itself goes wrong — this must never be the reason a
    real write fails or a tool call raises)."""
    try:
        mod = _load_validator()
        if mod is None:
            return ""
        issues = mod.validate_file(full)
        errors = [i for i in issues if i.level == "error"]
        if not errors:
            return ""
        return (f" WARNING: written, but frontmatter invalid: {errors[0].message} "
                "— fix with append_file or notify the human.")
    except Exception:
        return ""


# ---------------- Tools ----------------
def tool_read_file(args):
    full = _resolve(args.get("path"))
    if not os.path.isfile(full):
        return f"ERROR: not a file: {args.get('path')}"
    with open(full, "r", encoding="utf-8", errors="replace") as f:
        data = f.read()
    if len(data) > MAX_FILE_CHARS:
        return data[:MAX_FILE_CHARS] + f"\n...[truncated, {len(data)} chars total]"
    return data if data else "(empty file)"


def _atomic_write(full, content):
    """Write `content` to `full` via a temp file in the SAME directory + fsync +
    os.replace, so a kill mid-write (the scheduler kills hung agent process groups)
    can never leave a vault note truncated — the rename is atomic, so `full` always
    ends up either fully old or fully new, never partial. Temp file is same-directory
    (same filesystem) so os.replace is a pure rename, and is removed on any failure."""
    dirpath = os.path.dirname(full)
    fd, tmp = tempfile.mkstemp(prefix=os.path.basename(full) + ".tmp.", dir=dirpath or ".")
    try:
        # See the analogous chmod in _note_state_save() above — mkstemp's default 0600
        # can make the file unreadable to the vault's own later agent reads if the write
        # and read identities differ.
        os.chmod(tmp, 0o644)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, full)
    except Exception:
        try:
            os.remove(tmp)
        except OSError:
            pass
        raise


def tool_write_file(args):
    full = _resolve(args.get("path"))
    _assert_writable(full)
    content = args.get("content", "")
    relpath = _note_state_relpath(full)
    # Enforced version of the standing "never write_file over an existing Canon/
    # Thinking note — always append_file" rule (previously prompt-only). Refuses
    # unconditionally when the note already exists: even a byte-identical stored hash
    # doesn't make an overwrite safe, since write_file's whole failure mode is
    # discarding content the model didn't re-include in `content`. Gated behind
    # HARNESS_PROTECT_EXISTING (default ON) — every run-*.sh prompt that mentions
    # write_file (Extractor, Task-Enricher) already directs it at NEW notes only and
    # says "never write_file an existing note; always append_file", so this closes a
    # real gap (an LLM ignoring its own instructions) without touching any legitimate
    # workflow. If a future agent legitimately needs an overwrite, set
    # HARNESS_PROTECT_EXISTING=0 for that run.
    protect = os.environ.get("HARNESS_PROTECT_EXISTING", "1") != "0"
    if protect and _is_tracked_note(relpath) and os.path.isfile(full):
        mismatch = False
        try:
            with open(full, "r", encoding="utf-8", errors="replace") as f:
                live = f.read()
            mismatch = _note_state_hand_edited(relpath, live)
        except Exception:
            pass
        reason = ("it was hand-edited (or otherwise changed) since the last agent write to it"
                   if mismatch else "it already exists")
        return (f"ERROR: refused — {args.get('path')} is an EXISTING note and {reason}; "
                "write_file would overwrite it and lose its current content. "
                "Use append_file instead to add without losing prior content.")
    os.makedirs(os.path.dirname(full), exist_ok=True)
    _atomic_write(full, content)
    warn = ""
    if _is_tracked_note(relpath):
        _note_state_record(relpath, content)
        warn = _validate_note_inline(full, relpath)
        if warn:
            log(f"frontmatter validation: {relpath}:{warn.strip()}")
    return f"OK: wrote {len(content)} chars to {args.get('path')}" + warn


def tool_append_file(args):
    full = _resolve(args.get("path"))
    _assert_writable(full)
    content = args.get("content", "")
    relpath = _note_state_relpath(full)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    existing = ""
    if os.path.isfile(full):
        with open(full, "r", encoding="utf-8", errors="replace") as f:
            existing = f.read()
        # A hand-edit is NOT a reason to block an append — appending preserves whatever
        # the human/other writer added. Just make it visible instead of silent.
        if _is_tracked_note(relpath) and _note_state_hand_edited(relpath, existing):
            log(f"note was hand-edited since last agent write — appending anyway: {args.get('path')}")
            log_activity({
                "ts": datetime.now().isoformat(timespec="seconds"),
                "pid": os.getpid(), "agent": os.environ.get("AGENT_NAME", ""),
                "tool": "append_file", "note": relpath,
                "event": "hand_edit_detected_append_proceeds",
            })
    new_content = existing + content
    _atomic_write(full, new_content)
    warn = ""
    if _is_tracked_note(relpath):
        _note_state_record(relpath, new_content)
        warn = _validate_note_inline(full, relpath)
        if warn:
            log(f"frontmatter validation: {relpath}:{warn.strip()}")
    return f"OK: appended {len(content)} chars to {args.get('path')}" + warn


def tool_list_dir(args):
    full = _resolve(args.get("path", "."))
    if not os.path.isdir(full):
        return f"ERROR: not a directory: {args.get('path', '.')}"
    entries = []
    for name in sorted(os.listdir(full)):
        p = os.path.join(full, name)
        entries.append(f"{name}/" if os.path.isdir(p) else name)
    return "\n".join(entries) if entries else "(empty directory)"


def tool_grep(args):
    query = args.get("query", "")
    if not query:
        return "ERROR: missing 'query'"
    base = _resolve(args.get("path", "."))
    max_results = int(args.get("max_results", 40))
    hits = []
    for root, dirs, files in os.walk(base):
        dirs[:] = [d for d in dirs if not d.startswith(".")]
        for fn in files:
            if not fn.endswith((".md", ".txt", ".py", ".sh", ".json", ".yml", ".conf")):
                continue
            fp = os.path.join(root, fn)
            try:
                with open(fp, "r", encoding="utf-8", errors="replace") as f:
                    for i, line in enumerate(f, 1):
                        if query.lower() in line.lower():
                            rel = os.path.relpath(fp, VAULT_DIR)
                            hits.append(f"{rel}:{i}: {line.strip()[:200]}")
                            if len(hits) >= max_results:
                                return "\n".join(hits) + f"\n...[stopped at {max_results}]"
            except Exception:
                continue
    return "\n".join(hits) if hits else f"No matches for '{query}'."


def tool_move_file(args):
    src = _resolve(args.get("src"))
    dst = _resolve(args.get("dst"))
    _assert_writable(src)   # don't let the model move a shell-owned inbox note away
    _assert_writable(dst)   # ...or move anything into the pipeline-owned Inbox
    if not os.path.exists(src):
        return f"ERROR: src not found: {args.get('src')}"
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.move(src, dst)
    return f"OK: moved {args.get('src')} -> {args.get('dst')}"


_COMMIT_PREFIX_RE = re.compile(r'^\[[^\]]+\]')


def _agent_commit_prefix():
    """[Agent-Name] bracket prefix derived from AGENT_NAME (set by invoke-agent.sh),
    normalized to match the capitalization convention every run-*.sh commit already
    uses by hand (e.g. "task-enricher" -> "[Task-Enricher]"). Falls back to a generic
    "[Agent]" tag if AGENT_NAME is unset so a commit is never left unprefixed."""
    name = os.environ.get("AGENT_NAME", "").strip()
    if not name:
        return "[Agent]"
    label = "-".join(part.capitalize() for part in re.split(r'[-_]+', name) if part)
    return f"[{label}]" if label else "[Agent]"


def tool_git_commit(args):
    message = args.get("message", "agent commit")
    # Enforce the same "[Agent-Name] ..." subject prefix every hand-written run-*.sh
    # commit already carries (see lib-agent.sh's agent_prefixed_message and
    # agent-undo.sh, which trusts this prefix to distinguish agent commits from human
    # ones). Idempotent: a message the model already prefixed itself is left alone.
    if not _COMMIT_PREFIX_RE.match(message):
        message = f"{_agent_commit_prefix()} {message}"
    paths = args.get("paths")
    try:
        if paths:
            if isinstance(paths, str):
                paths = [paths]
            # Validate every path through the vault sandbox and pass them after `--`.
            # Without this, a model (or a prompt-injected transcript) could smuggle flags
            # like `--force` into `git add` and stage gitignored files (.secrets tokens)
            # into git history.
            safe = []
            vault_real = os.path.realpath(VAULT_DIR)
            for p in paths:
                p = str(p)
                if p.startswith("-"):
                    return f"ERROR: invalid path {p!r} (looks like a flag, not a file)"
                try:
                    full = _resolve(p)
                except ValueError as ve:
                    return f"ERROR: invalid path {p!r}: {ve}"
                safe.append(os.path.relpath(full, vault_real))
            subprocess.run(["git", "-C", VAULT_DIR, "add", "--"] + safe, check=True, capture_output=True, text=True)
        else:
            subprocess.run(["git", "-C", VAULT_DIR, "add", "-A"], check=True, capture_output=True, text=True)
        r = subprocess.run(["git", "-C", VAULT_DIR, "commit", "-m", message],
                           capture_output=True, text=True)
        if r.returncode != 0:
            if "nothing to commit" in (r.stdout + r.stderr).lower():
                return "OK: nothing to commit (working tree clean)"
            return f"ERROR: git commit failed: {r.stderr.strip()[:300]}"
        return f"OK: committed — {message}"
    except subprocess.CalledProcessError as e:
        return f"ERROR: git add failed: {e.stderr.strip()[:300]}"


# Web tools (added live 2026-07-07 for the Researcher; see SYSTEM.md "Researcher Web
# Access"). Merged back into the dev tree 2026-07-09. NOTE: these are dedicated tools —
# bash still refuses curl/wget, so the ONLY network egress is through these auditable,
# activity-logged calls.
def tool_fetch_url(args):
    url = args.get("url")
    if not url:
        return "ERROR: missing 'url'"
    try:
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=15) as response:
            html = response.read().decode('utf-8', errors='ignore')
        text = re.sub(r'<style[^>]*>.*?</style>', '', html, flags=re.IGNORECASE|re.DOTALL)
        text = re.sub(r'<script[^>]*>.*?</script>', '', text, flags=re.IGNORECASE|re.DOTALL)
        text = re.sub(r'<[^>]+>', ' ', text)
        text = re.sub(r'\s+', ' ', text).strip()
        if len(text) > MAX_RESULT_CHARS:
            return text[:MAX_RESULT_CHARS] + f"\n...[truncated]"
        return text if text else "(empty or unparseable page)"
    except Exception as e:
        return f"ERROR: fetch_url failed: {e}"

def tool_search_web(args):
    query = args.get("query")
    if not query:
        return "ERROR: missing 'query'"
    url_base = os.environ.get("SEARXNG_URL", "")
    if not url_base:
        try:
            path = os.path.join(VAULT_DIR, ".secrets", "searxng-url.txt")
            if os.path.isfile(path):
                url_base = open(path, encoding="utf-8").read().strip()
        except Exception:
            pass
    if not url_base:
        url_base = "http://localhost:8888"
    
    import urllib.parse
    import urllib.request
    try:
        search_url = f"{url_base.rstrip('/')}/search?q={urllib.parse.quote(query)}&format=json"
        req = urllib.request.Request(search_url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=10) as response:
            data = json.loads(response.read().decode('utf-8'))
        
        results = data.get("results", [])
        if not results:
            return "No search results found."
        
        out = []
        for r in results[:6]:
            out.append(f"Title: {r.get('title')}\nURL: {r.get('url')}\nSnippet: {r.get('content')}\n---")
        return "\n".join(out)
    except Exception as primary_e:
        try:
            ddg_url = f"https://html.duckduckgo.com/html/?q={urllib.parse.quote(query)}"
            req = urllib.request.Request(ddg_url, headers={'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'})
            with urllib.request.urlopen(req, timeout=10) as response:
                html = response.read().decode('utf-8', errors='ignore')
            
            out = ["(Primary search failed, used DuckDuckGo fallback)\n"]
            links = re.findall(r'<a class="result__url" href="([^"]+)">([^<]+)</a>', html)
            snippets = re.findall(r'<a class="result__snippet[^>]*>(.*?)</a>', html)
            
            if not links:
                return f"ERROR: Primary search failed ({primary_e}) and fallback found no results."
            
            for i in range(min(5, len(links))):
                url = links[i][0]
                if url.startswith('//'):
                    url = 'https:' + url
                title = links[i][1].strip()
                snip = re.sub(r'<[^>]+>', '', snippets[i]) if i < len(snippets) else ""
                out.append(f"Title: {title}\nURL: {url}\nSnippet: {snip.strip()}\n---")
            return "\n".join(out)
        except Exception as fallback_e:
            return f"ERROR: search_web failed (Primary: {primary_e}, Fallback: {fallback_e})"


# Agents use bash ONLY for read-only inspection (find/grep/cat/ls). All mutations go
# through the dedicated write_file/append_file/move_file tools, which are path-scoped.
# This used to be a deny-list, but deny-lists leak by nature (sort -o, split, awk system(),
# git push exfil, ... each needed its own patch). It is now DEFAULT-DENY: every command in
# the pipeline must start with a binary on this read-only allowlist; anything else — rm,
# curl, python, xargs, loops, subshell tricks — is refused without needing to be named.
_ALLOWED_BASH = {
    "find", "grep", "egrep", "fgrep", "rg", "cat", "ls", "wc", "head", "tail",
    "sort", "uniq", "diff", "comm", "stat", "date", "file", "du", "df", "tr",
    "cut", "echo", "printf", "basename", "dirname", "pwd", "realpath", "readlink",
    "sed", "strings", "md5sum", "sha256sum", "column", "nl", "paste", "test",
    "true", "false", "git",
}
# git is allowed only for read-only subcommands; mutations go through the git_commit tool
# and `git push/fetch/remote` would be a network-egress channel on an offline-by-design vault.
_ALLOWED_GIT_SUB = {"status", "log", "diff", "show", "ls-files", "blame", "shortlog",
                    "rev-parse", "branch", "tag", "describe", "count-objects", "grep"}


def _bash_segments(cmd):
    """Split a shell command into pipeline/sequence segments, quote-aware.

    Splits on unquoted ; | & newline ( ) ` and $( — i.e. every point where a new
    command can start — while leaving single/double-quoted text intact so a grep
    pattern like "inbox|transcribed" doesn't produce false segments. Command
    substitution inside double quotes DOES split (it executes). Imperfect edge
    cases fail toward refusal, never toward allowing."""
    segs, cur = [], []
    in_s = in_d = False
    i, n = 0, len(cmd)
    while i < n:
        c = cmd[i]
        if in_s:
            cur.append(c)
            if c == "'":
                in_s = False
        elif in_d:
            if c == '"':
                in_d = False
                cur.append(c)
            elif c == "`" or (c == "$" and i + 1 < n and cmd[i + 1] == "("):
                segs.append("".join(cur)); cur = []
                if c == "$":
                    i += 1
            elif c == ")":
                segs.append("".join(cur)); cur = []
            else:
                cur.append(c)
        else:
            if c == "'":
                in_s = True
                cur.append(c)
            elif c == '"':
                in_d = True
                cur.append(c)
            elif c in ";|&\n()`":
                segs.append("".join(cur)); cur = []
            elif c == "$" and i + 1 < n and cmd[i + 1] == "(":
                segs.append("".join(cur)); cur = []
                i += 1
            else:
                cur.append(c)
        i += 1
    segs.append("".join(cur))
    return [s.strip() for s in segs if s.strip()]


def _bash_blocked_reason(cmd):
    """Return a refusal reason unless every command in cmd is read-only-allowlisted."""
    # fd-duplication redirects (2>&1) contain '&', which the segmenter treats as a
    # command separator, leaving a bogus "1" segment — strip them before segmenting.
    # (The write-redirect check below runs on the ORIGINAL cmd, so nothing is hidden.)
    for seg in _bash_segments(re.sub(r"\d?>&\d", " ", cmd)):
        toks = seg.split()
        # skip leading VAR=value assignments and `!` negation
        while toks and (toks[0] == "!" or re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", toks[0])):
            toks.pop(0)
        if not toks:
            continue
        head = toks[0].strip("'\"")
        if not head:
            continue  # dangling-quote remnant after a $() split — string data, not a command
        if "/" in head or "\\" in head:
            return (f"path-invoked commands ({head!r}) are not permitted; "
                    "bash is for read-only inspection with allowlisted commands only.")
        if head not in _ALLOWED_BASH:
            return (f"'{head}' is not on the read-only bash allowlist. bash is for inspection "
                    f"only ({', '.join(sorted(_ALLOWED_BASH))}). "
                    "Use write_file / append_file / move_file / git_commit for changes.")
        if head == "git":
            rest = [t for t in toks[1:] if t not in ("-P", "--no-pager")]
            if rest and rest[0] == "-C" and len(rest) >= 3:
                rest = rest[2:]
            sub = rest[0] if rest else ""
            if sub not in _ALLOWED_GIT_SUB:
                return (f"git {sub!r} is not permitted; only read-only git "
                        f"({', '.join(sorted(_ALLOWED_GIT_SUB))}). Mutations go through the "
                        "git_commit tool; push/fetch would be network egress.")
    # Flags that make otherwise-allowlisted commands write or execute:
    if re.search(r'(?:^|[\s;&|`($])sed\b[^;&|]*\s(-i|-f|--file)\b', cmd):
        return "'sed -i/-f' is not permitted (in-place edit / script file). Use write_file / append_file."
    if re.search(r'(?:^|[\s;&|`($])sort\b[^;&|]*\s(-o|--output)\b', cmd):
        return "'sort -o' writes a file and is not permitted. Use write_file / append_file."
    if re.search(r'\s-(delete|exec|execdir|ok|okdir|fprint0?|fprintf|fls)\b', cmd):
        return "find's write/exec primaries (-delete/-exec/-fprint/...) are not permitted."
    # Allow only stderr/stdout redirects to /dev/null (and 2>&1); any other '>' writes a file.
    stripped = re.sub(r'\d?>>?\s*/dev/null', '', cmd)
    stripped = re.sub(r'2>&1', '', stripped)
    if re.search(r'>\s*\S', stripped):
        return "shell output redirection to a file is not permitted. Use write_file / append_file."
    return None

def tool_bash(args):
    """Run a READ-ONLY shell command with cwd=VAULT_DIR (find/grep/cat/ls).
    Destructive verbs are refused — mutations must use the file tools."""
    cmd = args.get("command") or args.get("cmd")
    if not cmd:
        return "ERROR: missing 'command'"
    blocked = _bash_blocked_reason(cmd)
    if blocked:
        log_activity({
            "ts": datetime.now().isoformat(timespec="seconds"),
            "pid": os.getpid(), "agent": os.environ.get("AGENT_NAME", ""),
            "tool": "bash", "blocked": True, "command": cmd[:300], "reason": blocked,
        })
        return f"ERROR: blocked — {blocked}"
    try:
        r = subprocess.run(["bash", "-c", cmd], cwd=VAULT_DIR,
                           capture_output=True, text=True, timeout=90)
    except subprocess.TimeoutExpired:
        return "ERROR: command timed out (90s)"
    except Exception as e:
        return f"ERROR: bash failed: {e}"
    out = r.stdout or ""
    if r.stderr.strip():
        out += "\n[stderr]\n" + r.stderr
    out = out.strip()
    return out if out else f"(exit {r.returncode}, no output)"


TOOLS = {
    "bash":       (tool_bash,       "bash(command) — run a READ-ONLY shell command (find/grep/cat/sed/ls/wc/head/tail) with cwd=vault root; writes/network/interpreters are refused"),
    "read_file":  (tool_read_file,  "read_file(path) — read a vault file"),
    "write_file": (tool_write_file, "write_file(path, content) — create/overwrite a file"),
    "append_file": (tool_append_file, "append_file(path, content) — append to a file"),
    "list_dir":   (tool_list_dir,   "list_dir(path) — list a directory (default '.')"),
    "grep":       (tool_grep,       "grep(query, path, max_results) — search file contents"),
    "move_file":  (tool_move_file,  "move_file(src, dst) — move/rename a file"),
    "git_commit": (tool_git_commit, "git_commit(message, paths?) — stage & commit (paths optional, defaults to all)"),
}

# Per-agent tool scopes — the harness-ENFORCED counterpart to each agent's own prompt-level tool
# claims (e.g. run-extractor.sh's prompt says "TOOLS: bash, read_file, write_file, append_file,
# list_dir, grep"; run-reviewer.sh's says "Do not use other tools."). Before this table existed,
# those were advisory only: every CLI-invoked agent (i.e. every agent except the Advisor, which
# imports this module directly and passes allowed_tools=READONLY) saw the FULL tool set regardless
# of what its own prompt claimed — including git_commit and move_file. That matters most for the
# Extractor, which processes untrusted voice-memo transcripts: the same prompt-injection threat
# model that motivated gating fetch_url/search_web behind OLLAMA_AGENT_WEB applies here too.
#
# Derived directly from what each run-*.sh script's prompt asks the model to do and what the
# SHELL already does deterministically on the model's behalf (most agents just return prose via
# `final`; the shell writes files and commits). Keyed by AGENT_NAME (invoke-agent.sh's first arg,
# already exported for activity logging). An agent name not listed here — i.e. anything invoked
# outside the documented run-*.sh scripts — gets the full tool set, same as before this table.
AGENT_TOOL_SCOPES = {
    # Creates/updates Canon+Thinking notes; checks Canon/ via bash find/grep. Never commits —
    # the shell commits after each chunk ("Never run git commit" is in its own prompt).
    "extractor": {"bash", "read_file", "write_file", "append_file", "list_dir", "grep"},
    # Reads the target action, appends a Sub-steps/Effort block. Shell sets enrichment_status
    # and commits — the prompt explicitly says "Do NOT run git commit."
    "task-enricher": {"read_file", "append_file"},
    # Vault context is bash-grepped and embedded by the shell; the model only synthesizes text
    # via final, plus the two web tools (opt-in; harmless to list if OLLAMA_AGENT_WEB unset —
    # they simply won't be in TOOLS, so calling them still errors "unknown tool").
    "researcher": {"fetch_url", "search_web"},
    # Text-only judgment/synthesis agents: the shell embeds all needed context in the prompt and
    # each is explicitly instructed to reply via final only ("Do not use other tools" / "Reply by
    # calling final with ONLY..."). No file or bash access needed — the shell does all writes.
    "reviewer": set(),
    "retrospective": set(),
    "thinker": set(),
    "mirror": set(),
    "groomer": set(),
    "dedup": set(),
    "corrector": set(),
    "operator": set(),
}

# Web tools are OPT-IN per run (OLLAMA_AGENT_WEB=1, set by run-researcher.sh only). Registered
# unconditionally, they were an exfiltration channel: any agent processing a prompt-injected
# transcript (the Extractor reads untrusted voice-memo text) could smuggle vault content out in
# a fetch_url query string. Gated, only the Researcher — which runs on a human-chosen topic,
# not on untrusted input — ever sees them. The Advisor's read-only set never included them.
if os.environ.get("OLLAMA_AGENT_WEB") == "1":
    TOOLS["fetch_url"] = (tool_fetch_url, "fetch_url(url) — fetch text content from a web page (for external research)")
    TOOLS["search_web"] = (tool_search_web, "search_web(query) — search the web using SearxNG. Returns snippets and URLs. Use fetch_url on URLs to read full pages.")


def build_system_prompt(extra_system="", allowed_tools=None):
    # NOTE: `allowed_tools is None` (not `not allowed_tools`) — an empty SET is a deliberate
    # "no tools, final only" restriction (several agents use this) and is falsy in Python, so
    # `not allowed_tools` would wrongly treat it the same as "no restriction" and leak the full
    # tool list into the prompt.
    items = TOOLS.items() if allowed_tools is None else [(k, v) for k, v in TOOLS.items() if k in allowed_tools]
    tool_docs = "\n".join(f"- {doc}" for _, doc in items)
    proto = f"""You are a local vault agent. You accomplish tasks by calling tools, one at a time.

AVAILABLE TOOLS:
{tool_docs}
- final(answer) — call this when the task is complete; 'answer' is your summary.

PROTOCOL (follow exactly):
- Each turn, reply with ONE JSON object and NOTHING else. No prose, no markdown fences.
  Format: {{"tool": "<tool_name>", "args": {{ ... }}}}
- All file paths are RELATIVE to the vault root. Do not use absolute paths or '..'.
- After each tool call you will receive the result as the next message. Then continue.
- When the task is fully done, reply: {{"tool": "final", "args": {{"answer": "<what you did>"}}}}
- Do exactly what the task asks. Verify by reading back when it matters. Keep going until done.
/no_think"""
    if extra_system:
        proto = extra_system.strip() + "\n\n" + proto
    return proto


# ---------------- JSON extraction ----------------
def extract_json_object(text):
    """Pull the first balanced {...} JSON object from model content (tolerates fences/prose)."""
    if not text:
        return None
    t = text.strip()
    t = re.sub(r"^```(?:json)?\s*", "", t)
    t = re.sub(r"\s*```$", "", t)
    start = t.find("{")
    if start == -1:
        return None
    depth = 0
    in_str = False
    esc = False
    for i in range(start, len(t)):
        c = t[i]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
        else:
            if c == '"':
                in_str = True
            elif c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    return t[start:i + 1]
    return None


# ---------------- Ollama call ----------------
def _is_openai_host(host):
    # Convention: every OpenAI-compatible endpoint (llama.cpp, LM Studio) is documented
    # with a trailing /v1; every native-Ollama endpoint is documented as bare host:port.
    # A plain Ollama OLLAMA_HOST never ends in /v1, so this is purely additive — no
    # existing caller's behavior changes.
    return host.rstrip("/").endswith("/v1")


def _build_payload(model, messages, options, openai):
    if openai:
        # llama.cpp / LM Studio's OpenAI-compatible surface: no "options" wrapper,
        # temperature is a top-level field, no num_ctx equivalent (context is fixed
        # server-side for these endpoints).
        return json.dumps({
            "model": model,
            "messages": messages,
            "temperature": options.get("temperature", 0),
            "stream": False,
        }).encode("utf-8")
    return json.dumps({
        "model": model,
        "messages": messages,
        "stream": False,
        "options": options,
    }).encode("utf-8")


def _extract_content(data, openai):
    if "error" in data:
        raise RuntimeError(f"API error: {data['error']}")
    if openai:
        choices = data.get("choices") or []
        if not choices:
            raise RuntimeError(f"no choices in response: {data}")
        return choices[0].get("message", {}).get("content", "")
    return data.get("message", {}).get("content", "")


def ollama_chat(model, messages, host=OLLAMA_HOST, timeout=600):
    # Only pin num_ctx when explicitly requested (OLLAMA_NUM_CTX). Left unset, Ollama uses
    # the model's own default — so this never *shrinks* a well-configured context window; it
    # only lets callers that feed large single prompts (e.g. the transcript corrector) raise
    # the window enough that the input isn't silently truncated.
    options = {"temperature": 0}
    _num_ctx = os.environ.get("OLLAMA_NUM_CTX")
    if _num_ctx:
        try:
            options["num_ctx"] = int(_num_ctx)
        except ValueError:
            pass

    # Resilience: retry each host on transient failures, then fall back to any hosts in
    # OLLAMA_FALLBACK (comma-separated). We retry the SAME single request — never the whole
    # agent loop — so a transient blip mid-run can't cause duplicate append_file mutations.
    hosts = [host] + [h.strip() for h in os.environ.get("OLLAMA_FALLBACK", "").split(",") if h.strip()]
    retries = int(os.environ.get("OLLAMA_RETRIES", "3"))
    delay = float(os.environ.get("OLLAMA_RETRY_DELAY", "2"))
    last_err = None
    for h in hosts:
        openai = _is_openai_host(h)
        payload = _build_payload(model, messages, options, openai)
        endpoint = f"{h.rstrip('/')}/chat/completions" if openai else f"{h}/api/chat"
        for attempt in range(1, retries + 1):
            try:
                req = urllib.request.Request(endpoint, data=payload,
                                             headers={"Content-Type": "application/json"})
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    data = json.loads(resp.read())
                return _extract_content(data, openai)
            except Exception as e:
                last_err = e
                if attempt < retries:
                    log(f"ollama_chat {h} attempt {attempt}/{retries} failed ({e}); retrying in {delay}s")
                    time.sleep(delay * attempt)  # linear backoff
                else:
                    log(f"ollama_chat {h} exhausted {retries} attempts ({e})"
                        + (" — trying fallback" if h != hosts[-1] else ""))
    raise RuntimeError(f"Ollama unreachable after retries/fallbacks: {last_err}")


# ---------------- Agent loop ----------------
def run_agent(prompt, model=DEFAULT_MODEL, extra_system="", max_iters=12, host=OLLAMA_HOST,
              verbose=False, allowed_tools=None):
    messages = [
        {"role": "system", "content": build_system_prompt(extra_system, allowed_tools)},
        {"role": "user", "content": prompt},
    ]
    mutated = False        # has any file-writing tool succeeded?
    final_nudged = False   # only push back on a premature final once
    last_text = ""         # last off-protocol prose (fallback answer for generation tasks)
    consecutive_errors = 0
    require_write = bool(os.environ.get("OLLAMA_AGENT_REQUIRE_WRITE"))
    for it in range(1, max_iters + 1):
        content = ollama_chat(model, messages, host=host)
        if verbose:
            log(f"iter {it} raw: {content[:300]!r}")
        raw = extract_json_object(content)
        if raw is None:
            # Model went off-protocol (replied with prose). Keep it as a fallback answer
            # for "just generate text" tasks, and nudge toward the JSON protocol.
            consecutive_errors += 1
            if consecutive_errors >= 5:
                log(f"iter {it}: aborting after 5 consecutive non-JSON responses")
                break
            log(f"iter {it}: no JSON found, nudging")
            if content.strip():
                last_text = content.strip()
            messages.append({"role": "assistant", "content": content})
            messages.append({"role": "user", "content": "Reply with ONE JSON tool call object only, no prose."})
            continue
        try:
            call = json.loads(raw)
        except json.JSONDecodeError as e:
            consecutive_errors += 1
            if consecutive_errors >= 5:
                log(f"iter {it}: aborting after 5 consecutive JSON decode errors")
                break
            messages.append({"role": "assistant", "content": content})
            messages.append({"role": "user", "content": f"Invalid JSON ({e}). Reply with one valid JSON tool call."})
            continue

        consecutive_errors = 0  # reset on success

        tool = call.get("tool")
        cargs = call.get("args", {}) or {}
        # Normalize common arg-name aliases (models often use file_path/filename/cmd/text).
        if isinstance(cargs, dict):
            _aliases = {"file_path": "path", "filepath": "path", "filename": "path",
                        "file": "path", "dest": "dst", "destination": "dst",
                        "source": "src", "text": "content", "cmd": "command",
                        "pattern": "query", "search": "query"}
            for _a, _canon in _aliases.items():
                if _a in cargs and _canon not in cargs:
                    cargs[_canon] = cargs.pop(_a)

        if tool == "final":
            if require_write and not mutated and not final_nudged:
                final_nudged = True
                log(f"iter {it}: premature final (no writes yet) — nudging")
                messages.append({"role": "assistant", "content": raw})
                messages.append({"role": "user", "content":
                    "STOP — you called final but have NOT created any files with write_file yet. "
                    "That is a FAILURE. Do NOT summarize the rules — APPLY them: create the required "
                    "files now using write_file, then call final. Continue with the next JSON tool call."})
                continue
            answer = cargs.get("answer", "")
            log(f"iter {it}: FINAL")
            return answer

        # `is not None` (not truthiness) for the same empty-set reason as build_system_prompt.
        if allowed_tools is not None and tool not in allowed_tools:
            result = f"ERROR: tool '{tool}' not permitted here. Allowed: {', '.join(list(allowed_tools) + ['final'])}"
        elif tool not in TOOLS:
            result = f"ERROR: unknown tool '{tool}'. Valid: {', '.join(list(TOOLS) + ['final'])}"
        else:
            try:
                result = TOOLS[tool][0](cargs)
            except Exception as e:
                result = f"ERROR: {tool} failed: {e}"
        result = str(result)
        if tool in ("write_file", "append_file", "move_file") and not result.startswith("ERROR"):
            mutated = True
        if len(result) > MAX_RESULT_CHARS:
            result = result[:MAX_RESULT_CHARS] + "\n...[truncated]"
        log(f"iter {it}: {tool}({json.dumps(cargs)[:120]}) -> {result[:120]!r}")
        log_activity({
            "ts": datetime.now().isoformat(timespec="seconds"),
            "pid": os.getpid(),
            "agent": os.environ.get("AGENT_NAME", ""),
            "model": model,
            "iter": it,
            "tool": tool,
            "args": json.dumps(cargs, ensure_ascii=False)[:300],
            "result": result[:200],
            "ok": not result.startswith("ERROR"),
        })

        messages.append({"role": "assistant", "content": raw})
        messages.append({"role": "user",
                         "content": f"TOOL_RESULT ({tool}):\n{result}\n\nContinue with the next JSON tool call, or call final when done."})

    if consecutive_errors >= 5:
        log("stopped early: 5 consecutive off-protocol replies; returning last prose if any")
        return last_text or "(agent stopped: model went off-protocol repeatedly)"
    log(f"hit max_iters={max_iters} without final; returning last prose if any")
    return last_text or "(agent stopped: reached max iterations without calling final)"


def main():
    global VAULT_DIR
    ap = argparse.ArgumentParser(description="Local Ollama tool-using agent harness")
    ap.add_argument("--prompt")
    ap.add_argument("--prompt-file")
    ap.add_argument("--system", default="")
    ap.add_argument("--system-file")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--vault", default=VAULT_DIR)
    ap.add_argument("--host", default=OLLAMA_HOST)
    ap.add_argument("--max-iters", type=int,
                    default=int(os.environ.get("OLLAMA_AGENT_MAX_ITERS", "12")))
    ap.add_argument("--allowed-tools", default=None,
                    help="comma-separated tool names this run may use (empty string = none, "
                         "final only); overrides the AGENT_TOOL_SCOPES default for AGENT_NAME")
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    VAULT_DIR = os.path.abspath(args.vault)

    prompt = args.prompt
    if args.prompt_file:
        with open(args.prompt_file, "r", encoding="utf-8") as f:
            prompt = f.read()
    if not prompt:
        ap.error("one of --prompt or --prompt-file is required")

    extra_system = args.system
    if args.system_file:
        with open(args.system_file, "r", encoding="utf-8") as f:
            extra_system = f.read()

    # --allowed-tools explicitly passed (even as "") overrides the per-agent default; otherwise
    # look up AGENT_NAME (set by invoke-agent.sh) in AGENT_TOOL_SCOPES. Unknown/unset AGENT_NAME
    # -> None -> full tool set, same as before this table existed (manual/ad-hoc invocations).
    if args.allowed_tools is not None:
        allowed_tools = {t.strip() for t in args.allowed_tools.split(",") if t.strip()}
    else:
        allowed_tools = AGENT_TOOL_SCOPES.get(os.environ.get("AGENT_NAME", ""))

    answer = run_agent(prompt, model=args.model, extra_system=extra_system,
                       max_iters=args.max_iters, host=args.host, verbose=args.verbose,
                       allowed_tools=allowed_tools)
    print(answer)


if __name__ == "__main__":
    main()
