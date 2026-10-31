import os
import time
import errno
import signal
import threading
import subprocess
import schedule
import logging
from logging.handlers import RotatingFileHandler
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# Serializes vault-MUTATING script runs. Both the voice watcher (watchdog thread) and the
# cron jobs (main thread) call run_script(); without this a late memo extraction could mutate
# Canon/git at the same instant as, say, the 21:30 reviewer. Read-only jobs (health/backup)
# opt out via mutating=False so they're never starved behind a long run.
_vault_lock = threading.Lock()

# Guards a single voice memo from being processed twice: the startup drain (main thread) and the
# watchdog observer thread can both see the same file. _inflight holds the basenames currently
# being processed so the second caller bails instead of launching a duplicate transcription.
_inflight = set()
_inflight_lock = threading.Lock()

# --- Config ---
VAULT_DIR = os.environ.get("VAULT_DIR", "/vault")
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
VOICE_DROP_DIR = os.path.join(VAULT_DIR, "Inbox", "Voice", "_drop")
TEXT_DROP_DIR = os.path.join(VAULT_DIR, "Inbox", "Text", "_drop")
TEXT_NOEXTRACT_DROP_DIR = os.path.join(VAULT_DIR, "Inbox", "Text", "_drop-noextract")

class _ResilientRotatingFileHandler(RotatingFileHandler):
    """RotatingFileHandler that recovers from NFS ESTALE instead of dropping every record
    forever. scheduler.py holds one FD open 24/7; if a network-backed vault mount replaces the
    underlying inode out from under it (observed in production: scheduler.log froze for ~22h,
    every emit() throwing OSError 116 on the seek() inside shouldRollover), the plain handler
    never reopens. Worse, RotatingFileHandler.emit() already wraps itself in a bare
    `except Exception: self.handleError(record)` — the error never even reaches an override of
    emit(), so the only place that can actually intercept and recover is shouldRollover() itself
    (and, for the same reason, the final write in FileHandler.emit). Reopening the stream on
    ESTALE and retrying fixes both without changing behavior for any other error, which still
    goes through the normal handleError() path exactly as before."""
    def shouldRollover(self, record):
        try:
            return super().shouldRollover(record)
        except OSError as e:
            if getattr(e, "errno", None) != errno.ESTALE:
                raise
            self._reopen_stream()
            return super().shouldRollover(record)

    def emit(self, record):
        try:
            if self.shouldRollover(record):
                self.doRollover()
            logging.FileHandler.emit(self, record)
        except OSError as e:
            if getattr(e, "errno", None) == errno.ESTALE:
                self._reopen_stream()
                try:
                    logging.FileHandler.emit(self, record)
                    return
                except Exception:
                    pass
            self.handleError(record)
        except Exception:
            self.handleError(record)

    def _reopen_stream(self):
        try:
            self.stream.close()
        except Exception:
            pass
        self.stream = self._open()


# RotatingFileHandler (not plain FileHandler): scheduler.log runs 24/7 and was unbounded —
# left alone it grows forever. 10MB x 5 backups keeps ~50MB of recent history on disk.
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        _ResilientRotatingFileHandler(os.path.join(VAULT_DIR, "Meta", "scheduler.log"),
                                       maxBytes=10 * 1024 * 1024, backupCount=5),
        logging.StreamHandler()
    ]
)

def _notify(title, body, prio="default", tags="", click=""):
    """Best-effort ntfy/Discord alert (notify.sh is a no-op if unconfigured); never raises."""
    try:
        subprocess.run(["/bin/bash", os.path.join(SCRIPTS_DIR, "notify.sh"), title, body, prio, tags, click],
                       cwd=VAULT_DIR, timeout=30,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass

# Long-lived child services (advisor-server.py, discord-bot.py). Nothing used to restart
# these if they crashed — the vault chat/bot silently died until the next container restart.
# _supervisor_loop() (dedicated daemon thread) restarts a dead child and also touches the
# heartbeat file that the HOST-side dead-man's switch (deadman-check.sh) watches. It runs in
# its own thread on purpose: the MAIN loop legitimately blocks for hours while a cron job
# runs, so a heartbeat written there would go stale mid-extraction and false-alarm.
_children = []  # [{"name", "argv", "proc", "restarts"}]
HEARTBEAT_FILE = os.path.join(VAULT_DIR, "Meta", ".scheduler-heartbeat")

def _start_child(name, argv):
    proc = subprocess.Popen(argv, cwd=VAULT_DIR)
    _children.append({"name": name, "argv": argv, "proc": proc, "restarts": 0})
    return proc

def _supervisor_loop():
    while True:
        try:
            with open(HEARTBEAT_FILE, "w") as f:
                f.write(time.strftime("%Y-%m-%d %H:%M:%S"))
        except Exception:
            pass
        for child in _children:
            if child["proc"].poll() is not None:
                child["restarts"] += 1
                code = child["proc"].returncode
                logging.error(f"Child {child['name']} exited (code {code}) — restarting "
                              f"(restart #{child['restarts']}).")
                # 60s loop cadence naturally rate-limits a crash-looping child; alert on the
                # first death and then every 10th so a crash loop can't flood the channel.
                if child["restarts"] == 1 or child["restarts"] % 10 == 0:
                    _notify(f"⚠️ {child['name']} died", f"exit code {code}; restarted (#{child['restarts']}).", "high", "warning")
                try:
                    child["proc"] = subprocess.Popen(child["argv"], cwd=VAULT_DIR)
                except Exception as e:
                    logging.error(f"Failed to restart {child['name']}: {e}")
        time.sleep(60)

def run_script(script_name, args=None, mutating=True, timeout=1800, extra_env=None):
    script_path = os.path.join(SCRIPTS_DIR, script_name)
    if not os.path.exists(script_path):
        logging.error(f"Script not found: {script_path}")
        return

    cmd = ["/bin/bash", script_path]
    if args:
        cmd.extend(args)

    logging.info(f"Running: {' '.join(cmd)}")
    # Hold the lock only for mutating jobs so a hung/long agent can't corrupt state via a
    # concurrent run — but health/backup (mutating=False) still run on time regardless.
    lock = _vault_lock if mutating else None
    if lock:
        lock.acquire()
    try:
        # timeout so one hung agent can't block the scheduler forever (which would starve
        # the hourly health watchdog and the 03:15 backup). start_new_session gives the
        # child its own process GROUP: subprocess.run's timeout-kill only hits the direct
        # bash child, and the real workers (whisperx, ollama_agent.py) survived as orphans
        # that kept mutating the vault AFTER the lock was released. killpg gets them all.
        child_env = None
        if extra_env:
            child_env = dict(os.environ)
            child_env.update(extra_env)
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, cwd=VAULT_DIR, start_new_session=True,
                                env=child_env)
        try:
            _out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            proc.communicate()  # reap
            logging.error(f"Script {script_name} TIMED OUT after {timeout}s — process group killed to free the scheduler.")
            _notify(f"⚠️ {script_name} timed out", f"Killed (whole process group) after {timeout}s so health/backup aren't starved.", "high", "warning")
            return
        if proc.returncode != 0:
            logging.error(f"Script {script_name} failed with exit code {proc.returncode}")
            logging.error(f"Stderr: {err}")
        else:
            logging.info(f"Script {script_name} completed successfully.")
    except Exception as e:
        logging.error(f"Error running {script_name}: {e}")
    finally:
        if lock:
            lock.release()

# --- Voice + Text Watchers ---
# Both drop dirs are watched by the SAME Observer/thread and dispatch through the SAME
# run_script() -> _vault_lock / subprocess-timeout+killpg machinery as everything else
# (see run_script above) — no second lock, no second poll loop.
AUDIO_EXTS = (".3gp", ".m4a", ".ogg", ".wav", ".amr", ".mp3", ".aac", ".opus")
TEXT_EXTS = (".md", ".txt", ".pdf")
# Text drops have no transcription step to naturally pace them, so on_created/on_moved
# can fire while Syncthing/an editor is still mid-write. Require the file's mtime to be
# quiet for this long before dispatching (bounded wait below so a file that never
# settles can't wedge the watcher thread forever).
TEXT_SETTLE_SECONDS = 10

class VoiceDropHandler(FileSystemEventHandler):
    def _maybe_process(self, path):
        base = os.path.basename(path)
        # Skip Syncthing temp/partial/hidden files
        if base.startswith(".") or base.endswith((".tmp", ".part", "~")) or ".syncthing." in base:
            return
        if not base.lower().endswith(AUDIO_EXTS):
            return
        # Claim this file so the drain and the observer thread can't both process it (see _inflight).
        with _inflight_lock:
            if base in _inflight:
                logging.info(f"Skipping {base} — already in flight")
                return
            _inflight.add(base)
        try:
            logging.info(f"New voice memo detected: {path}")
            time.sleep(2)  # let the file settle
            # Longer ceiling: a long meeting's transcription + chunked extraction is the single
            # longest legitimate job. If it still overruns, H1 leaves the note 'transcribed' for retry.
            run_script("process-voice-memo.sh", [path], timeout=7200)
        finally:
            with _inflight_lock:
                _inflight.discard(base)

    def on_created(self, event):
        if not event.is_directory:
            self._maybe_process(event.src_path)

    def on_moved(self, event):
        # Syncthing writes .syncthing.<name>.tmp then RENAMES to the final name,
        # which fires on_moved (not on_created) — must handle it or we miss memos.
        if not event.is_directory:
            self._maybe_process(event.dest_path)

class TextDropHandler(FileSystemEventHandler):
    def __init__(self, noextract=False):
        # noextract=True: wrap + file the note but skip the extraction chain
        # (TEXTNOTE_NO_EXTRACT=1) — the _drop-noextract/ folder for reference
        # material the vault owner wants to file themselves (question lists,
        # pasted articles).
        super().__init__()
        self.noextract = noextract

    def _maybe_process(self, path):
        base = os.path.basename(path)
        # Skip Syncthing temp/partial/hidden files (same patterns as the voice watcher)
        if base.startswith(".") or base.endswith((".tmp", ".part", "~")) or ".syncthing." in base:
            return
        if not base.lower().endswith(TEXT_EXTS):
            return
        # Namespaced key so a text drop and a voice memo that happen to share a
        # basename can never collide in the shared _inflight set (and the two text
        # drop dirs can't collide with each other either).
        key = f"text-noextract:{base}" if self.noextract else f"text:{base}"
        with _inflight_lock:
            if key in _inflight:
                logging.info(f"Skipping {base} — already in flight")
                return
            _inflight.add(key)
        try:
            logging.info(f"New text note detected: {path}")
            # Settle delay: wait until the file has been quiet for TEXT_SETTLE_SECONDS
            # (bounded to 60s total so a file that never stops changing can't wedge this
            # thread forever — process-text-note.sh has its own shorter stat-growing
            # loop too, as a standalone-invocation backstop).
            deadline = time.time() + 60
            while True:
                try:
                    mtime = os.path.getmtime(path)
                except FileNotFoundError:
                    return  # vanished (renamed/removed) before we got to it
                age = time.time() - mtime
                if age >= TEXT_SETTLE_SECONDS or time.time() >= deadline:
                    if age < TEXT_SETTLE_SECONDS:
                        logging.warning(f"Text note {base} never settled after 60s — processing anyway")
                    break
                time.sleep(min(TEXT_SETTLE_SECONDS - age, 2))
            extra = {"TEXTNOTE_NO_EXTRACT": "1"} if self.noextract else None
            run_script("process-text-note.sh", [path], timeout=3600, extra_env=extra)
        finally:
            with _inflight_lock:
                _inflight.discard(key)

    def on_created(self, event):
        if not event.is_directory:
            self._maybe_process(event.src_path)

    def on_moved(self, event):
        # Syncthing writes .syncthing.<name>.tmp then RENAMES to the final name,
        # which fires on_moved (not on_created) — must handle it or we miss drops.
        if not event.is_directory:
            self._maybe_process(event.dest_path)

def drain_drop_dir(event_handler, drop_dir):
    """Process files already sitting in a drop dir at startup.

    watchdog only emits events for changes that happen AFTER observer.start();
    files that landed while the scheduler was down — or were already present
    across a restart — never fire on_created/on_moved and would otherwise sit
    unprocessed forever. Scan once on boot so nothing is silently dropped.
    """
    try:
        existing = sorted(os.listdir(drop_dir))
    except FileNotFoundError:
        return
    for name in existing:
        path = os.path.join(drop_dir, name)
        if os.path.isfile(path):
            logging.info(f"Draining pre-existing drop: {path}")
            event_handler._maybe_process(path)

def start_voice_watcher():
    os.makedirs(VOICE_DROP_DIR, exist_ok=True)
    os.makedirs(TEXT_DROP_DIR, exist_ok=True)
    os.makedirs(TEXT_NOEXTRACT_DROP_DIR, exist_ok=True)
    voice_handler = VoiceDropHandler()
    text_handler = TextDropHandler()
    text_noextract_handler = TextDropHandler(noextract=True)
    observer = Observer()
    observer.schedule(voice_handler, VOICE_DROP_DIR, recursive=False)
    observer.schedule(text_handler, TEXT_DROP_DIR, recursive=False)
    observer.schedule(text_noextract_handler, TEXT_NOEXTRACT_DROP_DIR, recursive=False)
    observer.start()
    logging.info(f"Started watching {VOICE_DROP_DIR}, {TEXT_DROP_DIR} and {TEXT_NOEXTRACT_DROP_DIR}")
    # Catch up on anything already in either _drop (e.g. arrived while the scheduler was
    # down). Both process-*.sh scripts are idempotent: they move files to _processed/
    # (or _failed/) and skip anything already gone, so this can't double-run.
    drain_drop_dir(voice_handler, VOICE_DROP_DIR)
    drain_drop_dir(text_handler, TEXT_DROP_DIR)
    drain_drop_dir(text_noextract_handler, TEXT_NOEXTRACT_DROP_DIR)
    return observer

# --- Scheduled Jobs ---
def schedule_jobs():
    # All jobs below are LIVE (their local versions are built and run via the Ollama
    # harness / deterministic scripts). The nightly self-maintenance chain is:
    # retro 21:00 -> reviewer 21:30 -> implementer 21:45 (auto-fixes the Reviewer's
    # safe findings so they don't pile up unfixed).
    schedule.every().day.at("07:30").do(run_script, "daily-briefing.sh")       # lean deterministic digest
    schedule.every().day.at("08:30").do(run_script, "run-task-enricher.sh")    # enrich open un-enriched actions
    schedule.every().day.at("08:45").do(run_script, "run-researcher.sh", ["--scan"])  # research an action flagged needs-research (no-op if none)
    schedule.every().day.at("10:00").do(run_script, "auto-orchestrator.sh")    # proactive focus push to Discord for highest priority task
    schedule.every().day.at("21:00").do(run_script, "run-retro.sh")            # nightly retrospective
    schedule.every().sunday.at("10:00").do(run_script, "run-thinker.sh")       # weekly whole-vault patterns
    schedule.every().sunday.at("10:30").do(run_script, "run-mirror.sh")        # weekly coach reflection
    schedule.every().sunday.at("11:00").do(run_script, "run-groomer.sh")       # weekly vault grooming (small model)
    schedule.every().sunday.at("11:30").do(run_script, "run-dedup.sh")         # weekly duplicate-entity proposals -> review-queue
    schedule.every(2).hours.do(run_script, "run-extractor.sh", timeout=7200)   # catch-up: reprocess any memo stranded at status inbox|transcribed (no-op when none)
    schedule.every(1).hours.do(run_script, "run-health.sh", mutating=False, timeout=300)   # hourly watchdog: read-only, never starved
    schedule.every().day.at("21:30").do(run_script, "run-reviewer.sh")         # daily QA pass over recent extractions
    schedule.every().day.at("21:45").do(run_script, "run-implementer.sh")      # daily self-heal: auto-fix safe Reviewer findings, flag the rest
    schedule.every().day.at("03:15").do(run_script, "run-backup.sh", mutating=False, timeout=900)  # daily git-bundle backup (separate disk), read-only
    schedule.every().day.at("09:15").do(run_script, "run-decision-mining.sh", timeout=600)  # monthly (self-gates to the 1st): mine git log for decision candidates -> review-queue (propose-only)
    schedule.every().sunday.at("12:00").do(run_script, "run-ci-check.sh", mutating=False, timeout=600)  # weekly code/frontmatter sanity gate, read-only, self-alerts on failure
    logging.info("Schedules: briefing 07:30, enricher 08:30, researcher-scan 08:45, decision-mining 09:15 (1st of month), orchestrator 10:00, retro 21:00, reviewer 21:30, implementer 21:45, thinker+mirror Sun 10:00/10:30, groomer Sun 11:00, dedup Sun 11:30, ci-check Sun 12:00, extractor catch-up every 2h, health hourly, backup 03:15; voice + text watchers active.")

# --- Main ---
if __name__ == "__main__":
    logging.info("AutoADHD Scheduler starting...")

    advisor_path = os.path.join(SCRIPTS_DIR, "advisor-server.py")
    if os.path.exists(advisor_path):
        logging.info("Starting Advisor server (Open WebUI endpoint, port 8723)...")
        _start_child("advisor-server", ["python3", advisor_path])

    # Discord bot (Tier 2 gateway) — started ONLY if a token is configured, so this is a
    # no-op until .secrets/discord-token.txt (or env DISCORD_BOT_TOKEN) is added. Gating on
    # the token avoids a crash-loop from a bot that would immediately exit for lack of one.
    discord_path = os.path.join(SCRIPTS_DIR, "discord-bot.py")
    have_discord_token = bool(os.environ.get("DISCORD_BOT_TOKEN")) or os.path.exists(
        os.path.join(VAULT_DIR, ".secrets", "discord-token.txt"))
    if os.path.exists(discord_path) and have_discord_token:
        logging.info("Starting Discord bot (Tier 2 gateway)...")
        _start_child("discord-bot", ["python3", discord_path])
    else:
        logging.info("Discord bot not started (no token yet — add .secrets/discord-token.txt to enable).")

    # Heartbeat + child supervision (see _supervisor_loop). Daemon thread: dies with the process,
    # which is exactly what makes the heartbeat file go stale for the host-side dead-man's switch.
    threading.Thread(target=_supervisor_loop, daemon=True, name="supervisor").start()

    schedule_jobs()
    observer = start_voice_watcher()
    
    try:
        while True:
            schedule.run_pending()
            time.sleep(1)
    except KeyboardInterrupt:
        observer.stop()
    observer.join()
