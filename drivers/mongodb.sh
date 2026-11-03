driver_ext() { echo "archive.gz"; }

driver_dump() {
  mongodump --uri="$DB_URI" --archive --gzip
}

driver_restore() {
  local opts=(--archive --gzip --drop)
  # Test restores keep the fresh server's own users instead of production's
  [[ "${RESTORE_SKIP_ROLES:-false}" == "true" ]] && opts+=(--nsExclude='admin.*')
  mongorestore --uri="$DB_URI" "${opts[@]}"
}
