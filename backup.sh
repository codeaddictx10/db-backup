#!/usr/bin/env bash
set -euo pipefail

log() { echo "[backup $(date '+%F %T')] $*"; }

STATE_DIR=/state
STAMP="${STATE_DIR}/last-success"
LOCK="${STATE_DIR}/backup.lock"
LABEL="${BACKUP_LABEL:-$DB_NAME}"

# ---------- load drivers ----------
source "/app/drivers/${DB_ENGINE}.sh"

NOTIFIER_FILE="/app/notifiers/${NOTIFIER:-none}.sh"
[[ -f "$NOTIFIER_FILE" ]] || NOTIFIER_FILE="/app/notifiers/none.sh"
source "$NOTIFIER_FILE"

# ---------- 0. pause ----------
if [[ "${BACKUP_PAUSED:-false}" == "true" ]]; then
  log "BACKUP_PAUSED=true — skipping this run"
  notify_send paused "Scheduled backup skipped — BACKUP_PAUSED=true. Unset to resume." || true
  exit 0
fi

# ---------- 1. gate ----------
if [[ -f "$STAMP" ]]; then
  AGE=$(( ( $(date +%s) - $(stat -c %Y "$STAMP") ) / 3600 ))
  if (( AGE < ${MIN_INTERVAL_HOURS:-10} )); then
    log "last success ${AGE}h ago (< ${MIN_INTERVAL_HOURS}h) — skipping"
    exit 0
  fi
fi

# ---------- 2. lock ----------
command -v flock >/dev/null || { log "FATAL: flock not found — cannot guarantee single-run"; exit 1; }

exec 9>"$LOCK"
flock -n 9 || { log "another run in progress — exiting"; exit 0; }

# ---------- 3. failure trap ----------
FAILED_AT="unknown"
on_error() {
  log "FAILED during: ${FAILED_AT}"
  notify_send fail "Failed during: ${FAILED_AT}" || true
}
trap on_error ERR

START_TS=$(date +%s)
notify_send start "Backup started" || true

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------- 4. pre-hook (failure aborts) ----------
if [[ -x /app/hooks/pre-backup.sh ]]; then
  FAILED_AT="pre-backup hook"
  log "running pre-backup hook"
  /app/hooks/pre-backup.sh
fi

# ---------- 5. dump ----------
FAILED_AT="database dump"
DUMP_FILE="${TMP}/${LABEL}-$(date +%F_%H-%M-%S).$(driver_ext)"
log "dumping ${DB_NAME} from ${DB_HOST}"
driver_dump > "$DUMP_FILE"

DUMP_SIZE=$(du -h "$DUMP_FILE" | cut -f1)
[[ -s "$DUMP_FILE" ]] || { FAILED_AT="dump produced empty file"; false; }
log "dump complete (${DUMP_SIZE})"

# ---------- 6. upload ----------
FAILED_AT="restic backup"
log "uploading to restic repository"
SNAPSHOT_ID=$(restic backup "$DUMP_FILE" --tag "$LABEL" --json \
  | grep '"message_type":"summary"' \
  | sed -E 's/.*"snapshot_id":"([a-f0-9]+)".*/\1/')
log "snapshot ${SNAPSHOT_ID}"

# ---------- 7. retention ----------
FAILED_AT="restic forget/prune"
log "pruning to ${RETENTION}"
restic forget --tag "$LABEL" --keep-within "${RETENTION}" --prune

# ---------- 8. success ----------
touch "$STAMP"
DURATION=$(( $(date +%s) - START_TS ))
SNAPSHOT_COUNT=$(restic snapshots --tag "$LABEL" --json | grep -o '"short_id"' | wc -l)

# ---------- 9. post-hook (failure only warns) ----------
export SNAPSHOT_ID DUMP_FILE
if [[ -x /app/hooks/post-backup.sh ]]; then
  log "running post-backup hook"
  /app/hooks/post-backup.sh || log "WARN: post-backup hook failed (backup itself is safe)"
fi

trap - ERR
log "done in ${DURATION}s"
notify_send success "Size: ${DUMP_SIZE}
Duration: ${DURATION}s
Snapshot: ${SNAPSHOT_ID:0:8}
Retained: ${SNAPSHOT_COUNT} snapshots (${RETENTION})" || true
