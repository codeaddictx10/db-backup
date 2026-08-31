ARG BASE_IMAGE=mysql:8.4
FROM ${BASE_IMAGE}

ARG TARGETARCH          # <- declared, not assigned; BuildKit supplies it
ARG SUPERCRONIC_VERSION=v0.2.33

COPY --from=restic/restic:0.18.0 /usr/bin/restic /usr/local/bin/restic

RUN set -eux; \
    if   command -v microdnf >/dev/null; then microdnf install -y util-linux && microdnf clean all; \
    elif command -v dnf      >/dev/null; then dnf install -y util-linux && dnf clean all; \
    elif command -v apt-get  >/dev/null; then apt-get update && apt-get install -y --no-install-recommends util-linux && rm -rf /var/lib/apt/lists/*; \
    elif command -v apk      >/dev/null; then apk add --no-cache util-linux bash; \
    else echo "no supported package manager" >&2; exit 1; fi; \
    command -v curl >/dev/null || { echo "FATAL: curl missing from base image" >&2; exit 1; }

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) SHA1=71b0d58cc53f6bd72cf2f293e09e294b79c666d8 ;; \
      arm64) SHA1=e0f0c06ebc5627e43b25475711e694450489ab00 ;; \
      arm)   SHA1=0d3e3da1eeceaa34991d44b48aecfcbb9d9fba5a ;; \
      *) echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSLo /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
    echo "${SHA1}  /usr/local/bin/supercronic" | sha1sum -c -; \
    chmod +x /usr/local/bin/supercronic /usr/local/bin/restic

COPY entrypoint.sh backup.sh restore.sh /app/
COPY drivers/   /app/drivers/
COPY notifiers/ /app/notifiers/

RUN chmod +x /app/*.sh  /app/drivers/*.sh /app/notifiers/*.sh \
 && mkdir -p /state /cache /app/hooks

ENV DB_ENGINE=mysql \
    NOTIFIER=telegram \
    BACKUP_CRON="0 4,18 * * *" \
    RETENTION="7d" \
    MIN_INTERVAL_HOURS=10 \
    RESTIC_CACHE_DIR=/cache/restic

VOLUME ["/state", "/cache"]

ENTRYPOINT ["/app/entrypoint.sh"]
