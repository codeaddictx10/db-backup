#!/usr/bin/env bash
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---------- 1. validate ----------
missing=()

for bin in restic supercronic flock curl; do
  command -v "$bin" >/dev/null || { log "FATAL: required binary not found: $bin"; exit 1; }
done

for var in DB_ENGINE DB_NAME RESTIC_REPOSITORY RESTIC_PASSWORD; do
  [[ -z "${!var:-}" ]] && missing+=("$var")
done

# R2 needs S3 credentials
if [[ "$RESTIC_REPOSITORY" == s3:* ]]; then
  for var in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    [[ -z "${!var:-}" ]] && missing+=("$var")
  done
fi

if (( ${#missing[@]} )); then
  log "FATAL: missing required env: ${missing[*]}"
  exit 1
fi

[[ -f "/app/drivers/${DB_ENGINE}.sh" ]] || {
  log "FATAL: unknown DB_ENGINE '${DB_ENGINE}'. Available: $(ls /app/drivers | sed 's/\.sh//' | tr '\n' ' ')"
  exit 1
}

if [[ ! -f "/app/notifiers/${NOTIFIER}.sh" ]]; then
  log "WARN: unknown NOTIFIER '${NOTIFIER}' — falling back to none"
  export NOTIFIER=none
fi

# ---------- 2. init repo ----------
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/cache/restic}"
mkdir -p "$RESTIC_CACHE_DIR" /state

if restic cat config >/dev/null 2>&1; then
  log "restic repository OK"
else
  log "no repository found — initialising"
  restic init || { log "FATAL: restic init failed (check credentials / bucket)"; exit 1; }
fi

# ---------- 3. write crontab ----------
CRONTAB=/state/crontab
echo "${BACKUP_CRON} /bin/bash /app/backup.sh" > "$CRONTAB"
[[ -s "$CRONTAB" ]] || { log "FATAL: failed to write $CRONTAB"; exit 1; }
log "crontab: $(cat "$CRONTAB")"

supercronic -test "$CRONTAB" || { log "FATAL: invalid crontab"; exit 1; }

log "schedule: ${BACKUP_CRON} (TZ=${TZ:-UTC})"

[[ "${BACKUP_PAUSED:-false}" == "true" ]] && \
  log "WARN: BACKUP_PAUSED=true — no backups will run until this is unset"

# ---------- 4. catch-up ----------
if [[ "${RUN_ON_START:-true}" == "true" ]]; then
  log "startup catch-up check"
  /app/backup.sh || log "WARN: startup backup failed — cron will retry"
fi

log "handing off to supercronic"
exec /usr/local/bin/supercronic "$CRONTAB"
