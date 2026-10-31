#!/bin/bash
# run-backup.sh — off-array snapshot of the vault git repo via `git bundle`.
#
# The vault git lives on the array; this writes a COMPLETE, restorable bundle to a
# separate location (mounted at /backups -> Unraid appdata, a different pool) so a
# disk/array failure or a bad git operation can't take the second brain with it.
# Keeps the last GIT_BACKUP_KEEP bundles.
#
# Restore: git clone /path/to/autodhd-YYYYMMDD-HHMM.bundle restored-vault
set -uo pipefail

VAULT_DIR="${VAULT_DIR:-/vault}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# The off-array backup is a silent-failure risk (a failed snapshot is invisible until you NEED it).
# A backup failure does NOT imply the notify channel is down, so alert loudly (high priority).
alert() { /bin/bash "$SCRIPT_DIR/notify.sh" "🛑 Vault backup FAILED" "$1" high "rotating_light" 2>/dev/null || true; }
cd "$VAULT_DIR" || { echo "backup: cannot cd to $VAULT_DIR" >&2; alert "cannot cd to $VAULT_DIR"; exit 1; }
DEST="${GIT_BACKUP_DIR:-/backups}"
KEEP="${GIT_BACKUP_KEEP:-14}"

git config --global --add safe.directory '*' 2>/dev/null || true
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "backup: $VAULT_DIR is not a git repo" >&2; alert "$VAULT_DIR is not a git repo"; exit 1
fi
if ! mkdir -p "$DEST" 2>/dev/null; then
    echo "backup: cannot write to $DEST (is the backup volume mounted?)" >&2
    alert "cannot write to backup dir $DEST — is the off-array volume mounted?"; exit 1
fi

TS="$(date +%Y%m%d-%H%M)"
OUT="$DEST/autodhd-$TS.bundle"
if git bundle create "$OUT" --all >/dev/null 2>&1 && git bundle verify "$OUT" >/dev/null 2>&1; then
    echo "backup: wrote $(basename "$OUT") ($(du -h "$OUT" | cut -f1))"
else
    echo "backup: FAILED to create/verify bundle" >&2
    rm -f "$OUT" 2>/dev/null
    alert "git bundle create/verify failed (no restorable snapshot written)"; exit 1
fi

# Rotate: keep newest $KEEP bundles
ls -1t "$DEST"/autodhd-*.bundle 2>/dev/null | tail -n +"$((KEEP+1))" | while IFS= read -r old; do
    rm -f "$old" && echo "backup: pruned $(basename "$old")"
done

# Off-array snapshot of files that exist in exactly ONE place and aren't in git: enrolled
# voiceprints (irreplaceable embeddings — re-enrolling means re-recording every person) and
# .secrets (tokens with no other copy). The git bundle above only covers the tracked repo,
# so a disk/array failure would silently take both of these with it. chmod 600 since the
# tar contains live secrets.
SNAP_OUT="$DEST/autodhd-extras-$TS.tar.gz"
SNAP_TARGETS=()
[ -d "Meta/voiceprints" ] && SNAP_TARGETS+=("Meta/voiceprints")
[ -d ".secrets" ] && SNAP_TARGETS+=(".secrets")
if [ "${#SNAP_TARGETS[@]}" -gt 0 ]; then
    if tar -czf "$SNAP_OUT" "${SNAP_TARGETS[@]}" 2>/dev/null; then
        chmod 600 "$SNAP_OUT" 2>/dev/null || true
        echo "backup: wrote $(basename "$SNAP_OUT") ($(du -h "$SNAP_OUT" | cut -f1))"
    else
        echo "backup: FAILED to snapshot voiceprints/.secrets" >&2
        rm -f "$SNAP_OUT" 2>/dev/null
        alert "voiceprints/.secrets tar snapshot failed (git bundle OK, but irreplaceable files unprotected)"
    fi
fi
ls -1t "$DEST"/autodhd-extras-*.tar.gz 2>/dev/null | tail -n +"$((KEEP+1))" | while IFS= read -r old; do
    rm -f "$old" && echo "backup: pruned $(basename "$old")"
done

# Off-box replica: push the data repo to Gitea. Token is read at runtime from the
# vault's .secrets (harness-denied path) — never stored in .git/config, where the
# agents' read_file sandbox could reach it. No-ops until the token is provisioned.
GITEA_PUSH_URL="${GITEA_PUSH_URL:-git.example:3000/your-org/autoadhd-vault.git}"
GITEA_TOKEN_FILE="$VAULT_DIR/.secrets/gitea-bot-token.txt"
if [ -s "$GITEA_TOKEN_FILE" ]; then
    BT="$(tr -d '\r\n ' < "$GITEA_TOKEN_FILE")"
    if git push -q "http://autoadhd-bot:$BT@$GITEA_PUSH_URL" --all 2>/dev/null; then
        echo "backup: pushed replica to gitea"
    else
        alert "gitea replica push failed (bundle OK, replica stale)"
    fi
fi
