#!/usr/bin/env bash

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

notify_send() {
  local status="$1" msg="$2" icon

  [[ -z "${SLACK_WEBHOOK_URL:-}" ]] && return 0

  case "$status" in
    start)   icon=":hourglass:" ;;
    success) icon=":white_check_mark:" ;;
    fail)    icon=":x:" ;;
    paused)  icon=":double_vertical_bar:" ;;
    *)       icon=":information_source:" ;;
  esac

  local text
  text="$(_json_escape "${icon} *${BACKUP_LABEL:-$DB_NAME}* — ${status}
${msg}")"

  curl -fsS -m 15 --retry 2 \
    -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-Type: application/json' \
    -d "{\"text\":\"${text}\"}" \
    >/dev/null 2>&1 || echo "[notify] slack send failed" >&2
}
