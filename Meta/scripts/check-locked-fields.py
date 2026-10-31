#!/usr/bin/env python3
"""
check-locked-fields.py — enforce `locked:` frontmatter for staged commits.

For every staged, previously-committed .md file, compares each field named in HEAD's
`locked:` list against the staged version. A locked field that changed value (or got
dropped) fails the check. Called from pre-commit-guard.sh; VAULT_ALLOW_LOCKED_EDIT=1
overrides it there, the same pattern as VAULT_ALLOW_DELETE.

Stdlib only (git CLI + re) so it runs unchanged in the container.
"""
import re
import subprocess
import sys


def _git_show(ref_path):
    try:
        out = subprocess.run(["git", "show", ref_path], capture_output=True, text=True, check=True)
        return out.stdout
    except subprocess.CalledProcessError:
        return None


def parse_frontmatter(content):
    """Return (fields, locked) — scalar frontmatter fields and the `locked:` list."""
    if not content.startswith("---"):
        return {}, []
    end = content.find("\n---", 3)
    if end == -1:
        return {}, []
    lines = content[4:end].strip("\n").split("\n")

    fields, locked = {}, []
    i = 0
    while i < len(lines):
        m = re.match(r'^(\w[\w_-]*)\s*:\s*(.*)$', lines[i])
        if m:
            key, val = m.group(1), m.group(2).strip()
            if key == "locked" and val == "":
                j = i + 1
                while j < len(lines):
                    item = re.match(r'^\s*-\s*(.+)$', lines[j])
                    if not item:
                        break
                    locked.append(item.group(1).strip().strip('"\''))
                    j += 1
                i = j
                continue
            fields[key] = val.strip('"\'')
        i += 1
    return fields, locked


def main():
    staged = subprocess.run(
        ["git", "diff", "--cached", "--diff-filter=M", "--name-only"],
        capture_output=True, text=True,
    ).stdout.splitlines()

    violations = []
    for path in staged:
        if not path.endswith(".md"):
            continue
        old = _git_show(f"HEAD:{path}")
        new = _git_show(f":{path}")
        if old is None or new is None:
            continue
        old_fields, old_locked = parse_frontmatter(old)
        new_fields, _ = parse_frontmatter(new)
        for field in old_locked:
            if field not in old_fields:
                continue
            old_val, new_val = old_fields[field], new_fields.get(field)
            if new_val != old_val:
                violations.append(f"{path}: locked field '{field}' changed ({old_val!r} -> {new_val!r})")

    if violations:
        for v in violations:
            print(v, file=sys.stderr)
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
