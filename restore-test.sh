#!/usr/bin/env bash
# Restore drill: restore a snapshot into a throwaway local database container
# and leave it running so you can test it by hand. Needs only Docker, and
# works as a single downloaded file — no clone required.
#
#   ./restore-test.sh                          # repo credentials from ./.env
#   ENV_FILE=prod.env ./restore-test.sh        # ...or from another file
#   RESTORE_VERSION=v0.1.0 ./restore-test.sh   # test with that release's image
#   RESTORE_VERSION=local ./restore-test.sh    # build from this clone instead
#
# Values already exported in your shell win over the env file; anything
# missing from both is prompted for. RESTORE_PORT overrides the local port.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_REPO="${RESTORE_IMAGE_REPO:-ghcr.io/codeaddictx10/db-backup}"
RESTIC_IMAGE=restic/restic:0.18.0
NET=restore-test
CTR=restore-test-db
ENV_FILE="${ENV_FILE:-.env}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# ---------- 1. docker ----------
command -v docker >/dev/null 2>&1 || die "Docker is required. Install Docker Desktop (macOS/Windows) or Docker Engine (Linux), then re-run."
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start it, then re-run."

# ---------- 2. repository credentials ----------
# Read KEY=value from the env file without sourcing it: values such as
# BACKUP_CRON=0 4,18 * * * aren't valid shell.
env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  local v
  v=$(grep -E "^$1=" "$ENV_FILE" | tail -n 1) || return 0
  printf '%s' "${v#*=}" | sed -E "s/[[:space:]]+#.*\$//; s/^\"(.*)\"\$/\\1/; s/^'(.*)'\$/\\1/"
}

# need VAR "prompt" [secret] — shell env, then env file, then ask
need() {
  local var=$1 val="${!1:-}"
  [[ -n "$val" ]] || val=$(env_get "$var")
  if [[ -z "$val" ]]; then
    if [[ "${3:-}" == secret ]]; then read -rsp "$2: " val || true; echo
    else read -rp "$2: " val || true; fi
  fi
  [[ -n "$val" ]] || die "$var is required"
  export "$var=$val"
}

[[ -f "$ENV_FILE" ]] && echo "Using credentials from $ENV_FILE"
need RESTIC_REPOSITORY "Restic repository (s3:https://... or a local path)"
need RESTIC_PASSWORD   "Restic password" secret

# Secrets are passed as bare `-e NAME` so they never appear in `ps`
REPO_ARGS=(-e RESTIC_PASSWORD)
case "$RESTIC_REPOSITORY" in
  s3:*)
    need AWS_ACCESS_KEY_ID     "R2/S3 access key ID"
    need AWS_SECRET_ACCESS_KEY "R2/S3 secret access key" secret
    REPO_ARGS+=(-e RESTIC_REPOSITORY -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY) ;;
  *:*)
    REPO_ARGS+=(-e RESTIC_REPOSITORY) ;;
  *)
    [[ -d "$RESTIC_REPOSITORY" ]] || die "local repository not found: $RESTIC_REPOSITORY"
    REPO_ARGS+=(-e RESTIC_REPOSITORY=/repo -v "$(cd "$RESTIC_REPOSITORY" && pwd):/repo") ;;
esac

restic_run() { docker run --rm "${REPO_ARGS[@]}" "$RESTIC_IMAGE" "$@"; }

# ---------- 3. pick a snapshot ----------
log "Reading snapshots from $RESTIC_REPOSITORY"
LIST=$(restic_run snapshots) || die "could not read the repository — check the URL and credentials"

SNAPS=()
while IFS= read -r line; do SNAPS+=("$line"); done < <(grep -E '^[0-9a-f]{8}[[:space:]]' <<<"$LIST" || true)
N=${#SNAPS[@]}
(( N )) || die "no snapshots in this repository"

echo
printf '      %s\n' "$(head -n 1 <<<"$LIST")"
for i in "${!SNAPS[@]}"; do printf '%4d) %s\n' $((i + 1)) "${SNAPS[$i]}"; done
echo
read -rp "Snapshot to restore [1-$N, Enter = latest]: " PICK || true
PICK=${PICK:-$N}
[[ "$PICK" =~ ^[0-9]+$ ]] && (( PICK >= 1 && PICK <= N )) || die "invalid choice: $PICK"
SNAP=${SNAPS[$((PICK - 1))]%% *}

INFO=$(restic_run snapshots "$SNAP" --json)
DUMP_PATH=$(grep -o '"paths":\["[^"]*"' <<<"$INFO" | head -n 1 | sed 's/.*\["//; s/"$//' || true)
TAG=$(grep -o '"tags":\["[^"]*"' <<<"$INFO" | head -n 1 | sed 's/.*\["//; s/"$//' || true)

# ---------- 4. engine, version, target db ----------
# The dump's extension (driver_ext) tells us the engine
case "$DUMP_PATH" in
  *.sql.gz)     ENGINE=mysql;    NAME=MySQL;      IMG=mysql;    PREFIX=mysql; VER=8.4; PORT=3306;  HOST_PORT=${RESTORE_PORT:-3307} ;;
  *.dump)       ENGINE=postgres; NAME=PostgreSQL; IMG=postgres; PREFIX=pg;    VER=16;  PORT=5432;  HOST_PORT=${RESTORE_PORT:-5433} ;;
  *.archive.gz) ENGINE=mongodb;  NAME=MongoDB;    IMG=mongo;    PREFIX=mongo; VER=7;   PORT=27017; HOST_PORT=${RESTORE_PORT:-27018} ;;
  *) die "can't tell the engine from the snapshot path: ${DUMP_PATH:-<none>}" ;;
esac
log "Snapshot $SNAP is a $NAME dump ($(basename "$DUMP_PATH"))"

read -rp "$NAME server version [$VER]: " v || true
VER=${v:-$VER}

DB=""
if [[ $ENGINE != mongodb ]]; then   # mongorestore restores to the dump's own db names
  DEF_DB=${DB_NAME:-$(env_get DB_NAME)}
  DEF_DB=${DEF_DB:-$TAG}
  read -rp "Database name to restore into [$DEF_DB]: " v || true
  DB=${v:-$DEF_DB}
  [[ -n "$DB" ]] || die "database name is required"
fi

PW=$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')
case $ENGINE in
  mysql)
    DB_USER=root
    DB_ENV=(-e MYSQL_ROOT_PASSWORD="$PW" -e MYSQL_DATABASE="$DB")
    URL="mysql://root:$PW@127.0.0.1:$HOST_PORT/$DB"
    SHELL_CMD="docker exec -it $CTR mysql -uroot -p$PW $DB" ;;
  postgres)
    DB_USER=postgres
    DB_ENV=(-e POSTGRES_PASSWORD="$PW" -e POSTGRES_DB="$DB")
    URL="postgresql://postgres:$PW@127.0.0.1:$HOST_PORT/$DB"
    SHELL_CMD="docker exec -it $CTR psql -U postgres -d $DB" ;;
  mongodb)
    DB_USER=root
    DB_ENV=(-e MONGO_INITDB_ROOT_USERNAME=root -e MONGO_INITDB_ROOT_PASSWORD="$PW")
    URL="mongodb://root:$PW@127.0.0.1:$HOST_PORT/?authSource=admin"
    SHELL_CMD="docker exec -it $CTR mongosh -u root -p $PW" ;;
esac

# ---------- 5. backup image ----------
# publish.yml names tags <prefix><major> (mysql8, pg16, mongo7), so any
# version added there is found here without changes.
RELEASE="${RESTORE_VERSION:-}"
PUB_IMG="$IMAGE_REPO:$PREFIX${VER%%.*}${RELEASE:+-$RELEASE}"

if [[ "$RELEASE" != local ]] && log "Pulling $PUB_IMG" && docker pull -q "$PUB_IMG" >/dev/null 2>&1; then
  BACKUP_IMG=$PUB_IMG
elif [[ -z "$RELEASE" || "$RELEASE" == local ]] && [[ -f "$SCRIPT_DIR/Dockerfile" ]]; then
  # Not published (or local asked for): build from this clone
  BACKUP_IMG="db-backup:restore-test-$IMG$VER"
  log "Building $BACKUP_IMG from $SCRIPT_DIR (first build takes a minute)"
  docker build -q --build-arg BASE_IMAGE="$IMG:$VER" \
    --build-arg TARGETARCH="$(docker version -f '{{.Server.Arch}}')" \
    -t "$BACKUP_IMG" "$SCRIPT_DIR" >/dev/null
elif [[ "$RELEASE" == local ]]; then
  die "RESTORE_VERSION=local builds from the repo — run the script from a clone"
elif [[ -n "$RELEASE" ]]; then
  # A named release must be used as-is, never swapped for a local build
  die "couldn't pull $PUB_IMG — check that release exists and publishes $NAME ${VER%%.*}"
else
  die "couldn't pull $PUB_IMG — add $NAME ${VER%%.*} to publish.yml, or run from a clone to build it"
fi

# ---------- 6. throwaway database ----------
if docker container inspect "$CTR" >/dev/null 2>&1; then
  read -rp "A '$CTR' container already exists. Replace it? [y/N]: " v || true
  [[ "${v:-}" =~ ^[Yy] ]] || die "aborted — remove it yourself with: docker rm -f $CTR"
  docker rm -f "$CTR" >/dev/null
fi
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

log "Starting $NAME $VER as '$CTR' on 127.0.0.1:$HOST_PORT"
docker run -d --name "$CTR" --hostname "$CTR" --network "$NET" \
  -p "127.0.0.1:$HOST_PORT:$PORT" "${DB_ENV[@]}" "$IMG:$VER" >/dev/null

# Probe over the container's network address: every image's init phase
# runs a temporary server that isn't reachable there, so "ready" means
# the real server is up.
db_ready() {
  case $ENGINE in
    mysql)    docker exec -e MYSQL_PWD="$PW" "$CTR" mysql -h "$CTR" -uroot -e 'SELECT 1' ;;
    postgres) docker exec "$CTR" pg_isready -h "$CTR" -U postgres -d "$DB" ;;
    mongodb)  docker exec "$CTR" mongosh --quiet --host "$CTR" -u root -p "$PW" --eval 'db.runCommand({ping: 1})' ;;
  esac >/dev/null 2>&1
}
log "Waiting for $NAME to accept connections"
for i in $(seq 1 90); do
  db_ready && break
  if (( i == 90 )); then docker logs --tail 30 "$CTR"; die "$NAME didn't become ready within 3 minutes"; fi
  sleep 2
done

# ---------- 7. restore (the same restore.sh production uses) ----------
log "Restoring snapshot $SNAP"
docker run --rm --network "$NET" "${REPO_ARGS[@]}" \
  -e DB_ENGINE="$ENGINE" -e DB_HOST="$CTR" -e DB_PORT="$PORT" \
  -e DB_USER="$DB_USER" -e DB_PASSWORD="$PW" -e DB_NAME="$DB" \
  -e DB_URI="mongodb://root:$PW@$CTR:$PORT/?authSource=admin" \
  -e BACKUP_LABEL="$TAG" -e RESTORE_SKIP_ROLES=true \
  -e I_UNDERSTAND_THIS_OVERWRITES=yes \
  --entrypoint /app/restore.sh "$BACKUP_IMG" "$SNAP" \
  || die "restore failed — '$CTR' is left running for inspection (docker logs $CTR)"

# ---------- 8. row counts ----------
show_counts() {
  case $ENGINE in
    mysql)
      local q="" t
      while IFS= read -r t; do
        q+="${q:+ UNION ALL }SELECT '$t' AS \`table\`, COUNT(*) AS \`rows\` FROM \`$t\`"
      done < <(docker exec -e MYSQL_PWD="$PW" "$CTR" mysql -uroot -N -B -e 'SHOW TABLES' "$DB")
      if [[ -n "$q" ]]; then docker exec -e MYSQL_PWD="$PW" "$CTR" mysql -uroot -t -e "$q" "$DB"
      else echo "(no tables)"; fi ;;
    postgres)
      docker exec "$CTR" psql -U postgres -d "$DB" -c "
        SELECT table_schema || '.' || table_name AS \"table\",
               (xpath('/row/c/text()', query_to_xml(format('SELECT count(*) AS c FROM %I.%I',
                 table_schema, table_name), false, true, '')))[1]::text::bigint AS \"rows\"
        FROM information_schema.tables
        WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
        ORDER BY 1" ;;
    mongodb)
      docker exec "$CTR" mongosh --quiet -u root -p "$PW" --eval '
        db.getMongo().getDBNames().filter(d => !["admin", "config", "local"].includes(d)).forEach(d => {
          const s = db.getSiblingDB(d);
          s.getCollectionNames().forEach(c => print(`${d}.${c}  ${s.getCollection(c).countDocuments()}`));
        })' ;;
  esac
}
log "Row counts — compare these against production"
show_counts || echo "(couldn't read row counts — check by hand)"

# ---------- 9. hand-off ----------
cat <<EOF

==> Restored snapshot $SNAP into a throwaway $NAME $VER. It keeps running until you remove it.

  host      127.0.0.1
  port      $HOST_PORT
  user      $DB_USER
  password  $PW${DB:+
  database  $DB}

  URL       $URL
  shell     $SHELL_CMD

  teardown  docker rm -f $CTR && docker network rm $NET
EOF
