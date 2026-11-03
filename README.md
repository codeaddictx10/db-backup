# db-backup

Scheduled, encrypted database backups to any S3-compatible storage (built for Cloudflare R2), with Telegram/Slack notifications and a tested restore path.

One image, any database engine. Twice-daily by default, 7-day rolling retention, catch-up after host reboots.

---

## What it does

- Dumps your database on a cron schedule from a sidecar container
- Compresses, **encrypts client-side**, and uploads via [restic](https://restic.net) to R2/S3
- Prunes anything older than the retention window on every run
- Notifies Telegram or Slack on start, success, and failure — naming the stage that failed
- Runs a catch-up backup on container start, so a host reboot doesn't silently skip a window
- Restores to any target with one command

**Engines:** MySQL, PostgreSQL, MongoDB (adding one is an 8-line file — see [Drivers](#drivers))

---

## Why it's built this way

Three decisions drive everything else. Understanding them will save you from breaking it later.

**Engine-specific code lives in one file per engine.** `backup.sh` never knows what database it's talking to — it calls `driver_dump` and `driver_ext`. That's why adding Mongo didn't require touching the backup logic, and why you can point this at a managed database in another datacentre without changing the image.

**The dump goes to a temp file, not piped straight into restic.** If `mysqldump` dies at 80%, `set -o pipefail` catches it and the run aborts *before* restic snapshots a truncated dump. Streaming directly would cheerfully archive half a database and report success. This is the most dangerous mistake available in a backup script.

**Retention is `restic forget`, never an S3 lifecycle rule.** restic's pack files don't map one-to-one onto daily snapshots. A lifecycle rule that deletes objects by age will silently corrupt the repository. Leave R2 lifecycle rules **off**.

---

## Quick start

### 1. Create the R2 bucket

Cloudflare dashboard → R2 → create bucket → **Manage API Tokens** → create an **Object Read & Write** token scoped to that single bucket. Don't use an account-wide token.

### 2. Create the backup DB user

Least privilege — root is unnecessary.

```sql
-- MySQL
CREATE USER 'backup'@'%' IDENTIFIED BY 'change-me';
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES ON app_production.* TO 'backup'@'%';
FLUSH PRIVILEGES;
```

`SHOW VIEW` and `TRIGGER` are required by `--routines --triggers`. Omit them and the dump fails partway through.

```sql
-- PostgreSQL
CREATE USER backup WITH PASSWORD 'change-me';
GRANT CONNECT ON DATABASE app_production TO backup;
GRANT USAGE ON SCHEMA public TO backup;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO backup;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO backup;
```

### 3. Generate a restic passphrase

```bash
openssl rand -base64 32
```

> **Store this in a password manager before you run anything.** Encryption is client-side. Lose this passphrase and every snapshot in R2 is permanently unreadable. Cloudflare cannot recover it.

### 4. Write your `.env`

```bash
# ---------- timezone ----------
# Without this, "0 4,18 * * *" fires at 04:00 UTC
TZ=Africa/Lagos

# ---------- database ----------
DB_ENGINE=mysql
DB_HOST=mysql                      # compose service name, IP, or managed-DB endpoint
DB_PORT=3306
DB_USER=backup
DB_PASSWORD=change-me
DB_NAME=app_production

# ---------- schedule & retention ----------
BACKUP_CRON=0 4,18 * * *
RETENTION=7d
MIN_INTERVAL_HOURS=10              # MUST be below the shortest gap between runs
RUN_ON_START=true
BACKUP_LABEL=idice-prod            # restic tag; scopes retention per database

# ---------- restic -> Cloudflare R2 ----------
RESTIC_REPOSITORY=s3:https://<ACCOUNT_ID>.r2.cloudflarestorage.com/<BUCKET_NAME>
AWS_ACCESS_KEY_ID=<R2_ACCESS_KEY_ID>
AWS_SECRET_ACCESS_KEY=<R2_SECRET_ACCESS_KEY>
RESTIC_PASSWORD=<long-random-passphrase>
RESTIC_CACHE_DIR=/cache/restic

# ---------- notifications ----------
NOTIFIER=telegram
TELEGRAM_BOT_TOKEN=1234567890:AAxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
TELEGRAM_CHAT_ID=-1001234567890

# NOTIFIER=slack
# SLACK_WEBHOOK_URL=https://hooks.slack.com/services/xxx/yyy/zzz
```

```bash
chmod 600 .env
echo ".env" >> .gitignore
```

### 5. Deploy

```yaml
services:
  backup:
    image: ghcr.io/<you>/db-backup:mysql8
    restart: unless-stopped
    env_file: .env
    networks: [backend]
    volumes:
      - restic-cache:/cache
      - backup-state:/state
      - ./hooks:/app/hooks:ro

volumes:
  restic-cache:
  backup-state:

networks:
  backend:
    external: true
```

```bash
docker compose up -d backup
docker compose logs -f backup
```

You should see: config validated → repository initialised → startup backup → Telegram success → handoff to supercronic.

### 6. Run the restore drill

Do this **today**. Until a restore has produced correct row counts, you have an upload job, not a backup.

On any machine with Docker — no clone needed:

```bash
VERSION=v0.2.0   # the release your backup container runs
curl -fsSLO https://raw.githubusercontent.com/codeaddictx10/db-backup/$VERSION/restore-test.sh
ENV_FILE=/path/to/your/.env RESTORE_VERSION=$VERSION bash restore-test.sh
```

It restores a snapshot you pick into a throwaway local database and leaves it running for you to check. Production is never touched. See [The drill](#the-drill--never-rehearse-against-production).

---

## Configuration reference

### Runtime (environment variables)

| Variable | Default | Notes |
|---|---|---|
| `TZ` | `UTC` | Set it, or cron times are UTC |
| `DB_ENGINE` | `mysql` | `mysql` \| `postgres` \| `mongodb` |
| `DB_HOST` | — | Service name, IP, or remote endpoint |
| `DB_PORT` | engine default | |
| `DB_USER` | — | |
| `DB_PASSWORD` | — | |
| `DB_NAME` | — | Required |
| `DB_URI` | — | MongoDB only |
| `BACKUP_CRON` | `0 4,18 * * *` | Standard 5-field cron |
| `RETENTION` | `7d` | Passed to `restic forget --keep-within` |
| `MIN_INTERVAL_HOURS` | `10` | Gate: skip if a backup succeeded this recently |
| `RUN_ON_START` | `true` | Catch-up backup on container start |
| `BACKUP_PAUSED` | `false` | `true` skips every run (cron and startup) and sends a "paused" notification instead |
| `BACKUP_LABEL` | `$DB_NAME` | restic tag; scopes retention |
| `RESTIC_REPOSITORY` | — | Required |
| `RESTIC_PASSWORD` | — | Required. Irrecoverable if lost |
| `AWS_ACCESS_KEY_ID` | — | Required for `s3:` repositories |
| `AWS_SECRET_ACCESS_KEY` | — | Required for `s3:` repositories |
| `RESTIC_CACHE_DIR` | `/cache/restic` | Persist this volume |
| `NOTIFIER` | `telegram` | `telegram` \| `slack` \| `none` |
| `TELEGRAM_BOT_TOKEN` | — | |
| `TELEGRAM_CHAT_ID` | — | Negative for groups |
| `SLACK_WEBHOOK_URL` | — | |

**`MIN_INTERVAL_HOURS` must sit below your shortest gap between runs.** At 04:00 and 18:00 the gaps are 10h and 14h, so `10` is correct. Set it to `20` and your 18:00 backup is skipped every day.

### Build-time (build args, not env vars)

`ARG` values exist only while the image is built. Setting them in compose's `environment:` does nothing — the binaries are already baked in.

| Arg | Default | Purpose |
|---|---|---|
| `BASE_IMAGE` | `mysql:8.4` | Supplies the DB client at the right version |
| `SUPERCRONIC_VERSION` | `v0.2.33` | |
| `SUPERCRONIC_SHA1` | — | Must match your target arch |
| `TARGETARCH` | `amd64` | `arm64` on ARM hosts |

```yaml
  backup:
    build:
      context: ./db-backup
      args:
        BASE_IMAGE: ${BASE_IMAGE:-mysql:8.4}
```

Changing a build arg requires `docker compose build`, not `up`.

**Why the base image is the version selector:** `mysqldump` and `pg_dump` must match their server's major version, or dumps fail or silently drop objects. The official `mysql:8.4` and `postgres:16` images ship exactly the right client. That's why this publishes one tag per engine version rather than one fat image.

---

## Deployment topologies

The only hard requirement is that the backup container can reach the database over a network.

### Separate stacks, shared external network — recommended

Keeps backups independently deployable: `docker compose down` on your app doesn't take backups with it.

```bash
docker network create backend
```

Both compose files then declare:

```yaml
networks:
  backend:
    external: true
```

`DB_HOST=mysql` still resolves — Docker DNS works across stacks on a shared network.

Trade-off: `depends_on: condition: service_healthy` doesn't work across stacks, so the startup backup may fire before the database is ready. On a box that reboots often, set `RUN_ON_START=false`; cron picks up the next window either way.

### Same compose file

Simplest, and gives you a proper readiness gate:

```yaml
  mysql:
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      interval: 10s
      timeout: 5s
      retries: 5

  backup:
    depends_on:
      mysql:
        condition: service_healthy
```

Plain `depends_on` only waits for the container to *start*, not for MySQL to accept connections — you'll get a spurious failure notification on every reboot.

### Database on the host, or not in Docker

```yaml
  backup:
    extra_hosts:
      - "host.docker.internal:host-gateway"
```

with `DB_HOST=host.docker.internal`. Preferred over `network_mode: host`, which discards network isolation for the whole container.

### Managed database

Just set `DB_HOST` to the endpoint. No other changes.

---

## Drivers

Each driver exposes exactly two functions. `backup.sh` sources `drivers/$DB_ENGINE.sh` and never knows which engine it got.

```bash
driver_ext()      # file extension
driver_dump()     # writes compressed dump to stdout
driver_restore()  # reads dump from stdin, loads into target
```

Adding an engine is one file — no changes to `backup.sh`:

```bash
# drivers/mariadb.sh
driver_ext()  { echo "sql.gz"; }
driver_dump() {
  MYSQL_PWD="$DB_PASSWORD" mariadb-dump \
    -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" \
    --single-transaction --quick "$DB_NAME" | gzip
}
driver_restore() {
  gunzip -c | MYSQL_PWD="$DB_PASSWORD" mariadb \
    -h "$DB_HOST" -P "${DB_PORT:-3306}" -u "$DB_USER" "$DB_NAME"
}
```

---

## Notifiers

Same pattern. One function:

```bash
notify_send <start|success|fail> <message>
```

Two rules built into every implementation:

- **A notifier never fails the backup.** Telegram being down is not a backup failure. Every call ends in `|| true`.
- **Payloads are JSON-escaped.** An unescaped quote in a DB name silently breaks the request — no notification, no error.

An unknown `NOTIFIER` value falls back to `none` rather than erroring: a typo should cost you notifications, not backups.

### Failure messages name the stage

```
❌ idice-prod — fail
Failed during: database dump
```

The stage is tracked through the run, so you know whether it was the dump, the upload, or the prune before you SSH in.

### Getting Telegram credentials

1. Message `@BotFather`, send `/newbot` → you get the token
2. Send any message to your new bot (bots can't message you first)
3. `curl https://api.telegram.org/bot<TOKEN>/getUpdates` → read `result[0].message.chat.id`

For a group: add the bot, send a message there, hit `getUpdates` again. Group IDs are negative, usually starting `-100`.

### Custom notifier

```yaml
    volumes:
      - ./notifiers:/app/notifiers:ro
    environment:
      NOTIFIER: discord
```

This shadows *all* notifiers, so your mounted directory must include `none.sh` or the fallback breaks.

---

## Hooks

Optional extension points. Absent = no-op.

| Hook | When | On failure |
|---|---|---|
| `pre-backup.sh` | After gate and lock, before dump | **Aborts the run** |
| `post-backup.sh` | After prune succeeds | Warns only |

That asymmetry is deliberate. A failed quiesce means you don't want the dump that follows. A failed mirror-to-secondary doesn't undo a backup that's already safely in R2 — flipping it to "failed" would page you for nothing.

Hooks inherit the environment, including `$SNAPSHOT_ID`, `$DUMP_FILE`, `$DB_NAME`.

```yaml
    volumes:
      - ./hooks:/app/hooks:ro
```

Mount the **directory**, not individual files, so adding a hook later needs no compose change.

> **The exec-bit trap:** the image's `chmod +x` does not apply to bind-mounted files. Permissions come from the host. Run `chmod +x hooks/post-backup.sh` or the hook is silently skipped forever.

### Bind-mounting scripts

You *can* mount over `/app/backup.sh` to patch behaviour. Avoid it outside debugging: your running behaviour then lives on one VPS, outside the image, and pulling a new tag won't change it. Fold the fix back into the image and rebuild. If your VPS is running a script that isn't in the image, that's a bug you haven't hit yet.

---

## Retention

```bash
restic forget --tag "$LABEL" --group-by tags --keep-within 7d --prune
```

**`--group-by tags` is what makes retention delete anything.** By default restic splits snapshots into groups by host and path, and applies `--keep-within` to each group separately, measured from that group's newest snapshot. Every run here writes its dump to a fresh temp path, and the hostname changes whenever the container is recreated, so each snapshot ends up alone in its own group. It's then always "the newest", so it's always kept. Without this flag, nothing is ever removed and storage grows forever. Grouping by tag puts all of one database's snapshots into a single group.

**Use `--keep-within`, not `--keep-daily`.** `--keep-daily 7` keeps the last snapshot of each of the last 7 days — with two runs a day it silently discards your 04:00 backup every day. `--keep-within 7d` keeps everything inside the window: all 14 snapshots.

`--tag "$LABEL"` scopes pruning. Several containers can share one bucket with different labels and each prunes only its own snapshots. Get this wrong and one database's retention deletes another's.

Storage plateaus rather than growing: each run prunes anything past the window. Because restic deduplicates, 14 snapshots of a slowly-changing database cost well under 14× one dump.

---

## Restoring

Two different jobs. Don't mix them up:

- **Checking a backup works?** Use [the drill](#the-drill--never-rehearse-against-production): `restore-test.sh`. It restores into a throwaway copy and is safe to run any time.
- **Production is broken and you need the data back?** Use [Restore](#restore) below. It **overwrites the live database**.

### List snapshots

```bash
docker compose exec backup restic snapshots --tag idice-prod
```

### Restore

```bash
docker compose run --rm \
  -e I_UNDERSTAND_THIS_OVERWRITES=yes \
  --entrypoint /app/restore.sh backup latest
```

Pass a snapshot ID instead of `latest` for a specific point in time.

The `I_UNDERSTAND_THIS_OVERWRITES` guard isn't theatre. Restore is the one destructive operation here, and it gets run by someone tired at 3am during an outage.

### The drill — never rehearse against production

One file, any machine with Docker (your laptop or the server) — no clone needed. Download it from the release you run in production, so the drill tests the same code:

```bash
VERSION=v0.2.0   # the release your backup container runs
curl -fsSLO https://raw.githubusercontent.com/codeaddictx10/db-backup/$VERSION/restore-test.sh

RESTORE_VERSION=$VERSION bash restore-test.sh                           # uses .env in the current folder
ENV_FILE=/srv/backup/.env RESTORE_VERSION=$VERSION bash restore-test.sh  # or point at your deploy's .env
```

Download it with `curl -O`, as above. Don't pipe it into `bash`: the script reads your answers from the keyboard, and with `curl | bash` it would read its own source code instead.

`.env` is looked up in the folder you run the command from, not next to the script. With no env file, the script just asks for everything.

Which backup image it restores with:

| `RESTORE_VERSION` | Image | Use it for |
|---|---|---|
| `v0.1.0` (any release) | `ghcr.io/codeaddictx10/db-backup:mysql8-v0.1.0` etc. | testing exactly what production runs |
| unset | the moving tag, e.g. `:mysql8` (latest `main`) | quick checks |
| `local` | built from the clone the script is in | testing unreleased changes |

The script works out the image name from the version you type: `<prefix><major>`, so MySQL `8.4` uses `mysql8`, PostgreSQL `17` uses `pg17` and MongoDB `8` uses `mongo8`. Add a version to the `publish.yml` matrix with a tag following that pattern, and the drill finds it with no change to the script. If the image isn't published, the script builds it from the clone it's in. Outside a clone it stops with an error, and it never swaps a named `RESTORE_VERSION` for a local build.

Needs only Docker — it stops and tells you if Docker is missing or not running. It reads `RESTIC_REPOSITORY`, `RESTIC_PASSWORD` and the R2 keys from the env file (shell env wins; anything missing is prompted for), then:

1. lists the snapshots and asks which one to restore (Enter = latest)
2. detects the engine from the dump's extension and asks for the server version and target database name
3. starts a throwaway `restore-test-db` container on `127.0.0.1` — MySQL `3307`, Postgres `5433`, Mongo `27018` (override with `RESTORE_PORT`)
4. pulls the matching backup image (or builds it, see the table above) and runs the same `restore.sh` production uses against it
5. prints every table with its row count, plus the connection URL, a shell command, and the teardown command

The target is always the throwaway container — `DB_HOST` from your `.env` is never used. Compare the row counts against production, test by hand, then:

```bash
docker rm -f restore-test-db && docker network rm restore-test
```

Test restores set `RESTORE_SKIP_ROLES=true`: Postgres restores with `--no-owner --no-acl` (the fresh server doesn't have production's roles) and Mongo skips the `admin` database (so production's users don't replace the throwaway server's root login). Production restores are unchanged.

#### By hand

```bash
# throwaway target
docker run -d --name restore-test --network backend \
  -e MYSQL_ROOT_PASSWORD=test -e MYSQL_DATABASE=app_production \
  mysql:8.4

# restore into it
docker compose run --rm \
  -e DB_HOST=restore-test -e DB_USER=root -e DB_PASSWORD=test \
  -e I_UNDERSTAND_THIS_OVERWRITES=yes \
  --entrypoint /app/restore.sh backup latest

# verify with row counts, not "no errors"
docker exec -it restore-test mysql -uroot -ptest app_production \
  -e "SHOW TABLES; SELECT COUNT(*) FROM users;"

docker rm -f restore-test
```

Overriding `DB_HOST` on the command line works because it's an env var rather than a hardcoded service name — the same image restores anywhere.

### Pausing backups while you test

Set `BACKUP_PAUSED=true` on the `backup` service and `docker compose up -d backup`. The container stays up and `restore.sh` still works, but every scheduled run (and the startup catch-up) exits immediately and sends a ⏸️ "paused" notification instead of dumping — so a 04:00 backup can't land mid-drill and you can't forget it's off. Set it back to `false` and restart to resume.

**Repeat quarterly.** Put it in a calendar.

### Recovery window

Twice daily means worst-case data loss is whatever was written since the last run — up to 14 hours across the overnight gap. If that's unacceptable for a given database, the fix isn't more frequent dumps, it's binlog shipping for point-in-time recovery. Different setup, worth it only if the data justifies it.

---

## Building and publishing

```bash
echo "$GITHUB_TOKEN" | docker login ghcr.io -u <you> --password-stdin

docker build --build-arg BASE_IMAGE=mysql:8.4 -t ghcr.io/<you>/db-backup:mysql8 .
docker push ghcr.io/<you>/db-backup:mysql8

docker build --build-arg BASE_IMAGE=postgres:16 -t ghcr.io/<you>/db-backup:pg16 .
docker push ghcr.io/<you>/db-backup:pg16
```

**Tag by engine version. Never publish `:latest`.** A consumer pulling `:latest` and silently getting a `mysqldump` that no longer matches their server is exactly the failure this design exists to avoid.

On ARM hosts, pass the matching `SUPERCRONIC_SHA1` and `TARGETARCH=arm64` — the checksum verification fails the build loudly rather than shipping the wrong binary.

---

## Operations

### Health checks

```bash
docker compose logs -f backup                                    # live
docker compose exec backup restic snapshots --tag idice-prod     # what exists
docker compose exec backup restic stats --tag idice-prod         # storage used
docker compose exec backup cat /state/last-success               # last success time
```

### Force a run

```bash
docker compose exec backup rm -f /state/last-success
docker compose exec backup /app/backup.sh
```

### Weekly integrity check

Verifies stored data still decrypts correctly — catches silent corruption long before you need it. Add as a second cron line or a host cron:

```bash
docker compose exec backup restic check --read-data-subset=5%
```

---

## Troubleshooting

**Backup runs at the wrong hour** — `TZ` isn't set. Supercronic reads the container timezone; without it, `0 4,18 * * *` is UTC.

**Container starts, no backup, no error** — the gate. Check `/state/last-success`; if a backup succeeded within `MIN_INTERVAL_HOURS`, it correctly skips. `rm` the stamp to force.

**`config file already exists` at startup** — wrong `RESTIC_PASSWORD` against an existing repository. It's telling you the password is wrong. Don't delete the bucket.

**Prune gets slower every week** — the `/cache` volume isn't persisted, so restic re-downloads repository metadata each run.

**Hook never runs** — missing exec bit on the host file. `chmod +x hooks/*.sh`.

**Notifications stopped, backups fine** — expected behaviour. Notifier failures never fail a run; check `docker logs` for `[notify] ... send failed`.

**Empty or truncated dump** — `backup.sh` checks for a zero-byte dump and aborts, since `mysqldump` can exit 0 having written nothing (wrong DB name, empty schema). If it fires, verify `DB_NAME` and the backup user's grants.

**Spurious failure on every reboot** — the startup backup is racing the database. Add a healthcheck with `condition: service_healthy`, or set `RUN_ON_START=false`.

**Dump fails on `SHOW CREATE VIEW` or triggers** — missing `SHOW VIEW` / `TRIGGER` grants on the backup user.

---

## Security notes

- **Encryption is client-side.** R2 stores ciphertext. Someone with your R2 keys gets unreadable bytes. Someone with your `RESTIC_PASSWORD` gets everything — treat it as the crown jewel.
- **No Docker socket is mounted anywhere.** The container reaches the database over the network as an ordinary client. Mounting `/var/run/docker.sock` grants root-equivalent host access, and `:ro` on the socket does nothing to prevent it — the Docker API is HTTP over that socket, so read-only on the *file* doesn't make the *API* read-only.
- **Least-privilege DB user.** No root required.
- **Scope R2 tokens to one bucket.**
- `chmod 600 .env`, and keep it out of git.

---

## What you end up with

One sidecar container per database. Twice-daily encrypted snapshots in R2, a rolling 7-day window (14 snapshots), catch-up after host reboots, Telegram alerts on start, success, and failure with the failing stage named, and a restore path you've actually tested.
