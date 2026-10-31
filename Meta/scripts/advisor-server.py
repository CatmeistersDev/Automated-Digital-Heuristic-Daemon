#!/usr/bin/env python3
"""
advisor-server.py — OpenAI-compatible local endpoint for a vault-aware Advisor.

Lets Open WebUI (or any OpenAI client) chat with the AutoADHD vault, fully local.
Reuses ollama_agent.run_agent with READ-ONLY tools (read_file/grep/list_dir) so the
Advisor can look things up but can NEVER modify vault CONTENT from a chat. The one
exception is its own persistent-memory file (Meta/advisor-knowledge.md on the vault
data volume), appended to deterministically by this script, never by the model directly.

Endpoints:
  GET  /v1/models            -> lists the "autoadhd-advisor" model (for OWUI discovery)
  POST /v1/chat/completions  -> chat; supports stream:false (JSON) and stream:true (SSE)

Env: VAULT_DIR, OLLAMA_HOST, OLLAMA_AGENT_MODEL, VAULT_OWNER, ADVISOR_PORT (default 8723)
Stdlib only -> runs unchanged in the container.
"""
import os, re, sys, json, time, hmac, importlib.util
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VAULT_DIR = os.environ.get("VAULT_DIR", "/vault")
HOST = os.environ.get("ADVISOR_HOST", "0.0.0.0")
PORT = int(os.environ.get("ADVISOR_PORT", "8723"))
OWNER = os.environ.get("VAULT_OWNER", "Louise")
MODEL = os.environ.get("OLLAMA_AGENT_MODEL", "qwen3.6:35b-a3b")
MODEL_ID = "autoadhd-advisor"
READONLY = {"read_file", "grep", "list_dir"}
# Optional bearer-token auth. Unset -> open (backward compatible); set -> every chat/models
# request must send `Authorization: Bearer <token>`. Pair with ADVISOR_HOST=127.0.0.1 when
# Open WebUI is co-located. (Reading .secrets/ via the tools is already blocked in the harness.)
AUTH_TOKEN = os.environ.get("ADVISOR_TOKEN", "")

# Import the harness from the same directory
_here = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("ollama_agent", os.path.join(_here, "ollama_agent.py"))
oa = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(oa)
oa.VAULT_DIR = VAULT_DIR

ADVISOR_SYS_BASE = f"""You are {OWNER}'s personal AI assistant with read access to their private Obsidian "vault" — a knowledge base built automatically from their voice memos. Structure:
- Canon/People, Canon/Organizations, Canon/Places, Canon/Projects, Canon/Events, Canon/Decisions, Canon/Actions (tasks/intentions)
- Thinking/ (reflections, concepts, beliefs)

Use your READ-ONLY tools (grep, read_file, list_dir) to look things up in the vault BEFORE answering — do not guess or make up facts. For "my tasks/actions" check Canon/Actions; for a person check Canon/People; etc. Answer concisely and directly, reference notes by name, and speak to {OWNER} warmly and plainly. If the vault has nothing relevant, say so honestly."""

# Persistent Advisor memory (2026-07-27): lives on the VAULT_DIR data volume, not baked-code
# Meta/Agents/ — code ships baked into the image and gets wiped on every rebuild+recreate, so
# anything the Advisor learns has to be written to the data mount to survive a redeploy.
KNOWLEDGE_PATH = os.path.join(VAULT_DIR, "Meta", "advisor-knowledge.md")
KNOWLEDGE_SECTIONS = ("Patterns Noticed", "What Works", "What Doesn't Work", "Key Context")


def _knowledge_skeleton():
    return ("# Advisor Knowledge\n\nPersistent notes about " + OWNER + ", read every session.\n\n"
            "## Patterns Noticed\n\n## What Works\n\n## What Doesn't Work\n\n## Key Context\n")


def _load_knowledge():
    try:
        with open(KNOWLEDGE_PATH, encoding="utf-8") as f:
            return f.read().strip()
    except Exception:
        return ""


def _system_prompt():
    know = _load_knowledge()
    know_block = (f"\n\n[Persistent notes about {OWNER} from past sessions — use these; don't repeat "
                   f"mistakes logged under \"What Doesn't Work\"]\n{know}\n") if know else ""
    update_instructions = f"""

If — and only if — you learn something durable about {OWNER} this turn (a real pattern, a coaching
approach that landed or backfired, important recurring context — NOT a one-off fact already in the
vault), end your reply with exactly one extra line in this form:
UPDATE_KNOWLEDGE: <section> | <one-sentence learning>
<section> must be one of: {", ".join(KNOWLEDGE_SECTIONS)}. Omit this line entirely most turns — never
invent a learning just to have one."""
    return ADVISOR_SYS_BASE + know_block + update_instructions


_UPDATE_RE = re.compile(r'(?im)^UPDATE_KNOWLEDGE:\s*([^|]+?)\s*\|\s*(.+)$')


def _apply_knowledge_updates(answer):
    matches = _UPDATE_RE.findall(answer)
    if not matches:
        return answer
    cleaned = _UPDATE_RE.sub('', answer).rstrip()
    for section, learning in matches:
        section, learning = section.strip(), learning.strip()
        if section in KNOWLEDGE_SECTIONS and learning:
            _append_to_section(section, learning)
    return cleaned


def _append_to_section(section, learning):
    text = _load_knowledge() or _knowledge_skeleton()
    heading = f"## {section}"
    bullet = f"- {time.strftime('%Y-%m-%d')}: {learning}"
    lines = text.split("\n")
    if heading in (l.strip() for l in lines):
        out, inserted, i = [], False, 0
        while i < len(lines):
            out.append(lines[i])
            if not inserted and lines[i].strip() == heading:
                if i + 1 < len(lines) and lines[i + 1].strip().startswith("<!--"):
                    i += 1
                    out.append(lines[i])
                out.append(bullet)
                inserted = True
            i += 1
        text = "\n".join(out)
    else:
        text = text.rstrip() + f"\n\n{heading}\n\n{bullet}\n"
    try:
        os.makedirs(os.path.dirname(KNOWLEDGE_PATH), exist_ok=True)
        with open(KNOWLEDGE_PATH, "w", encoding="utf-8") as f:
            f.write(text)
    except Exception as e:
        print(f"[advisor] failed to write knowledge update: {e}", flush=True)


def _history(messages, max_turns=6, max_chars=600):
    """Short transcript of the recent PRIOR turns (everything but the final user msg) so follow-ups
    like "what about the other one?" have context. Within-conversation only — cross-session memory
    is handled separately via Meta/advisor-knowledge.md (see _system_prompt/_apply_knowledge_updates)."""
    turns = [m for m in messages if m.get("role") in ("user", "assistant")]
    lines = []
    for m in turns[:-1][-max_turns:]:
        c = m.get("content", "")
        if isinstance(c, list):
            c = " ".join(p.get("text", "") for p in c if isinstance(p, dict))
        c = (c or "").strip()
        if c:
            lines.append(f"{m.get('role', 'user').upper()}: {c[:max_chars]}")
    return "\n".join(lines)


def advise(messages):
    user_msg = _last_user(messages)
    convo = _history(messages)
    prompt = f"[Recent conversation]\n{convo}\n\n[Current question]\n{user_msg}" if convo else user_msg
    raw = oa.run_agent(
        prompt, model=MODEL, extra_system=_system_prompt(),
        max_iters=int(os.environ.get("ADVISOR_MAX_ITERS", "10")),
        allowed_tools=READONLY,
    )
    return _apply_knowledge_updates(raw)


def _last_user(messages):
    for m in reversed(messages):
        if m.get("role") == "user":
            c = m.get("content", "")
            if isinstance(c, str):
                return c
            if isinstance(c, list):
                return " ".join(p.get("text", "") for p in c if isinstance(p, dict))
    return ""


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def _authed(self):
        if not AUTH_TOKEN:
            return True
        # hmac.compare_digest, not ==: a naive string compare short-circuits on the first
        # mismatched byte, which leaks timing info an attacker could use to brute-force the
        # token one byte at a time over the network.
        return hmac.compare_digest(self.headers.get("Authorization", ""), f"Bearer {AUTH_TOKEN}")

    def do_GET(self):
        if "/v1/models" in self.path:
            if not self._authed():
                self._json(401, {"error": "unauthorized"}); return
            self._json(200, {"object": "list", "data": [
                {"id": MODEL_ID, "object": "model", "created": int(time.time()), "owned_by": "autoadhd"}]})
        else:
            self._json(200, {"status": "ok", "service": "autoadhd-advisor"})

    def do_POST(self):
        ln = int(self.headers.get("Content-Length", "0") or 0)
        try:
            data = json.loads(self.rfile.read(ln) or b"{}") if ln else {}
        except Exception:
            data = {}
        if "chat/completions" not in self.path:
            self._json(404, {"error": "not found"})
            return
        if not self._authed():
            self._json(401, {"error": "unauthorized"})
            return

        messages = data.get("messages", [])
        user_msg = _last_user(messages)
        try:
            answer = advise(messages) if user_msg else "Ask me anything about your vault."
        except Exception as e:
            print(f"[advisor] error handling request: {e}", flush=True)  # detail to logs only
            answer = "(advisor error — see server logs.)"

        cid = "chatcmpl-" + str(int(time.time()))
        if data.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            chunk = {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()),
                     "model": MODEL_ID,
                     "choices": [{"index": 0, "delta": {"role": "assistant", "content": answer},
                                  "finish_reason": None}]}
            done = {"id": cid, "object": "chat.completion.chunk", "created": int(time.time()),
                    "model": MODEL_ID,
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            self._json(200, {
                "id": cid, "object": "chat.completion", "created": int(time.time()),
                "model": data.get("model", MODEL_ID),
                "choices": [{"index": 0, "message": {"role": "assistant", "content": answer},
                             "finish_reason": "stop"}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
            })


if __name__ == "__main__":
    print(f"AutoADHD Advisor on {HOST}:{PORT} (vault={VAULT_DIR}, model={MODEL})", flush=True)
    if not AUTH_TOKEN and HOST not in ("127.0.0.1", "localhost"):
        # FAIL CLOSED, not just a warning (2026-07-12): this used to only print a SECURITY
        # notice and then bind anyway — the shipped docker-compose.yml has no ADVISOR_TOKEN
        # and no ADVISOR_HOST override, so a fresh deploy from this repo, exactly as shipped,
        # got an unauthenticated read endpoint into the vault on the LAN. Refuse to bind at
        # all rather than serve unauthenticated on a non-loopback host; scheduler.py's
        # supervisor will alert (not silently retry forever — every restart re-notifies per
        # its crash-loop cadence) until this is fixed. Loopback-only deployments (Open WebUI
        # co-located, ADVISOR_HOST=127.0.0.1) are unaffected — no token required there.
        print(f"FATAL: refusing to start — bound to {HOST} with no ADVISOR_TOKEN set. Any host "
              "on the network could read the vault via chat. Set ADVISOR_TOKEN (any random "
              "string; also set it as Open WebUI's connection API key), or set "
              "ADVISOR_HOST=127.0.0.1 if Open WebUI runs co-located on the same host/network "
              "namespace.", flush=True)
        sys.exit(1)
    ThreadingHTTPServer((HOST, PORT), H).serve_forever()
