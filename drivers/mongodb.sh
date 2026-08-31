driver_ext() { echo "archive.gz"; }

driver_dump() {
  mongodump --uri="$DB_URI" --archive --gzip
}

driver_restore() {
  mongorestore --uri="$DB_URI" --archive --gzip --drop
}
