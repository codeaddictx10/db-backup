#!/usr/bin/env bash

# Escapes a string for safe embedding in a JSON string value.
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"    # backslash first — order matters
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

notify_send() {
  local status="$1" msg="$2" icon

  [[ -z "${TELEGRAM_BOT_TOKEN:-}" || -z "${TELEGRAM_CHAT_ID:-}" ]] && return 0

  case "$status" in
    start)   icon="⏳" ;;
    success) icon="✅" ;;
    fail)    icon="❌" ;;
    paused)  icon="⏸️" ;;
    *)       icon="ℹ️" ;;
  esac

  local text
  text="$(_json_escape "${icon} *${BACKUP_LABEL:-$DB_NAME}* — ${status}
${msg}")"

  curl -fsS -m 15 --retry 2 \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${text}\",\"parse_mode\":\"Markdown\"}" \
    >/dev/null 2>&1 || echo "[notify] telegram send failed" >&2
}
