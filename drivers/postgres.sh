driver_ext() { echo "dump"; }

driver_dump() {
  PGPASSWORD="$DB_PASSWORD" pg_dump \
    -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" \
    -Fc "$DB_NAME"
}

driver_restore() {
  PGPASSWORD="$DB_PASSWORD" pg_restore \
    -h "$DB_HOST" -p "${DB_PORT:-5432}" -U "$DB_USER" \
    -d "$DB_NAME" --clean --if-exists
}
