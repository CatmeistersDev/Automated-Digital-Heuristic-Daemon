# Dockerfile for AutoADHD on any Docker host (Linux/Windows/macOS) — WhisperX (CPU) + diarization + Discord.
#
# History: an earlier revision of this file never built — it passed per-package
# `--hash=` on the pip *command line* (only valid inside a requirements file),
# pinned torch 2.11 against whisperX's `torch~=2.8` requirement, and COPYed the
# wrong (non-nested) whisperX path. This revision is verified end-to-end on CPU.
#
# NOTE: the AUTHORITATIVE live image is built/tagged as `autoadhd-brain:whisperx` (see SYSTEM.md
# "How to develop/deploy"). No cloud SDKs: the stack is Ollama + ntfy + Discord + Open WebUI only
# (the old python-telegram-bot / anthropic deps were dead upstream carryover and removed).
#
# REBUILT + validated end-to-end 2026-07-02 (retired the earlier `docker commit` that had only
# hot-patched discord.py into a running container — a `compose up` recreate kept wiping it).
# Versions are PINNED via constraints.txt (the known-good resolved set from the verified
# 2026-07-02 build: torch 2.8.0+cpu, whisperx 3.8.6, pyannote-audio 4.0.7, transformers
# 4.57.6, ctranslate2 4.8.0, faster-whisper 1.2.1, numpy 2.4.6, discord.py 2.7.1). Every
# pip install below gets `-c` so a rebuild can't silently drift onto a broken set. (Don't
# add pyannote to the early pip line — it drags in a CUDA torch before the CPU torch below.)
FROM python:3.11-slim

# System deps: ffmpeg (audio decode), git (whisperx build), jq/perl/curl (scripts),
# shellcheck (so the weekly in-container run-ci-check.sh job can lint, not just skip it)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git ffmpeg curl perl jq shellcheck \
    && rm -rf /var/lib/apt/lists/*

COPY constraints.txt /tmp/constraints.txt

# Scheduler/agent service deps (pymupdf: PDF->text for the Clippings lane)
RUN pip install --no-cache-dir -c /tmp/constraints.txt \
    httpx \
    watchdog \
    schedule \
    numpy \
    discord.py \
    pymupdf

# CPU-only PyTorch, matching whisperX's `torch~=2.8` pin. Installed FIRST so the
# whisperx install below sees torch already satisfied and does NOT drag in a CUDA
# build (whisperX's pyproject defaults to the cu128 index on linux/x86_64).
RUN pip install --no-cache-dir -c /tmp/constraints.txt \
    torch==2.8.0+cpu torchaudio==2.8.0+cpu torchvision==0.23.0+cpu \
    --index-url https://download.pytorch.org/whl/cpu

# WhisperX from vendored source. NOTE the nested path: whisperX-main/whisperX-main/
# is where pyproject.toml lives. Remaining deps (faster-whisper, ctranslate2,
# pyannote-audio, transformers, torchcodec, …) resolve from PyPI; CPU torch holds.
# pyannote.audio powers diarization + speaker-ID embeddings
# (pyannote/wespeaker-voxceleb-resnet34-LM), gated on .secrets/hf-token.txt.
COPY whisperX-main/whisperX-main/ /tmp/whisperx/
RUN pip install --no-cache-dir -c /tmp/constraints.txt /tmp/whisperx/ && rm -rf /tmp/whisperx/

# Code is BAKED into the image at /app (code/data split): /vault is a data-only
# mount, deploy = image rebuild + recreate, rollback = retag. Scripts self-locate
# (dirname "$0" / __file__), so they run from /app regardless of VAULT_DIR.
COPY Meta/scripts/ /app/Meta/scripts/
COPY Meta/Agents/ /app/Meta/Agents/
COPY Meta/agent-runtimes.conf /app/Meta/agent-runtimes.conf

# Agents commit to the data repo at /vault; without these a fresh container
# can't commit (dubious-ownership + missing identity — bit us on 2026-07-09).
RUN git config --global --add safe.directory /vault \
 && git config --global user.name "AutoADHD" \
 && git config --global user.email "autoadhd@local"

WORKDIR /vault
ENV VAULT_DIR=/vault
ENV PYTHONUNBUFFERED=1
ENV PATH="/app/Meta/scripts:${PATH}"

# Liveness: the Advisor answers `/` with an unauthenticated {"status":"ok"} (no vault data).
# The scheduler is PID 1 (its death exits the container -> compose `restart: unless-stopped`
# recovers it); this HEALTHCHECK catches the OTHER failure mode — container up but the
# Advisor child dead/wedged. The scheduler's supervisor thread restarts a dead child; if
# even that fails, `docker ps` shows unhealthy and the host-side deadman-check.sh alerts.
# start-period is generous: first boot loads models and can be slow.
HEALTHCHECK --interval=60s --timeout=10s --start-period=300s --retries=5 \
  CMD curl -sf http://localhost:8723/ || exit 1

# Default command is to run the scheduler
CMD ["python", "/app/Meta/scripts/scheduler.py"]
