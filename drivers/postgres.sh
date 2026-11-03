driver_ext() { echo "dump"; }

driver_dump() {
  PGPASSWORD="$DB_PASSWORD" pg_dump \
    -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" \
    -Fc "$DB_NAME"
}

driver_restore() {
  local opts=(--clean --if-exists)
  # Test restores into a fresh server lack production's roles
  [[ "${RESTORE_SKIP_ROLES:-false}" == "true" ]] && opts+=(--no-owner --no-acl)
  PGPASSWORD="$DB_PASSWORD" pg_restore \
    -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" \
    -d "$DB_NAME" "${opts[@]}"
}
