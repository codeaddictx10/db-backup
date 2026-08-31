#!/usr/bin/env bash
set -euo pipefail

log() { echo "[restore $(date '+%F %T')] $*"; }

SNAPSHOT="${1:-latest}"
LABEL="${BACKUP_LABEL:-$DB_NAME}"

source "/app/drivers/${DB_ENGINE}.sh"

# Refuse to run without an explicit acknowledgement — this overwrites a live DB
if [[ "${I_UNDERSTAND_THIS_OVERWRITES:-no}" != "yes" ]]; then
  log "REFUSING: set I_UNDERSTAND_THIS_OVERWRITES=yes to proceed"
  log "target: ${DB_NAME} on ${DB_HOST}  |  snapshot: ${SNAPSHOT}"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

log "restoring snapshot ${SNAPSHOT} (tag ${LABEL})"
restic restore "$SNAPSHOT" --tag "$LABEL" --target "$TMP"

DUMP=$(find "$TMP" -type f -name "*.$(driver_ext)" -print -quit)
[[ -n "$DUMP" && -s "$DUMP" ]] || { log "FATAL: no .$(driver_ext) file in snapshot"; exit 1; }
log "found $(du -h "$DUMP" | cut -f1) dump — loading into ${DB_NAME} on ${DB_HOST}"

driver_restore < "$DUMP"
log "restore complete"
