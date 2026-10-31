#!/bin/bash
# test-scheduler-log-resilience.sh — behavioral test for _ResilientRotatingFileHandler in
# scheduler.py. scheduler.py holds one log FD open 24/7; if the NFS-backed vault mount
# invalidates the underlying inode (observed 2026-07-22: scheduler.log froze for ~22h, every
# emit() throwing OSError 116 ESTALE with no recovery — see handoff.md), the plain
# RotatingFileHandler never reopens and silently drops every subsequent record forever.
# Asserts: a simulated ESTALE on the open stream is caught, the stream is reopened, and the
# record that triggered it still gets written (not lost). Loads scheduler.py by path (mirrors
# test-discord-bot.sh / test-ollama-agent-atomic.sh) — no watchdog polling loop is started.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
SCHED_PY="$SCRIPT_DIR/scheduler.py"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
mkdir -p "$TV/Meta"

VAULT_DIR="$TV" python3 - "$SCHED_PY" <<'PY'
import importlib.util, sys, os, logging, errno

spec = importlib.util.spec_from_file_location("sched", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)   # runs scheduler.py's module-level logging.basicConfig too

fail = 0
def check(desc, ok):
    global fail
    print(("  ok: " if ok else "  FAIL: ") + desc)
    if not ok:
        fail = 1

handler = next(h for h in logging.getLogger().handlers
               if isinstance(h, m._ResilientRotatingFileHandler))
log_path = handler.baseFilename

# Sanity: a normal record round-trips before we break anything
logging.info("before-stale")
handler.flush()
check("normal record reaches the log file", "before-stale" in open(log_path, encoding="utf-8").read())

# Simulate the exact failure: shouldRollover()'s stream.seek() raising ESTALE, as it did live
class _StaleStream:
    def seek(self, *a):
        raise OSError(errno.ESTALE, "Stale file handle")
    def write(self, *a):
        raise OSError(errno.ESTALE, "Stale file handle")
    def close(self):
        pass

real_stream = handler.stream
handler.stream = _StaleStream()

logging.info("during-stale")
handler.flush()

check("handler reopened its stream instead of staying stale",
      handler.stream is not None and not isinstance(handler.stream, _StaleStream))
check("the record that hit ESTALE was not lost — it reached the reopened file",
      "during-stale" in open(log_path, encoding="utf-8").read())

# Confirm recovery isn't a one-shot fluke: subsequent records keep flowing normally
logging.info("after-stale")
handler.flush()
check("logging continues normally after recovery",
      "after-stale" in open(log_path, encoding="utf-8").read())

# A non-ESTALE OSError must fall through to the normal handleError() path (print + continue,
# stdlib logging's standard non-crashing behavior) — NOT be treated as ESTALE-recoverable, and
# NOT crash the caller either.
class _OtherFailStream:
    def seek(self, *a):
        raise OSError(errno.EACCES, "Permission denied")
    def close(self):
        pass

handler.stream = _OtherFailStream()
still_the_broken_stream = True
raised = False
try:
    handler.emit(logging.LogRecord("x", logging.INFO, __file__, 0, "unrelated-error", None, None))
    still_the_broken_stream = isinstance(handler.stream, _OtherFailStream)
except Exception:
    raised = True
check("a non-ESTALE OSError doesn't crash the caller", not raised)
check("a non-ESTALE OSError is NOT treated as ESTALE-recoverable (stream left alone)",
      still_the_broken_stream)

try:
    handler.close()
except Exception:
    pass

sys.exit(fail)
PY
rc=$?
[ "$rc" -eq 0 ] && echo "test-scheduler-log-resilience: PASS" || { echo "test-scheduler-log-resilience: FAIL"; exit 1; }
