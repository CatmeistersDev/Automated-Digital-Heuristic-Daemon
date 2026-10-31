# Meta/voiceprints/

Your enrolled voiceprints live here. **This folder ships empty, and that is deliberate.**

Everything in it except this README is git-ignored, because a voiceprint is a biometric — a
256-dimension embedding of a real person's voice. Two consequences:

- Your enrollments are never committed and never pushed.
- A fresh clone starts with **zero enrolled voices**. You do not inherit anyone else's, and this
  repo ships none.

Until you enroll someone, diarized memos still transcribe fine — speakers just come through as
`SPEAKER_00`, `SPEAKER_01` and so on instead of names.

## Enroll

```bash
# From a diarized memo: pick the SPEAKER_xx cluster that is actually them
Meta/scripts/enroll-voice.sh "Louise" --from-memo <whisperx.json> SPEAKER_00 <audio-file>

# Or straight from one or more clean audio samples
Meta/scripts/enroll-voice.sh "Louise" <audio-file> [<audio-file> ...]
```

Writes `Meta/voiceprints/<slug>.json`. Re-running for the same name averages the new sample in
rather than replacing it, so a weak first enrollment can be improved by adding more audio.

Needs a Hugging Face token at `.secrets/hf-token.txt` — the embedding model is gated.

## What the files look like

See [`docs/examples/voiceprints/`](../../docs/examples/voiceprints/) for three worked examples with
the full schema. Those are synthetic and match nothing; they are documentation, not enrollments.
