#!/bin/bash
# ci-check.sh (local) — syntax + compile + frontmatter checks for the vault scripts.
#
# CODE_DIR (self-located, like every other post-split script) is where Meta/scripts/*
# actually lives — /app in the baked production image, or this repo root in dev.
# VAULT_DIR stays separate and defaults to CODE_DIR only for co-located dev checkouts;
# in production it's the live data mount, so frontmatter validation checks real vault
# content while the syntax/compile/shellcheck/behavioral-test steps check the running
# code. A single shared var here used to break both: VAULT_DIR=/vault has no Meta/scripts
# post-split, so `cd "$VAULT_DIR"` made every code check silently glob-fail.
set -uo pipefail
CODE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT_DIR="${VAULT_DIR:-$CODE_DIR}"
cd "$CODE_DIR"
fail=0
echo "[ci-check] private-custom-agent purity check..."
if [ -e "Meta/scripts/custom" ]; then
  echo "  FAIL: Meta/scripts/custom/ must never exist in the public mirror (private-only," \
       "gitignored convention -- see Meta/scripts/custom/README.md in the source repo)."
  fail=1
fi
echo "[ci-check] bash -n on shell scripts..."
for s in Meta/scripts/*.sh; do bash -n "$s" || { echo "  SYNTAX FAIL: $s"; fail=1; }; done
echo "[ci-check] py_compile on python scripts..."
for p in Meta/scripts/*.py; do python3 -m py_compile "$p" || { echo "  COMPILE FAIL: $p"; fail=1; }; done
if command -v shellcheck >/dev/null 2>&1; then
  echo "[ci-check] shellcheck..."; shellcheck -S error Meta/scripts/*.sh || fail=1
else echo "[ci-check] shellcheck not installed; skipping."; fi
echo "[ci-check] frontmatter validation..."
# validate-frontmatter.py exits 1 only on ERRORS (warnings/info stay non-fatal).
VAULT_DIR="$VAULT_DIR" python3 Meta/scripts/validate-frontmatter.py || { echo "  FRONTMATTER FAIL"; fail=1; }
echo "[ci-check] mechanical checks (near-empty stubs + manifest drift)..."
if [ -f "Meta/scripts/mechanical-checks.py" ]; then
  while IFS=$'\t' read -r sev msg; do
    [ -n "$sev" ] || continue
    case "$sev" in
      WARN) echo "  WARN: $msg" ;;
      SUMMARY) echo "  $msg" ;;
    esac
  done < <(VAULT_DIR="$VAULT_DIR" python3 Meta/scripts/mechanical-checks.py)
else
  echo "  mechanical-checks.py not present; skipping."
fi
echo "[ci-check] behavioral tests..."
for t in Meta/scripts/tests/*.sh; do
  [ -f "$t" ] || continue
  bash "$t" || { echo "  TEST FAIL: $t"; fail=1; }
done
[ "$fail" -eq 0 ] && echo "[ci-check] PASS" || { echo "[ci-check] FAIL"; exit 1; }
