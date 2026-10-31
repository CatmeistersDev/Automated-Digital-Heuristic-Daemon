#!/usr/bin/env python3
"""PII / topology / secret gate for the AutoADHD public mirror.

Runs in CI (.github/workflows/pii-gate.yml) and locally:

    python scripts/pii_check.py            # scan all tracked files
    python scripts/pii_check.py PATH ...   # scan specific files

Rules here are deliberately GENERIC (patterns, never real values) so the
gate itself cannot leak what it protects. The private repo carries a
companion literal blocklist (Meta/scripts/mirror-scan.sh there) that must
also pass before any mirror refresh is published — this file is the public
half of a two-sided gate.

Exit codes: 0 clean, 1 BLOCK findings, 2 usage/internal error.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

# (name, severity, compiled regex, why)
RULES = [
    (
        "internal-topology",
        "BLOCK",
        re.compile(r"\b10\.10\.\d{1,3}\.\d{1,3}\b"),
        "10.10.x.x is the origin homelab's addressing plan; demo content must use documentation ranges (192.0.2.x / 198.51.100.x / 203.0.113.x)",
    ),
    (
        "gps-coordinate-pair",
        "BLOCK",
        re.compile(r"-?\d{1,3}\.\d{4,}\s*,\s*-?\d{1,3}\.\d{4,}"),
        "high-precision lat,long pair — location PII",
    ),
    (
        "gps-frontmatter",
        "BLOCK",
        re.compile(r"^\s*gps:\s*[-\d]", re.MULTILINE),
        "gps: frontmatter with a numeric value — location PII",
    ),
    (
        "loc-slug",
        "BLOCK",
        re.compile(r"\bloc_-?\d[-\d._]*"),
        "loc_<coords> slug pattern from the private pipeline's note titles",
    ),
    (
        "private-key-block",
        "BLOCK",
        re.compile(r"-----BEGIN (?:OPENSSH|RSA|EC|DSA|ENCRYPTED)? ?PRIVATE KEY-----"),
        "private key material",
    ),
    (
        "credential-in-url",
        "BLOCK",
        re.compile(r"https?://[^/\s:@]+:[^/\s@]{8,}@"),
        "user:secret@host URL (the .git/config token-leak shape)",
    ),
    (
        "dob-frontmatter",
        "BLOCK",
        re.compile(r"^\s*(?:dob|date_of_birth|birthdate):\s*\d{4}-\d{2}-\d{2}\s*$", re.MULTILINE | re.IGNORECASE),
        "date-of-birth frontmatter — only schema-doc placeholders (YYYY-MM-DD literal) are allowed, never a real-looking date",
    ),
    (
        "ssh-public-key",
        "WARN",
        re.compile(r"\bssh-(?:ed25519|rsa) AAAA[0-9A-Za-z+/=]{20,}"),
        "real SSH public key — fingerprints the origin infrastructure; replace with a placeholder",
    ),
    (
        "windows-drive-layout",
        "WARN",
        re.compile(r"\b[ZOY]:\\\\?[A-Za-z]"),
        "Z:/O:/Y: drive references describe the origin machine's layout; genericize",
    ),
]

# Paths where a rule is expected and acceptable (path prefix or exact, posix).
ALLOWLIST: dict[str, set[str]] = {
    # This file and the workflow describe the patterns themselves.
    "scripts/pii_check.py": {r[0] for r in RULES},
    ".github/workflows/pii-gate.yml": {r[0] for r in RULES},
    ".gitleaks.toml": {r[0] for r in RULES},
    # This test exercises the GPS-stripping path, so it has to contain coordinate-shaped
    # input to be a test at all. The values in it are synthetic — not a real location.
    "Meta/scripts/tests/test-voice-memo-gps-slug.sh": {"gps-coordinate-pair", "loc-slug"},
}

SKIP_SUFFIXES = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".ico", ".pdf", ".zip", ".gz"}


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def main(argv: list[str]) -> int:
    files = argv or tracked_files()
    blocks, warns = [], []
    for name in files:
        p = Path(name)
        if p.suffix.lower() in SKIP_SUFFIXES or not p.is_file():
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"pii-gate: cannot read {name}: {exc}", file=sys.stderr)
            return 2
        allowed = ALLOWLIST.get(p.as_posix(), set())
        for rule, sev, rx, why in RULES:
            if rule in allowed:
                continue
            for m in rx.finditer(text):
                line_no = text.count("\n", 0, m.start()) + 1
                finding = f"{name}:{line_no}: [{sev}] {rule} — {why}"
                (blocks if sev == "BLOCK" else warns).append(finding)

    for f in warns:
        print(f)
    for f in blocks:
        print(f)
    if blocks:
        print(f"\npii-gate: {len(blocks)} blocking finding(s) — do not publish.", file=sys.stderr)
        return 1
    print(f"pii-gate: clean ({len(files)} files scanned, {len(warns)} warnings).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
