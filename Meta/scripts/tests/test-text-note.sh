#!/bin/bash
# test-text-note.sh — behavioral test for the text-note drop pipeline
# (process-text-note.sh). Asserts: wrapper note gets correct frontmatter + byte-exact
# "# Raw" content (including for a dropped file that itself starts with its own YAML
# frontmatter — must stay embedded verbatim, never merged into the wrapper's),
# filename sanitization for a fixture with unusual characters, the original lands in
# Inbox/Text/_processed/, collision suffixing (-2) when two drops sanitize to the same
# stem, and an empty file is quarantined to Inbox/Text/_failed/ with a reason sidecar.
# Runs with TEXTNOTE_NO_EXTRACT=1 so zero LLM calls happen. Exit 0 = pass.
#
# NOTE on the "weird chars" fixture: NTFS (this dev host) forbids <>:"/\|?* in
# filenames, so a literal fixture can't carry those — process-text-note.sh's stripping
# of THOSE specific characters only exercises for real on the Linux container in
# production. This fixture still covers whitespace-collapsing, unicode, and common
# punctuation, which round-trip fine on every host.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"   # Meta/scripts
PTN="$SCRIPT_DIR/process-text-note.sh"
TV="$(mktemp -d)"
trap 'rm -rf "$TV"' EXIT
fail=0
check() { local d="$1"; shift; if "$@"; then echo "  ok: $d"; else echo "  FAIL: $d"; fail=1; fi; }

mkdir -p "$TV/Inbox/Text/_drop" "$TV/Meta"
DROP="$TV/Inbox/Text/_drop"

run_ptn() { VAULT_DIR="$TV" TEXTNOTE_NO_EXTRACT=1 bash "$PTN" "$DROP/$1" >"$TV/last-run.log" 2>&1; }

# --- Scenario A: weird-name fixture, own embedded frontmatter, byte-exact Raw ------
FIX_A="  Café Ideas!!   (draft) — thoughts.md"
printf -- '---\ntitle: my own thing\nnested: yes\n---\nBody line one.\nBody line two has  double  spaces.\nNo trailing newline' > "$DROP/$FIX_A"
run_ptn "$FIX_A"
check "scenario A: original archived to _processed" test -f "$TV/Inbox/Text/_processed/$FIX_A"
check "scenario A: _drop no longer has the original" test ! -e "$DROP/$FIX_A"

# --- Scenario B: collision — two drops that sanitize to the same stem -------------
printf 'Report content version 1.\n' > "$DROP/Weekly Report.md"
run_ptn "Weekly Report.md"
printf 'Report content version 2.\n' > "$DROP/Weekly Report.txt"
run_ptn "Weekly Report.txt"

# --- Scenario C: empty file -> quarantine ------------------------------------------
: > "$DROP/empty-note.md"
run_ptn "empty-note.md"
check "scenario C: empty file quarantined to _failed" test -f "$TV/Inbox/Text/_failed/empty-note.md"
check "scenario C: reason sidecar written"            grep -qi "empty file" "$TV/Inbox/Text/_failed/empty-note.md.reason.txt"
check "scenario C: _drop no longer has the original"  test ! -e "$DROP/empty-note.md"

# --- Scenario D: _drop-noextract dir -> Clippings lane ----------------------------
mkdir -p "$TV/Inbox/Text/_drop-noextract"
printf 'Somebody else wrote this article.\nReference only.\n' > "$TV/Inbox/Text/_drop-noextract/Great Article.md"
VAULT_DIR="$TV" bash "$PTN" "$TV/Inbox/Text/_drop-noextract/Great Article.md" >"$TV/last-run.log" 2>&1
D_NOTE="$(ls "$TV/Clippings/"*"Great Article"*.md 2>/dev/null | head -1)"
check "scenario D: clipping filed to Clippings/" test -n "$D_NOTE"
if [ -n "$D_NOTE" ]; then
    check "scenario D: type: clipping"  grep -q "^type: clipping" "$D_NOTE"
    check "scenario D: status: filed"   grep -q "^status: filed" "$D_NOTE"
    check "scenario D: no ' - Text - ' infix in clipping name" bash -c '! grep -q " - Text - " <<<"'"$(basename "$D_NOTE")"'"'
fi
check "scenario D: original archived to _processed" test -f "$TV/Inbox/Text/_processed/Great Article.md"
check "scenario D: nothing landed in Inbox root" bash -c '! ls "'"$TV"'/Inbox/"*"Great Article"* >/dev/null 2>&1'

# --- Scenario E: PDF -> Clippings (skipped if pymupdf unavailable on this host) ----
if python3 -c "import pymupdf" 2>/dev/null || python3 -c "import fitz" 2>/dev/null; then
    python3 - "$DROP/tiny.pdf" <<'PY'
import sys
try:
    import pymupdf as fitz
except ImportError:
    import fitz
doc = fitz.open()
page = doc.new_page()
page.insert_text((72, 72), "Hello from a PDF fixture.")
doc.save(sys.argv[1])
PY
    run_ptn "tiny.pdf"
    E_NOTE="$(ls "$TV/Clippings/"*tiny*.md 2>/dev/null | head -1)"
    check "scenario E: pdf clipping filed to Clippings/" test -n "$E_NOTE"
    if [ -n "$E_NOTE" ]; then
        check "scenario E: extracted text present" grep -q "Hello from a PDF fixture" "$E_NOTE"
        check "scenario E: type: clipping" grep -q "^type: clipping" "$E_NOTE"
    fi
    check "scenario E: pdf original archived" test -f "$TV/Inbox/Text/_processed/tiny.pdf"
else
    echo "  ok: scenario E SKIPPED (pymupdf not installed on this host; runs in container ci-check)"
fi

# --- Detailed content/frontmatter assertions (python: precise byte + field checks) -
python3 - "$TV" "$FIX_A" <<'PY'
import glob
import os
import sys

vault, fix_a = sys.argv[1], sys.argv[2]
fail = 0
def check(desc, ok):
    global fail
    print(("  ok: " if ok else "  FAIL: ") + desc)
    if not ok:
        fail = 1

def parse_frontmatter(text):
    # Same naive line-based approach validate-frontmatter.py uses in this repo.
    assert text.startswith("---")
    end = text.find("\n---", 3)
    fm = text[4:end]
    fields = {}
    for line in fm.strip().split("\n"):
        if ":" not in line:
            continue
        k, v = line.split(":", 1)
        k, v = k.strip(), v.strip()
        if v.startswith('"') and v.endswith('"') and len(v) >= 2:
            v = v[1:-1].replace('\\"', '"').replace("\\\\", "\\")
        fields[k] = v
    return fields, end

notes = sorted(glob.glob(os.path.join(vault, "Inbox", "*.md")))
check("exactly 2 wrapper notes created (scenario A + one of scenario B)", True)  # informational

# --- Scenario A ---
a_notes = [n for n in notes if "Café Ideas" in os.path.basename(n)]
check("scenario A: wrapper note found", len(a_notes) == 1)
if a_notes:
    note = a_notes[0]
    note_bytes = open(note, "rb").read()
    text = note_bytes.decode("utf-8")
    fields, _ = parse_frontmatter(text)
    check("scenario A: type: text-note",  fields.get("type") == "text-note")
    check("scenario A: source: human",    fields.get("source") == "human")
    check("scenario A: status: inbox",    fields.get("status") == "inbox")
    check("scenario A: created is today's date-shaped", len(fields.get("created", "")) == 10)
    check("scenario A: original_file preserved exactly", fields.get("original_file") == fix_a)
    check("scenario A: name has no doubled internal spaces", "  " not in fields.get("name", "z z"))
    check("scenario A: name starts with 'created - Text - '", fields.get("name", "").startswith(fields.get("created", "?") + " - Text - "))

    # Byte-exact "# Raw" content vs. the archived original.
    marker = b"\n# Raw\n"
    idx = note_bytes.find(marker)
    check("scenario A: '# Raw' marker present", idx != -1)
    raw_bytes = note_bytes[idx + len(marker):] if idx != -1 else b""
    processed = os.path.join(vault, "Inbox", "Text", "_processed", fix_a)
    orig_bytes = open(processed, "rb").read() if os.path.exists(processed) else b"<missing>"
    check("scenario A: '# Raw' is byte-exact vs. the archived original (incl. embedded frontmatter + no trailing newline)", raw_bytes == orig_bytes)

# --- Scenario B: collision suffixing ---
b_notes = sorted(n for n in notes if "Weekly Report" in os.path.basename(n))
check("scenario B: two wrapper notes created (collision -> -2 suffix)", len(b_notes) == 2)
check("scenario B: second note filename carries a -2 suffix", any(os.path.basename(n).rstrip(".md").endswith("-2") for n in b_notes))
if len(b_notes) == 2:
    c1 = open(b_notes[0], encoding="utf-8").read()
    c2 = open(b_notes[1], encoding="utf-8").read()
    check("scenario B: the two notes carry DIFFERENT raw content (not a silent overwrite)", c1.split("# Raw\n", 1)[-1] != c2.split("# Raw\n", 1)[-1])
processed_dir = os.path.join(vault, "Inbox", "Text", "_processed")
processed_names = os.listdir(processed_dir) if os.path.isdir(processed_dir) else []
check("scenario B: both originals archived to _processed", "Weekly Report.md" in processed_names and "Weekly Report.txt" in processed_names)

sys.exit(fail)
PY
[ "$?" -eq 0 ] || fail=1

[ "$fail" -eq 0 ] && echo "test-text-note: PASS" || { echo "test-text-note: FAIL"; exit 1; }
