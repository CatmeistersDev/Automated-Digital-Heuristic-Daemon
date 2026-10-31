#!/usr/bin/env python3
"""Speaker enrollment + identification for AutoADHD voice memos.

Embeddings: pyannote/wespeaker-voxceleb-resnet34-LM (256-dim), loaded with the HF
token in .secrets/hf-token.txt. Audio is decoded with ffmpeg to in-memory PCM, so
no torchaudio file backend (soundfile/sox) is required inside the slim container.

Voiceprints live in Meta/voiceprints/<slug>.json:
  {name, slug, model, dim, embedding:[...], n_seconds, samples:[...], created, updated}

Subcommands
-----------
enroll --name NAME --out DIR [--json WHISPERX_JSON --speaker SPK] AUDIO [AUDIO ...]
    Build (or update by averaging) a voiceprint from one or more samples. With
    --json + --speaker, only that diarized speaker's segments of a single AUDIO are
    used (e.g. pull one person out of a meeting). Otherwise the whole file is used.

match --json WHISPERX_JSON --audio AUDIO --voiceprints DIR [--owner NAME]
      [--threshold 0.50] [--margin 0.10] [--max-seconds 30] [--single-owner]
    Embed each diarized SPEAKER_xx cluster and compare to every enrolled voiceprint.
    Emits TSV "SPEAKER_xx<TAB>NAME<TAB>score" on stdout, one line per CONFIDENT match
    (>= threshold and winning by >= margin). Unmatched clusters are omitted so the
    caller keeps the original SPEAKER_xx label. With --single-owner, a lone cluster
    that matches nobody is mapped to --owner (solo-memo shortcut).
"""
import argparse, json, subprocess, sys, os, datetime, re
import numpy as np

SR = 16000
EMB_MODEL = "pyannote/wespeaker-voxceleb-resnet34-LM"
TOKEN_FILE = os.environ.get("HF_TOKEN_FILE", os.path.join(os.environ.get("VAULT_DIR", "/vault"), ".secrets", "hf-token.txt"))

_inf = None


def log(*a):
    print(*a, file=sys.stderr)


def get_inf():
    global _inf
    if _inf is None:
        import warnings
        warnings.filterwarnings("ignore")
        tok = os.environ.get("HF_TOKEN") or open(TOKEN_FILE).read().strip()
        from pyannote.audio import Model, Inference
        model = Model.from_pretrained(EMB_MODEL, use_auth_token=tok)
        _inf = Inference(model, window="whole")
    return _inf


def load_wave(path):
    raw = subprocess.run(
        ["ffmpeg", "-v", "quiet", "-i", path, "-ar", str(SR), "-ac", "1", "-f", "f32le", "-"],
        check=True, capture_output=True).stdout
    import torch
    w = np.frombuffer(raw, dtype=np.float32).copy()
    return torch.from_numpy(w).unsqueeze(0)  # (1, n_samples)


def slugify(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-") or "speaker"


def embed_segments(file, dur, segments, max_seconds=30.0, min_seg=0.6):
    """Average duration-weighted unit embeddings over the longest segments
    (up to max_seconds total). Returns (unit_vector, seconds_used)."""
    from pyannote.core import Segment
    inf = get_inf()
    segs = sorted(((max(0.0, s), min(e, dur - 0.05)) for s, e in segments),
                  key=lambda x: x[1] - x[0], reverse=True)
    vecs, used = [], 0.0
    for s, e in segs:
        if e - s < min_seg:
            continue
        v = np.asarray(inf.crop(file, Segment(s, e))).reshape(-1)
        n = np.linalg.norm(v)
        if n < 1e-9:
            continue
        vecs.append((v / n) * (e - s))
        used += e - s
        if used >= max_seconds:
            break
    if not vecs:
        return None, 0.0
    m = np.sum(vecs, axis=0)
    return m / (np.linalg.norm(m) + 1e-9), used


def windows(dur, win=10.0, step=6.0):
    out, t = [], 0.0
    while t < dur - 0.5:
        out.append((t, min(t + win, dur)))
        t += step
    return out or [(0.0, dur)]


def speaker_segments(whisperx_json, speaker=None):
    data = json.load(open(whisperx_json, encoding="utf-8"))
    by = {}
    for s in data.get("segments", []):
        spk = s.get("speaker")
        if spk is None or s.get("start") is None or s.get("end") is None:
            continue
        if speaker and spk != speaker:
            continue
        by.setdefault(spk, []).append((float(s["start"]), float(s["end"])))
    return by


def cmd_enroll(args):
    if args.json and args.speaker:
        segmap = speaker_segments(args.json, args.speaker)
        segs = segmap.get(args.speaker, [])
        if not segs:
            log(f"no segments for {args.speaker} in {args.json}")
            return 2
        file = {"waveform": load_wave(args.audio[0]), "sample_rate": SR}
        dur = file["waveform"].shape[1] / SR
        emb, used = embed_segments(file, dur, segs)
        samples = [f"{os.path.basename(args.audio[0])}#{args.speaker}"]
    else:
        accum, total = [], 0.0
        samples = []
        for ap in args.audio:
            file = {"waveform": load_wave(ap), "sample_rate": SR}
            dur = file["waveform"].shape[1] / SR
            emb, used = embed_segments(file, dur, windows(dur))
            if emb is None:
                log(f"could not embed {ap}")
                continue
            accum.append(emb * used)
            total += used
            samples.append(os.path.basename(ap))
        if not accum:
            log("enroll failed: no usable audio")
            return 2
        emb = np.sum(accum, axis=0)
        emb = emb / (np.linalg.norm(emb) + 1e-9)
        used = total
    if emb is None:
        log("enroll failed: empty embedding")
        return 2

    os.makedirs(args.out, exist_ok=True)
    slug = slugify(args.name)
    path = os.path.join(args.out, f"{slug}.json")
    now = datetime.datetime.now().isoformat(timespec="seconds")
    if os.path.exists(path):  # update: weighted-average with the existing print
        old = json.load(open(path, encoding="utf-8"))
        ow = float(old.get("n_seconds", 0)) or 1.0
        oe = np.asarray(old.get("embedding", []), dtype=np.float64)
        if oe.shape == emb.shape:
            merged = oe * ow + emb * used
            emb = merged / (np.linalg.norm(merged) + 1e-9)
            used += ow
            samples = list(dict.fromkeys(old.get("samples", []) + samples))
        created = old.get("created", now)
    else:
        created = now
    json.dump({
        "name": args.name, "slug": slug, "model": EMB_MODEL, "dim": int(emb.shape[0]),
        "embedding": [float(x) for x in emb], "n_seconds": round(float(used), 1),
        "samples": samples, "created": created, "updated": now,
    }, open(path, "w", encoding="utf-8"), indent=2)
    log(f"enrolled {args.name} -> {path} ({round(used,1)}s, {emb.shape[0]}d)")
    return 0


def load_prints(d):
    prints = {}
    if not os.path.isdir(d):
        return prints
    for fn in os.listdir(d):
        if not fn.endswith(".json"):
            continue
        try:
            p = json.load(open(os.path.join(d, fn), encoding="utf-8"))
            v = np.asarray(p["embedding"], dtype=np.float64)
            prints[p["name"]] = v / (np.linalg.norm(v) + 1e-9)
        except Exception as e:
            log(f"skip voiceprint {fn}: {e}")
    return prints


def cmd_match(args):
    by = speaker_segments(args.json)
    if not by:
        return 0
    prints = load_prints(args.voiceprints)
    file = {"waveform": load_wave(args.audio), "sample_rate": SR}
    dur = file["waveform"].shape[1] / SR
    single = len(by) == 1
    for spk, segs in by.items():
        emb, used = embed_segments(file, dur, segs, max_seconds=args.max_seconds)
        if emb is None:
            continue
        best, best_s, second_s = None, -1.0, -1.0
        for name, vp in prints.items():
            s = float(emb @ vp)
            if s > best_s:
                best, second_s, best_s = name, best_s, s
            elif s > second_s:
                second_s = s
        if best is not None and best_s >= args.threshold and (best_s - second_s) >= args.margin:
            print(f"{spk}\t{best}\t{best_s:.3f}")
        elif single and args.single_owner and args.owner:
            print(f"{spk}\t{args.owner}\t0.000")
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("enroll")
    e.add_argument("--name", required=True)
    e.add_argument("--out", required=True)
    e.add_argument("--json")
    e.add_argument("--speaker")
    e.add_argument("audio", nargs="+")
    e.set_defaults(func=cmd_enroll)

    m = sub.add_parser("match")
    m.add_argument("--json", required=True)
    m.add_argument("--audio", required=True)
    m.add_argument("--voiceprints", required=True)
    m.add_argument("--owner", default="")
    m.add_argument("--threshold", type=float, default=0.50)
    m.add_argument("--margin", type=float, default=0.10)
    m.add_argument("--max-seconds", type=float, default=30.0)
    m.add_argument("--single-owner", action="store_true")
    m.set_defaults(func=cmd_match)

    args = ap.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
