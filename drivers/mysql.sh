driver_ext() { echo "sql.gz"; }

driver_dump() {
  MYSQL_PWD="$DB_PASSWORD" mysqldump \
    -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" \
    --single-transaction --quick --routines --triggers --events \
    --no-tablespaces --set-gtid-purged=OFF \
    "$DB_NAME" | gzip
}

driver_restore() {
  gunzip -c | MYSQL_PWD="$DB_PASSWORD" mysql \
    -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" "$DB_NAME"
}
