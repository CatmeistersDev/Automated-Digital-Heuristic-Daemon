# Example voiceprints

**These are examples. They are not real voiceprints and will never match anyone's audio.**

They exist so you can see the exact file shape `Meta/scripts/enroll-voice.sh` produces before you
enroll anyone, and so the speaker-ID path is documented without shipping biometric data.

`louise.json` · `tina.json` · `gene.json` — the three demo-vault speakers.

## Why they are here and not in `Meta/voiceprints/`

A voiceprint is a biometric: a 256-dimension embedding of someone's voice. `Meta/voiceprints/` is
**git-ignored on purpose**, so:

- Your enrolled voices never get committed or pushed.
- A fresh clone starts with **zero enrolled voices** — you do not inherit anyone else's, and this
  repo ships none.

These examples live under `docs/` precisely so nothing here can be mistaken for a real enrollment.
Each file also carries `"_example": true` and a `_warning` field.

## The schema

```json
{
  "name": "Louise",
  "slug": "louise",
  "model": "pyannote/wespeaker-voxceleb-resnet34-LM",
  "dim": 256,
  "embedding": [0.041, -0.017, "... 256 floats, unit length ..."],
  "n_seconds": 41.8,
  "samples": ["2026-06-03 - Voice - 6-3-26-02.30"],
  "created": "2026-06-03T09:15:00",
  "updated": "2026-06-03T09:15:00"
}
```

`slug` is the filename stem, lowercased with non-alphanumerics collapsed to `-`. Re-running
enrollment for an existing name **averages** the new sample into the stored embedding and appends
to `samples`, rather than replacing it.

## Enrolling for real

```bash
# From a diarized memo: pick the SPEAKER_xx cluster that is actually them
Meta/scripts/enroll-voice.sh "Louise" --from-memo <whisperx.json> SPEAKER_00 <audio-file>

# Or straight from one or more clean audio samples
Meta/scripts/enroll-voice.sh "Louise" <audio-file> [<audio-file> ...]
```

Output lands in `Meta/voiceprints/<slug>.json`. Requires a Hugging Face token at
`.secrets/hf-token.txt` — the embedding model is gated.

## How matching behaves

`speaker_id.py match` embeds each diarized speaker cluster and compares it to every enrolled
voiceprint by cosine similarity. A cluster is only labelled when it clears **both** a threshold
(default `0.50`) and a margin over the runner-up (default `0.10`). Anything short of that is left
unlabelled rather than guessed — a wrong name in your notes is worse than no name.

The three example vectors here sit near zero similarity to each other (|cos| < 0.06), so even if
you pointed the matcher at this folder, nothing would ever match.
