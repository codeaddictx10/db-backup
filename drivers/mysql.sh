driver_ext() { echo "sql.gz"; }

driver_dump() {
  # 9.x mysqldump also dumps masking policies, which a least-privilege user
  # can't read, so it logs an error every run. 8.4 rejects the flag outright.
  local opts=()
  [[ $(mysqldump --help) == *--masking-policies* ]] && opts+=(--skip-masking-policies)

  MYSQL_PWD="$DB_PASSWORD" mysqldump \
    -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" \
    --single-transaction --quick --routines --triggers --events \
    --no-tablespaces --set-gtid-purged=OFF "${opts[@]}" \
    "$DB_NAME" | gzip
}

driver_restore() {
  gunzip -c | MYSQL_PWD="$DB_PASSWORD" mysql \
    -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" "$DB_NAME"
}
