#!/usr/bin/env python3
"""
thinker-conflict-stubs.py — deterministic post-pass (Phase 4b): turns
"CONFLICT: <topic> — <description>" lines from Thinker/Mirror model output into
propose-only Meta/review-queue/ stubs.

run-thinker.sh's prompt instructs the model to mark a genuine contradiction it
spots as its own line, exactly: "CONFLICT: <topic> — <description>". This
script is the SHELL side — the model never writes review-queue files itself.
One stub per CONFLICT line, deduped by slug (of the topic) against any
already-queued conflict file for that slug, regardless of date. If the model
output has no CONFLICT lines, nothing happens (prints nothing, creates nothing).

Usage: thinker-conflict-stubs.py [--vault DIR] --narrative-file F --agent NAME
                                  [--date YYYY-MM-DD]
       (or pipe the narrative on stdin, omitting --narrative-file)

Prints the relpath of each stub actually created (one per line). Exit 0 always
— this is a propose-only tool, not a gate. Stdlib only.
"""
import argparse
import datetime
import os
import re
import sys

CONFLICT_RE = re.compile(r"^CONFLICT:\s*(.+)$")
LINK_RE = re.compile(r"\[\[[^\]]+\]\]")
EXISTING_STUB_RE = re.compile(r"^\d{4}-\d{2}-\d{2}-conflict-(.+)\.md$")


def slugify(s, maxlen=40):
    s = s.lower()
    s = re.sub(r"[^a-z0-9]+", "-", s).strip("-")
    return s[:maxlen] or "conflict"


def split_topic(rest):
    for sep in ("—", " - "):
        if sep in rest:
            topic, _, _ = rest.partition(sep)
            topic = topic.strip()
            if topic:
                return topic, rest.strip()
    return rest.strip(), rest.strip()


def existing_slugs(queue_dir):
    slugs = set()
    if os.path.isdir(queue_dir):
        for f in os.listdir(queue_dir):
            m = EXISTING_STUB_RE.match(f)
            if m:
                slugs.add(m.group(1))
    return slugs


def build_stub(topic, full_line, agent, date):
    links = sorted(set(LINK_RE.findall(full_line)))
    lines = [
        "---", "type: review-item", f"name: Conflict — {topic}", "status: open",
        f"source_agent: {agent}", f"created: {date}", "---", "",
        f"# ⚖️ Conflict: {topic}", "",
        "> Flagged by the Thinker as a contradiction between two or more notes. "
        "Propose-only — nothing was changed.",
        "",
        full_line,
    ]
    if links:
        lines += ["", "## Involved notes"] + [f"- {l}" for l in links]
    return "\n".join(lines) + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vault", default=os.environ.get("VAULT_DIR", os.getcwd()))
    ap.add_argument("--narrative-file")
    ap.add_argument("--agent", default="Thinker")
    ap.add_argument("--date", default=datetime.date.today().isoformat())
    args = ap.parse_args(argv)

    if args.narrative_file:
        with open(args.narrative_file, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    else:
        text = sys.stdin.read()

    queue_dir = os.path.join(args.vault, "Meta", "review-queue")
    already = existing_slugs(queue_dir)
    created = []

    for line in text.splitlines():
        m = CONFLICT_RE.match(line.strip())
        if not m:
            continue
        rest = m.group(1).strip()
        if not rest:
            continue
        topic, full_line = split_topic(rest)
        slug = slugify(topic)
        if slug in already:
            continue
        already.add(slug)

        os.makedirs(queue_dir, exist_ok=True)
        out_path = os.path.join(queue_dir, f"{args.date}-conflict-{slug}.md")
        with open(out_path, "w", encoding="utf-8") as fh:
            fh.write(build_stub(topic, full_line, args.agent, args.date))
        created.append(os.path.relpath(out_path, args.vault).replace(os.sep, "/"))

    for p in created:
        print(p)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
